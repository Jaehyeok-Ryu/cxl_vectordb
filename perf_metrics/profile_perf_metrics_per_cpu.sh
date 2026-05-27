#!/bin/bash
# ==============================================================================
# profile_perf_metrics_per_cpu.sh
# ==============================================================================
# 기존 profile_perf_metrics.sh의 모든 지표를 "각 CPU 코어별로" 별도 파일에
# 측정하고 파싱하여 요약해주는 확장 스크립트입니다.
# ==============================================================================

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 기본 옵션 설정
TARGET_CPUS="0,1"
DURATION=60
RUNS=3
WARMUP_TIME=15
LABEL="per_cpu_metrics"

show_help() {
  echo "사용법: $0 [옵션]"
  echo "  --cpus <목록>         측정할 CPU 코어 목록 (기본값: $TARGET_CPUS)"
  echo "  --duration <초>       각 측정 주기(Run)별 측정 시간 (기본값: $DURATION초)"
  echo "  --runs <횟수>         총 측정 횟수 (기본값: $RUNS회)"
  echo "  --warmup <초>         웜업 대기 시간 (기본값: $WARMUP_TIME초)"
  echo "  --label <라벨>        결과 저장 폴더 지정을 위한 라벨 (기본값: $LABEL)"
  echo "  -h, --help            도움말 출력"
  exit 0
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --cpus) TARGET_CPUS="$2"; shift ;;
    --duration) DURATION="$2"; shift ;;
    --runs) RUNS="$2"; shift ;;
    --warmup) WARMUP_TIME="$2"; shift ;;
    --label) LABEL="$2"; shift ;;
    -h|--help) show_help ;;
    *) echo " [Error] 알 수 없는 옵션: $1"; show_help ;;
  esac
  shift
done

if [ "$EUID" -ne 0 ]; then
  echo "  [Warning] perf stat 구동을 위해 root 권한(sudo)이 필요할 수 있습니다."
fi

# ==============================================================================
# 후보 성능 카운터 (기존 스크립트와 동일)
# ==============================================================================
CANDIDATE_EVENTS=(
  "slots"
  "topdown-mem-bound"
  "topdown-be-bound"
  "cycle_activity.stalls_l3_miss"
  "mem_inst_retired.all_loads"
  "mem_inst_retired.all_stores"
  "uncore_upi_*/unc_upi_txl_flits.all_data/"
  "uncore_cha_*/unc_cha_rxc_inserts.irq/"
  "uncore_cha_*/unc_cha_rxc_inserts.irq_rej/"
  "uncore_cha_*/unc_cha_rxc_inserts.ipq/"
  "uncore_cha_*/unc_cha_rxc_inserts.rrq/"
  "uncore_cha_*/unc_cha_rxc_occupancy.rrq/"
  "uncore_cha_*/unc_cha_rxc_inserts.wbq/"
  "uncore_cha_*/unc_cha_rxc_occupancy.wbq/"
  "uncore_cha_*/unc_cha_tor_inserts.all/"
  "uncore_cha_*/unc_cha_tor_occupancy.all/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_local_ddr/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_local_ddr/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_remote_ddr/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_remote_ddr/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_local/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_local/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_remote/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_remote/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_cxl_acc/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc/"
)

echo "[INFO] 시스템이 지원하는 하드웨어 카운터를 식별하는 중 (Dry-run)..."
SUPPORTED_EVENTS=()
FIRST_CPU=$(echo "$TARGET_CPUS" | cut -d',' -f1)

for ev in "${CANDIDATE_EVENTS[@]}"; do
  # -C 옵션을 사용했을 때 실패하는 uncore 이벤트 방지를 위해 와일드카드 처리
  ev_fixed=$(echo "$ev" | sed 's/\*/0/g')
  if sudo perf stat -C "$FIRST_CPU" -e "$ev" sleep 0.1 >/dev/null 2>&1; then
    SUPPORTED_EVENTS+=("$ev")
  elif sudo perf stat -C "$FIRST_CPU" -e "$ev_fixed" sleep 0.1 >/dev/null 2>&1; then
    SUPPORTED_EVENTS+=("$ev_fixed")
  fi
done

echo " 필터링 완료: 후보 ${#CANDIDATE_EVENTS[@]}개 중 ${#SUPPORTED_EVENTS[@]}개 이벤트 지원 확인."

if [ ${#SUPPORTED_EVENTS[@]} -eq 0 ]; then
  echo " [Error] 측정 가능한 성능 카운터가 하나도 없습니다." >&2
  exit 1
fi

if [ $WARMUP_TIME -gt 0 ]; then
  echo "[INFO] 웜업 대기 $WARMUP_TIME초..."
  sleep $WARMUP_TIME
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/perf_results/run_${LABEL}_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

echo "========================================================================="
echo " Starting Per-CPU Performance Profiling"
echo "========================================================================="
echo "   - Target CPUs      : $TARGET_CPUS"
echo "   - Save Directory   : $RESULT_DIR"
echo "   - Run Duration     : $DURATION seconds per run"
echo "   - Total Runs       : $RUNS runs"
echo "========================================================================="

EVENT_STR=$(IFS=, ; echo "${SUPPORTED_EVENTS[*]}")
IFS=',' read -ra CPU_ARRAY <<< "$TARGET_CPUS"

# ==============================================================================
# 실전 루프 (각 CPU별로 백그라운드 측정)
# ==============================================================================
for ((run=1; run<=RUNS; run++)); do
  echo " [Run $run/$RUNS] perf stat 데이터 수집 중... ($DURATION초 대기)"
  
  for cpu in "${CPU_ARRAY[@]}"; do
    RAW_LOG="$RESULT_DIR/raw_run_${run}_cpu_${cpu}.txt"
    sudo perf stat -C "$cpu" -e "$EVENT_STR" sleep "$DURATION" &> "$RAW_LOG" &
  done
  
  wait # 모든 CPU 측정이 끝날 때까지 동기화 대기
  
  echo " Run $run 완료."
  sleep 3
done

# ==============================================================================
#  수집 로그 파싱 및 평균 계산
# ==============================================================================
echo "[INFO] 수집된 perf 로그 종합 중..."

SUMMARY_TXT="$RESULT_DIR/perf_summary_per_cpu.txt"

echo "=========================================================================" > "$SUMMARY_TXT"
echo " CXL VectorDB Per-CPU Performance Summary (Average of $RUNS Runs)" >> "$SUMMARY_TXT"
echo "   - Target CPUs : $TARGET_CPUS" >> "$SUMMARY_TXT"
echo "   - Label       : $LABEL" >> "$SUMMARY_TXT"
echo "   - Time        : $(date)" >> "$SUMMARY_TXT"
echo "=========================================================================" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

get_avg_val_for_cpu() {
  local target_event="$1"
  local cpu_id="$2"
  local sum=0
  for ((r=1; r<=RUNS; r++)); do
    local R_LOG="$RESULT_DIR/raw_run_${r}_cpu_${cpu_id}.txt"
    local raw_val=$(grep -iF "$target_event" "$R_LOG" | awk '{print $1}' | tr -d ',' | tr -d ' ' | grep -o '^[0-9.]*') || true
    if [ -z "$raw_val" ]; then raw_val="0"; fi
    sum=$(echo "$sum + $raw_val" | bc -l)
  done
  local avg=$(echo "$sum / $RUNS" | bc -l)
  if [ $(echo "$avg == 0" | bc -l) -eq 1 ]; then echo "0.0001"; else printf "%.2f" "$avg"; fi
}

for cpu in "${CPU_ARRAY[@]}"; do
  echo "=========================================================================" >> "$SUMMARY_TXT"
  echo " [ CPU $cpu ] Analysis Indicators" >> "$SUMMARY_TXT"
  echo "=========================================================================" >> "$SUMMARY_TXT"
  
  # A. Core Metrics
  topdown_mem_bound=$(get_avg_val_for_cpu "topdown-mem-bound" "$cpu")
  slots=$(get_avg_val_for_cpu "slots" "$cpu")
  retired_loads=$(get_avg_val_for_cpu "mem_inst_retired.all_loads" "$cpu")
  retired_stores=$(get_avg_val_for_cpu "mem_inst_retired.all_stores" "$cpu")
  
  mem_bound_ratio=$(echo "($topdown_mem_bound / $slots) * 100" | bc -l)
  mem_bound_ratio_fmt=$(printf "%.2f" "$mem_bound_ratio" 2>/dev/null || echo "0.00")
  rw_ratio=$(echo "$retired_loads / $retired_stores" | bc -l)
  rw_ratio_fmt=$(printf "%.2f" "$rw_ratio" 2>/dev/null || echo "0.00")
  
  echo "  [A. Core Execution Metrics]" >> "$SUMMARY_TXT"
  echo "   Memory-Bound Ratio           : $mem_bound_ratio_fmt % (Mem Bound Slots: $topdown_mem_bound, Total Slots: $slots)" >> "$SUMMARY_TXT"
  echo "   Application R/W Ratio        : $rw_ratio_fmt (Loads: $retired_loads, Stores: $retired_stores)" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  # B. Ingress Buffer Queueing Delay
  rxc_inserts_rrq=$(get_avg_val_for_cpu "unc_cha_rxc_inserts.rrq" "$cpu")
  rxc_occupancy_rrq=$(get_avg_val_for_cpu "unc_cha_rxc_occupancy.rrq" "$cpu")
  tau_rrq=$(echo "$rxc_occupancy_rrq / $rxc_inserts_rrq" | bc -l)
  tau_rrq_fmt=$(printf "%.2f" "$tau_rrq" 2>/dev/null || echo "0.00")
  
  rxc_inserts_wbq=$(get_avg_val_for_cpu "unc_cha_rxc_inserts.wbq" "$cpu")
  rxc_occupancy_wbq=$(get_avg_val_for_cpu "unc_cha_rxc_occupancy.wbq" "$cpu")
  tau_wbq=$(echo "$rxc_occupancy_wbq / $rxc_inserts_wbq" | bc -l)
  tau_wbq_fmt=$(printf "%.2f" "$tau_wbq" 2>/dev/null || echo "0.00")
  
  echo "  [B. Ingress Buffer Queueing Delay (Uncore - Socket Wide)]" >> "$SUMMARY_TXT"
  echo "   Average Read Ingress Delay (τ_RRQ)   : $tau_rrq_fmt cycles/req" >> "$SUMMARY_TXT"
  echo "   Average Write Ingress Delay (τ_WBQ)  : $tau_wbq_fmt cycles/req" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  # C & D. DDR5 and CXL RTT (TOR)
  ins_drd_local=$(get_avg_val_for_cpu "unc_cha_tor_inserts.ia_miss_drd_local_ddr" "$cpu")
  occ_drd_local=$(get_avg_val_for_cpu "unc_cha_tor_occupancy.ia_miss_drd_local_ddr" "$cpu")
  tau_drd_local=$(echo "$occ_drd_local / $ins_drd_local" | bc -l)
  tau_drd_local_fmt=$(printf "%.2f" "$tau_drd_local" 2>/dev/null || echo "0.00")
  
  ins_drd_remote=$(get_avg_val_for_cpu "unc_cha_tor_inserts.ia_miss_drd_remote_ddr" "$cpu")
  occ_drd_remote=$(get_avg_val_for_cpu "unc_cha_tor_occupancy.ia_miss_drd_remote_ddr" "$cpu")
  tau_drd_remote=$(echo "$occ_drd_remote / $ins_drd_remote" | bc -l)
  tau_drd_remote_fmt=$(printf "%.2f" "$tau_drd_remote" 2>/dev/null || echo "0.00")
  
  ins_drd_cxl_local=$(get_avg_val_for_cpu "unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local" "$cpu")
  occ_drd_cxl_local=$(get_avg_val_for_cpu "unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local" "$cpu")
  tau_drd_cxl_local=$(echo "$occ_drd_cxl_local / $ins_drd_cxl_local" | bc -l)
  tau_drd_cxl_local_fmt=$(printf "%.2f" "$tau_drd_cxl_local" 2>/dev/null || echo "0.00")
  
  echo "  [C & D. RTT Latency (Uncore - Socket Wide)]" >> "$SUMMARY_TXT"
  echo "   Local DDR5 Read RTT : $tau_drd_local_fmt cycles" >> "$SUMMARY_TXT"
  echo "   Remote DDR5 Read RTT: $tau_drd_remote_fmt cycles" >> "$SUMMARY_TXT"
  echo "   Local CXL Read RTT  : $tau_drd_cxl_local_fmt cycles" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  echo "  [Raw Averaged Values]" >> "$SUMMARY_TXT"
  for ev in "${SUPPORTED_EVENTS[@]}"; do
    avg_val=$(get_avg_val_for_cpu "$ev" "$cpu")
    printf "   %-55s : %15s \n" "$ev" "$avg_val" >> "$SUMMARY_TXT"
  done
  echo "" >> "$SUMMARY_TXT"

done

echo "========================================================================="
echo " 성능 분석 측정이 성공적으로 완료되었습니다!"
echo "   - 보고서 요약본 : $SUMMARY_TXT"
echo "========================================================================="
cat "$SUMMARY_TXT" | head -n 40
