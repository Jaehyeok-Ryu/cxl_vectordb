# 📈 VectorDB Intel Xeon PMU (perf) 성능 계측 및 분석 가이드

이 디렉터리는 가설 1(Hypothesis 1)인 **"Inter-socket interconnect의 대역폭 제약과 원격 메모리 접근(Remote access)의 지연 증가가 CHA ToR/IRQ 큐 체증(HOL blocking)을 유발하고, 이로 인해 로컬 메모리 트랜잭션까지 제한(Throttling)되어 시스템 전체 Throughput이 저하된다"**는 주장을 실측 데이터를 기반으로 수학적으로 검증하기 위해 구성된 성능 분석 툴킷입니다.

---

## 🗺️ 디렉터리 구조 및 가동 흐름

```
perf_metrics/
 ├── profile_perf_metrics.sh  # 수집 및 자동 분석 통합 쉘 스크립트
 ├── perf_metrics_readme.md   # 본 분석 가이드 문서
 └── perf_results/            # 성능 분석 결과가 저장되는 아카이빙 폴더
      └── run_[라벨]_[시간]/
           ├── raw_run_1.txt  # perf stat 1회차 날것의 데이터
           ├── raw_run_2.txt  # perf stat 2회차 날것의 데이터
           ├── raw_run_3.txt  # perf stat 3회차 날것의 데이터
           ├── perf_summary.txt  # 평균 계측 수치 요약 및 Matchup 결합 분석서
           └── perf_summary.csv  # 엑셀/판다스 시각화용 통합 CSV 파일
```

---

## 🚀 사용법 및 실행 명령어 (Usage Guide)

### 1️⃣ 사전 권한 요구사항
Uncore PMU(CHA, UPI) 계측 및 System-wide(-a) 카운터 수집을 위해 **root 권한(`sudo`)**이 필요합니다.

### 2️⃣ 실행 명령어 예시
```bash
cd /home/cxl_qemu/cxl_vectordb/perf_metrics

# 예시) 소켓 0 Qdrant 컨테이너에 대해 15초 웜업 대기 후, 60초씩 3회 반복 측정하여 성능 요약 추출
sudo ./profile_perf_metrics.sh --container vectorDB_container_socket0 --duration 60 --runs 3 --label Socket0_weighted_RPS30
```

---

## 🎯 측정하는 성능 카운터 지표 정리 (PMU Events Reference)

호스트 시스템의 하드웨어 PMU(Performance Monitoring Unit)를 통해 정밀 수집하는 **32가지 핵심 하드웨어 카운터(Events)**의 정의와 의미는 다음과 같습니다.

### 1. 코어 파이프라인 지표 (Core Execution Metrics)
* `slots`: CPU 코어가 명령어를 처리하기 위해 사용할 수 있는 총 파이프라인 슬롯의 수입니다. (Topdown 분석의 기본 분모)
* `topdown-mem-bound`: 메모리 서브시스템(캐시/메모리)의 정체로 인해 유휴 상태가 된 파이프라인 슬롯의 수입니다.
* `topdown-be-bound`: 실행 유닛 분산 지연 등 백엔드(Back-end) 유닛 문제로 인해 멈춘 파이프라인 슬롯의 수입니다.
* `cycle_activity.stalls_l3_miss`: L3 캐시(LLC) 미스가 발생하여 대기 중일 때 파이프라인이 멈춘(stall) 사이클 수입니다.
* `mem_inst_retired.all_loads`: CPU 코어가 완전히 수행 완료(Retired)한 전체 메모리 로드(Read) 명령어 개수입니다.
* `mem_inst_retired.all_stores`: CPU 코어가 완전히 수행 완료(Retired)한 전체 메모리 스토어(Write) 명령어 개수입니다.

### 2. 소켓 간 연결망 지표 (Interconnect Metrics)
* `uncore_upi_*/unc_upi_txl_flits.all_data/`: 소켓 외부의 원격 메모리로 접근하기 위해 UPI 링크를 통해 전송된 총 데이터 Flit 수입니다. (소켓 간 remote bandwidth 측정용)

### 3. 언코어 인입 큐 지표 (Uncore Ingress Queue Metrics)
* `uncore_cha_*/unc_cha_rxc_inserts.irq/`: RxC(Receive Caching) Ingress Queue에 유입된 일반 요청 삽입 횟수입니다.
* `uncore_cha_*/unc_cha_rxc_inserts.irq_rej/`: 큐 포화 및 체증으로 인해 언코어(Uncore)가 강제로 드롭/거부한 코어 요청 횟수입니다. (과부하 지표)
* `uncore_cha_*/unc_cha_rxc_inserts.ipq/`: RxC Ingress Queue에 유입된 캐시 일관성 유지를 위한 Probe(Snoop) 요청 횟수입니다.
* `uncore_cha_*/unc_cha_rxc_inserts.rrq/`: MLC의 읽기 요청으로 유입된 Read Ingress Queue 삽입 횟수입니다.
* `uncore_cha_*/unc_cha_rxc_occupancy.rrq/`: Read Ingress Queue 내부에 누적되어 대기 중인 패킷의 사이클당 점유량입니다.
* `uncore_cha_*/unc_cha_rxc_inserts.wbq/`: 쓰기 후 플러시(Writeback) 등으로 인해 쓰기 큐(Write Ingress Queue)에 유입된 횟수입니다.
* `uncore_cha_*/unc_cha_rxc_occupancy.wbq/`: Write Ingress Queue 내부에 대기 중인 패킷의 사이클당 점유량입니다.

### 4. 요청 테이블 지표 (Table of Requests Metrics)
* `uncore_cha_*/unc_cha_tor_inserts.all/`: 코어에서 캐시 컨트롤러(CHA)의 TOR(Table of Requests) 버퍼로 들어온 모든 요청 삽입 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.all/`: TOR 버퍼 내 전체 미결(outstanding) 트랜잭션의 총 점유 시간(사이클)입니다.

### 5. DDR5 & CXL.mem 읽기 미스 상세 지표 (DRD Sub-Events)
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_local_ddr/`: 로컬 소켓의 DDR5 메모리 Demand Read Miss 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_local_ddr/`: 로컬 소켓 DDR5 Demand Read Miss 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_remote_ddr/`: 원격 소켓의 DDR5 메모리 Demand Read Miss 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_remote_ddr/`: 원격 소켓 DDR5 Demand Read Miss 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local/`: 로컬 CXL 장치의 Demand Read Miss 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local/`: 로컬 CXL Demand Read Miss 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc/`: 시스템 내 전체 CXL 장치의 Demand Read Miss 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc/`: 시스템 내 전체 CXL Demand Read Miss 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.

### 6. DDR5 & CXL.mem 쓰기 미스 상세 지표 (RFO Sub-Events)
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_local/`: 로컬 소켓 DDR5 캐시라인 확보를 위한 Write Miss (RFO) 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_local/`: 로컬 소켓 DDR5 RFO 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_remote/`: 원격 소켓 DDR5 캐시라인 확보를 위한 Write Miss (RFO) 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_remote/`: 원격 소켓 DDR5 RFO 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_cxl_acc_local/`: 로컬 CXL 장치 캐시라인 확보를 위한 Write Miss (RFO) 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc_local/`: 로컬 CXL RFO 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.
* `uncore_cha_*/unc_cha_tor_inserts.ia_miss_rfo_cxl_acc/`: 시스템 내 전체 CXL 장치 캐시라인 확보를 위한 Write Miss (RFO) 요청 횟수입니다.
* `uncore_cha_*/unc_cha_tor_occupancy.ia_miss_rfo_cxl_acc/`: 시스템 내 전체 CXL RFO 트랜잭션이 TOR 버퍼에 체류한 점유 시간입니다.

---

## 📊 13가지 통합 마이크로아키텍처 지표 (Unified Indicators)

스크립트 기동 시 32개의 성능 카운터 중 호스트 아키텍처가 실제로 지원하는 카운터만 동적으로 필터링하여 수집한 후, 다음 13가지 유도 분석 수식을 통해 하드웨어 병목 지표를 자동으로 정밀 산출합니다.

### A. 코어 파이프라인 (Core Execution)
1. **Memory-Bound Ratio (%)** (메모리 정체율):
   $$\text{Memory-Bound Ratio (\%)} = \frac{\text{topdown-mem-bound}}{\text{slots}} \times 100\%$$
2. **Application Read-to-Write Ratio** (어플리케이션 읽기/쓰기 비율):
   $$\text{R/W Ratio} = \frac{\text{Retired Loads (mem\_inst\_retired.all\_loads)}}{\text{Retired Stores (mem\_inst\_retired.all\_stores)}}$$

### B. RxC Ingress 버퍼 지연 (Read vs. Write Backpressure)
3. **Average Read Ingress Delay ($\tau_{RRQ}$)** (평균 읽기 큐 대기 시간):
   $$\tau_{RRQ} \text{ (cycles)} = \frac{\text{unc\_cha\_rxc\_occupancy.rrq}}{\text{unc\_cha\_rxc\_inserts.rrq}}$$
4. **Average Write Ingress Delay ($\tau_{WBQ}$)** (평균 쓰기 큐 대기 시간):
   $$\tau_{WBQ} \text{ (cycles)} = \frac{\text{unc\_cha\_rxc\_occupancy.wbq}}{\text{unc\_cha\_rxc\_inserts.wbq}}$$

### C. DDR5 로컬/원격 지연 (Read vs. Write RTT)
5. **Local DDR5 Read RTT ($\tau_{Local\_DDR\_Read}$)**:
   $$\tau_{Local\_DDR\_Read} \text{ (cycles)} = \frac{\text{occupancy.ia\_miss\_drd\_local\_ddr}}{\text{inserts.ia\_miss\_drd\_local\_ddr}}$$
6. **Local DDR5 Write RTT ($\tau_{Local\_DDR\_Write}$)**:
   $$\tau_{Local\_DDR\_Write} \text{ (cycles)} = \frac{\text{occupancy.ia\_miss\_rfo\_local}}{\text{inserts.ia\_miss\_rfo\_local}}$$
7. **Remote DDR5 Read RTT ($\tau_{Remote\_DDR\_Read}$)**:
   $$\tau_{Remote\_DDR\_Read} \text{ (cycles)} = \frac{\text{occupancy.ia\_miss\_drd\_remote\_ddr}}{\text{inserts.ia\_miss\_drd\_remote\_ddr}}$$
8. **Remote DDR5 Write RTT ($\tau_{Remote\_DDR\_Write}$)**:
   $$\tau_{Remote\_DDR\_Write} \text{ (cycles)} = \frac{\text{occupancy.ia\_miss\_rfo\_remote}}{\text{inserts.ia\_miss\_rfo\_remote}}$$

### D. CXL.mem 로컬/원격 지연 (Read vs. Write RTT)
9. **Local CXL Read RTT ($\tau_{Local\_CXL\_Read}$)**:
   $$\tau_{Local\_CXL\_Read} \text{ (cycles)} = \frac{\text{occupancy.ia\_miss\_drd\_cxl\_acc\_local}}{\text{inserts.ia\_miss\_drd\_cxl\_acc\_local}}$$
10. **Local CXL Write RTT ($\tau_{Local\_CXL\_Write}$)**:
    $$\tau_{Local\_CXL\_Write} \text{ (cycles)} = \frac{\text{occupancy.ia\_miss\_rfo\_cxl\_acc\_local}}{\text{inserts.ia\_miss\_rfo\_cxl\_acc\_local}}$$
11. **Remote CXL Read RTT ($\tau_{Remote\_CXL\_Read}$)** (원격 CXL 장치 수치 유도):
    $$\text{Remote CXL Read Ins} = \text{drd\_cxl\_acc\_inserts} - \text{drd\_cxl\_acc\_local\_inserts}$$
    $$\text{Remote CXL Read Occ} = \text{drd\_cxl\_acc\_occupancy} - \text{drd\_cxl\_acc\_local\_occupancy}$$
    $$\tau_{Remote\_CXL\_Read} \text{ (cycles)} = \frac{\text{Remote CXL Read Occ}}{\text{Remote CXL Read Ins}}$$
12. **Remote CXL Write RTT ($\tau_{Remote\_CXL\_Write}$)** (원격 CXL 장치 수치 유도):
    $$\text{Remote CXL Write Ins} = \text{rfo\_cxl\_acc\_inserts} - \text{rfo\_cxl\_acc\_local\_inserts}$$
    $$\text{Remote CXL Write Occ} = \text{rfo\_cxl\_acc\_occupancy} - \text{rfo\_cxl\_acc\_local\_occupancy}$$
    $$\tau_{Remote\_CXL\_Write} \text{ (cycles)} = \frac{\text{Remote CXL Write Occ}}{\text{Remote CXL Write Ins}}$$

### E. 소켓 간 연결망 대역폭 (Interconnect Bandwidth)
13. **UPI Transmit Bandwidth ($BW_{UPI}$)**:
    $$BW_{UPI} \text{ (GB/s)} = \frac{\text{unc\_upi\_txl\_flits.all\_data} \times 8 \text{ Bytes}}{\text{time\_elapsed} \times 10^9}$$

---

## ⚔️ 2대 읽기/쓰기 매치업 상관관계 분석 (Matchup Analysis)

도구 실행 완료 시 생성되는 보고서(`perf_summary.txt`) 하단에 아래 2대 매치업 지표가 실시간 계산되어 출력되므로, 이를 연계 분석하여 가설 1의 병목 고리를 완벽하게 증명할 수 있습니다.

### ⚔️ Matchup 1: Ingress Congestion Read-Write Cross-Talk (교차 정체 지연)
* **내용:** Qdrant 가동 중 쓰기 미스 요청으로 인해 CXL 쓰기 버퍼 체증($\tau_{WBQ}$)이 유발될 때, 읽기 큐 대기 시간($\tau_{RRQ}$)이 동시에 동반 급상승하는지 분석합니다. 
* **의미:** 쓰기 백프레셔가 인입 경계에서 읽기 트랜잭션까지 가로막아 상호 간섭 큐잉 정체(Cross-talk head-of-line blocking)를 유발하고 있음을 수학적으로 입증합니다.

### ⚔️ Matchup 2: Write-Miss Invalidate-on-Write (RFO) Latency Penalty (RFO 패널티)
* **내용:** 일반 Read RTT 계열 수치 대비 RFO(Request for Ownership) 캐시 무효화가 결합된 Write RTT 수치를 로컬/원격 DRAM 및 CXL 메모리에서 직접 대조 비교합니다.
* **의미:** 쓰기 작업량이 늘어남에 따라 UPI 대역폭($BW_{UPI}$)이 어떻게 급상승하는지 매치업하여, 원격 캐시 무효화 프로토콜이 인터커넥트 고갈과 메모리 트랜잭션 제한을 일으키는 트리거임을 증명합니다.
