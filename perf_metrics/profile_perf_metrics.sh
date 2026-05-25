#!/bin/bash
# ==============================================================================
# profile_perf_metrics.sh
# ==============================================================================
# 이 스크립트는 가설 1(Hypothesis 1) 증명을 위해 VectorDB(Qdrant) 컨테이너가 가동 중인
# 호스트에서 하드웨어 성능 카운터(perf events)를 정밀 측정하는 전문 분석 도구입니다.
# 
# [주요 분석 관점]
#   1. Core Execution: Retired Loads/Stores, L3 Miss stalls, pipeline slots
#   2. Interconnect: UPI link flits (소켓 간 remote access traffic)
#   3. Uncore Ingress Queue (RxC Buffer): IRQ, RRQ, WBQ occupancy & inserts (HOL blocking 분석)
#   4. Table of Requests (TOR): Local DDR, Remote DDR, Local/Remote CXL read/write RTT 분석
# ==============================================================================

set -e

# 스크립트 실행 경로 고정
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 기본 옵션 설정
CONTAINER_NAME="vectorDB_container"
DURATION=60
RUNS=3
WARMUP_TIME=15
LABEL="default_test"

# 도움말 출력 함수
show_help() {
  echo "사용법: $0 [옵션]"
  echo ""
  echo "옵션:"
  echo "  --container <이름>    모니터링할 VectorDB 컨테이너 이름 (기본값: $CONTAINER_NAME)"
  echo "  --duration <초>       각 측정 주기(Run)별 perf stat 측정 시간 (기본값: $DURATION초)"
  echo "  --runs <횟수>         평균 산출을 위한 총 측정 횟수 (기본값: $RUNS회)"
  echo "  --warmup <초>         초기 Page Fault 오버헤드 배제를 위한 웜업 대기 시간 (기본값: $WARMUP_TIME초)"
  echo "  --label <라벨>        결과 저장 폴더 지정을 위한 매개변수 라벨 (예: RPS_40_weighted)"
  echo "  -h, --help            도움말 출력"
  echo ""
  echo "예시:"
  echo "  $0 --container vectorDB_container_socket0 --duration 60 --runs 3 --label Socket0_weighted_RPS30"
  exit 0
}

# 인자 파싱
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --container) CONTAINER_NAME="$2"; shift ;;
    --duration) DURATION="$2"; shift ;;
    --runs) RUNS="$2"; shift ;;
    --warmup) WARMUP_TIME="$2"; shift ;;
    --label) LABEL="$2"; shift ;;
    -h|--help) show_help ;;
    *) echo "❌ [Error] 알 수 없는 옵션: $1"; show_help ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# [입력 인자 정합성 검증 - Security Input Validation]
# ------------------------------------------------------------------------------
if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "❌ [Error] Invalid container name format." >&2
  exit 1
fi
if [[ ! "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -eq 0 ]; then
  echo "❌ [Error] Duration must be a positive integer." >&2
  exit 1
fi
if [[ ! "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -eq 0 ]; then
  echo "❌ [Error] Runs count must be a positive integer." >&2
  exit 1
fi
if [[ ! "$WARMUP_TIME" =~ ^[0-9]+$ ]]; then
  echo "❌ [Error] Warmup time must be a non-negative integer." >&2
  exit 1
fi
if [[ ! "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "❌ [Error] Invalid label format. Alphanumeric, underscores, and dashes only." >&2
  exit 1
fi
# ------------------------------------------------------------------------------

# perf 도구 설치 여부 확인
if ! command -v perf &> /dev/null; then
  echo "❌ [Error] 'perf' 도구가 시스템에 설치되어 있지 않거나 PATH에 없습니다." >&2
  exit 1
fi

# sudo 권한 체크 (perf stat -a 및 uncore event 측정에 필수)
if [ "$EUID" -ne 0 ]; then
  echo "⚠️  [Warning] Uncore PMU 및 System-wide 수집을 위해 root 권한(sudo)이 필요할 수 있습니다."
fi

# 컨테이너 상태 및 PID 확인
echo "[INFO] 컨테이너 '$CONTAINER_NAME'의 상태를 검증합니다..."
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "❌ [Error] 컨테이너 '${CONTAINER_NAME}'가 현재 실행 중이 아닙니다." >&2
  exit 1
fi

PID=$(docker inspect --format '{{.State.Pid}}' "$CONTAINER_NAME")
VECTORDB_CPUS=$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$CONTAINER_NAME")
echo "✅ 컨테이너가 확인되었습니다. (Host PID: $PID, CPUS: ${VECTORDB_CPUS:-All})"

# ==============================================================================
# 🎯 후보 성능 카운터 리스트 선언 (가설 1 검증 최적화)
# ==============================================================================
CANDIDATE_EVENTS=(
  # A. Core Execution Metrics
  "slots"
  "topdown-mem-bound"
  "topdown-be-bound"
  "cycle_activity.stalls_l3_miss"
  "mem_inst_retired.all_loads"
  "mem_inst_retired.all_stores"

  # B. Interconnect Metrics
  "uncore_upi_*/unc_upi_txl_flits.all_data/"

  # C. Uncore Ingress Queue (RxC Buffer) Metrics
  "uncore_cha_*/unc_cha_rxc_inserts.irq/"
  "uncore_cha_*/unc_cha_rxc_inserts.irq_rej/"
  "uncore_cha_*/unc_cha_rxc_inserts.ipq/"
  "uncore_cha_*/unc_cha_rxc_inserts.rrq/"
  "uncore_cha_*/unc_cha_rxc_occupancy.rrq/"
  "uncore_cha_*/unc_cha_rxc_inserts.wbq/"
  "uncore_cha_*/unc_cha_rxc_occupancy.wbq/"

  # D. Uncore TOR (Table of Requests) Metrics
  "uncore_cha_*/unc_cha_tor_inserts.all/"
  "uncore_cha_*/unc_cha_tor_occupancy.all/"

  # Read (DRD - Demand Read Miss) Sub-Events
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_local_ddr/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_local_ddr/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_remote_ddr/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_remote_ddr/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc/"

  # Write (RFO - Request for Ownership Write Miss) Sub-Events
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_local/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_local/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_remote/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_remote/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc_local/"
  "uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_cxl_acc/"
  "uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc/"
)

# ==============================================================================
# 🔍 호스트에서 실제 측정이 가능한 카운터만 동적 필터링 (Dry-run 검증)
# ==============================================================================
echo "[INFO] 시스템이 지원하는 하드웨어 카운터를 식별하는 중 (Dry-run)..."
SUPPORTED_EVENTS=()

for ev in "${CANDIDATE_EVENTS[@]}"; do
  # 0.1초 동안 아주 짧게 테스트하여 지원 여부를 가립니다.
  if sudo perf stat -a -e "$ev" sleep 0.1 >/dev/null 2>&1; then
    SUPPORTED_EVENTS+=("$ev")
  else
    # 와일드카드 실패 시 개별 장치(예: 0번 장치)로 매핑 재시도
    ev_fixed=$(echo "$ev" | sed 's/\*/0/g')
    if sudo perf stat -a -e "$ev_fixed" sleep 0.1 >/dev/null 2>&1; then
      SUPPORTED_EVENTS+=("$ev_fixed")
    fi
  fi
done

echo "📊 필터링 완료: 후보 ${#CANDIDATE_EVENTS[@]}개 중 ${#SUPPORTED_EVENTS[@]}개 이벤트 지원 확인."

if [ ${#SUPPORTED_EVENTS[@]} -eq 0 ]; then
  echo "❌ [Error] 측정 가능한 성능 카운터가 하나도 없습니다. 커널 설정 및 uncore 드라이버를 확인해 주세요." >&2
  exit 1
fi

# ==============================================================================
# ⏳ 웜업 대기 (초기 페이지 폴트 등의 노이즈 제거)
# ==============================================================================
if [ $WARMUP_TIME -gt 0 ]; then
  echo "[INFO] 초기 노이즈(Page Fault, Cold Start)를 배제하기 위해 $WARMUP_TIME초 동안 대기(웜업)합니다..."
  sleep $WARMUP_TIME
fi

# 결과 저장 폴더 경로 생성
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/perf_results/run_${LABEL}_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

echo "========================================================================="
echo "📈 Starting Perf Performance Profiling"
echo "========================================================================="
echo "   - Target Container : $CONTAINER_NAME (PID: $PID)"
echo "   - Save Directory   : $RESULT_DIR"
echo "   - Run Duration     : $DURATION seconds per run"
echo "   - Total Runs       : $RUNS runs"
echo "========================================================================="

# ==============================================================================
# 🔄 실전 루프 기동 (60초씩 N번 연속 측정)
# ==============================================================================
# perf stat 아규먼트용 문자열 구성
EVENT_STR=""
for ev in "${SUPPORTED_EVENTS[@]}"; do
  if [ -z "$EVENT_STR" ]; then
    EVENT_STR="$ev"
  else
    EVENT_STR="$EVENT_STR,$ev"
  fi
done

for ((run=1; run<=RUNS; run++)); do
  echo "🔄 [Run $run/$RUNS] perf stat 데이터 수집 중... ($DURATION초 대기)"
  RAW_LOG="$RESULT_DIR/raw_run_$run.txt"
  
  # 시스템 전체(-a)로 Qdrant 바인딩 영역을 포괄하여 대역폭 및 큐 지표 정밀 측정
  sudo perf stat -a -e "$EVENT_STR" sleep "$DURATION" &> "$RAW_LOG"
  
  echo "✅ Run $run 완료."
  # 측정 간 3초 휴식
  sleep 3
done

# ==============================================================================
# 📊 수집 로그 자동 파싱 및 평균 계산 (분석 자동화)
# ==============================================================================
echo "[INFO] 수집된 perf 로그를 종합하고 평균값(Average)을 계산하는 중..."

SUMMARY_TXT="$RESULT_DIR/perf_summary.txt"
SUMMARY_CSV="$RESULT_DIR/perf_summary.csv"

# 파일 헤더 생성
echo "=========================================================================" > "$SUMMARY_TXT"
echo "📊 CXL VectorDB 가설 1 검증 - 성능 분석 요약 (Average of $RUNS Runs)" >> "$SUMMARY_TXT"
echo "   - Target : $CONTAINER_NAME (PID: $PID)" >> "$SUMMARY_TXT"
echo "   - Label  : $LABEL" >> "$SUMMARY_TXT"
echo "   - Time   : $(date)" >> "$SUMMARY_TXT"
echo "=========================================================================" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

echo "metric,run1,run2,run3,average,unit" > "$SUMMARY_CSV"

# 각 이벤트별로 N개 파일에 걸친 결과 파싱
for ev in "${SUPPORTED_EVENTS[@]}"; do
  VALUES=()
  UNIT=""
  
  for ((run=1; run<=RUNS; run++)); do
    RAW_LOG="$RESULT_DIR/raw_run_$run.txt"
    
    # perf stat 특유의 공백 및 숫자 서식 파싱
    # 예: "  1,234,567,890      uncore_cha_0/..." -> "1234567890" 추출
    raw_val=$(grep -iF "$ev" "$RAW_LOG" | awk '{print $1}' | tr -d ',' | tr -d ' ' | grep -o '^[0-9.]*') || true
    
    if [ -z "$raw_val" ]; then
      raw_val="0"
    fi
    VALUES+=("$raw_val")
  done
  
  # 평균값 계산
  sum=0
  for val in "${VALUES[@]}"; do
    sum=$(echo "$sum + $val" | bc -l)
  done
  avg=$(echo "$sum / $RUNS" | bc -l)
  
  # 출력 포맷 세련되게 변환 (소수점 2자리)
  avg_formatted=$(printf "%.2f" "$avg" 2>/dev/null || echo "0.00")
  
  # 각 런의 기록을 나열
  run_str=""
  csv_str="$ev"
  for ((run=0; run<RUNS; run++)); do
    run_str="$run_str Run$((run+1)): ${VALUES[$run]} |"
    csv_str="$csv_str,${VALUES[$run]}"
  done
  csv_str="$csv_str,$avg_formatted,counts"
  
  # 요약본 파일에 출력
  printf "📍 %-55s | Avg: %-15s | [ %s ]\n" "$ev" "$avg_formatted" "$run_str" >> "$SUMMARY_TXT"
  echo "$csv_str" >> "$SUMMARY_CSV"
done

# ==============================================================================
# 🧠 가설 1 검증 - 통합 마이크로아키텍처 유도 분석 지표 (Unified Indicators)
# ==============================================================================
echo "" >> "$SUMMARY_TXT"
echo "=========================================================================" >> "$SUMMARY_TXT"
echo "📊 가설 1 검증 - 통합 마이크로아키텍처 분석 지표 (Unified Indicators)" >> "$SUMMARY_TXT"
echo "=========================================================================" >> "$SUMMARY_TXT"

# 파싱 유틸리티 함수
get_avg_val() {
  local target_event="$1"
  # CSV에서 해당 이벤트의 평균 컬럼(5번째 열) 값 추출
  local val=$(grep -iF "$target_event" "$SUMMARY_CSV" | cut -d',' -f5) || echo "0"
  if [ -z "$val" ] || [ "$val" == "0" ] || [ "$val" == "0.00" ]; then echo "0.0001"; else echo "$val"; fi
}

# ------------------------------------------------------------------------------
# A. Core Execution Metrics
# ------------------------------------------------------------------------------
topdown_mem_bound=$(get_avg_val "topdown-mem-bound")
slots=$(get_avg_val "slots")
retired_loads=$(get_avg_val "mem_inst_retired.all_loads")
retired_stores=$(get_avg_val "mem_inst_retired.all_stores")

# Memory-Bound Ratio (%)
mem_bound_ratio=$(echo "($topdown_mem_bound / $slots) * 100" | bc -l)
mem_bound_ratio_fmt=$(printf "%.2f" "$mem_bound_ratio" 2>/dev/null || echo "0.00")

# R/W Ratio (Retired Loads / Retired Stores)
rw_ratio=$(echo "$retired_loads / $retired_stores" | bc -l)
rw_ratio_fmt=$(printf "%.2f" "$rw_ratio" 2>/dev/null || echo "0.00")

echo "  [A. Core Execution Metrics]" >> "$SUMMARY_TXT"
echo "  📌 Memory-Bound Ratio           : $mem_bound_ratio_fmt % (Mem Bound Slots: $topdown_mem_bound, Total Slots: $slots)" >> "$SUMMARY_TXT"
echo "  📌 Application R/W Ratio         : $rw_ratio_fmt (Loads: $retired_loads, Stores: $retired_stores)" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

# ------------------------------------------------------------------------------
# B. Ingress Buffer Queueing Delay (Read vs. Write Backpressure)
# ------------------------------------------------------------------------------
rxc_inserts_rrq=$(get_avg_val "unc_cha_rxc_inserts.rrq")
rxc_occupancy_rrq=$(get_avg_val "unc_cha_rxc_occupancy.rrq")
tau_rrq=$(echo "$rxc_occupancy_rrq / $rxc_inserts_rrq" | bc -l)
tau_rrq_fmt=$(printf "%.2f" "$tau_rrq" 2>/dev/null || echo "0.00")

rxc_inserts_wbq=$(get_avg_val "unc_cha_rxc_inserts.wbq")
rxc_occupancy_wbq=$(get_avg_val "unc_cha_rxc_occupancy.wbq")
tau_wbq=$(echo "$rxc_occupancy_wbq / $rxc_inserts_wbq" | bc -l)
tau_wbq_fmt=$(printf "%.2f" "$tau_wbq" 2>/dev/null || echo "0.00")

echo "  [B. Ingress Buffer Queueing Delay - Read vs. Write Backpressure]" >> "$SUMMARY_TXT"
echo "  📌 Average Read Ingress Delay (τ_RRQ)   : $tau_rrq_fmt cycles/req (Occupancy: $rxc_occupancy_rrq, Inserts: $rxc_inserts_rrq)" >> "$SUMMARY_TXT"
echo "  📌 Average Write Ingress Delay (τ_WBQ)  : $tau_wbq_fmt cycles/req (Occupancy: $rxc_occupancy_wbq, Inserts: $rxc_inserts_wbq)" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

# ------------------------------------------------------------------------------
# C. DDR5 Round-Trip Time (Read vs. Write RTT)
# ------------------------------------------------------------------------------
ins_drd_local_ddr=$(get_avg_val "unc_cha_tor_inserts.ia_miss_drd_local_ddr")
occ_drd_local_ddr=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_drd_local_ddr")
tau_local_ddr_read=$(echo "$occ_drd_local_ddr / $ins_drd_local_ddr" | bc -l)
tau_local_ddr_read_fmt=$(printf "%.2f" "$tau_local_ddr_read" 2>/dev/null || echo "0.00")

ins_rfo_local=$(get_avg_val "unc_cha_tor_inserts.ia_miss_rfo_local")
occ_rfo_local=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_rfo_local")
tau_local_ddr_write=$(echo "$occ_rfo_local / $ins_rfo_local" | bc -l)
tau_local_ddr_write_fmt=$(printf "%.2f" "$tau_local_ddr_write" 2>/dev/null || echo "0.00")

ins_drd_remote_ddr=$(get_avg_val "unc_cha_tor_inserts.ia_miss_drd_remote_ddr")
occ_drd_remote_ddr=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_drd_remote_ddr")
tau_remote_ddr_read=$(echo "$occ_drd_remote_ddr / $ins_drd_remote_ddr" | bc -l)
tau_remote_ddr_read_fmt=$(printf "%.2f" "$tau_remote_ddr_read" 2>/dev/null || echo "0.00")

ins_rfo_remote=$(get_avg_val "unc_cha_tor_inserts.ia_miss_rfo_remote")
occ_rfo_remote=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_rfo_remote")
tau_remote_ddr_write=$(echo "$occ_rfo_remote / $ins_rfo_remote" | bc -l)
tau_remote_ddr_write_fmt=$(printf "%.2f" "$tau_remote_ddr_write" 2>/dev/null || echo "0.00")

echo "  [C. DDR5 Round-Trip Time - Read vs. Write RTT]" >> "$SUMMARY_TXT"
echo "  📌 Local DDR5 Read RTT (τ_Local_DDR_Read)   : $tau_local_ddr_read_fmt cycles (Occupancy: $occ_drd_local_ddr, Inserts: $ins_drd_local_ddr)" >> "$SUMMARY_TXT"
echo "  📌 Local DDR5 Write RTT (τ_Local_DDR_Write) : $tau_local_ddr_write_fmt cycles (Occupancy: $occ_rfo_local, Inserts: $ins_rfo_local)" >> "$SUMMARY_TXT"
echo "  📌 Remote DDR5 Read RTT (τ_Remote_DDR_Read)   : $tau_remote_ddr_read_fmt cycles (Occupancy: $occ_drd_remote_ddr, Inserts: $ins_drd_remote_ddr)" >> "$SUMMARY_TXT"
echo "  📌 Remote DDR5 Write RTT (τ_Remote_DDR_Write) : $tau_remote_ddr_write_fmt cycles (Occupancy: $occ_rfo_remote, Inserts: $ins_rfo_remote)" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

# ------------------------------------------------------------------------------
# D. CXL.mem Round-Trip Time (Read vs. Write RTT)
# ------------------------------------------------------------------------------
ins_drd_cxl_local=$(get_avg_val "unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local")
occ_drd_cxl_local=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local")
tau_local_cxl_read=$(echo "$occ_drd_cxl_local / $ins_drd_cxl_local" | bc -l)
tau_local_cxl_read_fmt=$(printf "%.2f" "$tau_local_cxl_read" 2>/dev/null || echo "0.00")

ins_rfo_cxl_local=$(get_avg_val "unc_cha_tor_inserts.ia_miss_rfo_cxl_acc_local")
occ_rfo_cxl_local=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc_local")
tau_local_cxl_write=$(echo "$occ_rfo_cxl_local / $ins_rfo_cxl_local" | bc -l)
tau_local_cxl_write_fmt=$(printf "%.2f" "$tau_local_cxl_write" 2>/dev/null || echo "0.00")

# Remote CXL Read RTT
ins_drd_cxl_all=$(get_avg_val "unc_cha_tor_inserts.ia_miss_drd_cxl_acc")
occ_drd_cxl_all=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_drd_cxl_acc")
remote_cxl_read_ins=$(echo "$ins_drd_cxl_all - $ins_drd_cxl_local" | bc -l)
remote_cxl_read_occ=$(echo "$occ_drd_cxl_all - $occ_drd_cxl_local" | bc -l)
if (( $(echo "$remote_cxl_read_ins <= 0" | bc -l) )); then remote_cxl_read_ins="0.0001"; fi
tau_remote_cxl_read=$(echo "$remote_cxl_read_occ / $remote_cxl_read_ins" | bc -l)
tau_remote_cxl_read_fmt=$(printf "%.2f" "$tau_remote_cxl_read" 2>/dev/null || echo "0.00")

# Remote CXL Write RTT
ins_rfo_cxl_all=$(get_avg_val "unc_cha_tor_inserts.ia_miss_rfo_cxl_acc")
occ_rfo_cxl_all=$(get_avg_val "unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc")
remote_cxl_write_ins=$(echo "$ins_rfo_cxl_all - $ins_rfo_cxl_local" | bc -l)
remote_cxl_write_occ=$(echo "$occ_rfo_cxl_all - $occ_rfo_cxl_local" | bc -l)
if (( $(echo "$remote_cxl_write_ins <= 0" | bc -l) )); then remote_cxl_write_ins="0.0001"; fi
tau_remote_cxl_write=$(echo "$remote_cxl_write_occ / $remote_cxl_write_ins" | bc -l)
tau_remote_cxl_write_fmt=$(printf "%.2f" "$tau_remote_cxl_write" 2>/dev/null || echo "0.00")

echo "  [D. CXL.mem Round-Trip Time - Read vs. Write RTT]" >> "$SUMMARY_TXT"
echo "  📌 Local CXL Read RTT (Explicit) (τ_Local_CXL_Read)  : $tau_local_cxl_read_fmt cycles (Occupancy: $occ_drd_cxl_local, Inserts: $ins_drd_cxl_local)" >> "$SUMMARY_TXT"
echo "  📌 Local CXL Write RTT (Explicit) (τ_Local_CXL_Write): $tau_local_cxl_write_fmt cycles (Occupancy: $occ_rfo_cxl_local, Inserts: $ins_rfo_cxl_local)" >> "$SUMMARY_TXT"
echo "  📌 Remote CXL Read RTT (Derived) (τ_Remote_CXL_Read)  : $tau_remote_cxl_read_fmt cycles (Occupancy: $remote_cxl_read_occ, Inserts: $remote_cxl_read_ins)" >> "$SUMMARY_TXT"
echo "  📌 Remote CXL Write RTT (Derived) (τ_Remote_CXL_Write): $tau_remote_cxl_write_fmt cycles (Occupancy: $remote_cxl_write_occ, Inserts: $remote_cxl_write_ins)" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

# ------------------------------------------------------------------------------
# E. Interconnect Bandwidth
# ------------------------------------------------------------------------------
upi_txl_flits=$(get_avg_val "unc_upi_txl_flits.all_data")

# Parse average time elapsed across runs
sum_time=0
for ((run=1; run<=RUNS; run++)); do
  RAW_LOG="$RESULT_DIR/raw_run_$run.txt"
  raw_time=$(grep -i "seconds time elapsed" "$RAW_LOG" | awk '{print $1}' | tr -d ',' | tr -d ' ' | grep -o '^[0-9.]*') || true
  if [ -z "$raw_time" ] || [ "$raw_time" == "0" ]; then
    raw_time="$DURATION"
  fi
  sum_time=$(echo "$sum_time + $raw_time" | bc -l)
done
avg_time_elapsed=$(echo "$sum_time / $RUNS" | bc -l)

# BW = flits * 8 bytes / (time * 10^9) -> GB/s
bw_upi=$(echo "($upi_txl_flits * 8) / ($avg_time_elapsed * 1000000000)" | bc -l)
bw_upi_fmt=$(printf "%.4f" "$bw_upi" 2>/dev/null || echo "0.0000")

echo "  [E. Interconnect Bandwidth]" >> "$SUMMARY_TXT"
echo "  📌 UPI Transmit Bandwidth (BW_UPI)      : $bw_upi_fmt GB/s (Flits: $upi_txl_flits, Avg Time: ${avg_time_elapsed}s)" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"



echo "========================================================================="
echo "🎉 성능 분석 측정이 성공적으로 완료되었습니다!"
echo "   - 보고서 요약본 : $SUMMARY_TXT"
echo "   - CSV 가시화 데이터: $SUMMARY_CSV"
echo "========================================================================="

cat "$SUMMARY_TXT" | tail -n 35

