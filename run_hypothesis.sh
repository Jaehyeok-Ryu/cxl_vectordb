#!/bin/bash

# ==============================================================================
# run_hypothesis.sh
# ==============================================================================
# 이 스크립트는 CPU 서버의 각 소켓(Socket 0, Socket 1)에 독립적인 Qdrant 인스턴스를
# 격리 실행합니다. 가설(Hypothesis 1) 검증을 최적화하기 위해 오직 로컬 격리 DDR인
# 'ddr-only'와 글로벌 NUMA 가중치 배분인 'weighted' 두 가지 정책만 명시적으로 지원합니다.
#
# [하드웨어 매핑 정보]
#   - Socket 0: CPU Node 0 | Local DDR Node 0 | Remote CXL Node 2
#   - Socket 1: CPU Node 1 | Local DDR Node 1 | Remote CXL Node 3
# ==============================================================================

set -e

# 기본값 설정
POLICY="weighted"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="qdrant/qdrant:latest"

# 도움말 출력 함수
show_help() {
    echo "사용법: $0 [옵션]"
    echo ""
    echo "옵션:"
    echo "  --policy <ddr-only | weighted>  (기본값: weighted)"
    echo "      - ddr-only: 각 소켓의 로컬 DDR 메모리만 엄격하게 할당"
    echo "      - weighted: 모든 NUMA 노드를 대상으로 weighted interleave 할당 수행"
    echo ""
    echo "  -h, --help                      도움말 출력"
    exit 0
}

# 파라미터 파싱
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --policy) POLICY="$2"; shift ;;
        -h|--help) show_help ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1"; show_help ;;
    esac
    shift
done

# 입력값 검증 (CWE-78: Command Injection 방지를 위한 화이트리스트 검사)
if [[ ! "$POLICY" =~ ^(ddr-only|weighted)$ ]]; then
    echo "[ERROR] 허용되지 않는 정책값입니다: $POLICY"
    echo "        'ddr-only' 또는 'weighted'만 가능합니다."
    exit 1
fi

echo "===================================================================="
echo "🚀 Dual Socket Isolated Qdrant VectorDB for Hypothesis Testing"
echo "   - Selected Policy: ${POLICY^^}"
echo "===================================================================="

# 1. NUMA 하드웨어 토폴로지 검증 및 CPU 바인딩 코어 설정
# Socket 0
SOCKET0_CPUS=0
# Socket 1
SOCKET1_CPUS=1

# 2. 정책에 따른 메모리 노드 바인딩 설정 및 numactl 인자 생성
case "$POLICY" in
    ddr-only)
        NUMACTL_ARGS_0="--cpunodebind=$SOCKET0_CPUS -m 0"
        NUMACTL_ARGS_1="--cpunodebind=$SOCKET1_CPUS -m 1"
        ;;
    weighted)
        NUMACTL_ARGS_0="--cpunodebind=$SOCKET0_CPUS -w all"
        NUMACTL_ARGS_1="--cpunodebind=$SOCKET1_CPUS -w all"
        ;;
    *)
        echo "[ERROR] 지원되지 않는 메모리 정책: $POLICY"
        exit 1
        ;;
esac

# 3. 기존 컨테이너 및 스토리지 디렉토리 격리 정리
CONTAINER_0="vectorDB_container_socket0"
CONTAINER_1="vectorDB_container_socket1"

STORAGE_0="${SCRIPT_DIR}/Data/qdrant_storage_socket0"
STORAGE_1="${SCRIPT_DIR}/Data/qdrant_storage_socket1"

echo "[INFO] 격리 스토리지 디렉토리 준비 중..."
mkdir -p "$STORAGE_0" "$STORAGE_1"

echo "[INFO] 기존 컨테이너 중단 및 제거 진행..."
docker rm -f "$CONTAINER_0" "$CONTAINER_1" >/dev/null 2>&1 || true

# 4. Socket 0 Qdrant 기동 (Port: 6333 / 6334)
echo "[INFO] Socket 0 Qdrant 기동 중..."
echo "       - CPU 코어 바인딩   : $SOCKET0_CPUS"
echo "       - numactl 적용 옵션 : $NUMACTL_ARGS_0"
docker run -d \
    --name "$CONTAINER_0" \
    --privileged \
    -v /usr/local/bin/numactl:/usr/local/bin/numactl \
    -v /usr/local/lib/libnuma.so.1:/usr/lib/x86_64-linux-gnu/libnuma.so.1 \
    -p 6333:6333 \
    -p 6334:6334 \
    -v "$STORAGE_0":/qdrant/storage \
    --restart unless-stopped \
    --entrypoint /usr/local/bin/numactl \
    "$IMAGE_NAME" \
    $NUMACTL_ARGS_0 \
    ./entrypoint.sh

# 5. Socket 1 Qdrant 기동 (Port: 6343 / 6344)
echo "[INFO] Socket 1 Qdrant 기동 중..."
echo "       - CPU 코어 바인딩   : $SOCKET1_CPUS"
echo "       - numactl 적용 옵션 : $NUMACTL_ARGS_1"
docker run -d \
    --name "$CONTAINER_1" \
    --privileged \
    -v /usr/local/bin/numactl:/usr/local/bin/numactl \
    -v /usr/local/lib/libnuma.so.1:/usr/lib/x86_64-linux-gnu/libnuma.so.1 \
    -p 6343:6333 \
    -p 6344:6334 \
    -v "$STORAGE_1":/qdrant/storage \
    --restart unless-stopped \
    --entrypoint /usr/local/bin/numactl \
    "$IMAGE_NAME" \
    $NUMACTL_ARGS_1 \
    ./entrypoint.sh

# 6. 두 서비스 헬스체크 대기
echo "[INFO] 두 인스턴스가 정상 기동될 때까지 대기합니다..."
for i in {1..30}; do
    HEALTH_0=0
    HEALTH_1=0
    
    if curl -sf http://localhost:6333/readyz >/dev/null 2>&1; then
        HEALTH_0=1
    fi
    if curl -sf http://localhost:6343/readyz >/dev/null 2>&1; then
        HEALTH_1=1
    fi
    
    if [ "$HEALTH_0" -eq 1 ] && [ "$HEALTH_1" -eq 1 ]; then
        echo "[SUCCESS] 양쪽 Qdrant VectorDB 서비스가 모두 성공적으로 구동되었습니다!"
        break
    fi
    
    if [ "$i" -eq 30 ]; then
        echo "[ERROR] 구동 대기 시간이 초과되었습니다. 컨테이너 상태를 점검해 주세요."
        docker ps -a
        exit 1
    fi
    sleep 1
done

# 7. 기동 완료 안내 출력
HOST_IP=$(hostname -I | awk '{print $1}')
echo "===================================================================="
echo "🎉 Dual Qdrant VectorDB Instances Active for Hypothesis!"
echo "===================================================================="
echo "👉 Socket 0"
echo "   - Container: $CONTAINER_0"
echo "   - HTTP Port: 6333 | gRPC Port: 6334"
echo "   - Storage  : $STORAGE_0"
echo ""
echo "👉 Socket 1"
echo "   - Container: $CONTAINER_1"
echo "   - HTTP Port: 6343 | gRPC Port: 6344"
echo "   - Storage  : $STORAGE_1"
echo "===================================================================="
echo "💡 외부 GPU/클라이언트 설정 IP:"
echo "   - CPU_SERVER_IP = \"$HOST_IP\""
echo "===================================================================="
