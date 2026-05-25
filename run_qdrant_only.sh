#!/bin/bash

# ==============================================================================
# run_qdrant_only.sh
# ==============================================================================
# 이 스크립트는 CPU 서버에서 단독으로 Qdrant VectorDB 컨테이너를 구동합니다.
# 외부 GPU 서버에서 원격으로 고속 임베딩 데이터를 삽입(Insert)하거나 질의할 수 있도록
# HTTP (6333) 및 gRPC (6334) 포트를 모두 호스트에 바인딩합니다.
#
# [NUMA 및 CXL 최적화 지원]
#   - 기본적으로 호스트의 모든 리소스를 사용하도록 구동할 수 있으며,
#   - 필요시 특정 NUMA 노드(예: 로컬 DDR 0번 + CXL 2번 노드)에 바인딩할 수 있습니다.
# ==============================================================================

set -e

# 스크립트 위치 기반으로 저장소 경로 계산
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QDRANT_STORAGE="${SCRIPT_DIR}/Data/qdrant_storage"
VECTORDB_CONTAINER="vectorDB_container"
VECTORDB_IMAGE="qdrant/qdrant:latest"

# 1. 저장소 디렉토리 생성
echo "[INFO] Qdrant 스토리지 디렉토리 준비 중..."
mkdir -p "$QDRANT_STORAGE"
echo "[INFO] 스토리지 경로: $QDRANT_STORAGE"

# 2. 기존 Qdrant 컨테이너 정리
if sudo docker ps -a --format '{{.Names}}' | grep -Eq "^${VECTORDB_CONTAINER}$"; then
    echo "[INFO] 기존에 실행 중인 $VECTORDB_CONTAINER 컨테이너를 정리합니다..."
    sudo docker rm -f "$VECTORDB_CONTAINER" >/dev/null 2>&1 || true
fi

# 3. NUMA 바인딩 여부 결정 (인자값으로 --numa 설정 시 활성화)
NUMA_FLAGS=""
if [[ "$1" == "--numa" ]]; then
    echo "[INFO] NUMA 바인딩 모드가 활성화되었습니다."
    # Node 0 (Local DDR) 및 Node 2 (CXL Expander)를 사용
    # CPU 코어는 Node 0의 물리 코어를 매핑 (Sapphire Rapids HT 고려)
    if command -v numactl &> /dev/null; then
        VECTORDB_CPUS=$(numactl -H | grep "node 0 cpus:" | sed 's/^node 0 cpus: //' | tr ' ' ',')
        VECTORDB_MEM_NODE="0,2"
        NUMA_FLAGS="--cpuset-cpus=$VECTORDB_CPUS --cpuset-mems=$VECTORDB_MEM_NODE --privileged"
        echo "[INFO] CPU 바인딩 코어: $VECTORDB_CPUS"
        echo "[INFO] 메모리 노드 바인딩: $VECTORDB_MEM_NODE (DDR Node 0 + CXL Node 2)"
    else
        echo "[WARNING] numactl 도구가 설치되어 있지 않아 NUMA 바인딩을 적용하지 못했습니다."
        echo "          일반 모드로 기동합니다."
    fi
fi

# 4. Qdrant 컨테이너 가동 (HTTP 6333 및 gRPC 6334 포트 오픈)
echo "[INFO] Qdrant VectorDB 컨테이너를 시작합니다..."
sudo docker run -d \
    --name "$VECTORDB_CONTAINER" \
    $NUMA_FLAGS \
    -p 6333:6333 \
    -p 6334:6334 \
    -v "$QDRANT_STORAGE":/qdrant/storage \
    --restart unless-stopped \
    "$VECTORDB_IMAGE"

# 5. 구동 확인 대기
echo "[INFO] Qdrant 서비스가 정상 작동할 때까지 대기합니다..."
for i in {1..30}; do
    if curl -sf http://localhost:6333/readyz >/dev/null 2>&1; then
        echo "[SUCCESS] Qdrant VectorDB가 성공적으로 준비되었습니다!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "[ERROR] Qdrant 구동 대기 시간이 초과되었습니다. 로그를 확인해 주세요."
        sudo docker logs "$VECTORDB_CONTAINER" | tail -n 20
        exit 1
    fi
    sleep 1
done

# 6. 접속 정보 및 IP 출력
HOST_IP=$(hostname -I | awk '{print $1}')
echo "===================================================================="
echo " Qdrant VectorDB 서버 가동 완료!"
echo "===================================================================="
echo "  * 컨테이너 이름 : $VECTORDB_CONTAINER"
echo "  * HTTP 포트     : 6333 (REST API)"
echo "  * gRPC 포트     : 6334 (원격 초고속 Insert)"
echo "  * 스토리지 경로 : $QDRANT_STORAGE"
echo "===================================================================="
echo " 외부 GPU 서버에서 원격으로 연결할 때 설정할 IP 정보:"
echo "  * CPU_SERVER_IP = \"$HOST_IP\""
echo "===================================================================="
