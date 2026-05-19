#!/bin/bash
# =========================================================================
# CXL VectorDB - GPU Ingestion & Remote Upload Script
# =========================================================================
# * Description: GPU 서버에서 이 스크립트를 기동하여, 로컬 데이터셋을 GPU로
#                초고속 임베딩하고 CPU 서버의 Qdrant VectorDB로 실시간 전송합니다.
# * Usage: ./run_gpu_ingestion.sh [QDRANT_HOST_IP] [QDRANT_PORT]
# =========================================================================

# 1. 스크립트 실행 경로를 본인이 위치한 폴더로 고정
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 2. 파라미터 기본값 설정
QDRANT_HOST=${1:-"localhost"}  # Qdrant가 가동 중인 CPU 서버 IP (단일 서버인 경우 localhost)
QDRANT_PORT=${2:-"6333"}
EMBED_BATCH_SIZE=${3:-"2048"}   # 기본 배치 사이즈를 512로 설정 (VRAM 여유가 커서 연산 효율이 극적으로 상승합니다)
COLLECTION_NAME="wiki_passages"

# 로컬 대형 데이터셋 경로 및 모델 설정
DATASET_PATH="/home/cxl_qemu/cxl_vectordb/Data/c4_100gb"
MODEL_NAME="BAAI/bge-base-en-v1.5"
MODEL_CACHE="/home/cxl_qemu/.cache/huggingface"

echo "========================================================================="
echo " Start GPU Inline Embedding & Remote Ingestion"
echo "========================================================================="
echo " Qdrant Target: $QDRANT_HOST:$QDRANT_PORT"
echo " Dataset Path : $DATASET_PATH"
echo " Model Name   : $MODEL_NAME"
echo " Batch Size   : $EMBED_BATCH_SIZE"
echo "========================================================================="

# 3. 데이터셋 폴더 존재 여부 검증
if [ ! -d "$DATASET_PATH" ]; then
    echo "❌ Error: Dataset path not found at $DATASET_PATH"
    echo "   Please download or copy the c4_100gb dataset to this path first."
    exit 1
fi

# 4. GPU 인라인 임베딩 & 원격 Qdrant 삽입 실행 (Mode B)
python3 build_vectorDB.py \
    --dataset-path "$DATASET_PATH" \
    --inline-embed \
    --embedding-model "$MODEL_NAME" \
    --model-cache "$MODEL_CACHE" \
    --device cuda \
    --embed-batch-size "$EMBED_BATCH_SIZE" \
    --host "$QDRANT_HOST" \
    --port "$QDRANT_PORT" \
    --collection-name "$COLLECTION_NAME" \
    --text-field "text" \
    # --document-count 100000 # 테스트용으로 100,000건 제한 지정 (전체는 제거하거나 큰 값 지정)

echo "========================================================================="
echo "Ingestion Complete! VectorDB is successfully built on $QDRANT_HOST."
echo "========================================================================="
