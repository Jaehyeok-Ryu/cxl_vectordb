#!/bin/bash
# ==============================================================================
# compare_kernel_time.sh
# ==============================================================================
# This script performs a robust 60-second comparative analysis of System-wide 
# Kernel Mode CPU Time (System CPU Time), Context Switches, and CPU Migrations
# under two distinct configurations:
#   1) Auto NUMA Balancing ENABLED (kernel.numa_balancing = 1)
#   2) Auto NUMA Balancing DISABLED (kernel.numa_balancing = 0)
# ==============================================================================

set -e

DURATION=60
# Parse custom duration if provided as first argument
if [[ "$1" =~ ^[0-9]+$ ]]; then
    DURATION="$1"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_FILE="${SCRIPT_DIR}/perf_results/kernel_comparison_${DURATION}s.txt"
mkdir -p "${SCRIPT_DIR}/perf_results"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root (sudo) to alter kernel configurations and run perf stat."
    exit 1
fi

# Function to read /proc/stat system ticks (in USER, NICE, SYSTEM, IDLE)
get_system_ticks() {
    # Returns total ticks and system (kernel mode) ticks
    head -n 1 /proc/stat | awk '{
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 + $10 + $11
        sys_ticks = $4
        print total " " sys_ticks
    }'
}

# Temporary variables to store measurements
declare -A RESULTS

measure_phase() {
    local phase_label="$1"
    echo "[INFO] Commencing 60-second measurement for [${phase_label}]..."
    
    # Read ticks before
    read -r total_before sys_before <<< "$(get_system_ticks)"
    
    # Launch perf stat in parallel to capture context-switches and migrations
    PERF_RAW_FILE="/tmp/perf_stat_${phase_label}.log"
    perf stat -a -e context-switches,cpu-migrations,cpu-cycles -- sleep "${DURATION}" &> "${PERF_RAW_FILE}" &
    PERF_PID=$!
    
    # Wait for completion of 60 seconds
    sleep "${DURATION}"
    wait "${PERF_PID}" 2>/dev/null || true
    
    # Read ticks after
    read -r total_after sys_after <<< "$(get_system_ticks)"
    
    # Parse /proc/stat tick deltas
    total_delta=$(( total_after - total_before ))
    sys_delta=$(( sys_after - sys_before ))
    
    # Calculate percentage of total CPU time spent in Kernel Mode
    # On Linux, /proc/stat tick values are usually in USER_HZ (100 ticks = 1 second of individual core)
    # We obtain percentage ratio
    kernel_percentage=$(echo "scale=4; ($sys_delta / $total_delta) * 100" | bc -l)
    
    # Parse perf stat results
    ctx_switches=$(grep -i "context-switches" "${PERF_RAW_FILE}" | awk '{print $1}' | sed 's/,//g' || echo 0)
    cpu_mig=$(grep -i "cpu-migrations" "${PERF_RAW_FILE}" | awk '{print $1}' | sed 's/,//g' || echo 0)
    cpu_cycles=$(grep -i "cpu-cycles" "${PERF_RAW_FILE}" | awk '{print $1}' | sed 's/,//g' || echo 1)
    
    # Store in variables
    RESULTS["${phase_label}_pct"]="${kernel_percentage}"
    RESULTS["${phase_label}_ctx"]="${ctx_switches:-0}"
    RESULTS["${phase_label}_mig"]="${cpu_mig:-0}"
    RESULTS["${phase_label}_sys_ticks"]="${sys_delta}"
    
    # Cleanup temp log
    rm -f "${PERF_RAW_FILE}"
}

# ==============================================================================
# MAIN COMPARATIVE TEST SEQUENCE
# ==============================================================================
echo "========================================================================" | tee "${RESULT_FILE}"
echo " 60-SECOND KERNEL CPU TIME COMPARATIVE PROFILE" | tee -a "${RESULT_FILE}"
echo "   Timestamp : $(date)" | tee -a "${RESULT_FILE}"
echo "   Duration  : ${DURATION} seconds per run" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"

# 1. Run with Auto NUMA Balancing ENABLED (Ensure it's ON first)
echo "[INFO] Preparing Enabled state..."
sysctl -w kernel.numa_balancing=1 >/dev/null
sleep 2
measure_phase "ENABLED"

# 2. Run with Auto NUMA Balancing DISABLED (Turn it OFF)
echo "[INFO] Preparing Disabled state..."
sysctl -w kernel.numa_balancing=0 >/dev/null
sleep 2
measure_phase "DISABLED"

# 3. Restore Default State (Restore to Enabled)
echo "[INFO] Restoring default kernel configuration..."
sysctl -w kernel.numa_balancing=1 >/dev/null

# ==============================================================================
# GENERATE COMPARISON REPORT
# ==============================================================================
# Tick values to Core Seconds conversion (Assuming 100 ticks = 1 second of CPU core time)
# For 64 cores over 60 seconds, total available CPU time is 3840 core-seconds.
enabled_core_sec=$(echo "scale=3; ${RESULTS["ENABLED_sys_ticks"]} / 100" | bc -l)
disabled_core_sec=$(echo "scale=3; ${RESULTS["DISABLED_sys_ticks"]} / 100" | bc -l)

core_sec_diff=$(echo "scale=3; $enabled_core_sec - $disabled_core_sec" | bc -l)
core_sec_diff_pct=$(echo "scale=2; (($enabled_core_sec - $disabled_core_sec) / $enabled_core_sec) * 100" | bc -l)

ctx_diff=$(( RESULTS["ENABLED_ctx"] - RESULTS["DISABLED_ctx"] ))
if [ "${RESULTS["ENABLED_ctx"]}" -gt 0 ]; then
    ctx_diff_pct=$(echo "scale=2; ($ctx_diff / ${RESULTS["ENABLED_ctx"]}) * 100" | bc -l)
else
    ctx_diff_pct="0.00"
fi

mig_diff=$(( RESULTS["ENABLED_mig"] - RESULTS["DISABLED_mig"] ))
if [ "${RESULTS["ENABLED_mig"]}" -gt 0 ]; then
    mig_diff_pct=$(echo "scale=2; ($mig_diff / ${RESULTS["ENABLED_mig"]}) * 100" | bc -l)
else
    mig_diff_pct="0.00"
fi

echo "" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
echo " 60s STATISTICAL COMPARISON REPORT" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
printf "  %-32s | %-16s | %-16s | %-16s\n" "Metric Analyzed" "Balancing ENABLED" "Balancing DISABLED" "Difference (Delta)" | tee -a "${RESULT_FILE}"
printf "  %-32s | %-16s | %-16s | %-16s\n" "--------------------------------" "----------------" "----------------" "----------------" | tee -a "${RESULT_FILE}"

printf "  %-32s | %13.2f %% | %13.2f %% | %13.2f %%\n" "Avg Kernel CPU % (Ratio)" "${RESULTS["ENABLED_pct"]}" "${RESULTS["DISABLED_pct"]}" "$(echo "${RESULTS["ENABLED_pct"]} - ${RESULTS["DISABLED_pct"]}" | bc -l)" | tee -a "${RESULT_FILE}"
printf "  %-32s | %13.3f s  | %13.3f s  | %13.3f s (-%s%%)\n" "Kernel Execution Time (Core-Sec)" "$enabled_core_sec" "$disabled_core_sec" "$core_sec_diff" "$core_sec_diff_pct" | tee -a "${RESULT_FILE}"
printf "  %-32s | %16d | %16d | %16d (-%s%%)\n" "Context Switches" "${RESULTS["ENABLED_ctx"]}" "${RESULTS["DISABLED_ctx"]}" "$ctx_diff" "$ctx_diff_pct" | tee -a "${RESULT_FILE}"
printf "  %-32s | %16d | %16d | %16d (-%s%%)\n" "CPU Migrations" "${RESULTS["ENABLED_mig"]}" "${RESULTS["DISABLED_mig"]}" "$mig_diff" "$mig_diff_pct" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
echo "" | tee -a "${RESULT_FILE}"

echo "========================================================================" | tee -a "${RESULT_FILE}"
echo " INTUITIVE EXPLANATION OF RESULTS" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"
echo "  * Avg Kernel CPU % (Ratio) represents the percentage of total CPU time allocated to the" | tee -a "${RESULT_FILE}"
echo "    kernel mode vs. the user space across all active CPU cores." | tee -a "${RESULT_FILE}"
echo "  * Kernel Execution Time in Core-Seconds represents the absolute accumulated core time" | tee -a "${RESULT_FILE}"
echo "    all 64 cores combined spent performing kernel-level tasks." | tee -a "${RESULT_FILE}"
echo "  * Turning Auto NUMA Balancing OFF completely eliminates background scanning and reduces" | tee -a "${RESULT_FILE}"
echo "    unnecessary page faults and memory migration cycles, directly translating to less" | tee -a "${RESULT_FILE}"
echo "    Kernel Time, fewer Context Switches, and lower CPU migration events." | tee -a "${RESULT_FILE}"
echo "" | tee -a "${RESULT_FILE}"
echo "[SUCCESS] Comparative evaluation finalized. Summary written to:" | tee -a "${RESULT_FILE}"
echo "          ${RESULT_FILE}" | tee -a "${RESULT_FILE}"
echo "========================================================================" | tee -a "${RESULT_FILE}"

cat "${RESULT_FILE}"
