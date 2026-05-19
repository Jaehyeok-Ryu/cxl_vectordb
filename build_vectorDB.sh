#!/bin/bash

# ==============================================================================
# build_vectorDB.sh
# ==============================================================================
# 이 스크립트는 Qdrant VectorDB를 실행하고 문서를 삽입(Insert)하는 작업을 제어합니다.
#
# [지원 모드]
#   Mode A (사전 임베딩): 타 서버(GPU)에서 이미 임베딩한 Arrow 데이터셋을 읽어 CPU 서버에서 삽입만 수행.
#   Mode B (인라인 임베딩): GPU 서버에서 원본 텍스트를 BAAI/bge-large-en-v1.5로 실시간 임베딩하며 삽입.
# ==============================================================================

# 스크립트 위치 기반으로 DATASET_DIR 자동 계산
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET_DIR="${SCRIPT_DIR}/../Data"

# 기본 설정 (환경 변수 또는 실행 인자로 덮어쓰기 가능)
MODE=${MODE:-"A"}                      # "A" = 사전 임베딩 삽입 (CPU), "B" = 인라인 임베딩 (GPU)
DOCUMENT_COUNT=${DOCUMENT_COUNT:-10000} # 기본 1만 개 (전체는 100000000)
COLLECTION_NAME=${COLLECTION_NAME:-"wiki_passages"}
CHUNK_SIZE=${CHUNK_SIZE:-0}             # 토큰 단위 청킹 크기 (0 = 청킹 없음, 예: 100)
CHUNK_OVERLAP=${CHUNK_OVERLAP:-15}       # 청크 오버랩 크기 (토큰 수)

VECTORDB_CONTAINER="vectorDB_container"
VECTORDB_IMAGE="qdrant/qdrant"
QDRANT_STORAGE="$DATASET_DIR/qdrant_storage"

INSERT_CONTAINER="insert_container"
NET="my_network"

# 모드별 세부 경로 및 이미지 설정
if [ "$MODE" = "A" ]; then
    echo "===================================================================="
    echo "[MODE A] 사전 임베딩 데이터 삽입 모드 (CPU 서버 최적화)"
    echo "===================================================================="
    # 타 GPU 서버에서 생성한 bge 임베딩 데이터셋 경로
    KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$DATASET_DIR/c4_bge_embedded}"
    INSERT_IMAGE="vectordb_insert_image"  # 경량 CPU 이미지
    DOCKER_GPU_FLAGS=""
    PYTHON_ARGS="--dataset-path=/app/wiki_test --collection-name=$COLLECTION_NAME --document-count=$DOCUMENT_COUNT"
else
    echo "===================================================================="
    echo "[MODE B] 인라인 임베딩 및 삽입 모드 (GPU 서버용)"
    echo "===================================================================="
    # 원본 문서 데이터셋 경로 (Shahzebbb/c4_100gb 다운로드 본)
    KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$DATASET_DIR/c4_100gb}"
    INSERT_IMAGE="loadgen_image"          # PyTorch/Transformers 포함 GPU 이미지
    
    # GPU 사용 가능 여부 확인
    if command -v nvidia-smi &> /dev/null; then
        DOCKER_GPU_FLAGS="--gpus all"
        DEVICE="cuda"
    else
        echo "[WARNING] nvidia-smi가 감지되지 않았습니다. CPU 모드로 작동합니다."
        DOCKER_GPU_FLAGS=""
        DEVICE="cpu"
    fi
    
    PYTHON_ARGS="--dataset-path=/app/wiki_test --collection-name=$COLLECTION_NAME --document-count=$DOCUMENT_COUNT --inline-embed --device=$DEVICE --embedding-model=BAAI/bge-base-en-v1.5 --chunk-size=$CHUNK_SIZE --chunk-overlap=$CHUNK_OVERLAP"
fi

echo "[INFO] SCRIPT_DIR      : $SCRIPT_DIR"
echo "[INFO] DATASET_DIR     : $DATASET_DIR"
echo "[INFO] KNOWLEDGE_DIR   : $KNOWLEDGE_DIR"
echo "[INFO] QDRANT_STORAGE  : $QDRANT_STORAGE"
echo "[INFO] INSERT_IMAGE    : $INSERT_IMAGE"
echo "[INFO] DOCUMENT_COUNT  : $DOCUMENT_COUNT"
echo "[INFO] CHUNK_SIZE      : $CHUNK_SIZE (0 = No chunking)"
echo "[INFO] CHUNK_OVERLAP   : $CHUNK_OVERLAP"
echo "===================================================================="

# 디렉토리 생성
mkdir -p "$QDRANT_STORAGE"
mkdir -p "$KNOWLEDGE_DIR"

function wait_for_vectordb_ready() {
  echo "Waiting for VectorDB Container to be ready..."
  while true; do
    if curl -sf http://localhost:6333/collections >/dev/null 2>&1; then
      echo "VectorDB Container is ready."
      break
    else
      sleep 1
    fi
  done
}

# Docker 네트워크 확인 및 생성
docker network inspect $NET > /dev/null 2>&1 || docker network create $NET

# 기존 컨테이너 정리
echo "Cleaning up existing containers if any..."
docker rm -f $VECTORDB_CONTAINER >/dev/null 2>&1 || true
docker rm -f $INSERT_CONTAINER >/dev/null 2>&1 || true

# 1. Qdrant VectorDB 컨테이너 실행
echo "Starting VectorDB Container..."
docker run -d \
    --name $VECTORDB_CONTAINER \
    --network $NET \
    -p 6333:6333 \
    -v $QDRANT_STORAGE:/qdrant/storage \
    $VECTORDB_IMAGE

# Qdrant 준비 대기
wait_for_vectordb_ready

# 2. 데이터 임베딩/삽입 컨테이너 실행
echo "Starting Insert Container (${INSERT_CONTAINER})..."
docker run -it --rm \
  --name $INSERT_CONTAINER \
  --network $NET \
  $DOCKER_GPU_FLAGS \
  -v "$KNOWLEDGE_DIR":/app/wiki_test \
  $INSERT_IMAGE python3 /app/build_vectorDB.py \
                --host=$VECTORDB_CONTAINER \
                --port=6333 \
                $PYTHON_ARGS

echo "VectorDB Build & Insert process finished successfully."

