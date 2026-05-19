#!/bin/bash

# ==============================================================================
# run_dual_qdrants.sh
# ==============================================================================
# 이 스크립트는 CPU 서버의 각 소켓(Socket 0, Socket 1)에 독립적인 Qdrant 인스턴스를
# 격리 실행합니다. NUMA 메모리 정책(Local DDR, Remote CXL, Interleave, Weighted)을
# 인자값으로 설정하여 대칭/비대칭 시나리오 실험을 지원합니다.
#
# [하드웨어 매핑 정보]
#   - Socket 0: CPU Node 0 (0-15,32-47) | Local DDR Node 0 | Remote CXL Node 2
#   - Socket 1: CPU Node 1 (16-31,48-63) | Local DDR Node 1 | Remote CXL Node 3
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
    echo "  --policy <ddr-only | ddr-only-12c | cxl-only | interleave | weighted>  (기본값: weighted)"
    echo "      - ddr-only: 각 소켓의 로컬 DDR 메모리만 사용"
    echo "      - ddr-only-12c: 로컬 DDR 사용 + Socket 0(0-11 코어), Socket 1(16-27 코어) 제한"
    echo "      - cxl-only: 각 소켓에 연결된 CXL 확장 메모리만 사용"
    echo "      - interleave: DDR과 CXL 메모리에 페이지를 1:1로 교차 할당"
    echo "      - weighted: 시스템 자동 지정된 가중치(weighted interleave)로 메모리 교차 할당"
    echo ""
    echo "  -h, --help                                             도움말 출력"
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

echo "===================================================================="
echo " 듀얼 소켓 격리 Qdrant VectorDB 가동을 시작합니다."
echo "   - 설정 정책: ${POLICY^^}"
echo "===================================================================="

# 1. NUMA 하드웨어 토폴로지 검증 및 CPU 바인딩 코어 설정
# Socket 0
SOCKET0_CPUS=0
SOCKET0_DDR_NODE=0
SOCKET0_CXL_NODE=2

# Socket 1
SOCKET1_CPUS=1
SOCKET1_DDR_NODE=1
SOCKET1_CXL_NODE=3

# 2. 정책에 따른 메모리 노드 바인딩 설정 및 numactl 인자 생성
case $POLICY in
    ddr-only)
        NUMACTL_ARGS_0="--cpunodebind=$SOCKET0_CPUS -m 0"
        NUMACTL_ARGS_1="--cpunodebind=$SOCKET1_CPUS -m 1"
        ;;
    ddr-only-12c)
        NUMACTL_ARGS_0="--physcpubind=0-11 -m 0"
        NUMACTL_ARGS_1="--physcpubind=16-27 -m 1"
        ;;
    cxl-only)
        NUMACTL_ARGS_0="--cpunodebind=$SOCKET0_CPUS -m 2"
        NUMACTL_ARGS_1="--cpunodebind=$SOCKET1_CPUS -m 3"
        ;;
    interleave)
        NUMACTL_ARGS_0="--cpunodebind=$SOCKET0_CPUS"
        NUMACTL_ARGS_1="--cpunodebind=$SOCKET1_CPUS"
        ;;
    weighted)
        NUMACTL_ARGS_0="--cpunodebind=$SOCKET0_CPUS -w all"
        NUMACTL_ARGS_1="--cpunodebind=$SOCKET1_CPUS -w all"
        ;;
    weighted-2c)
        NUMACTL_ARGS_0="--physcpubind=0-1 -w all"
        NUMACTL_ARGS_1="--physcpubind=16-17 -w all"
        ;;
    *)
        echo "[ERROR] 알 수 없는 메모리 정책: $POLICY"
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
echo "       - CPU 코어 바인딩 : $SOCKET0_CPUS"
echo "       - 메모리 노드 바인딩: $MEM_NODE_0"
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
echo "       - CPU 코어 바인딩 : $SOCKET1_CPUS"
echo "       - 메모리 노드 바인딩: $MEM_NODE_1"
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
    
    if [ $HEALTH_0 -eq 1 ] && [ $HEALTH_1 -eq 1 ]; then
        echo "[SUCCESS] 양쪽 Qdrant VectorDB 서비스가 모두 성공적으로 구동되었습니다!"
        break
    fi
    
    if [ $i -eq 30 ]; then
        echo "[ERROR] 구동 대기 시간이 초과되었습니다. 컨테이너 상태를 점검해 주세요."
        docker ps -a
        exit 1
    fi
    sleep 1
done

# 7. 기동 완료 안내 출력
HOST_IP=$(hostname -I | awk '{print $1}')
echo "===================================================================="
echo " Dual Qdrant VectorDB Instances Active!"
echo "===================================================================="
echo "  Socket 0"
echo "   - Container: $CONTAINER_0"
echo "   - HTTP Port: 6333 | gRPC Port: 6334"
echo "   - Storage  : $STORAGE_0"
echo ""
echo "  Socket 1 (DDR Node 1 / CXL Node 3)"
echo "   - Container: $CONTAINER_1"
echo "   - HTTP Port: 6343 | gRPC Port: 6344"
echo "   - Storage  : $STORAGE_1"
echo "===================================================================="
echo "  외부 GPU/클라이언트 설정 IP:"
echo "   - CPU_SERVER_IP = \"$HOST_IP\""
echo "===================================================================="
