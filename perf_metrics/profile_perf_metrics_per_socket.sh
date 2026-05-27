#!/bin/bash
# ==============================================================================
# profile_perf_metrics_per_socket.sh
# ==============================================================================
# 기존 profile_perf_metrics.sh의 모든 지표를 "소켓(Socket) 단위"로 분리하여
# 병목 현상과 메모리/CXL 트래픽을 정밀 측정하기 위한 스크립트입니다.
# ==============================================================================

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 기본 옵션 설정
TARGET_SOCKETS="0,1"
DURATION=60
RUNS=3
WARMUP_TIME=15
LABEL="per_socket_metrics"

show_help() {
  echo "사용법: $0 [옵션]"
  echo "  --sockets <목록>      측정할 소켓 번호 목록 (기본값: $TARGET_SOCKETS, 예: 0,1)"
  echo "  --duration <초>       각 측정 주기(Run)별 측정 시간 (기본값: $DURATION초)"
  echo "  --runs <횟수>         총 측정 횟수 (기본값: $RUNS회)"
  echo "  --warmup <초>         웜업 대기 시간 (기본값: $WARMUP_TIME초)"
  echo "  --label <라벨>        결과 저장 폴더 지정을 위한 라벨 (기본값: $LABEL)"
  echo "  -h, --help            도움말 출력"
  exit 0
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --sockets) TARGET_SOCKETS="$2"; shift ;;
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
# 후보 성능 카운터 (Core & Uncore 통합)
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

for ev in "${CANDIDATE_EVENTS[@]}"; do
  # uncore 이벤트 매핑 확인 (0번 소켓 기준)
  ev_fixed=$(echo "$ev" | sed 's/\*/0/g')
  if sudo perf stat -a --per-socket -e "$ev" sleep 0.1 >/dev/null 2>&1; then
    SUPPORTED_EVENTS+=("$ev")
  elif sudo perf stat -a --per-socket -e "$ev_fixed" sleep 0.1 >/dev/null 2>&1; then
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
echo " Starting Per-Socket Performance Profiling"
echo "========================================================================="
echo "   - Target Sockets   : $TARGET_SOCKETS"
echo "   - Save Directory   : $RESULT_DIR"
echo "   - Run Duration     : $DURATION seconds per run"
echo "   - Total Runs       : $RUNS runs"
echo "========================================================================="

EVENT_STR=$(IFS=, ; echo "${SUPPORTED_EVENTS[*]}")
IFS=',' read -ra SOCK_ARRAY <<< "$TARGET_SOCKETS"

# ==============================================================================
# 실전 루프 (시스템 전체 측정, CSV 포맷으로 출력)
# ==============================================================================
for ((run=1; run<=RUNS; run++)); do
  echo " [Run $run/$RUNS] perf stat 데이터 수집 중... ($DURATION초 대기)"
  RAW_LOG="$RESULT_DIR/raw_run_$run.csv"
  
  # --per-socket 및 -x, (CSV 포맷) 사용
  sudo perf stat -a --per-socket -x, -e "$EVENT_STR" sleep "$DURATION" &> "$RAW_LOG"
  
  echo " Run $run 완료."
  sleep 3
done

# ==============================================================================
#  수집 로그 파싱 및 평균 계산 (CSV 파싱)
# ==============================================================================
echo "[INFO] 수집된 perf 로그 종합 중..."

SUMMARY_TXT="$RESULT_DIR/perf_summary_per_socket.txt"

echo "=========================================================================" > "$SUMMARY_TXT"
echo " CXL VectorDB Per-Socket Performance Summary (Average of $RUNS Runs)" >> "$SUMMARY_TXT"
echo "   - Target Sockets : $TARGET_SOCKETS" >> "$SUMMARY_TXT"
echo "   - Label          : $LABEL" >> "$SUMMARY_TXT"
echo "   - Time           : $(date)" >> "$SUMMARY_TXT"
echo "=========================================================================" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

get_avg_val_for_socket() {
  local target_event="$1"
  local sock_id="$2"
  local sum=0
  for ((r=1; r<=RUNS; r++)); do
    local R_LOG="$RESULT_DIR/raw_run_$r.csv"
    # 정확한 이벤트 이름 매칭을 위해 awk 사용 (부분 문자열 매칭으로 인한 _local 중복 매칭 방지)
    local raw_val=$(awk -F, -v sock="^S${sock_id}$" -v target="$target_event" '
      toupper($1) ~ sock {
        n = split($5, parts, "/")
        name = parts[n]
        if (name == "") name = parts[n-1] # handle trailing slash in uncore events
        
        if (name == target || $5 == target || $5 == target"/") {
          print $3
          exit
        }
      }
    ' "$R_LOG" | grep -o '^[0-9.]*')
    
    if [ -z "$raw_val" ]; then raw_val="0"; fi
    sum=$(echo "$sum + $raw_val" | bc -l)
  done
  local avg=$(echo "$sum / $RUNS" | bc -l)
  if [ $(echo "$avg == 0" | bc -l) -eq 1 ]; then echo "0.0001"; else printf "%.2f" "$avg"; fi
}

for sock in "${SOCK_ARRAY[@]}"; do
  echo "=========================================================================" >> "$SUMMARY_TXT"
  echo " [ Socket $sock ] Analysis Indicators" >> "$SUMMARY_TXT"
  echo "=========================================================================" >> "$SUMMARY_TXT"
  
  # ------------------------------------------------------------------------------
  # A. Core Execution Metrics
  # ------------------------------------------------------------------------------
  topdown_mem_bound=$(get_avg_val_for_socket "topdown-mem-bound" "$sock")
  slots=$(get_avg_val_for_socket "slots" "$sock")
  retired_loads=$(get_avg_val_for_socket "mem_inst_retired.all_loads" "$sock")
  retired_stores=$(get_avg_val_for_socket "mem_inst_retired.all_stores" "$sock")
  
  mem_bound_ratio=$(echo "($topdown_mem_bound / $slots) * 100" | bc -l)
  mem_bound_ratio_fmt=$(printf "%.2f" "$mem_bound_ratio" 2>/dev/null || echo "0.00")
  rw_ratio=$(echo "$retired_loads / $retired_stores" | bc -l)
  rw_ratio_fmt=$(printf "%.2f" "$rw_ratio" 2>/dev/null || echo "0.00")
  
  echo "  [A. Core Execution Metrics]" >> "$SUMMARY_TXT"
  echo "   Memory-Bound Ratio           : $mem_bound_ratio_fmt % (Mem Bound Slots: $topdown_mem_bound, Total Slots: $slots)" >> "$SUMMARY_TXT"
  echo "   Application R/W Ratio        : $rw_ratio_fmt (Loads: $retired_loads, Stores: $retired_stores)" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  # ------------------------------------------------------------------------------
  # B. Ingress Buffer Queueing Delay
  # ------------------------------------------------------------------------------
  rxc_inserts_rrq=$(get_avg_val_for_socket "unc_cha_rxc_inserts.rrq" "$sock")
  rxc_occupancy_rrq=$(get_avg_val_for_socket "unc_cha_rxc_occupancy.rrq" "$sock")
  tau_rrq=$(echo "$rxc_occupancy_rrq / $rxc_inserts_rrq" | bc -l)
  tau_rrq_fmt=$(printf "%.2f" "$tau_rrq" 2>/dev/null || echo "0.00")
  
  rxc_inserts_wbq=$(get_avg_val_for_socket "unc_cha_rxc_inserts.wbq" "$sock")
  rxc_occupancy_wbq=$(get_avg_val_for_socket "unc_cha_rxc_occupancy.wbq" "$sock")
  tau_wbq=$(echo "$rxc_occupancy_wbq / $rxc_inserts_wbq" | bc -l)
  tau_wbq_fmt=$(printf "%.2f" "$tau_wbq" 2>/dev/null || echo "0.00")
  
  echo "  [B. Ingress Buffer Queueing Delay - Read vs. Write Backpressure]" >> "$SUMMARY_TXT"
  echo "   Average Read Ingress Delay (τ_RRQ)   : $tau_rrq_fmt cycles/req (Occupancy: $rxc_occupancy_rrq, Inserts: $rxc_inserts_rrq)" >> "$SUMMARY_TXT"
  echo "   Average Write Ingress Delay (τ_WBQ)  : $tau_wbq_fmt cycles/req (Occupancy: $rxc_occupancy_wbq, Inserts: $rxc_inserts_wbq)" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  # ------------------------------------------------------------------------------
  # C. DDR5 Round-Trip Time (Read vs. Write RTT)
  # ------------------------------------------------------------------------------
  ins_drd_local_ddr=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_drd_local_ddr" "$sock")
  occ_drd_local_ddr=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_drd_local_ddr" "$sock")
  tau_local_ddr_read=$(echo "$occ_drd_local_ddr / $ins_drd_local_ddr" | bc -l)
  tau_local_ddr_read_fmt=$(printf "%.2f" "$tau_local_ddr_read" 2>/dev/null || echo "0.00")
  
  ins_rfo_local=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_rfo_local" "$sock")
  occ_rfo_local=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_rfo_local" "$sock")
  tau_local_ddr_write=$(echo "$occ_rfo_local / $ins_rfo_local" | bc -l)
  tau_local_ddr_write_fmt=$(printf "%.2f" "$tau_local_ddr_write" 2>/dev/null || echo "0.00")
  
  ins_drd_remote_ddr=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_drd_remote_ddr" "$sock")
  occ_drd_remote_ddr=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_drd_remote_ddr" "$sock")
  tau_remote_ddr_read=$(echo "$occ_drd_remote_ddr / $ins_drd_remote_ddr" | bc -l)
  tau_remote_ddr_read_fmt=$(printf "%.2f" "$tau_remote_ddr_read" 2>/dev/null || echo "0.00")
  
  ins_rfo_remote=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_rfo_remote" "$sock")
  occ_rfo_remote=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_rfo_remote" "$sock")
  tau_remote_ddr_write=$(echo "$occ_rfo_remote / $ins_rfo_remote" | bc -l)
  tau_remote_ddr_write_fmt=$(printf "%.2f" "$tau_remote_ddr_write" 2>/dev/null || echo "0.00")
  
  echo "  [C. DDR5 Round-Trip Time - Read vs. Write RTT]" >> "$SUMMARY_TXT"
  echo "   Local DDR5 Read RTT (τ_Local_DDR_Read)   : $tau_local_ddr_read_fmt cycles (Occupancy: $occ_drd_local_ddr, Inserts: $ins_drd_local_ddr)" >> "$SUMMARY_TXT"
  echo "   Local DDR5 Write RTT (τ_Local_DDR_Write) : $tau_local_ddr_write_fmt cycles (Occupancy: $occ_rfo_local, Inserts: $ins_rfo_local)" >> "$SUMMARY_TXT"
  echo "   Remote DDR5 Read RTT (τ_Remote_DDR_Read)   : $tau_remote_ddr_read_fmt cycles (Occupancy: $occ_drd_remote_ddr, Inserts: $ins_drd_remote_ddr)" >> "$SUMMARY_TXT"
  echo "   Remote DDR5 Write RTT (τ_Remote_DDR_Write) : $tau_remote_ddr_write_fmt cycles (Occupancy: $occ_rfo_remote, Inserts: $ins_rfo_remote)" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  # ------------------------------------------------------------------------------
  # D. CXL.mem Round-Trip Time (Read vs. Write RTT)
  # ------------------------------------------------------------------------------
  ins_drd_cxl_local=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local" "$sock")
  occ_drd_cxl_local=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local" "$sock")
  tau_local_cxl_read=$(echo "$occ_drd_cxl_local / $ins_drd_cxl_local" | bc -l)
  tau_local_cxl_read_fmt=$(printf "%.2f" "$tau_local_cxl_read" 2>/dev/null || echo "0.00")
  
  ins_rfo_cxl_local=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_rfo_cxl_acc_local" "$sock")
  occ_rfo_cxl_local=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc_local" "$sock")
  tau_local_cxl_write=$(echo "$occ_rfo_cxl_local / $ins_rfo_cxl_local" | bc -l)
  tau_local_cxl_write_fmt=$(printf "%.2f" "$tau_local_cxl_write" 2>/dev/null || echo "0.00")
  
  # Remote CXL Read RTT
  ins_drd_cxl_all=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_drd_cxl_acc" "$sock")
  occ_drd_cxl_all=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_drd_cxl_acc" "$sock")
  remote_cxl_read_ins=$(echo "$ins_drd_cxl_all - $ins_drd_cxl_local" | bc -l)
  remote_cxl_read_occ=$(echo "$occ_drd_cxl_all - $occ_drd_cxl_local" | bc -l)
  if (( $(echo "$remote_cxl_read_ins <= 0" | bc -l) )); then remote_cxl_read_ins="0.0001"; fi
  tau_remote_cxl_read=$(echo "$remote_cxl_read_occ / $remote_cxl_read_ins" | bc -l)
  tau_remote_cxl_read_fmt=$(printf "%.2f" "$tau_remote_cxl_read" 2>/dev/null || echo "0.00")
  
  # Remote CXL Write RTT
  ins_rfo_cxl_all=$(get_avg_val_for_socket "unc_cha_tor_inserts.ia_miss_rfo_cxl_acc" "$sock")
  occ_rfo_cxl_all=$(get_avg_val_for_socket "unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc" "$sock")
  remote_cxl_write_ins=$(echo "$ins_rfo_cxl_all - $ins_rfo_cxl_local" | bc -l)
  remote_cxl_write_occ=$(echo "$occ_rfo_cxl_all - $occ_rfo_cxl_local" | bc -l)
  if (( $(echo "$remote_cxl_write_ins <= 0" | bc -l) )); then remote_cxl_write_ins="0.0001"; fi
  tau_remote_cxl_write=$(echo "$remote_cxl_write_occ / $remote_cxl_write_ins" | bc -l)
  tau_remote_cxl_write_fmt=$(printf "%.2f" "$tau_remote_cxl_write" 2>/dev/null || echo "0.00")
  
  echo "  [D. CXL.mem Round-Trip Time - Read vs. Write RTT]" >> "$SUMMARY_TXT"
  echo "   Local CXL Read RTT (Explicit) (τ_Local_CXL_Read)  : $tau_local_cxl_read_fmt cycles (Occupancy: $occ_drd_cxl_local, Inserts: $ins_drd_cxl_local)" >> "$SUMMARY_TXT"
  echo "   Local CXL Write RTT (Explicit) (τ_Local_CXL_Write): $tau_local_cxl_write_fmt cycles (Occupancy: $occ_rfo_cxl_local, Inserts: $ins_rfo_cxl_local)" >> "$SUMMARY_TXT"
  echo "   Remote CXL Read RTT (Derived) (τ_Remote_CXL_Read)  : $tau_remote_cxl_read_fmt cycles (Occupancy: $remote_cxl_read_occ, Inserts: $remote_cxl_read_ins)" >> "$SUMMARY_TXT"
  echo "   Remote CXL Write RTT (Derived) (τ_Remote_CXL_Write): $tau_remote_cxl_write_fmt cycles (Occupancy: $remote_cxl_write_occ, Inserts: $remote_cxl_write_ins)" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  # ------------------------------------------------------------------------------
  # E. Interconnect Bandwidth
  # ------------------------------------------------------------------------------
  upi_txl_flits=$(get_avg_val_for_socket "unc_upi_txl_flits.all_data" "$sock")
  bw_upi=$(echo "($upi_txl_flits * 8) / ($DURATION * 1000000000)" | bc -l)
  bw_upi_fmt=$(printf "%.4f" "$bw_upi" 2>/dev/null || echo "0.0000")
  
  echo "  [E. Interconnect Bandwidth]" >> "$SUMMARY_TXT"
  echo "   UPI Transmit Bandwidth (BW_UPI)      : $bw_upi_fmt GB/s (Flits: $upi_txl_flits, Avg Time: ${DURATION}s)" >> "$SUMMARY_TXT"
  echo "" >> "$SUMMARY_TXT"
  
  echo "  [Raw Averaged Values]" >> "$SUMMARY_TXT"
  for ev in "${SUPPORTED_EVENTS[@]}"; do
    avg_val=$(get_avg_val_for_socket "$ev" "$sock")
    printf "   %-55s : %15s \n" "$ev" "$avg_val" >> "$SUMMARY_TXT"
  done
  echo "" >> "$SUMMARY_TXT"
done

echo "========================================================================="
echo " 성능 분석 측정이 성공적으로 완료되었습니다!"
echo "   - 보고서 요약본 : $SUMMARY_TXT"
echo "========================================================================="
cat "$SUMMARY_TXT"
