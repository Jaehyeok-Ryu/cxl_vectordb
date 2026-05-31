#!/bin/bash
# ==============================================================================
# profile_kernel_overhead.sh
# ==============================================================================
# This script analyzes Kernel Execution Time Breakdown for Auto NUMA Balancing
# across Phase 1 (PTE scanning), Phase 2 (NUMA Hint Faults), and Phase 3 (Migration).
# It captures both kernel-level CPU call-graphs (using perf) and system-wide
# NUMA statistics (via /proc/vmstat deltas).
# ==============================================================================

set -e

# Parameters
DURATION=30
LABEL="kernel_overhead"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/perf_results"
mkdir -p "${RESULT_DIR}"

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --duration <seconds>   Duration for perf record sampling (default: $DURATION)"
    echo "  --label <label>        Label for output files (default: $LABEL)"
    echo "  -h, --help             Display this help message"
    exit 0
}

# Parse options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --duration) DURATION="$2"; shift ;;
        --label) LABEL="$2"; shift ;;
        -h|--help) show_help ;;
        *) echo "[ERROR] Unknown option: $1"; show_help ;;
    esac
    shift
done

# Validate input (CWE-78 Command Injection prevention)
if [[ ! "$DURATION" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Duration must be a positive integer."
    exit 1
fi
if [[ ! "$LABEL" =~ ^[a-zA-Z0-9_\-]+$ ]]; then
    echo "[ERROR] Invalid label format. Only alphanumeric characters, dashes, and underscores allowed."
    exit 1
fi

# Ensure root privileges
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run as root (sudo) to access perf event registers."
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${RESULT_DIR}/${LABEL}_report_${TIMESTAMP}.txt"
PERF_DATA_FILE="${RESULT_DIR}/${LABEL}_${TIMESTAMP}.data"

echo "========================================================================" | tee "${REPORT_FILE}"
echo " KERNEL EXECUTION TIME BREAKDOWN & NUMA BALANCING PROFILE" | tee -a "${REPORT_FILE}"
echo "   Timestamp : $(date)" | tee -a "${REPORT_FILE}"
echo "   Duration  : ${DURATION} seconds" | tee -a "${REPORT_FILE}"
echo "========================================================================" | tee -a "${REPORT_FILE}"

# 1. Check NUMA Balancing State
NUMA_BALANCING=$(sysctl -n kernel.numa_balancing)
echo "[INFO] System Settings:" | tee -a "${REPORT_FILE}"
echo "   kernel.numa_balancing = ${NUMA_BALANCING}" | tee -a "${REPORT_FILE}"
if [ "${NUMA_BALANCING}" -eq 1 ]; then
    echo "   -> Auto NUMA Balancing is ENABLED. High kernel overhead expected on Agnostic/WI policies." | tee -a "${REPORT_FILE}"
else
    echo "   -> Auto NUMA Balancing is DISABLED. Low/Zero migration overhead expected." | tee -a "${REPORT_FILE}"
fi
echo "" | tee -a "${REPORT_FILE}"

# 2. Extract initial VMSTAT NUMA Balancing counters
echo "[INFO] Taking initial /proc/vmstat snapshot..."
declare -A VMSTAT_BEFORE
VMSTAT_KEYS=(
    "numa_pte_updates"
    "numa_huge_pte_updates"
    "numa_hint_faults"
    "numa_hint_faults_local"
    "numa_pages_migrated"
    "pgmigrate_success"
    "pgmigrate_fail"
)

for key in "${VMSTAT_KEYS[@]}"; do
    val=$(grep -w "$key" /proc/vmstat | awk '{print $2}')
    VMSTAT_BEFORE[$key]=${val:-0}
done

# 3. Perform Call-Stack Profiling using perf record
echo "[INFO] Starting CPU Call-Graph sampling for ${DURATION}s..."
echo "       Command: perf record -a -g -F 99 -o ${PERF_DATA_FILE} -- sleep ${DURATION}"
perf record -a -g -F 99 -o "${PERF_DATA_FILE}" -- sleep "${DURATION}"
echo "[INFO] Perf sampling completed successfully."

# 4. Extract final VMSTAT NUMA Balancing counters
echo "[INFO] Taking final /proc/vmstat snapshot..."
declare -A VMSTAT_AFTER
for key in "${VMSTAT_KEYS[@]}"; do
    val=$(grep -w "$key" /proc/vmstat | awk '{print $2}')
    VMSTAT_AFTER[$key]=${val:-0}
done

# Compute VMSTAT Deltas
echo "========================================================================" | tee -a "${REPORT_FILE}"
echo " 1. SYSTEM-WIDE NUMA BALANCING STATISTICS (Deltas over ${DURATION}s)" | tee -a "${REPORT_FILE}"
echo "========================================================================" | tee -a "${REPORT_FILE}"
printf "  %-30s : %15s | %15s / sec\n" "Metric" "Delta Total" "Rate" | tee -a "${REPORT_FILE}"
printf "  %-30s : %15s | %15s\n" "------------------------------" "---------------" "---------------" | tee -a "${REPORT_FILE}"

for key in "${VMSTAT_KEYS[@]}"; do
    diff=$(( ${VMSTAT_AFTER[$key]} - ${VMSTAT_BEFORE[$key]} ))
    rate=$(echo "scale=2; $diff / $DURATION" | bc -l)
    printf "  %-30s : %15d | %15.2f / sec\n" "$key" "$diff" "$rate" | tee -a "${REPORT_FILE}"
done
echo "" | tee -a "${REPORT_FILE}"

# 5. Extract Kernel Function execution time percentages from perf.data
echo "[INFO] Parsing perf.data flat symbol table for kernel execution breakdown..."
PERF_RAW_REPORT="${RESULT_DIR}/${LABEL}_raw_${TIMESTAMP}.txt"
perf report -i "${PERF_DATA_FILE}" --stdio -g none --percent-limit 0.0001 --sort symbol > "${PERF_RAW_REPORT}"

# Define Target Functions by Phase
declare -A CORE_FUNCS
CORE_FUNCS["task_numa_work"]="Phase 1: PTE Scan Manager"
CORE_FUNCS["change_prot_numa"]="Phase 1: PTE PROT_NONE modifier"
CORE_FUNCS["do_numa_page"]="Phase 2: NUMA Hint Fault Handler"
CORE_FUNCS["migrate_misplaced_page"]="Phase 3: Migration Trigger"
CORE_FUNCS["migrate_pages"]="Phase 3: Migration Engine"
CORE_FUNCS["copy_page"]="Phase 3: Memory Copy (DRAM <-> CXL)"
CORE_FUNCS["clear_page_erms"]="Phase 3: Zero Page allocation"
CORE_FUNCS["flush_tlb_mm_range"]="Phase 3: TLB Shootdown Initiator"
CORE_FUNCS["smp_call_function_many"]="Phase 3: Multi-Core IPI (TLB Shootdown)"

echo "========================================================================" | tee -a "${REPORT_FILE}"
echo " 2. KERNEL EXECUTION TIME BREAKDOWN (Target NUMA Functions)" | tee -a "${REPORT_FILE}"
echo "========================================================================" | tee -a "${REPORT_FILE}"
printf "  %-32s | %-12s | %-12s | %s\n" "Kernel Function" "Children %" "Self %" "Phase Context" | tee -a "${REPORT_FILE}"
printf "  %-32s | %-12s | %-12s | %s\n" "--------------------------------" "------------" "------------" "-------------------------" | tee -a "${REPORT_FILE}"

for func in "${!CORE_FUNCS[@]}"; do
    # In flat symbol view (-g none --sort symbol), output looks like:
    #      1.23%     0.05%  [k] do_numa_page
    # We match the function name at the end of the line.
    match_line=$(awk -v f="[k] $func" '$0 ~ f {print $1, $2; exit}' "${PERF_RAW_REPORT}")
    if [ -z "$match_line" ]; then
        match_line=$(awk -v f=" $func" '$0 ~ f {print $1, $2; exit}' "${PERF_RAW_REPORT}")
    fi
    
    if [ -n "$match_line" ]; then
        child_pct=$(echo "$match_line" | awk '{print $1}')
        self_pct=$(echo "$match_line" | awk '{print $2}')
    else
        child_pct="0.00%"
        self_pct="0.00%"
    fi
    
    printf "  %-32s | %-12s | %-12s | %s\n" "$func" "$child_pct" "$self_pct" "${CORE_FUNCS[$func]}" | tee -a "${REPORT_FILE}"
done

echo "" | tee -a "${REPORT_FILE}"
echo "========================================================================" | tee -a "${REPORT_FILE}"
echo " 3. INTERPRETATION & RECOMMENDATIONS" | tee -a "${REPORT_FILE}"
echo "========================================================================" | tee -a "${REPORT_FILE}"
echo "  * Phase 1 (PTE Scanning): High task_numa_work/change_prot_numa cycles indicate that the" | tee -a "${REPORT_FILE}"
echo "    kernel scanner is highly active, scanning and marking PTEs to PROT_NONE." | tee -a "${REPORT_FILE}"
echo "  * Phase 2 (NUMA Hint Fault): High do_numa_page indicates heavy context switching and" | tee -a "${REPORT_FILE}"
echo "    intermittent latency spikes as application threads hit the PROT_NONE pages." | tee -a "${REPORT_FILE}"
echo "  * Phase 3 (Migration): migrate_pages, copy_page, flush_tlb_mm_range, and smp_call_function_many" | tee -a "${REPORT_FILE}"
echo "    represent actual physical data migrations and Inter-Processor Interrupts (IPIs)." | tee -a "${REPORT_FILE}"
echo "    These are the most expensive operations. In global Agnostic or Weighted Interleave mode," | tee -a "${REPORT_FILE}"
echo "    if Auto NUMA Balancing is ON, this section will consume substantial CPU cycles." | tee -a "${REPORT_FILE}"
echo "" | tee -a "${REPORT_FILE}"
echo "[SUCCESS] Profiling completed. Breakdown saved to:" | tee -a "${REPORT_FILE}"
echo "          ${REPORT_FILE}" | tee -a "${REPORT_FILE}"
echo "========================================================================" | tee -a "${REPORT_FILE}"

cat "${REPORT_FILE}"
