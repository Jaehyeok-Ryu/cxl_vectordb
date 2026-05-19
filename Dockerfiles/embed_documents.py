"""
embed_documents.py
==================
GPU 서버에서 실행: 원본 c4_100gb 문서 텍스트를 BAAI/bge-large-en-v1.5로 임베딩 후
HuggingFace datasets 형식(.arrow)으로 저장한다.

저장된 결과를 build_vectorDB.py의 --dataset-path로 지정하면
이 서버(GPU 없는 서버)에서도 Qdrant 삽입 가능.

출력 데이터셋 스키마:
  - chunk_id  : str  (원본 chunk_id 또는 자동 생성)
  - document  : str  (원본 텍스트)
  - embedding : List[float]  (1024-dim, bge-large-en-v1.5)

사용법 (GPU 서버):
  python3 embed_documents.py \\
      --dataset-path /path/to/Shahzebbb_c4_100gb \\   # HF load_from_disk 경로
      --output-path  /path/to/c4_bge_embedded \\      # 저장 경로
      --model-name   BAAI/bge-large-en-v1.5 \\
      --model-cache  /path/to/model_cache \\           # HF_HOME 캐시 경로
      --batch-size   256 \\
      --document-count 1000000 \\                      # 0 = 전체
      --device cuda
"""

import os
import sys
import time
import argparse
import torch
import numpy as np
from datasets import load_from_disk, Dataset
from transformers import AutoTokenizer, AutoModel
import torch.nn.functional as F


# --------------------------------------------------------------------------- #
# BGE embedding helper                                                         #
# --------------------------------------------------------------------------- #

def mean_pooling(model_output, attention_mask):
    """Mean pooling over token embeddings (sentence-transformers 방식)."""
    token_embeddings = model_output.last_hidden_state  # (B, T, H)
    input_mask_expanded = (
        attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
    )
    return torch.sum(token_embeddings * input_mask_expanded, 1) / torch.clamp(
        input_mask_expanded.sum(1), min=1e-9
    )


def load_model(model_name: str, cache_dir: str | None, device: str):
    print(f"[INFO] Loading tokenizer & model: {model_name}", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(model_name, cache_dir=cache_dir)
    model = AutoModel.from_pretrained(model_name, cache_dir=cache_dir)
    model.to(device)
    model.eval()
    print(f"[INFO] Model loaded on device={device}", flush=True)
    return tokenizer, model


def encode_batch(texts: list[str], tokenizer, model, device: str, max_length: int = 512) -> np.ndarray:
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
                sub_texts,
                padding=True,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            encoded = {k: v.to(device) for k, v in encoded.items()}
            output = model(**encoded)
            embeddings = mean_pooling(output, encoded["attention_mask"])
            embeddings = F.normalize(embeddings, p=2, dim=1)
            all_embeddings.append(embeddings.cpu().numpy())
            
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
# Main                                                                         #
# --------------------------------------------------------------------------- #

def argument_parser():
    parser = argparse.ArgumentParser(
        description="Embed c4_100gb documents with BAAI/bge-large-en-v1.5"
    )
    parser.add_argument("--dataset-path",   type=str, required=True,
                        help="load_from_disk 경로 (Shahzebbb/c4_100gb를 저장한 디렉토리)")
    parser.add_argument("--output-path",    type=str, required=True,
                        help="임베딩 결과를 저장할 경로 (HF dataset 포맷)")
    parser.add_argument("--model-name",     type=str, default="BAAI/bge-base-en-v1.5",
                        help="임베딩 모델 이름 (HuggingFace hub 또는 로컬 경로)")
    parser.add_argument("--model-cache",    type=str, default=None,
                        help="HuggingFace 모델 캐시 디렉토리 (HF_HOME)")
    parser.add_argument("--document-count", type=int, default=0,
                        help="처리할 문서 수 (0 = 전체)")
    parser.add_argument("--start-idx",      type=int, default=0,
                        help="처리를 시작할 인덱스 (재시작/분산 처리용)")
    parser.add_argument("--batch-size",     type=int, default=512,
                        help="임베딩 배치 크기 (GPU VRAM에 맞게 조정)")
    parser.add_argument("--text-field",     type=str, default="document",
                        help="데이터셋에서 텍스트로 사용할 컬럼명")
    parser.add_argument("--id-field",       type=str, default="chunk_id",
                        help="데이터셋에서 ID로 사용할 컬럼명 (없으면 자동 생성)")
    parser.add_argument("--device",         type=str, default="cuda",
                        choices=["cuda", "cpu"],
                        help="사용할 디바이스 (cuda / cpu)")
    parser.add_argument("--max-length",     type=int, default=512,
                        help="토크나이저 최대 시퀀스 길이")
    parser.add_argument("--chunk-size",     type=int, default=0,
                        help="토큰 기준 텍스트 청킹 크기 (0 = 청킹 없음, 예: 100)")
    parser.add_argument("--chunk-overlap",  type=int, default=15,
                        help="청크 오버랩 크기 (토큰 수)")
    return parser.parse_args()


def main():
    args = argument_parser()

    # ── 디바이스 확인 ─────────────────────────────────────────────────────── #
    if args.device == "cuda" and not torch.cuda.is_available():
        print("[WARNING] CUDA unavailable. Falling back to CPU.", flush=True)
        args.device = "cpu"
    print(f"[INFO] Using device: {args.device}", flush=True)
    if args.device == "cuda":
        print(f"[INFO] GPU: {torch.cuda.get_device_name(0)}", flush=True)

    # ── 데이터셋 로드 ─────────────────────────────────────────────────────── #
    if not os.path.exists(args.dataset_path):
        print(f"[ERROR] Dataset path not found: {args.dataset_path}", flush=True)
        sys.exit(1)

    print(f"[INFO] Loading dataset from: {args.dataset_path}", flush=True)
    dataset = load_from_disk(args.dataset_path)

    # DatasetDict인 경우 train split 선택
    if hasattr(dataset, "keys"):
        split = "train" if "train" in dataset else list(dataset.keys())[0]
        print(f"[INFO] DatasetDict detected. Using split: '{split}'", flush=True)
        dataset = dataset[split]

    total = len(dataset)
    start_idx = args.start_idx
    end_idx   = total if args.document_count == 0 else min(total, start_idx + args.document_count)
    print(f"[INFO] Dataset total rows: {total:,}", flush=True)
    print(f"[INFO] Processing rows [{start_idx:,} ~ {end_idx:,}]", flush=True)

    # ── 모델 로드 ─────────────────────────────────────────────────────────── #
    tokenizer, model = load_model(args.model_name, args.model_cache, args.device)
    vector_dim = model.config.hidden_size
    print(f"[INFO] Embedding dimension: {vector_dim}", flush=True)

    # ── 임베딩 루프 ───────────────────────────────────────────────────────── #
    chunk_ids  = []
    documents  = []
    embeddings = []

    t0 = time.time()
    processed = 0

    for batch_start in range(start_idx, end_idx, args.batch_size):
        batch_end  = min(batch_start + args.batch_size, end_idx)
        batch      = dataset[batch_start:batch_end]  # 초고속 슬라이싱 (딕셔너리 리턴)

        # chunk_id 처리: 컬럼이 없으면 인덱스로 대체
        if args.id_field in batch:
            ids = [str(x) for x in batch[args.id_field]]
        else:
            ids = [str(i) for i in range(batch_start, batch_end)]

        # 토큰 청킹 적용 여부에 따른 데이터 전처리
        batch_texts = []
        batch_ids = []

        if args.chunk_size > 0:
            for text, base_id in zip(batch[args.text_field], ids):
                chunks = chunk_text_by_tokens(text, tokenizer, args.chunk_size, args.chunk_overlap)
                for idx, chunk in enumerate(chunks):
                    batch_texts.append(chunk)
                    batch_ids.append(f"{base_id}_chunk_{idx}")
        else:
            batch_texts = batch[args.text_field]
            batch_ids = ids

        # 임베딩 생성
        if batch_texts:
            vecs = encode_batch(batch_texts, tokenizer, model, args.device, args.max_length)

            chunk_ids.extend(batch_ids)
            documents.extend(batch_texts)
            embeddings.extend(vecs.tolist())

        processed += len(ids)
        elapsed = time.time() - t0
        speed   = processed / elapsed if elapsed > 0 else 0
        eta     = (end_idx - start_idx - processed) / speed if speed > 0 else 0

        print(
            f"[PROGRESS] {processed:>8,}/{end_idx - start_idx:,} "
            f"| {speed:.0f} source_docs/s | ETA {eta/60:.1f} min | total_chunks={len(chunk_ids):,}",
            flush=True,
        )

    # ── 저장 ─────────────────────────────────────────────────────────────── #
    print(f"[INFO] Saving embedded dataset to: {args.output_path}", flush=True)
    os.makedirs(args.output_path, exist_ok=True)

    result_dataset = Dataset.from_dict({
        "chunk_id":  chunk_ids,
        "document":  documents,
        "embedding": embeddings,
    })
    result_dataset.save_to_disk(args.output_path)

    total_time = time.time() - t0
    print(f"[INFO] Done. {len(result_dataset):,} chunks saved in {total_time/60:.1f} min.", flush=True)
    print(f"[INFO] Output: {args.output_path}", flush=True)


if __name__ == "__main__":
    main()
