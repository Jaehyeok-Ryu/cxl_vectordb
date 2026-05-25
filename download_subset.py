#!/usr/bin/env python3
"""
download_subset.py
==================
Hugging Face의 BramVanroy/CommonCrawl-CreativeCommons 데이터셋에서 
오직 'text' 필드만 추출하여 지정된 개수(기본값: 1,000,000건)만큼 로컬 스토리지에 
오프라인 Arrow 포맷으로 저장하는 고속/저메모리 유틸리티입니다.

이 스크립트는 Streaming 모드와 Generator 방식을 활용하여 
RAM 사용량을 100MB 미만으로 억제하면서 대용량 데이터를 안전하게 다운로드합니다.
"""

import os
import sys
import time
import argparse
from datasets import load_dataset, Dataset

def argument_parser():
    parser = argparse.ArgumentParser(description="Download a subset of BramVanroy/CommonCrawl-CreativeCommons")
    parser.add_argument("--document-count", type=int, default=1000000,
                        help="다운로드할 최대 문서 수 (기본값: 1000000)")
    parser.add_argument("--save-path", type=str, default="/home/cxl_qemu/cxl_vectordb/Data/commoncrawl_subset",
                        help="로컬 저장 경로")
    return parser.parse_args()

def main():
    args = argument_parser()
    
    dataset_name = "BramVanroy/CommonCrawl-CreativeCommons"
    doc_limit = args.document_count
    save_path = args.save_path
    
    print("=========================================================================", flush=True)
    print(" CommonCrawl CC Subset One-Time Downloader", flush=True)
    print("=========================================================================", flush=True)
    print(f"  - Target Dataset  : {dataset_name}", flush=True)
    print(f"  - Document Count  : {doc_limit:,} items", flush=True)
    print(f"  - Save Location   : {save_path}", flush=True)
    print("=========================================================================", flush=True)

    start_time = time.time()

    # 1. 스트리밍 연결
    print("[INFO] Connecting to Hugging Face Hub (Streaming Mode)...", flush=True)
    try:
        streamed_ds = load_dataset(dataset_name, split="train", streaming=True)
    except Exception as e:
        print(f"[ERROR] Failed to connect to HF Hub: {e}", flush=True)
        sys.exit(1)
        
    # 2. 고속 & 저메모리 제너레이터 정의 (RAM OOM 방지용)
    def gen_subset():
        count = 0
        for item in streamed_ds:
            if count >= doc_limit:
                break
            
            # 'text' 필드 추출 (비어있거나 문자열이 아닌 경우 대비 예외처리)
            text_val = item.get("text", "")
            if text_val:
                yield {"text": str(text_val)}
                count += 1
                
                if count % 50000 == 0:
                    print(f"[PROGRESS] Downloaded and processed {count:,} / {doc_limit:,} docs...", flush=True)

    # 3. 제너레이터로부터 고속 캐싱 데이터셋 구성
    print("[INFO] Starting chunk download and mapping to Arrow cache...", flush=True)
    try:
        local_dataset = Dataset.from_generator(gen_subset)
    except Exception as e:
        print(f"[ERROR] Failed during dataset building: {e}", flush=True)
        sys.exit(1)

    # 4. 로컬 스토리지에 영구 파일로 저장
    print(f"[INFO] Writing final Arrow dataset files to: {save_path}", flush=True)
    os.makedirs(os.path.dirname(save_path), exist_ok=True)
    try:
        local_dataset.save_to_disk(save_path)
    except Exception as e:
        print(f"[ERROR] Failed to save dataset to disk: {e}", flush=True)
        sys.exit(1)

    elapsed_time = time.time() - start_time
    
    # 최종 디스크 용량 계산
    total_size = 0
    for dirpath, _, filenames in os.walk(save_path):
        for filename in filenames:
            total_size += os.path.getsize(os.path.join(dirpath, filename))
            
    print("=========================================================================", flush=True)
    print(" Downloader completed successfully!", flush=True)
    print("=========================================================================", flush=True)
    print(f"  - Total Elapsed Time : {elapsed_time:.1f} seconds ({elapsed_time/60:.1f} minutes)", flush=True)
    print(f"  - Saved Folder Size  : {total_size / (1024 * 1024 * 1024):.2f} GB", flush=True)
    print(f"  - Actual Items Saved : {len(local_dataset):,} items", flush=True)
    print("=========================================================================", flush=True)

if __name__ == "__main__":
    main()
