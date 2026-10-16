#!/usr/bin/env bash
# Build the openTPU bitstream for the ADM-PCIE-9H3 (xcvu35p-fsvh2104-2-e) in Vivado batch mode
# (docs/plans/vu35p-hbm/). The knobs, as boards/bcu1525/run_vivado.sh's:
#   S=2   the accelerator (two slices, two HBM channels each)   PCIE_LANES=16|8 (Gen3)
#   CORE_MHZ=100 (the HBM IP is configured for a 100 MHz AXI clock and the top's MMCM makes
#   HBM_REF_CLK 100 MHz too: other rates need the IP regenerated)
#   FAST=1: Vivado's default strategies   TMEM_URAM=0|1 (the TMEM in UltraRAM)
#   OUT_DIR   JOBS (concurrent IP runs; default 16)   STEP=impl   IMPL_STRATEGY   PREFLIGHT=1|0
#   BUILD_ID   OTPU_MAX_THREADS (default min(nproc, 24): implementation threads)
# The VU35P needs a Vivado license that covers it (not the free tier) and the Virtex UltraScale+
# HBM device files. The preflight (scripts/preflight.tcl, about a minute) checks both first.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${OUT_DIR:-$root/build/vivado}"
jobs="${JOBS:-16}"
# The target (targets/admpcie9h3.toml through opentpu/target.py): the knobs' defaults, the platform
# id, the HBM rate and the arch hash the CFG_* registers report (without python3: the same built-in
# values, CFG_HASH 0)
if tenv="$(PYTHONPATH="$root" python3 -m opentpu.target env admpcie9h3 2>/dev/null)"; then
  eval "$tenv"
else
  echo "run_vivado: python3 -m opentpu.target env admpcie9h3 failed: built-in defaults, CFG_HASH 0" >&2
fi
s="${S:-${T_S:-2}}"
mcols="${MCOLS:-${T_MCOLS:-4}}"
vpu_cl="${VPU_CL:-${T_VPU_CL:-2}}"
lanes="${LANES:-${T_LANES:-8}}"
act_rows="${ACT_ROWS:-$mcols}"
dstep="${DSTEP:-${T_DSTEP:-1}}"
seq_wc="${SEQ_WC:-${T_SEQ_WC:-0}}"
core_mhz="${CORE_MHZ:-${T_CORE_MHZ:-100}}"
platform="${T_PLATFORM:-3}"
ddr_mts="${T_DDR_MTS:-1000}"
# core_clk is at once the fabric clock, the HBM IP's AXI clock and its APB PCLK, and HBM_REF_CLK
# comes from the same 300 MHz pin through the top's MMCM: the HBM IP is configured for 100 MHz
# (USER_AXI_INPUT_CLK_FREQ 100, USER_HBM_REF_CLK_0/1 100; M0.2, vivado/hbm_ip.tcl). Any other rate
# needs the IP regenerated (100/200/300) and the ref clock decoupled.
case "$core_mhz" in
  100|100.0|100.00|100.000) ;;
  *) echo "run_vivado: CORE_MHZ $core_mhz: the HBM IP is configured for 100 MHz (HBM_REF_CLK = \
refclk300 through the MMCM = 100, USER_AXI_INPUT_CLK_FREQ 100; M0.2). Regenerate the IP for another rate." >&2
     exit 2 ;;
esac
arch_hash="$(PYTHONPATH="$root" python3 -m opentpu.target hash admpcie9h3 MCOLS="$mcols" \
  LANES="$lanes" ACT_ROWS="$act_rows" DSTEP="$dstep" SEQ_WC="$seq_wc" 2>/dev/null || echo 0)"
build_id="${BUILD_ID:-$(git -C "$root" rev-parse HEAD 2>/dev/null | cut -c1-8)}"
build_id="${build_id:-0}"
mkdir -p "$out"
export OTPU_IP_CACHE="${OTPU_IP_CACHE-$HOME/.cache/otpu-vivado-ip}"
export OTPU_FAST="${FAST:-0}"
export OTPU_SEQ_WC_GEN="$seq_wc"
export PCIE_LANES="${PCIE_LANES:-16}"
export TMEM_URAM="${TMEM_URAM:-0}"     # 1: the TMEM copies in UltraRAM (vivado/tmem_uram.xdc)
run() { local script="$1"; shift
  vivado -mode batch -nojournal -log "$out/$(basename "$script" .tcl).log" -source "$script" -tclargs "$@"; }
if [[ "${PREFLIGHT:-1}" != 0 ]]; then
  part="${T_PART:-xcvu35p-fsvh2104-2-e}"
  if ! command -v vivado > /dev/null; then
    echo "run_vivado: no vivado on PATH (source <Vivado>/settings64.sh)" >&2; exit 2
  fi
  if ! (cd "$out" && vivado -mode batch -nojournal -nolog -source "$here/scripts/preflight.tcl" \
          -tclargs "$part") > "$out/preflight.log" 2>&1; then
    grep -E "PREFLIGHT|ERROR" "$out/preflight.log" >&2 || tail -20 "$out/preflight.log" >&2
    echo "run_vivado: preflight failed ($out/preflight.log); PREFLIGHT=0 skips it" >&2
    exit 2
  fi
  grep "PREFLIGHT ok" "$out/preflight.log" >&2
fi
if [[ "${STEP:-}" == impl ]]; then
  run "$here/vivado/build.tcl" "$out" "$jobs" impl "${IMPL_STRATEGY:-}"
else
  run "$here/vivado/create_project.tcl" "$out" "$mcols" "$core_mhz" "$build_id" "$vpu_cl" "$lanes" \
    "$act_rows" "$dstep" "$s" "$platform" "$arch_hash" "$ddr_mts"
  run "$here/vivado/build.tcl" "$out" "$jobs" full "${IMPL_STRATEGY:-}"
fi
echo "done: $out/otpu.bit"
