# M3 — Vivado flow: `boards/<board>/` (XDMA Gen3 x16 + HBM IP, no memory pins)

Goal: a build that produces `build/vivado/otpu.bit` from
`boards/<board>/run_vivado.sh`, cloned from `boards/bcu1525` minus the DDR4 subsystem,
plus the HBM IP. The only things needing a licensed VU35P are the HBM IP generation and
the final implementation; the flow is structured so as much as possible runs before that.

## 3.1 Directory

```
boards/<board>/
  Makefile                     lint, ipcheck, bit, impl, program, flash
  run_vivado.sh                knobs (CORE_MHZ, S, PCIE_LANES, ...), reads
                               `python3 -m opentpu.target env <board>`
  vivado/create_project.tcl    part, RTL list = sources("<board>"), IP creation, XDC
  vivado/bd.tcl                XDMA Gen3 x16, DMA split, SYSMONE4, BAR0 map
  vivado/build.tcl             synth, impl + phys_opt, reports, bitstream, flash image
  vivado/ip_check.tcl          BD-only check (runs on any US+ part) + HBM step (real part)
  vivado/tmem_uram.xdc         (if M1 chose TMEM_URAM=1; copy from bcu1525)
  scripts/preflight.tcl        part installed+licensed (copy from bcu1525, part changed)
  scripts/elab_check.tcl       `synth_design -rtl` on the real part: ports/pins/cells
  scripts/synth_check.tcl      whole-project synth on a free part with HBM stubbed
  scripts/check_offline.py     Tcl syntax, XDC-vs-ports, core.json-style checks
  constraints/<board>_pins.xdc from the user's board XDC (M0.3): PCIe refclk/PERST,
                               sysclk, HBM refclk, config, UART/LEDs — NO memory pins
  sim/hbm_ip_stub.sv, otpu_bd_wrapper_stub.sv, unisim_dsp48e2_stub.sv, ...
```

## 3.2 `create_project.tcl` differences against `boards/bcu1525/vivado/create_project.tcl`

1. `set_part xcvu35p-fsvh2104-2-e`; the RTL list from `opentpu.target sources("<board>")`
   (kept in sync with `rtlsim.RTL_SOURCES` and the Makefile — `tests/test_target.py`
   checks this; add the board to that check now).
2. **IP creation instead of LiteDRAM cores**: `create_ip -name hbm -vendor xilinx.com
   -library ip` (PG276's IP name; confirm against your Vivado version's catalog), with a
   Tcl config script setting, from M0:
   - 2 stacks, all 16 MCs per stack enabled, **global addressing** on, switch on;
   - ECC per the M0.2 decision;
   - HBM data rate = `mem_mts`;
   - **8 AXI3 slave ports enabled** (2 per channel; enable more later if bandwidth says
     so — re-generating the IP is a `bd`/IP step, not an RTL change, since the top
     instantiates a fixed port subset; decide the port count now: plan default **8**);
   - APB/user-access port enabled (BAR0);
   - `generate_target all` + `create_ip_run` so it is synthesized out of context and
     cached in `~/.cache/otpu-vivado-ip` like the other IPs (`OTPU_IP_CACHE`).
   Instantiate it in the **project (non-BD)** like the LiteDRAM cores were, so its scoped
   XDC applies (BCU1525 precedent: `SCOPED_TO_REF` for `otpu_ld4`; do the same for the
   `hbm_*` IP XDC in `create_project.tcl`).
3. Constraints: only the board XDC (3.1) + `tmem_uram.xdc` + the late crossing/floorplan
   Tcl files (added when written; none at first bring-up except what `elab_check`
   validates).
4. The BD wrapper from `vivado/bd.tcl` (3.3) is `SCOPED_TO_REF` as on the other boards.

## 3.3 `bd.tcl` differences against `boards/bcu1525/vivado/bd.tcl`

Keep byte-for-byte where possible; the BCU1525 BD already is "XDMA Gen3 x16 + DMA split +
sysmon + CSR windows":

1. **XDMA**: Gen3 x16, 512-bit AXI at 250 MHz, the house PCI identity (device 7028,
   class 12 00 00, subsystem 10EE:4F54, revision 01, `xdma_rnum_rids` 8) — unchanged, so
   the existing XDMA driver binds without changes; the PCIe block / GTY quad choice from
   M0.3/M0.4 (`select_quad` equivalent for PCIE4C on this part — check PG213 for the
   VU35P block locations).
2. **DMA split**: `sc_dma` + per-channel 128-bit masters by address bits 32:31 → 4 masters
   for 4 channels (identical rule to BCU1525; 8 GiB window covers the 4 × 2 GiB channels).
   ID_WIDTH check as BCU1525 (must be 0).
3. **SYSMONE4** (die temperature) as BCU1525.
4. **BAR0 map**: control registers 0x0 (unchanged register map 4), sysmon 0x30000, **HBM
   APB window 0x40000** (0x10000, the old R_MEMCAL, stays unmapped).
5. Remove everything DDR4-specific: the four `M_AXI_MEMCAL*` masters, the DDR4 CSR
   windows, the UART routing (unless the board's UART is wanted for the trace).

## 3.4 `build.tcl`

Copy from BCU1525, minus DDR4 specifics:

- synthesis (cached IP runs), implementation with post-route `phys_opt`, the report set
  (`SUMMARY.txt`, `timing_summary`, `util`, `util_hier`, `cdc`, `drc`) — add
  per-SLR utilization like BCU1525's `util_slr.rpt`;
- bitstream + flash image: the flash part from M0.3 (SPI x4? then `write_cfgmem` with the
  board's part, e.g. `mt25qu...`), and note `openFPGALoader` needs a `spiOverJtag`
  bitstream for `xcvu35p-fsvh2104` if the board is programmed that way (BCU1525 hit the
  same gap; Vivado hardware manager `program_hw_cfgmem` is the fallback);
- `WARNING: timing not met` handling identical to the other boards.

## 3.5 Checks that run *without* a VU35P license

These run on the free `xcku5p-fsvh2104`? (BCU1525 used `xcku5p-ffvb676-2-e`; pick the
free UltraScale+ part this Vivado lists, note the package difference means the board pin
XDC is excluded — `synth_check.tcl` already does exactly this):

1. `make lint` — Tcl syntax, XDC ports = top ports (the board XDC against the top),
   Verilator lint of the top against the stand-ins, `check_offline.py`.
2. `make ipcheck IPCHECK_STEPS=bd` — the BD (XDMA, split, sysmon, CSR windows)
   synthesizes out of context on the free part; the **HBM IP cannot** (it exists only on
   HBM parts) — `ip_check.tcl` therefore has two steps: `bd` (free part) and `hbm`
   (real part, license).
3. `make synthcheck` — whole project synthesized on the free part with `hbm_ip_stub.sv`
   substituted for the IP: the top elaborates, `elab_check.tcl`'s cell/pin names resolve,
   the late constraint files apply. This is where BCU1525 found its BD errors before any
   hardware existed; expect the same value here.

## 3.6 Checks that need the licensed VU35P

1. `scripts/preflight.tcl` ok (M0.1).
2. `scripts/elab_check.tcl xcvu35p-fsvh2104-2-e` — `synth_design -rtl` on the real part:
   `ELAB-CHECK done: 0 missing`.
3. `make ipcheck IPCHECK_STEPS=hbm` — the HBM IP generates and synthesizes out of context
   on the part; record its LUT/FF/BRAM from the report (PG276's utilization page gives the
   order of magnitude: ~1.5K LUTs per stack + switch for a minimal config, more with all
   MCs/ports).
4. `FAST=1 CORE_MHZ=100 make bit` — the first bitstream (see M4 for what to look at in the
   reports).

## Deliverable

- `make -C boards/<board> lint` clean;
- `ipcheck` (bd on free part, hbm on real part) and `synthcheck` pass;
- `FAST=1 CORE_MHZ=100 boards/<board>/run_vivado.sh` produces `build/vivado/otpu.bit`
  with `SUMMARY.txt` showing all constraints met at 100 MHz (a build that misses timing
  is still loadable for bring-up at `CORE_MHZ=80`).

# Done (2026-10-16)

`<board>` = **`admpcie9h3`**; `<free part>` = **`xcvu5p-flvb2104-2-e`** (3.5's "pick the
free UltraScale+ part this Vivado lists" — this host has no free Kintex US+ files, and
`xcvu5p` is the nearest free part with PCIE4C/GTY).

## The flow (3.1–3.4)

`boards/admpcie9h3/`: `Makefile` (`lint`, `ipcheck`, `bit`, `impl`, `program`, `flash`),
`run_vivado.sh`; `vivado/{create_project,bd,build,ip_check,hbm_ip}.tcl` + `tmem_uram.xdc`;
`constraints/{admpcie9h3_pins.xdc,admpcie9h3_top.tcl}`;
`scripts/{preflight,elab_check,synth_check,program}.tcl` + `check_offline.py`;
`sim/{hbm_ip_stub,otpu_bd_wrapper_stub,unisim_dsp48e2_stub,unisim_stubs}.sv`.

- `create_project.tcl`: `set_part xcvu35p-fsvh2104-2-e`; the RTL list from
  `opentpu.target sources("admpcie9h3")` (28 files, the top included); the HBM IP **non-BD**
  (`create_ip -name hbm -module_name hbm_ip` from `hbm_ip.tcl`, then `generate_target` +
  `create_ip_run`), so its scoped XDC applies automatically; the BD wrapper and
  `otpu_mem_ch` are `SCOPED_TO_REF`-scoped as on the DDR boards.
- `bd.tcl`: XDMA Gen3 x16 (512-bit @ 250 MHz), `sc_ctl`/`sc_dma`, the SYSMONE4; BAR0 =
  control `0x0`/64 KiB, sysmon `0x30000`/64 KiB, **HBM APB `0x800000`/8 MiB**.
- `build.tcl`: synth, impl + post-route `phys_opt` (skipped under `FAST=1`), the report set
  (`SUMMARY.txt`, `timing_summary`, `timing_worst`, `util`/`util_slr`/`util_hier`, `cdc`,
  `clock_interaction`, `drc`, `methodology`, `power`, `congestion`), the bitstream, the
  SPIx8 flash image, and the copy of the bitstream out of the run directory.
- `scripts/`: `preflight.tcl` (part installed + licensed), `elab_check.tcl`
  (`synth_design -rtl` on the real part), `synth_check.tcl` (whole project on the free part
  with `hbm_ip_stub.sv` in place of the IP), `program.tcl` (Vivado hardware manager, JTAG
  10 MHz; flash `mt25qu512-spi-x1_x2_x4_x8`).

## 3.5 — checks without the license

```
$ make -C boards/admpcie9h3 lint                               # exit 0
$ make -C boards/admpcie9h3 ipcheck IPCHECK_STEPS=bd,bdsynth   # exit 0
$ make -C boards/admpcie9h3 synthcheck                         # exit 0
SYNTH-CHECK done on xcvu5p-flvb2104-2-e
```

`lint` prints only `otpu_tmem`'s pre-existing `%Warning-UNOPTFLAT`. `synthcheck` leaves 12
non-fatal `Synth 12-4739` "net has no driver" errors — the shared scoped constraints
(`otpu_mem_ch.tcl`'s `-through` lines) name nets the HBM stub stand-in does not create — and
the step still exits 0.

## 3.6 — checks that need the licensed VU35P

```
$ scripts/preflight.tcl xcvu35p-fsvh2104-2-e            # PREFLIGHT ok
$ scripts/elab_check.tcl xcvu35p-fsvh2104-2-e           # ELAB-CHECK done: 0 missing
$ make -C boards/admpcie9h3 ipcheck IPCHECK_STEPS=hbm    # exit 0
$ PATH="$PWD/.venv/bin:$PATH" FAST=1 CORE_MHZ=100 JOBS=24 OTPU_MAX_THREADS=24 \
    boards/admpcie9h3/run_vivado.sh
```

`ipcheck hbm` (real part): the IP generates and synthesizes out of context at
**LUT 1597 / FF 1648 / BRAM 4 / URAM 0 / DSP 0**. The full build leaves
`build/vivado/otpu.bit` (44,196,567 bytes), `otpu_primary.mcs` + `otpu_secondary.mcs`
(one per flash device — `write_cfgmem -size 64 -interface SPIx8` splits the 64 MiB image in
two, so ~32 MiB of payload each and ~60 MB of ASCII `.mcs` per file) and
`build/vivado/reports/`.

## Deviations from the plan (deliberate)

1. **Check part** `xcvu5p-flvb2104-2-e` (3.5). The board pin XDC is excluded from the
   free-part steps, exactly as `synth_check.tcl` does.
2. **BAR0 HBM APB window `0x800000`/8 MiB**, not 3.3's `0x40000`/`0x10000`: Vivado requires
   a segment's offset to be a multiple of its range. `APB_AW 22`; the APB stack is AXI
   address bit 22.
3. **The APB bridge is real RTL** (`rtl/boards/admpcie9h3/otpu_axi_apb_bridge.sv`: AXI4-Lite
   → `APB_0`/`APB_1`) rather than the catalog `axi_apb_bridge` IP, so the two stacks map the
   way M0.2 wanted.
4. **XDMA on the VU35P** needs `CONFIG.pcie_blk_locn PCIE4C_X1Y0` **and**
   `CONFIG.select_quad GTY_Quad_227` in the *same* `set_property -dict` (PG213).
5. **HBM IP `CONFIG.USER_XSDB_INTF_EN {FALSE}`** (`hbm_ip.tcl`): the IP otherwise hard-codes
   `` `define EN_DBG_HUB ``, which leaves `dbg_hub/clk` unconnected (Chipscope 16-213).
6. `` `default_nettype none `` removed from `sim/hbm_ip_stub.sv` and
   `otpu_axi_apb_bridge.sv` (Vivado `Synth 8-6735`).
7. The top's `HBM_AXI` macro explicitly connects `.AXI_0n_RDATA_PARITY()`.
8. The BD's `diff_clock` port is named `sys`; the wrapper therefore pins
   `sys_clk_p`/`sys_clk_n` (AF9/AF8).
9. `boards/ypcb-00338/constraints/otpu_mem_ch.tcl`: `c_ucl` falls back to `c_clk` when the
   `uclk` port carries no clock (guarded, so `bcu1525`/`ypcb-00338` are unchanged).
10. `ip_check.tcl` needed a run-object fix for the BD step. `general.maxThreads =
    min(nproc, 24)` (`OTPU_MAX_THREADS` overrides it); `run_vivado.sh`'s `JOBS` default is
    16.
11. `write_bitstream` is a *required* impl step, so it has **no**
    `STEPS.WRITE_BITSTREAM.IS_ENABLED` (setting it → `Common 17-54`). `build.tcl` instead
    copies `otpu.runs/impl_1/*.bit` → `$out/otpu.bit`, so the `.bit` survives a kill of the
    batch process after `wait_on_run`.
12. The flow needs the repo venv Python (`PATH="$PWD/.venv/bin:$PATH"`): the system
    `python3` 3.14 has no numpy, so `opentpu.target` fails and `CFG_HASH` comes out 0.
13. `bd.tcl`'s local boolean was renamed `VU35P` → `IS_VU35P`: it clobbered
    `create_project.tcl`'s `$VU35P` part string, which silently dropped
    `admpcie9h3_pins.xdc`.

## The one M3 finding: HBM APB clock pulse width → one MMCM

M2's clock plan was "no MMCM": `refclk300` (300 MHz, AY31/BA31) → `BUFGCE_DIV` ÷3 = 100 MHz
for `core_clk` / `hbm_ref_clk`. That is a **33 % duty** clock, and the HBM IP's APB macro
(`BLI_HBM_APB_INTF`) wants a 5 ns pulse at 100 MHz:

```
High Pulse Width   HBM_SNGLBLI_INTF_APB/PCLK   Required  5.000   Actual  3.333   Slack -1.667
Min Period         HBM_SNGLBLI_INTF_APB/PCLK   Required 10.000   Actual  9.999   Slack -0.001
```

`report_timing_summary` therefore printed *"Timing constraints are not met"* even though
setup and hold were clean: **WNS +0.027, WHS +0.005, 0 failing endpoints** (`core_clk` slack
+0.960, fmax 110.6 MHz; `pipe_clk` +0.185; `xdma_aclk` +0.069). M0 recorded that the vendor's
own design runs APB from `refclk300` **÷4** (75 MHz, even ⇒ 50 %) — the ÷3 was the deviation.

Fix (this milestone): the top generates `core_clk` and `hbm_ref_clk` from **one
`MMCME4_BASE`** — `refclk300` × 4 / 12 = 100 MHz, an *even* output divide, so the duty cycle
is 50 % (`CLKFBOUT` → `CLKFBIN` internal feedback, `BANDWIDTH "OPTIMIZED"`; `MMCME4_BASE`
has no `COMPENSATION` parameter — that knob is `MMCME4_ADV`-only). `LOCKED` is ANDed into the
reset synchroniser. The pins XDC's `refclk300` period is **3.334** (the board kit says
3.333): Vivado rounds the input period to ps, so 3.333…3.3334 propagate the MMCM's 100 MHz as
9.999 ns (pulse 4.999, still short of 5.000), while 3.334 gives 10.002 ns / 5.001 ns — 0.02 %
conservative.

Verified before the rebuild: `make lint` clean, and a standalone
`synth_design` + `opt_design` + `place_design` on `xcvu5p-flvb2104-2-e` gives both MMCM
outputs period 10.002 ns / waveform `{0, 5.001}` with no MMCM/VCO DRC violation.

**The rebuilt bitstream** (`build/vivado/otpu.bit`, 44,196,567 bytes) **meets all
constraints** — `report_timing_summary` prints *"All user specified timing constraints are
met"*: **WNS +0.081, WHS +0.007, WPWS 0.000, 0 failing endpoints** (`core_clk_mmcm` period
10.002 ns, slack +0.830, fmax 109.0 MHz; `sys_clk` +7.134; `pipe_clk` +0.208; `xdma_aclk`
+0.140; the GT clocks positive). The HBM APB checks that failed before are now positive:

```
Min Period        HBM_SNGLBLI_INTF_APB/PCLK   Required 10.000   Actual 10.002   Slack +0.002
Low/High Pulse    HBM_SNGLBLI_INTF_APB/PCLK   Required  5.000   Actual  5.001   Slack +0.001
```
