#!/bin/bash
# Advanced Symmetric Sapphire Rapids CXL Multi-Socket Experiment Script
# Binds memory and CPU across 10 fully symmetric scenarios, profiles advanced Core & Uncore PMU events, 
# and saves all MLC and perf results sequentially to a single log file.
#
# Prerequisite: Configure sysfs weighted_interleave weights before running.
# Usage: Run with sudo: 'sudo bash run_advanced_experiment.sh'

# Output Log File
LOG_FILE="cxl_advanced_experiment_results.log"

# Clear previous log file
rm -f "${LOG_FILE}"
touch "${LOG_FILE}"

# Verify root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root (sudo) to access Uncore PMU registers." | tee -a "${LOG_FILE}"
  exit 1
fi

# Define PMU Event Groups
# Core PMU Group: slots, mem-bound, be-bound, stalls_l3_miss, retired loads, and retired stores (for unified R/W profiling)
EVENTS_CORE="slots,topdown-mem-bound,topdown-be-bound,cycle_activity.stalls_l3_miss,mem_inst_retired.all_loads,mem_inst_retired.all_stores"
# UPI Tx Flits: Using symbolic name for all data flits
EVENTS_UPI="uncore_upi_*/unc_upi_txl_flits.all_data/"
# IRQ (RxC Ingress Queue) & RRQ (Read Request Queue):
# - unc_cha_rxc_inserts.irq (General IRQ Inserts)
# - unc_cha_rxc_inserts.irq_rej (General IRQ Rejections - Core requests actively rejected by uncore!)
# - unc_cha_rxc_inserts.ipq (General IPQ Probes)
# - unc_cha_rxc_inserts.rrq (Read Ingress Queue Inserts - Highly specific to MLC's read traffic)
# - unc_cha_rxc_occupancy.rrq (Read Ingress Queue Occupancy - Tracks exact queue delay for reads)
EVENTS_IRQ="uncore_cha_*/unc_cha_rxc_inserts.irq/,uncore_cha_*/unc_cha_rxc_inserts.irq_rej/,uncore_cha_*/unc_cha_rxc_inserts.ipq/,uncore_cha_*/unc_cha_rxc_inserts.rrq/,uncore_cha_*/unc_cha_rxc_occupancy.rrq/"
# TOR (Table of Requests):
# - unc_cha_tor_inserts.all (Aggregate TOR Inserts)
# - unc_cha_tor_occupancy.all (Aggregate TOR Occupancy)
# - [Level 4: Local vs Remote DRAM/CXL separation]
#   - local_ddr: unc_cha_tor_inserts.ia_miss_drd_local_ddr, unc_cha_tor_occupancy.ia_miss_drd_local_ddr
#   - remote_ddr: unc_cha_tor_inserts.ia_miss_drd_remote_ddr, unc_cha_tor_occupancy.ia_miss_drd_remote_ddr
#   - local_cxl: unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local, unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local
#   - total_cxl: unc_cha_tor_inserts.ia_miss_drd_cxl_acc, unc_cha_tor_occupancy.ia_miss_drd_cxl_acc (Used to calculate Remote CXL as Total - Local)
EVENTS_TOR="uncore_cha_*/unc_cha_tor_inserts.all/,uncore_cha_*/unc_cha_tor_occupancy.all/,uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_local_ddr/,uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_remote_ddr/,uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc_local/,uncore_cha_*/unc_cha_tor_inserts.ia_miss_drd_cxl_acc/,uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_local_ddr/,uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_remote_ddr/,uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc_local/,uncore_cha_*/unc_cha_tor_occupancy.ia_miss_drd_cxl_acc/"

ALL_EVENTS="${EVENTS_CORE},${EVENTS_UPI},${EVENTS_IRQ},${EVENTS_TOR}"

log_and_run() {
  local title="$1"
  local cmd="$2"

  echo "=========================================================================" | tee -a "${LOG_FILE}"
  echo "${title}" | tee -a "${LOG_FILE}"
  echo "Command: ${cmd}" | tee -a "${LOG_FILE}"
  echo "=========================================================================" | tee -a "${LOG_FILE}"
  
  # Execute the command and redirect both stdout and stderr (perf output) to the log file
  eval "${cmd}" >> "${LOG_FILE}" 2>&1
  
  echo -e "\n\n" >> "${LOG_FILE}"
  echo "Completed: ${title}"
}

echo "Starting 11 advanced fully symmetric & global experiments. All output will be saved to ${LOG_FILE}"

# =========================================================================
# GROUP 1: SOCKET 0 CORES (0-15) PROFILE
# =========================================================================

# 1. Scenario A: Local Host DDR Only (Baseline for S0)
CMD_A="perf stat -a -e ${ALL_EVENTS} -- numactl -w 0 mlc --loaded_latency -d0 -T -t10 -Z -R -k0-15"
log_and_run "Scenario A [Socket 0 Cores]: Local Host DDR Only" "${CMD_A}"

# 2. Scenario B: Local DDR + Local CXL (Weighted Interleave for S0)
CMD_B="perf stat -a -e ${ALL_EVENTS} -- numactl -w 0,2 mlc --loaded_latency -d0 -T -t10 -Z -R -k0-15"
log_and_run "Scenario B [Socket 0 Cores]: Local DDR + Local CXL (WI)" "${CMD_B}"

# 3. Scenario C: Remote Host DDR Only (Access to Node 1 - Remote to S0)
CMD_C="perf stat -a -e ${ALL_EVENTS} -- numactl -w 1 mlc --loaded_latency -d0 -T -t10 -Z -R -k0-15"
log_and_run "Scenario C [Socket 0 Cores]: Remote Host DDR Only (Access to Node 1)" "${CMD_C}"

# 4. Scenario D: Remote DDR + Remote CXL (Weighted Interleave for S0)
CMD_D="perf stat -a -e ${ALL_EVENTS} -- numactl -w 1,3 mlc --loaded_latency -d0 -T -t10 -Z -R -k0-15"
log_and_run "Scenario D [Socket 0 Cores]: Remote DDR + Remote CXL (WI)" "${CMD_D}"

# 5. Scenario E: Global Weighted Interleave (DDRs + CXLs for S0)
CMD_E="perf stat -a -e ${ALL_EVENTS} -- numactl -w all mlc --loaded_latency -d0 -T -t10 -Z -R -k0-15"
log_and_run "Scenario E [Socket 0 Cores]: Global Weighted Interleave (All Nodes)" "${CMD_E}"

# =========================================================================
# GROUP 2: SOCKET 1 CORES (16-31) PROFILE
# =========================================================================

# 6. Scenario F: Local Host DDR Only (Baseline for S1)
CMD_F="perf stat -a -e ${ALL_EVENTS} -- numactl -w 1 mlc --loaded_latency -d0 -T -t10 -Z -R -k16-31"
log_and_run "Scenario F [Socket 1 Cores]: Local Host DDR Only" "${CMD_F}"

# 7. Scenario G: Local DDR + Local CXL (Weighted Interleave for S1)
CMD_G="perf stat -a -e ${ALL_EVENTS} -- numactl -w 1,3 mlc --loaded_latency -d0 -T -t10 -Z -R -k16-31"
log_and_run "Scenario G [Socket 1 Cores]: Local DDR + Local CXL (WI)" "${CMD_G}"

# 8. Scenario H: Remote Host DDR Only (Access to Node 0 - Remote to S1)
CMD_H="perf stat -a -e ${ALL_EVENTS} -- numactl -w 0 mlc --loaded_latency -d0 -T -t10 -Z -R -k16-31"
log_and_run "Scenario H [Socket 1 Cores]: Remote Host DDR Only (Access to Node 0)" "${CMD_H}"

# 9. Scenario I: Remote DDR + Remote CXL (Access to Node 0,2 - Remote to S1)
CMD_I="perf stat -a -e ${ALL_EVENTS} -- numactl -w 0,2 mlc --loaded_latency -d0 -T -t10 -Z -R -k16-31"
log_and_run "Scenario I [Socket 1 Cores]: Remote DDR + Remote CXL (Access to Node 0,2)" "${CMD_I}"

# 10. Scenario J: Global Weighted Interleave (DDRs + CXLs for S1)
CMD_J="perf stat -a -e ${ALL_EVENTS} -- numactl -w all mlc --loaded_latency -d0 -T -t10 -Z -R -k16-31"
log_and_run "Scenario J [Socket 1 Cores]: Global Weighted Interleave (All Nodes)" "${CMD_J}"

# =========================================================================
# GROUP 3: ALL SYSTEM CORES (0-31) GLOBAL RUN
# =========================================================================

# 11. Scenario K: Peak Global Weighted Interleave (All Cores & All Nodes)
CMD_K="perf stat -a -e ${ALL_EVENTS} -- numactl -w all mlc --loaded_latency -d0 -T -t10 -Z -R -k0-31"
log_and_run "Scenario K [All Cores]: Peak Global Weighted Interleave (All Nodes)" "${CMD_K}"

echo "========================================================================="
echo "All 11 symmetric and global experiments completed. Results saved in file: ${LOG_FILE}"
echo "========================================================================="