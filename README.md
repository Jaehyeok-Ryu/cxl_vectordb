# 🚀 CXL RAG VectorDB Build Pipeline (BAAI/bge-large-en-v1.5)

이 리포지토리는 CXL RAG 시뮬레이션 워크로드에서 성능 벤치마크 및 시뮬레이션을 진행할 때 사용하는 **Qdrant VectorDB 구축 파이프라인**을 단독으로 격리하여 설계된 독립형 리포지토리입니다.

기존 사전 임베딩(`all-MiniLM-L6-v2`, 384차원)의 품질 한계를 극복하기 위해 최신 고성능 모델인 **`BAAI/bge-large-en-v1.5` (1024차원)**을 활용하여 텍스트 데이터를 직접 임베딩하고 DB에 삽입하는 모든 도구를 제공합니다.

---

## 🛠️ 듀얼 모드 아키텍처 지원

현재 서버(CPU 전용)와 향후 통합될 타겟 서버(GPU) 환경 모두에서 사용할 수 있도록 유연한 **듀얼 모드 아키텍처**로 설계되었습니다:

- **Mode A (사전 임베딩 데이터 삽입 - CPU 최적화)**
  - GPU 성능이 우수한 다른 서버에서 `embed_documents.py`를 실행하여 원본 문서의 임베딩 연산을 사전에 완료합니다.
  - 생성된 Arrow 데이터셋 폴더를 현재 CPU 서버로 복사(rsync/SCP)한 뒤, CPU 서버에서는 PyTorch/Transformers 설치 없이 **매우 빠르게 DB 주입만 처리**합니다.
  - 이 방식은 CPU 서버의 메모리와 CPU 리소스를 낭비하지 않으며 이미지 크기가 수백 MB 수준으로 가볍습니다.

- **Mode B (실시간 인라인 임베딩 & 삽입 - GPU 전용)**
  - GPU 환경에서 단 한 줄의 명령어로 원본 텍스트 로딩, BGE 모델 실시간 연산(CUDA), Qdrant 데이터 주입까지 원스톱으로 빌드합니다.

---

## 📂 디렉토리 구조

```text
cxl_vectordb/
├── build_vectorDB.sh         # 🚀 런처 스크립트 (모드 전환, 네트워크 구성 및 볼륨 바인딩 자동화)
├── Dockerfiles/
│   ├── build_vectorDB.py     # Qdrant 연결, 컬렉션 검증 및 데이터 삽입 코어 스크립트 (Mode A/B 공용)
│   ├── embed_documents.py    # [GPU 전용] BGE-large-en-v1.5 모델 일괄 임베딩 생성기
│   ├── download_huggingface.py# 원본 데이터셋/모델 허브 다운로더
│   ├── Dockerfile.vectordb_insert # [CPU 전용] PyTorch가 제외된 100MB대 경량 삽입 이미지
│   └── Dockerfile.loadgen     # [GPU 전용] PyTorch/CUDA 12.1 및 임베딩 패키지 풀세트 이미지
└── README.md                 # 본 문서
```

---

## 🏃‍♂️ 서버 환경별 실행 가이드

### 1. GPU 서버: 임베딩 생성 (오프라인 연산)
GPU가 탑재된 장비에서 원본 데이터셋(`Shahzebbb/c4_100gb`)을 임베딩합니다.

```bash
# 1. GPU 파이프라인 이미지 빌드
cd Dockerfiles
docker build -f Dockerfile.loadgen -t loadgen_image .
cd ..

# 2. 원본 데이터셋 다운로드 (약 61GB)
docker run --rm -v ~/.cache:/root/.cache -v $(pwd)/..:/workspace \
  loadgen_image python3 /workspace/Dockerfiles/download_huggingface.py \
  --hf-dir="Shahzebbb/c4_100gb" \
  --save-dir="/workspace/Data/c4_100gb"

# 3. BGE-large-en-v1.5 임베딩 추출 실행
# --document-count 0 으로 설정 시 4600만 개 전체 연산 (초기 테스트는 10000개 등으로 시도 가능)
docker run --rm --gpus all \
  -v ~/.cache:/root/.cache \
  -v $(pwd)/..:/workspace \
  loadgen_image python3 /app/embed_documents.py \
  --dataset-path="/workspace/Data/c4_100gb" \
  --output-path="/workspace/Data/c4_bge_embedded" \
  --document-count=10000 \
  --batch-size=256 \
  --device=cuda
```
완료되면 `Data/c4_bge_embedded` 디렉토리에 생성된 Arrow 포맷 결과물을 대상 CPU 서버로 안전하게 전송합니다.

---

### 2. CPU 서버: VectorDB 신속 주입
임베딩이 포함된 결과 데이터가 `Data/c4_bge_embedded`로 준비되었다면, 현 서버(CPU 전용)에서 실행합니다.

```bash
# 1. 초경량 CPU 삽입 전용 이미지 빌드
cd Dockerfiles
docker build -f Dockerfile.vectordb_insert -t vectordb_insert_image .
cd ..

# 2. 실행 스크립트 실행 (MODE=A 사용)
# DOCUMENT_COUNT는 삽입할 레코드 수를 제어합니다.
MODE=A DOCUMENT_COUNT=10000 bash build_vectorDB.sh
```

---

### 3. GPU 통합 서버: 원스톱 인라인 빌드
만약 처음부터 GPU가 포함된 서버에서 텍스트 임베딩과 DB 빌드를 한 번에 하고 싶다면 아래와 같이 실행합니다.

```bash
# 1. GPU용 이미지 빌드
cd Dockerfiles
docker build -f Dockerfile.loadgen -t loadgen_image .
cd ..

# 2. 실시간 GPU 임베딩 및 DB 삽입 실행 (MODE=B 사용)
MODE=B DOCUMENT_COUNT=10000 bash build_vectorDB.sh
```

---

## 🔒 라이센스 및 기여

본 소프트웨어는 내부 RAG 벤치마크 및 시뮬레이션을 위한 용도로 작성되었습니다. 기여 및 개선 사항은 내부 Git CLI를 통해 Commit 및 Pull Request를 생성해 주세요.
