# Risks, fallbacks and open questions

Each risk: what can go wrong, how it will be detected, and the isolated fix. Ordered by
likelihood × impact.

## R1 — Write visibility through the HBM switch (host data → flag → device read)

- **Risk**: the hard crossbar reorders two host writes (different pseudo-channel regions,
  different AXI ports) so the flag becomes visible to the device before the data. The
  bridge (2.1) preserves today's two-port structure, and B means "accepted by the target
  controller", which orders later reads behind it — but this is the one property the RTL
  cannot prove.
- **Detect**: WAITW phase of `tools/qual/qual.sh` (CAPS bit 31), `otpu-diag`'s memory
  stages, the `waitw.py` 200-round soak.
- **Fix (isolated)**: `DRAIN=1` mode in `otpu_native_axi3` — the host path issues one
  write at a time, holding each until its B (host traffic only; the accelerator's stream
  unaffected). Cost: host DMA rate; measured, then tuned (drain per burst, not per beat)
  if it shows up.

## R2 — ECC costs HBM capacity

- **Risk**: PG276's SECDED halves the 8 GB; then S = 2 slices at 2 GiB/channel no longer
  fits and images > 2 GiB/slice break.
- **Detect**: M0.2 (IP GUI / PG276) — before any RTL.
- **Fix**: either ECC off for the large-image config (a `[variants.ecc-off]`), or S = 1
  with ECC (4 GiB window, same as the production YPCB), or a smaller `channel_phys_bytes`
  with the slices' windows overlapping the ECC-protected region only. Decide in M0; the
  target file is the only thing that changes.

## R3 — AXI ACLK ceiling: one port is not 14.4 GB/s

- **Risk**: PG276's per-port clock max is lower than assumed (e.g. 300 MHz → 9.6 GB/s per
  port), and at 133 MHz+ core plus heavy DMA a channel (2 ports) saturates.
- **Detect**: `tools/rw_bench.py` rows and `MXU_STARVE`/DRAM counters on the card;
  `otpu-hbm bw` per-MC monitors.
- **Fix**: regenerate the IP with more AXI ports per channel (the bridge takes a `NP`
  parameter; address striping at 1 GiB within the channel keeps every burst inside one
  pseudo-channel); or run the core at 100 MHz (the DDR boards' rule: DRAM-bound decode
  barely cares).

## R4 — HBM IP cannot be checked off-part

- **Risk**: `make ipcheck`/`synthcheck` on the free `xcku5p` cannot include the HBM IP, so
  integration errors surface only with the license.
- **Detect**: `IPCHECK_STEPS=hbm` is a separate step (3.6) run early on the licensed host.
- **Fix**: none needed beyond the split-step design; the `hbm_ip_stub.sv` keeps the rest
  of the flow off-part-checkable.

## R5 — AXI3-only slave

- **Risk**: the HBM slave is AXI3 (6-bit ID, `len ≤ 16`); a careless master (or a future
  SmartConnect insertion) issues AXI4 bursts or wide IDs.
- **Detect**: the unit TB asserts protocol (2.2); the HBM IP itself errors on violations
  (bring-up).
- **Fix**: the bridge is the only master to the HBM ports by construction (both the
  accelerator's native traffic and XDMA's traffic are merged inside `otpu_mem_ch` before
  the bridge); never route a second master to the ports directly.

## R6 — Partial writes / RMW semantics differ from LiteDRAM

- **Risk**: with `RMW=0` + WSTRB, the HBM IP's RMW behaves subtly differently (latency,
  ordering, ECC side effects) than `otpu_mem_ch`'s own read-modify-write; the quantizer's
  gathered byte stores and XDMA's 16-byte beats depend on it.
- **Detect**: unit TB with both `RMW` values (2.2); `otpu-diag --mem full` byte-lane
  hints; `rw_bench`'s `st`/`dstep` rows vs the ISA simulator.
- **Fix**: keep `RMW=1` (the bridge's own RMW) for this board if the IP's path shows any
  anomaly — a parameter, no RTL change.

## R7 — Board specifics unknowns

- **Risk**: the XDC/board file disagrees with assumptions (HBM refclk frequency/pin,
  PCIe block/quad selection on PCIE4C, flash part for the `.mcs`, JTAG chain).
- **Detect**: M0.3 inventory; `elab_check.tcl` on the real part; first PCIe rescan.
- **Fix**: each is a board-flow constant (constraints / `bd.tcl` / `program.sh`), not RTL.

## R8 — SLR floorplan / routing

- **Risk**: two slices + shell + 8 AXI ports across unknown SLR boundaries route poorly or
  miss timing at 100 MHz.
- **Detect**: first build's `util_slr.rpt`, `timing_summary.rpt`, the
  `report_timing -through USER_SLL_REG` view (BCU1525's method).
- **Fix**: BCU1525's floorplan Tcl (pblocks per SLR + Laguna crossing constraints) adapted
  once M0.4's SLR map is known; fall back to `CORE_MHZ=80` for bring-up regardless.

## R9 — HBM efficiency on the access pattern

- **Risk**: 64-byte beats hashed over two channels and 8-16 pseudo-channels may hit lower
  efficiency than the DDR3 boards' 82-94% (row misses across 256 MB regions, turnarounds
  between the weight stream and the KV/activation traffic).
- **Detect**: `otpu-smi` per-MC counters + `tools/qual/perf.py` DRAM GB/s vs the card's
  own beat counters; Lens DRAM-wait histograms.
- **Fix**: address-map tuning (interleave granularity: keep `CHASH` on; try region-granular
  vs bit-7-granular port selection), IP-side reordering knobs (PG276: configurable
  reordering/grouping per memory controller), burst-length tuning in the bridge (longer
  INCR bursts for the weight stream — native port B reads are already chunk-sized, so
  this may be free).

## Open questions parked for later

- More slices (S = 3/4) or bigger TMEM with `TMEM_URAM=1`: the VU35P has the LUTs/DSPs;
  capacity per slice (4 GiB) is the limit, and the ISA's 32-bit DRAM address space per
  slice is fixed until the per-slice window-register decision (`docs/targets.md`
  "Limits") lands.
- The `docs/wide_dram.md` 256-byte path: HBM could feed a wider per-cycle port than any
  DDR board; out of scope here, but the port-width knob is where it would start.
- AXI4/Gen4 host link: the PCIE4C blocks support Gen4 x8; XDMA support and the host slot
  decide; not needed for bring-up.
