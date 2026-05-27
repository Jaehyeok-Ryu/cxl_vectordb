#!/bin/bash
# ==============================================================================
# profile_cpu_ocr_metrics.sh
# ==============================================================================
# 각 CPU 코어별로(Per-CPU) Offcore Response(OCR) 및 L3 Miss 메모리 접근 지표를 
# 정밀 측정하기 위한 스크립트입니다.
# Local vs Remote (DDR/CXL) 메모리 접근 카운트를 CPU별로 분리해서 보여줍니다.
# ==============================================================================

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 기본 옵션 설정
TARGET_CPUS="0,1"
DURATION=60
RUNS=3
WARMUP_TIME=15
LABEL="cpu_ocr_test"

# 도움말 출력 함수
show_help() {
  echo "사용법: $0 [옵션]"
  echo "옵션:"
  echo "  --cpus <목록>         측정할 CPU 코어 목록 (기본값: $TARGET_CPUS, 예: 0,1,2)"
  echo "  --duration <초>       각 측정 주기(Run)별 측정 시간 (기본값: $DURATION초)"
  echo "  --runs <횟수>         총 측정 횟수 (기본값: $RUNS회)"
  echo "  --warmup <초>         웜업 대기 시간 (기본값: $WARMUP_TIME초)"
  echo "  --label <라벨>        결과 저장 폴더 라벨 (기본값: $LABEL)"
  echo "  -h, --help            도움말 출력"
  exit 0
}

# 인자 파싱
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

# sudo 권한 체크
if [ "$EUID" -ne 0 ]; then
  echo "  [Warning] perf stat 구동을 위해 root 권한(sudo)이 필요할 수 있습니다."
fi

# ==============================================================================
#  측정 대상 OCR 및 Core 카운터 목록
# ==============================================================================
CANDIDATE_EVENTS=(
  "mem_load_l3_miss_retired.local_dram"
  "mem_load_l3_miss_retired.remote_dram"
  "ocr.demand_data_rd.local_dram"
  "ocr.demand_data_rd.remote_dram"
  "ocr.demand_rfo.local_dram"
  "ocr.reads_to_core.remote_memory"
)

echo "[INFO] 시스템이 지원하는 하드웨어 카운터를 식별하는 중 (Dry-run)..."
SUPPORTED_EVENTS=()

for ev in "${CANDIDATE_EVENTS[@]}"; do
  # 첫 번째 지정된 CPU를 이용해 테스트
  FIRST_CPU=$(echo "$TARGET_CPUS" | cut -d',' -f1)
  if sudo perf stat -C "$FIRST_CPU" -e "$ev" sleep 0.1 >/dev/null 2>&1; then
    SUPPORTED_EVENTS+=("$ev")
  fi
done

echo " 필터링 완료: 후보 ${#CANDIDATE_EVENTS[@]}개 중 ${#SUPPORTED_EVENTS[@]}개 이벤트 지원 확인."

if [ ${#SUPPORTED_EVENTS[@]} -eq 0 ]; then
  echo " [Error] 측정 가능한 성능 카운터가 하나도 없습니다." >&2
  exit 1
fi

if [ $WARMUP_TIME -gt 0 ]; then
  echo "[INFO] 초기 노이즈 배제를 위해 $WARMUP_TIME초 동안 대기(웜업)합니다..."
  sleep $WARMUP_TIME
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$SCRIPT_DIR/perf_results/run_${LABEL}_${TIMESTAMP}"
mkdir -p "$RESULT_DIR"

echo "========================================================================="
echo " Starting Per-CPU OCR Profiling"
echo "========================================================================="
echo "   - Target CPUs      : $TARGET_CPUS"
echo "   - Save Directory   : $RESULT_DIR"
echo "   - Run Duration     : $DURATION seconds per run"
echo "   - Total Runs       : $RUNS runs"
echo "========================================================================="

# perf에 전달할 이벤트 문자열 조합
EVENT_STR=$(IFS=, ; echo "${SUPPORTED_EVENTS[*]}")

for ((run=1; run<=RUNS; run++)); do
  echo " [Run $run/$RUNS] perf stat 데이터 수집 중... ($DURATION초 대기)"
  
  # 각 CPU별로 개별 perf stat 백그라운드 실행
  IFS=',' read -ra CPU_ARRAY <<< "$TARGET_CPUS"
  for cpu in "${CPU_ARRAY[@]}"; do
    RAW_LOG="$RESULT_DIR/raw_run_${run}_cpu_${cpu}.txt"
    sudo perf stat -C "$cpu" -e "$EVENT_STR" sleep "$DURATION" &> "$RAW_LOG" &
  done
  
  # 모든 백그라운드 측정이 끝날 때까지 대기
  wait
  
  echo " Run $run 완료."
  sleep 3
done

# ==============================================================================
#  수집 로그 파싱 및 코어별 요약 계산
# ==============================================================================
echo "[INFO] 수집된 perf 로그 종합 및 평균 계산 중..."

SUMMARY_TXT="$RESULT_DIR/cpu_ocr_summary.txt"

echo "=========================================================================" > "$SUMMARY_TXT"
echo " Per-CPU OCR Profiling Summary (Average of $RUNS Runs)" >> "$SUMMARY_TXT"
echo "   - Target CPUs : $TARGET_CPUS" >> "$SUMMARY_TXT"
echo "   - Time        : $(date)" >> "$SUMMARY_TXT"
echo "=========================================================================" >> "$SUMMARY_TXT"
echo "" >> "$SUMMARY_TXT"

# CPU 목록 배열 변환
IFS=',' read -ra CPU_ARRAY <<< "$TARGET_CPUS"

for cpu in "${CPU_ARRAY[@]}"; do
  echo "--------------------------------------------------------" >> "$SUMMARY_TXT"
  echo " [ CPU $cpu ]" >> "$SUMMARY_TXT"
  echo "--------------------------------------------------------" >> "$SUMMARY_TXT"
  
  for ev in "${SUPPORTED_EVENTS[@]}"; do
    sum=0
    for ((run=1; run<=RUNS; run++)); do
      RAW_LOG="$RESULT_DIR/raw_run_${run}_cpu_${cpu}.txt"
      
      # 단일 CPU 로그에서 이벤트 값 파싱 (첫 번째 숫자 컬럼)
      raw_val=$(grep -iF "$ev" "$RAW_LOG" | awk '{print $1}' | tr -d ',' | tr -d ' ' | grep -o '^[0-9.]*') || true
      
      if [ -z "$raw_val" ]; then
        raw_val="0"
      fi
      sum=$(echo "$sum + $raw_val" | bc -l)
    done
    
    avg=$(echo "$sum / $RUNS" | bc -l)
    avg_formatted=$(printf "%.2f" "$avg" 2>/dev/null || echo "0.00")
    
    printf " %-45s | Avg: %-15s \n" "$ev" "$avg_formatted" >> "$SUMMARY_TXT"
  done
  echo "" >> "$SUMMARY_TXT"
done

echo "========================================================================="
echo " 성능 분석 측정이 성공적으로 완료되었습니다!"
echo "   - 보고서 요약본 : $SUMMARY_TXT"
echo "========================================================================="

cat "$SUMMARY_TXT"
