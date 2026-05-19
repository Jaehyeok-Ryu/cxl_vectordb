"""
build_vectorDB.py
=================
임베딩이 완료된 데이터셋(HF Arrow 포맷)을 읽어 Qdrant VectorDB에 삽입한다.

지원하는 두 가지 모드:
  [Mode A] 사전 임베딩 데이터 삽입 (현재 서버 - GPU 없는 경우)
      embed_documents.py 로 GPU 서버에서 생성한 Arrow 데이터셋을 사용.
      --dataset-path 에 해당 경로를 지정.

  [Mode B] 인라인 임베딩 + 삽입 (GPU 있는 서버에서 원스텝 처리)
      --inline-embed 플래그 활성화 시 raw 텍스트 문서를 직접 임베딩 후 삽입.
      --text-field 로 원본 텍스트 컬럼명 지정 (기본값: "document").

사용 예시:
  # Mode A (사전 임베딩 데이터 사용)
  python3 build_vectorDB.py \\
      --dataset-path /app/wiki_test \\
      --host vectorDB_container --port 6333

  # Mode B (인라인 임베딩, GPU 서버)
  python3 build_vectorDB.py \\
      --dataset-path /app/wiki_test \\
      --inline-embed \\
      --embedding-model BAAI/bge-large-en-v1.5 \\
      --model-cache /app/model_cache \\
      --device cuda \\
      --embed-batch-size 256 \\
      --host vectorDB_container --port 6333
"""

import os
import sys
import time
import argparse
from datasets import load_from_disk
from qdrant_client import QdrantClient, models

# --------------------------------------------------------------------------- #
# BGE Embedding (Mode B 전용)                                                  #
# --------------------------------------------------------------------------- #

def load_embedding_model(model_name: str, cache_dir, device: str):
    """BAAI/bge-large-en-v1.5 로드 (Mode B 전용)."""
    import torch
    import torch.nn.functional as F
    from transformers import AutoTokenizer, AutoModel

    print(f"[INFO] Loading embedding model: {model_name} on {device}", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(model_name, cache_dir=cache_dir)
    model     = AutoModel.from_pretrained(model_name, cache_dir=cache_dir)
    model.to(device).eval()
    print(f"[INFO] Embedding model ready (dim={model.config.hidden_size})", flush=True)
    return tokenizer, model


def mean_pooling(model_output, attention_mask):
    import torch
    token_embeddings   = model_output.last_hidden_state
    input_mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
    return torch.sum(token_embeddings * input_mask_expanded, 1) / torch.clamp(
        input_mask_expanded.sum(1), min=1e-9
    )


def encode_batch(texts, tokenizer, model, device: str, max_length: int = 512):
    import torch
    import torch.nn.functional as F
    import numpy as np

    """
    [초고속 + 저메모리 튜닝]
    대량의 텍스트 청크를 안전한 단위(mini_batch=512)로 쪼개어 GPU로 순차 전달함으로써,
    VRAM OOM(메모리 초과) 문제를 원천 차단하고 최고 수준의 병렬성을 유지합니다.
    """
    mini_batch_size = 512
    all_embeddings = []
    
    for i in range(0, len(texts), mini_batch_size):
        sub_texts = texts[i : i + mini_batch_size]
        with torch.no_grad():
            encoded = tokenizer(
                sub_texts, padding=True, truncation=True,
                max_length=max_length, return_tensors="pt"
            )
            encoded = {k: v.to(device) for k, v in encoded.items()}
            output  = model(**encoded)
            vecs    = mean_pooling(output, encoded["attention_mask"])
            vecs    = F.normalize(vecs, p=2, dim=1)
            all_embeddings.append(vecs.cpu().numpy())
            
    return np.concatenate(all_embeddings, axis=0)


def chunk_text_by_tokens(text: str, tokenizer, chunk_size: int = 100, overlap: int = 15):
    """
    [초고속 튜닝 버전] 공백 기준 단어 청킹으로 대체하여 CPU 병목을 100% 제거합니다.
    (대략 100 토큰 = 75 단어 수준으로 자동 환산하여 처리)
    """
    if not text or not isinstance(text, str):
        return [""]
    
    # 대략적인 토큰 대 단어 비율 적용 (75%)
    word_size = max(1, int(chunk_size * 0.75))
    word_overlap = max(0, int(overlap * 0.75))
    
    words = text.split()
    if len(words) <= word_size:
        return [text]
    
    chunks = []
    step = word_size - word_overlap
    if step <= 0:
        step = max(1, word_size // 2)
        
    for i in range(0, len(words), step):
        chunk_words = words[i : i + word_size]
        chunks.append(" ".join(chunk_words))
        if i + word_size >= len(words):
            break
            
    return chunks


# --------------------------------------------------------------------------- #
# Argument Parser                                                               #
# --------------------------------------------------------------------------- #

def argument_parser():
    parser = argparse.ArgumentParser(
        description="Insert embeddings into Qdrant VectorDB"
    )

    # ── 데이터셋 ───────────────────────────────────────────────────────────── #
    parser.add_argument("--dataset-path",    type=str, default="/app/wiki_test",
                        help="HF load_from_disk 경로")
    parser.add_argument("--document-count",  type=int, default=1_000_000_000,
                        help="삽입할 최대 문서 수 (기본값: 전체)")
    parser.add_argument("--collection-name", type=str, default="wiki_passages",
                        help="Qdrant 컬렉션 이름")

    # ── Qdrant 연결 ────────────────────────────────────────────────────────── #
    parser.add_argument("--host", type=str, default="vectorDB_container",
                        help="Qdrant 호스트 (Docker 컨테이너명 또는 IP)")
    parser.add_argument("--port", type=int, default=6333,
                        help="Qdrant 포트 (기본값: 6333)")

    # ── 삽입 설정 ─────────────────────────────────────────────────────────── #
    parser.add_argument("--upload-workers",  type=int, default=4,
                        help="Qdrant 업로드 병렬 스레드 수")
    parser.add_argument("--upload-batch",    type=int, default=10000,
                        help="Qdrant 업로드 배치 크기")

    # ── Mode B: 인라인 임베딩 ─────────────────────────────────────────────── #
    parser.add_argument("--inline-embed",    action="store_true",
                        help="[Mode B] raw 텍스트 데이터셋을 직접 임베딩 후 삽입")
    parser.add_argument("--embedding-model", type=str, default="BAAI/bge-base-en-v1.5",
                        help="[Mode B] 임베딩 모델 이름")
    parser.add_argument("--model-cache",     type=str, default=None,
                        help="[Mode B] HuggingFace 모델 캐시 경로")
    parser.add_argument("--device",          type=str, default="cuda",
                        choices=["cuda", "cpu"],
                        help="[Mode B] 임베딩 디바이스 (cuda / cpu)")
    parser.add_argument("--embed-batch-size", type=int, default=512,
                        help="[Mode B] 임베딩 배치 크기 (GPU VRAM에 맞게 조정)")
    parser.add_argument("--max-length",      type=int, default=512,
                        help="[Mode B] 토크나이저 최대 시퀀스 길이")
    parser.add_argument("--text-field",      type=str, default="document",
                        help="[Mode B] 원본 텍스트 컬럼명")
    parser.add_argument("--id-field",        type=str, default="chunk_id",
                        help="[Mode B] ID 컬럼명 (없으면 자동 생성)")
    parser.add_argument("--chunk-size",      type=int, default=0,
                        help="[Mode B] 토큰 기준 텍스트 청킹 크기 (0 = 청킹 없음, 예: 100)")
    parser.add_argument("--chunk-overlap",   type=int, default=15,
                        help="[Mode B] 청크 오버랩 크기 (토큰 수)")

    return parser.parse_args()


# --------------------------------------------------------------------------- #
# Main                                                                         #
# --------------------------------------------------------------------------- #

def main():
    args = argument_parser()

    # ── 데이터셋 로드 ─────────────────────────────────────────────────────── #
    if not os.path.exists(args.dataset_path):
        print(f"[ERROR] Dataset path not found: '{args.dataset_path}'", flush=True)
        sys.exit(1)

    print(f"[INFO] Loading dataset from: {args.dataset_path}", flush=True)
    dataset = load_from_disk(args.dataset_path)

    # DatasetDict 처리
    if hasattr(dataset, "keys"):
        split = "train" if "train" in dataset else list(dataset.keys())[0]
        print(f"[INFO] DatasetDict → using split: '{split}'", flush=True)
        dataset = dataset[split]

    if len(dataset) == 0:
        print("[ERROR] The dataset is empty.", flush=True)
        sys.exit(1)

    print(f"[INFO] Dataset rows: {len(dataset):,}", flush=True)
    print(f"[INFO] Columns: {dataset.column_names}", flush=True)

    # ── Mode 결정 ─────────────────────────────────────────────────────────── #
    if args.inline_embed:
        # Mode B: raw text → embed on-the-fly
        print("[MODE] B: Inline embedding enabled", flush=True)
        if args.text_field not in dataset.column_names:
            print(f"[ERROR] text-field '{args.text_field}' not in dataset columns: "
                  f"{dataset.column_names}", flush=True)
            sys.exit(1)

        try:
            import torch
        except ImportError:
            print("[ERROR] PyTorch not installed. Required for --inline-embed.", flush=True)
            sys.exit(1)

        if args.device == "cuda" and not torch.cuda.is_available():
            print("[WARNING] CUDA unavailable. Falling back to CPU.", flush=True)
            args.device = "cpu"

        tokenizer, emb_model = load_embedding_model(
            args.embedding_model, args.model_cache, args.device
        )
        vector_dim = emb_model.config.hidden_size

    else:
        # Mode A: 사전 임베딩 데이터 사용
        print("[MODE] A: Using pre-computed embeddings", flush=True)
        if "embedding" not in dataset.column_names:
            print("[ERROR] 'embedding' column not found. "
                  "Use --inline-embed for raw text datasets.", flush=True)
            sys.exit(1)
        vector_dim = len(dataset[0]["embedding"])
        tokenizer  = None
        emb_model  = None

    print(f"[INFO] Vector dimension: {vector_dim}", flush=True)

    # ── Qdrant 클라이언트 설정 ────────────────────────────────────────────── #
    print(f"[INFO] Connecting to Qdrant at {args.host}:{args.port}", flush=True)
    client = QdrantClient(host=args.host, port=args.port)
    collection_name = args.collection_name

    # ── 컬렉션 확인 / 생성 ────────────────────────────────────────────────── #
    try:
        client.get_collection(collection_name=collection_name)
        print(f"[INFO] Collection '{collection_name}' already exists.", flush=True)
    except Exception:
        print(f"[INFO] Creating collection '{collection_name}' (dim={vector_dim})...", flush=True)
        client.create_collection(
            collection_name=collection_name,
            vectors_config=models.VectorParams(
                size=vector_dim,
                distance=models.Distance.COSINE,
            ),
        )

    # ── 기존 삽입 개수 확인 (재시작 지원) ────────────────────────────────── #
    try:
        existing_count = client.count(collection_name=collection_name, timeout=3000).count
    except Exception as e:
        print(f"[ERROR] Cannot fetch existing count: {e}", flush=True)
        sys.exit(1)

    start_idx = existing_count
    end_idx   = min(len(dataset), start_idx + args.document_count)
    print(f"[INFO] Already in DB: {existing_count:,}", flush=True)
    print(f"[INFO] Will insert rows [{start_idx:,} ~ {end_idx:,}]", flush=True)

    if start_idx >= len(dataset):
        print("[INFO] No more data to add.", flush=True)
        return

    # ── 업로드 함수 (Mode A) ─────────────────────────────────────────────── #
    def upload_precomputed(start: int, end: int):
        t = time.time()
        batch = dataset.select(range(start, end))
        points = [
            models.PointStruct(
                id=start + idx,
                vector=item["embedding"],
                payload={
                    "chunk_id": item.get("chunk_id", str(start + idx)),
                    "document": item.get("document", ""),
                },
            )
            for idx, item in enumerate(batch)
        ]
        client.upload_points(collection_name=collection_name, points=points)
        print(
            f"[UPLOAD] rows {start:,}–{end:,} "
            f"({end - start} docs, {time.time() - t:.1f}s)",
            flush=True,
        )

    # ── 업로드 함수 (Mode B) ─────────────────────────────────────────────── #
    def upload_inline(start: int, end: int, current_id: int) -> int:
        t = time.time()
        # 임베딩 배치는 embed_batch_size 단위로 처리
        all_vecs   = []
        all_texts  = []
        all_ids    = []

        for emb_start in range(start, end, args.embed_batch_size):
            emb_end  = min(emb_start + args.embed_batch_size, end)
            sub      = dataset.select(range(emb_start, emb_end))
            texts    = sub[args.text_field]
            if args.id_field in sub.column_names:
                ids = [str(x) for x in sub[args.id_field]]
            else:
                ids = [str(i) for i in range(emb_start, emb_end)]

            # 토큰 청킹 적용 여부에 따른 데이터 전처리
            sub_texts = []
            sub_ids = []

            if args.chunk_size > 0:
                for text, base_id in zip(texts, ids):
                    chunks = chunk_text_by_tokens(text, tokenizer, args.chunk_size, args.chunk_overlap)
                    for idx, chunk in enumerate(chunks):
                        sub_texts.append(chunk)
                        sub_ids.append(f"{base_id}_chunk_{idx}")
            else:
                sub_texts = texts
                sub_ids = ids

            if sub_texts:
                vecs = encode_batch(sub_texts, tokenizer, emb_model, args.device, args.max_length)
                all_vecs.extend(vecs.tolist())
                all_texts.extend(sub_texts)
                all_ids.extend(sub_ids)

        points = [
            models.PointStruct(
                id=current_id + idx,
                vector=vec,
                payload={
                    "chunk_id": all_ids[idx],
                    "document": all_texts[idx],
                },
            )
            for idx, vec in enumerate(all_vecs)
        ]
        client.upload_points(collection_name=collection_name, points=points)
        print(
            f"[UPLOAD] rows {start:,}–{end:,} "
            f"({end - start} source docs -> {len(all_vecs)} chunks, {time.time() - t:.1f}s)",
            flush=True,
        )
        return current_id + len(all_vecs)

    # ── 실제 삽입 ─────────────────────────────────────────────────────────── #
    total_start = time.time()

    if args.inline_embed:
        # Mode B: GPU 직렬 실행
        upload_batch = args.embed_batch_size
        print(f"[INFO] Starting upload in Mode B, batch_size={upload_batch}", flush=True)
        
        current_id = start_idx
        for start in range(start_idx, end_idx, upload_batch):
            end = min(start + upload_batch, end_idx)
            current_id = upload_inline(start, end, current_id)
            
    else:
        # Mode A: 멀티스레드 병렬 업로드
        upload_batch = args.upload_batch
        print(f"[INFO] Starting upload in Mode A with {args.upload_workers} worker(s), "
              f"batch_size={upload_batch}", flush=True)
        
        with ThreadPoolExecutor(max_workers=args.upload_workers) as executor:
            for start in range(start_idx, end_idx, upload_batch):
                end = min(start + upload_batch, end_idx)
                executor.submit(upload_precomputed, start, end)

    total_elapsed = time.time() - total_start
    print(f"[INFO] Total upload time: {total_elapsed:.1f}s "
          f"({total_elapsed/60:.1f} min)", flush=True)

    # ── 최종 개수 확인 ────────────────────────────────────────────────────── #
    try:
        total_points = client.count(collection_name=collection_name, timeout=3000).count
        print(f"[INFO] Total points in '{collection_name}': {total_points:,}", flush=True)
    except Exception as e:
        print(f"[WARNING] Cannot verify total count: {e}", flush=True)


if __name__ == "__main__":
    main()
