#!/bin/bash
# ==============================================================================
# compare_weighted_socket.sh
# ==============================================================================
# Performs comparative benchmarking of /sys/kernel/mm/mempolicy/weighted_interleave/socket
# options (0 vs 1) including kernel execution time breakdown (NUMA vs total kernel).
# ==============================================================================

set -e

DURATION=1000
WARMUP=30
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CXL_DIR="/home/sawi/cxl_vectordb"
RESULT_FILE="${SCRIPT_DIR}/perf_results/weighted_socket_comparison_${DURATION}s.txt"
mkdir -p "${SCRIPT_DIR}/perf_results"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root (sudo)."
    exit 1
fi

get_system_ticks() {
    head -n 1 /proc/stat | awk '{
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 + $10 + $11
        sys_ticks = $4
        print total " " sys_ticks
    }'
}

initialize_and_run() {
    local socket_val="$1"
    echo "========================================================================"
    echo "[SETUP] Initializing environment for socket = ${socket_val}"
    echo "========================================================================"
    
    echo "[INFO] Stopping vectorDB containers..."
    docker stop vectorDB_container_socket0 vectorDB_container_socket1 >/dev/null 2>&1 || true
    
    echo "[INFO] Dropping OS Page caches..."
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    echo "[INFO] Setting __auto_type = 0 and socket = ${socket_val}..."
    echo 0 > /sys/kernel/mm/mempolicy/weighted_interleave/__auto_type
    echo "${socket_val}" > /sys/kernel/mm/mempolicy/weighted_interleave/socket
    
    echo "  * Current __auto_type = $(cat /sys/kernel/mm/mempolicy/weighted_interleave/__auto_type)"
    echo "  * Current socket      = $(cat /sys/kernel/mm/mempolicy/weighted_interleave/socket)"
    
    echo "[INFO] Launching Qdrant dual instances under WEIGHTED policy..."
    cd "${CXL_DIR}"
    ./run_dual_qdrants.sh >/dev/null
    
    echo "[WARMUP] Waiting for ${WARMUP} seconds of warm-up time..."
    sleep "${WARMUP}"
}

declare -A RESULTS

measure_phase() {
    local socket_val="$1"
    
    initialize_and_run "${socket_val}"
    
    echo "[MEASURE] Commencing ${DURATION}-second profiling for socket = ${socket_val}..."
    
    # 1. Take initial vmstat snapshot
    local fault_before=$(grep -w "numa_hint_faults" /proc/vmstat | awk '{print $2}')
    fault_before=${fault_before:-0}
    local mig_before=$(grep -w "numa_pages_migrated" /proc/vmstat | awk '{print $2}')
    mig_before=${mig_before:-0}

    # 2. Write and attach bpftrace script
    local bpf_script="/tmp/numa_trace_socket_${socket_val}.bt"
    cat << 'EOF' > "${bpf_script}"
kprobe:task_numa_work { @start_scan[tid] = nsecs; }
kretprobe:task_numa_work /@start_scan[tid]/ { @total_scan_ns = sum(nsecs - @start_scan[tid]); delete(@start_scan[tid]); }
kprobe:change_prot_numa { @start_prot[tid] = nsecs; }
kretprobe:change_prot_numa /@start_prot[tid]/ { @total_prot_ns = sum(nsecs - @start_prot[tid]); delete(@start_prot[tid]); }
kprobe:do_huge_pmd_numa_page { @start_huge[tid] = nsecs; }
kretprobe:do_huge_pmd_numa_page /@start_huge[tid]/ { @total_huge_ns = sum(nsecs - @start_huge[tid]); delete(@start_huge[tid]); }
kprobe:migrate_misplaced_folio { @start_mig[tid] = nsecs; }
kretprobe:migrate_misplaced_folio /@start_mig[tid]/ { @total_mig_ns = sum(nsecs - @start_mig[tid]); delete(@start_mig[tid]); }
EOF

    local bpf_output="/tmp/bpftrace_socket_${socket_val}.log"
    bpftrace "${bpf_script}" > "${bpf_output}" 2>&1 &
    local bpf_pid=$!
    
    sleep 3
    
    # 3. Read ticks before
    read -r total_before sys_before <<< "$(get_system_ticks)"
    
    # 4. Launch perf stat
    local perf_raw="/tmp/perf_stat_socket_${socket_val}.log"
    perf stat -a -e context-switches,cpu-migrations,cpu-cycles,cycles:k -- sleep "${DURATION}" &> "${perf_raw}" &
    local perf_pid=$!
    
    wait "${perf_pid}" 2>/dev/null || true
    
    # 5. Read ticks after
    read -r total_after sys_after <<< "$(get_system_ticks)"
    
    # 6. Stop bpftrace
    kill -2 "${bpf_pid}" || true
    wait "${bpf_pid}" 2>/dev/null || true
    
    # 7. Take final vmstat snapshot
    local fault_after=$(grep -w "numa_hint_faults" /proc/vmstat | awk '{print $2}')
    fault_after=${fault_after:-0}
    local mig_after=$(grep -w "numa_pages_migrated" /proc/vmstat | awk '{print $2}')
    mig_after=${mig_after:-0}

    # Process metrics
    local fault_delta=$(( fault_after - fault_before ))
    local mig_delta=$(( mig_after - mig_before ))
    
    local total_delta=$(( total_after - total_before ))
    local sys_delta=$(( sys_after - sys_before ))
    local kernel_pct=$(echo "scale=4; ($sys_delta / $total_delta) * 100" | bc -l)
    local kernel_ms=$(echo "scale=2; ($sys_delta / 100) * 1000" | bc -l)
    
    local ctx_switches=$(grep -i "context-switches" "${perf_raw}" | awk '{print $1}' | sed 's/,//g' || echo 0)
    local cpu_mig=$(grep -i "cpu-migrations" "${perf_raw}" | awk '{print $1}' | sed 's/,//g' || echo 0)
    local kernel_cycles=$(grep -i "cycles:k" "${perf_raw}" | awk '{print $1}' | sed 's/,//g' || echo 0)
    
    local raw_scan_ns=$(grep -A 1 "@total_scan_ns:" "${bpf_output}" | tail -n 1 | grep -o '[0-9]*' || echo 0)
    local raw_prot_ns=$(grep -A 1 "@total_prot_ns:" "${bpf_output}" | tail -n 1 | grep -o '[0-9]*' || echo 0)
    local raw_huge_ns=$(grep -A 1 "@total_huge_ns:" "${bpf_output}" | tail -n 1 | grep -o '[0-9]*' || echo 0)
    local raw_mig_ns=$(grep -A 1 "@total_mig_ns:" "${bpf_output}" | tail -n 1 | grep -o '[0-9]*' || echo 0)

    # Convert to ms
    local scan_ms=$(echo "scale=4; ${raw_scan_ns:-0} / 1000000" | bc -l)
    local prot_ms=$(echo "scale=4; ${raw_prot_ns:-0} / 1000000" | bc -l)
    local huge_ms=$(echo "scale=4; ${raw_huge_ns:-0} / 1000000" | bc -l)
    local actual_mig_ms=$(echo "scale=4; ${raw_mig_ns:-0} / 1000000" | bc -l)
    
    # Hint fault time (2.2 us baseline)
    local avg_fault_lat_us=2.2
    local fault_lat_total_ms=$(echo "scale=4; ($fault_delta * $avg_fault_lat_us) / 1000" | bc -l)
    
    local total_numa_ms=$(echo "scale=4; $scan_ms + $fault_lat_total_ms + $huge_ms + $actual_mig_ms" | bc -l)
    
    # Save results
    RESULTS["SOCK_${socket_val}_pct"]="${kernel_pct}"
    RESULTS["SOCK_${socket_val}_kernel_ms"]="${kernel_ms}"
    RESULTS["SOCK_${socket_val}_ctx"]="${ctx_switches:-0}"
    RESULTS["SOCK_${socket_val}_cpu_mig"]="${cpu_mig:-0}"
    RESULTS["SOCK_${socket_val}_k_cycles"]="${kernel_cycles:-0}"
    RESULTS["SOCK_${socket_val}_faults"]="${fault_delta}"
    RESULTS["SOCK_${socket_val}_page_mig"]="${mig_delta}"
    
    RESULTS["SOCK_${socket_val}_numa_ms"]="${total_numa_ms}"
    RESULTS["SOCK_${socket_val}_scan_ms"]="${scan_ms}"
    RESULTS["SOCK_${socket_val}_fault_ms"]="${fault_lat_total_ms}"
    RESULTS["SOCK_${socket_val}_mig_ms"]="${actual_mig_ms}"
    
    rm -f "${bpf_script}" "${bpf_output}" "${perf_raw}"
}

echo "========================================================================" | tee "${RESULT_FILE}"
echo " WEIGHTED INTERLEAVE 'SOCKET' OPTION COMPARATIVE EVALUATION & KERNEL BREAKDOWN" | tee -a "${RESULT_FILE}"
echo "   Timestamp : $(date)" | tee -a "${RESULT_FILE}"
echo "   Warmup    : ${WARMUP} seconds" | tee -a "${RESULT_FILE}"
echo "   Duration  : ${DURATION} seconds" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"

measure_phase 0
measure_phase 1

print_metric() {
    local label="$1"
    local v0="$2"
    local v1="$3"
    local unit="$4"
    local diff=$(echo "$v0 - $v1" | bc -l)
    local pct_diff="0.00"
    if (( $(echo "$v0 > 0" | bc -l) )); then
        pct_diff=$(echo "scale=2; (($v0 - $v1) / $v0) * 100" | bc -l)
    fi
    # formatting diff
    if [[ "$v0" != *"."* ]]; then
        printf "  %-32s | %16d | %16d | %16d (%6.2f%%)\n" "$label" "$v0" "$v1" "$diff" "$pct_diff" | tee -a "${RESULT_FILE}"
    else
        printf "  %-32s | %13.3f %s| %13.3f %s| %13.3f %s(%6.2f%%)\n" "$label" "$v0" "$unit" "$v1" "$unit" "$diff" "$unit" "$pct_diff" | tee -a "${RESULT_FILE}"
    fi
}

echo "" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
echo " 1. SYSTEM-WIDE EVENT COUNTS (perf & vmstat) " | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
printf "  %-32s | %-16s | %-16s | %-16s\n" "Metric Analyzed" "Socket = 0" "Socket = 1" "Difference (Delta)" | tee -a "${RESULT_FILE}"
printf "  %-32s | %-16s | %-16s | %-16s\n" "--------------------------------" "----------------" "----------------" "----------------" | tee -a "${RESULT_FILE}"
print_metric "Context Switches" "${RESULTS["SOCK_0_ctx"]}" "${RESULTS["SOCK_1_ctx"]}" ""
print_metric "CPU Migrations" "${RESULTS["SOCK_0_cpu_mig"]}" "${RESULTS["SOCK_1_cpu_mig"]}" ""
print_metric "Kernel Cycles (perf)" "${RESULTS["SOCK_0_k_cycles"]}" "${RESULTS["SOCK_1_k_cycles"]}" ""
print_metric "NUMA Hint Faults" "${RESULTS["SOCK_0_faults"]}" "${RESULTS["SOCK_1_faults"]}" ""
print_metric "NUMA Page Migrations" "${RESULTS["SOCK_0_page_mig"]}" "${RESULTS["SOCK_1_page_mig"]}" ""

echo "" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
echo " 2. KERNEL EXECUTION TIME BREAKDOWN (bpftrace) " | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
printf "  %-32s | %-16s | %-16s | %-16s\n" "Execution Time Metric" "Socket = 0" "Socket = 1" "Difference" | tee -a "${RESULT_FILE}"
printf "  %-32s | %-16s | %-16s | %-16s\n" "--------------------------------" "----------------" "----------------" "----------------" | tee -a "${RESULT_FILE}"
print_metric "Kernel Avg CPU %" "${RESULTS["SOCK_0_pct"]}" "${RESULTS["SOCK_1_pct"]}" "% "
print_metric "Total Kernel Time" "${RESULTS["SOCK_0_kernel_ms"]}" "${RESULTS["SOCK_1_kernel_ms"]}" "ms "
print_metric "Total NUMA Balancing Time" "${RESULTS["SOCK_0_numa_ms"]}" "${RESULTS["SOCK_1_numa_ms"]}" "ms "
print_metric "  -> PTE Scanning Time" "${RESULTS["SOCK_0_scan_ms"]}" "${RESULTS["SOCK_1_scan_ms"]}" "ms "
print_metric "  -> Hint Fault Overhead Time" "${RESULTS["SOCK_0_fault_ms"]}" "${RESULTS["SOCK_1_fault_ms"]}" "ms "
print_metric "  -> Page Migration Time" "${RESULTS["SOCK_0_mig_ms"]}" "${RESULTS["SOCK_1_mig_ms"]}" "ms "

# Calculate remainder non-NUMA kernel time
non_numa_0=$(echo "scale=2; ${RESULTS["SOCK_0_kernel_ms"]} - ${RESULTS["SOCK_0_numa_ms"]}" | bc -l)
non_numa_1=$(echo "scale=2; ${RESULTS["SOCK_1_kernel_ms"]} - ${RESULTS["SOCK_1_numa_ms"]}" | bc -l)
print_metric "Remainder (Other Kernel Time)" "$non_numa_0" "$non_numa_1" "ms "

echo "" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
echo " 3. KERNEL TIME BREAKDOWN RATIOS " | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"

calc_ratio() {
    local part="$1"
    local total="$2"
    if (( $(echo "$total > 0" | bc -l) )); then
        echo $(echo "scale=2; ($part / $total) * 100" | bc -l)
    else
        echo "0.00"
    fi
}

r_numa_0=$(calc_ratio "${RESULTS["SOCK_0_numa_ms"]}" "${RESULTS["SOCK_0_kernel_ms"]}")
r_numa_1=$(calc_ratio "${RESULTS["SOCK_1_numa_ms"]}" "${RESULTS["SOCK_1_kernel_ms"]}")
printf "  %% Kernel Time spent on NUMA   | Socket 0: %6.2f %% | Socket 1: %6.2f %%\n" "$r_numa_0" "$r_numa_1" | tee -a "${RESULT_FILE}"

echo "" | tee -a "${RESULT_FILE}"
echo "[SUCCESS] Comparative breakdown report saved to: ${RESULT_FILE}" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"

cat "${RESULT_FILE}"
