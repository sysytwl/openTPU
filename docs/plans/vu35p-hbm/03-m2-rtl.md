# M2 — RTL: the native→AXI3 bridge, board top, Verilator HBM model (offline)

Goal: the one genuinely new piece of hardware — `otpu_native_axi3` — plus the board's RTL
top and a behavioural HBM model, all validated in Verilator against the ISA simulator
before a line of Vivado flow exists. Everything here is testable with
`python3 -m pytest` + Verilator 5, like the rest of the repo.

## 2.1 The bridge: `rtl/shell/otpu_native_axi3.sv`

### Contract (write this as the module header comment — it is the spec)

Input side: **one LiteDRAM native port** (the controller side of `otpu_mem_ch`), as
`otpu_mem_ch` drives it today:

- command: `{we, beat_addr}` handshake, one command per cycle when ready;
- write data: taken some cycles after its command, in write-command order;
- read data: in command order, **no backpressure** (must always be accepted);
- byte enables on writes (the native port carries them; `otpu_mem_ch` already resolves
  partial beats into whole beats plus a `wmask` — decide at implementation time whether
  to pass `wmask` through as AXI WSTRB or keep the bridge's RMW; **first version: pass
  WSTRB through and let the HBM IP's RMW do the work**, and add a `RMW` parameter to
  `otpu_mem_ch` to disable its read-modify-write for this board only, defaulting to
  today's behaviour for the DDR boards).

Output side: **one AXI3 master**, 256-bit data, single ID (ID width 6 on the HBM slave),
in:

- AR: one transaction per native beat, `INCR`, `len = 1` (2 × 256-bit = 64 bytes),
  64-byte-aligned addresses; `araddr = {hbm_base, 32'(beat_addr) << 6}`;
- AW/W: same shape, `awlen = 1`, WSTRB from the byte enables, WLAST on the second beat;
- R: accepted always; pushes into a read-data FIFO (depth ≥ the credit limit below);
  reassembles the two 256-bit beats into the 512-bit native beat, in order (single ID ⇒
  strictly in order, no reordering logic needed);
- B: write responses counted; the native side's write-visibility count (`n_wdone` in
  `otpu_mem_ch`) keeps working because a native write is "taken" when its command is
  accepted into the bridge's AW/W path — mirror `otpu_mem_ch`'s existing definition
  (command handshake, not B) unless M0 found a hazard; see 2.1 "ordering" below.
- Credits: issue an AR only when the read FIFO has room for the beat **and** every read
  not yet through (the same credit rule `otpu_mem_ch` applies to its masters).
- Clocking: the bridge runs in the **HBM AXI clock domain**; its native side crosses
  through `otpu_afifo` exactly the way `otpu_mem_ch` crosses its own masters (commands,
  write data, read data as separate FIFOs). Alternative if M0 shows the AXI clock can be
  the core clock: run it in core_clk and skip the FIFOs — decide at implementation,
  measure both.

### Ordering (the property the software depends on)

The host protocol writes data, then a flag; the device polls the flag, then reads data.
On the DDR boards this holds because all of a channel's traffic passes one arbiter
(`otpu_mem_ch`) and the controller keeps each port's commands in order. Preserved here by:

1. every write of a channel goes through the same bridge instances (2 per channel, one per
   native port — the same two-port split the DDR boards have, so cross-port behaviour is
   bit-for-bit today's);
2. single ID per port ⇒ the HBM controller must not reorder our transactions;
3. B means the write passed into the target pseudo-channel's controller queue, so any
   later read to that region (any port) is ordered behind it.

Property (3) is the one thing the RTL cannot prove — it is checked on hardware in M4/M5
with the existing WAITW phase (`tools/qual/waitw.py`, CAPS bit 31) and `rw_bench`.
If WAITW fails, the isolated fix is a "drain" mode on the host path: hold each host write
until the previous one's B (parameter `DRAIN=1`, host traffic only).

### Files

- `rtl/shell/otpu_native_axi3.sv` — the bridge (new);
- `rtl/shell/otpu_mem_ch.sv` — add the `RMW` parameter (default 1 = today's behaviour);
  no behaviour change for `ypcb-00338`/`bcu1525`;
- `sim/verilator/otpu_hbm_model.sv` — behavioural AXI3 slave (new, see 2.3).

## 2.2 Unit testbench (before the board model)

New cocotb/Verilator test in the style of `tests/test_rtl.py`'s `tb_memch` runs
(`sim/verilator/tb_memch.sv` is the model to copy):

1. `sim/verilator/tb_hbmbdg.sv`: `otpu_mem_ch` + `otpu_native_axi3` + `otpu_hbm_model`
   wired exactly as the board will (this is the integration the board needs, and it makes
   the mem_ch `RMW` parameter's off-state testable).
2. Directed cases (each both `RMW=0` and `RMW=1`):
   - full-beat writes and reads at random addresses, back-to-back, read data checked
     against the model's memory;
   - partial-beat writes (quantizer-style gathered byte stores, XDMA's 16-byte beats);
     with `RMW=0` assert the model received WSTRB and merged it, with `RMW=1` assert the
     whole beat arrives with the old bytes preserved;
   - read-after-write to the same beat (both orders), write-then-flag-then-read sequences
     (the host protocol);
   - credit exhaustion: issue reads faster than the model returns them, check the FIFO
     never overflows and no beat is dropped;
   - burst interleave from both masters (native stream + AXI host traffic), like
     `tools/rw_bench.py` does on hardware (`mm`, `st`, `ld`, `dstep`, `mm+st`, ...).
3. Random long soak with a scoreboard comparing against a shadow array.

Gate: `python3 -m pytest -q tests/test_hbmbdg.py` (name per repo convention) green.

## 2.3 Behavioural HBM model: `sim/verilator/otpu_hbm_model.sv`

Mirror the DDR3 model's structure (`sim/verilator/otpu_native_mem.sv`, `+axi_dram`
plusargs, `docs/board.md` section 4) but at the AXI3 side:

- 256-bit AXI3 slave, configurable latency (`+hbm_lat`, default a few dozen ns), simple
  flat memory with per-pseudo-channel arrays (address bits [31:28] → 32 regions);
- optional timing mode (`+hbm_dram=1`): per-region row buffers, tRCD/tRP/tRAS, refresh,
  read/write turnarounds, so `tools/perf_qwen.py`-style projections can later be fitted
  against the card like the DDR3 model was;
- optional `+hbm_ecc=1`: model the ECC counters' semantics (correctable/uncorrectable on
  injected errors) so `otpu-diag --sim` can exercise the ECC stage;
- WSTRB merge, AXI3 same-ID ordering (in-order R/B), and a fatal on protocol violations
  (len > 16, unaligned, overlapping same-ID write/read hazards).

Wire it into `sim/verilator/tb_board.sv` behind a `TARGET_HAS_HBM`-style parameter (check
how `tb_board` selects its per-channel model today — `otpu_ldc_model`/`otpu_chmem` — and
follow that mechanism).

## 2.4 Board RTL: `rtl/boards/<board>/`

Clone the BCU1525 pair, subtracting DDR4, adding the bridge:

1. `otpu_<board>_sys.sv` (from `rtl/boards/bcu1525/otpu_bcu_sys.sv`):
   - `otpu_board` at S = 2 (unchanged shell: control block, collective unit, trace);
   - per channel `j = 0..3`: `otpu_mem_ch` (accelerator native port + the XDMA 128-bit
     AXI master from the block design);
   - per native port of each `otpu_mem_ch`: one `otpu_native_axi3` → 8 AXI3 masters
     total, `hbm_base = j * 2 GiB`;
   - the SLR-crossing register slices (`otpu_native_reg`, `USER_SLL_REG`) stay for the
     signals that cross (defer until M0.4 says where the HBM AXI interfaces live; if the
     shell and both slices end up in two SLRs, keep the crossings exactly as
     `otpu_bcu_sys` does).
2. `otpu_fpga_top_<board>.sv` (from `rtl/boards/bcu1525/otpu_fpga_top_bcu.sv`):
   - the block design wrapper's ports: XDMA (PCIe + 4 × 128-bit DMA masters + AXI-Lite
     BAR0) and SYSMONE4 — as BCU1525;
   - **the HBM IP instance** (8 used AXI3 ports + APB + refclk), replacing the four
     `otpu_ld4` instantiations; the IP is a Vivado-generated IP (M3), so lint needs a stub
     (`boards/<board>/sim/hbm_ip_stub.sv`, like `otpu_ld4_stub.sv`);
   - **the AXI-Lite→APB bridge** (if M0.2 says no catalog IP) in BAR0's map at a free
     window (follow the BCU1525 CSR layout: control 0x0, sysmon 0x30000, DDR4 cores
     0x40000+ → here HBM registers at, say, 0x40000);
   - clocks: board sysclk → MMCM: `core_clk` (100 MHz dev), `hbm_aclk` (M0.2 number),
     the XDMA clocks come from the BD; no DDR reference/`ui_clk` any more;
   - resets, `otpu_axil_iso` for the HBM APB crossing, LEDs/UART as the board has them.
3. Register both files in `opentpu/target.py` `BOARDS["<board>"]` (M1 already names them).

## 2.5 Lint stand-ins and `make lint`

`boards/<board>/sim/`: `hbm_ip_stub.sv` (ports of the generated IP, hand-written from the
PG276 port table), the BD wrapper stub, `unisim_dsp48e2_stub.sv` (copy from
`boards/bcu1525/sim/`). The `boards/<board>/Makefile` and its offline checks arrive in M3;
here ensure `verilator --lint-only` of the top against the stand-ins is clean:

```sh
verilator --lint-only -Wall -sv rtl/... boards/<board>/sim/...   # as boards/bcu1525 does
```

## 2.6 Board-model token-exact tests (the M2 gate)

1. `sim/verilator/tb_board.sv` with the HBM model selected for this target;
2. `opentpu/rtlsim.py`: make `SimTransport(target="<board>")` build the new top
   (check `BOARD_UARCH` / `target.sim_uarch` picks the new model and plusargs);
3. the existing two-slice tests parameterized by target must pass:
   `test_tiny_qwen3_two_slices_on_board_model` with `OTPU_TARGET=<board>` (plus both
   channel-crossing settings, as BCU1525 runs them);
4. `otpu-selftest --sim` and `otpu-diag --sim` pass every stage the model can run
   (`docs/board.md` section 4 lists what a model cannot show: here, the HBM switch's
   write visibility, real latency and PCIe — same caveat, new cause).

```sh
OTPU_TARGET=<board> python3 -m pytest -q tests/test_rtl.py -k two_slices
OTPU_TARGET=<board> python3 -m pytest -q
python3 -m opentpu.selftest --sim --target <board>   # if the CLI takes it; else via env
```

## Deliverable

- `otpu_native_axi3.sv` with its header contract and unit tests green;
- board top lints clean against stubs;
- `OTPU_TARGET=<board>` token-exact against the ISA simulator in the Verilator board model;
- no changes to `ypcb-00338` / `bcu1525` behaviour (`tools/synth/board_equiv.sh` still
  proves the S = 1 shell equivalence; full `pytest` green).

---

# Done (2026-10-15)

`<board>` = **`admpcie9h3`** (M1).

## 2.1 The bridge — `rtl/shell/otpu_native_axi3.sv`

The header is the contract. One native port (26-bit command `{we, beat[24:0]}`, 576-bit write data
`{wmask[63:0], data[511:0]}`) to one AXI3 master, 256-bit, single ID (6'h00), all in the HBM AXI
clock (`clk`; the board wires it to `otpu_mem_ch`'s `uclk`, so `otpu_mem_ch`'s own clock-crossing
FIFOs are what carry the accelerator's core-clock and XDMA's traffic into it — 2.1's "run it in the
AXI clock and skip the FIFOs" alternative, which M0.4 allowed because the card's HBM AXI clock is
`refclk300`/its divider, not the core clock).

- AR one transaction per native beat, `INCR`, `len = 1`, `araddr = HBM_BASE + (beat << 6)`; AW/W the
  same shape from `wmask` as WSTRB, WLAST on the second beat; R reassembled low-then-high into the
  512-bit native beat, always accepted; B counted (`bready` high).
- Credits: `n_cmd_ready` for a read only while `rd_cred != 0` (the read-data FIFO has room for the
  beat and one spare), the same rule `otpu_mem_ch` applies to its masters.
- Ordering: the native command FIFO is dispatched strictly in order (`cq_rr` a read only when
  `m_arready`; a write's command and data leave together at its last W beat), so a later read never
  passes an earlier write of the same port — 2.1 property (2).

`rtl/shell/otpu_mem_ch.sv` gained **`RMW`** (default `1` = today's DDR behaviour; HBM = `0`: a
partial beat's byte enables go out on `c_wdata_we` and the unwritten bytes are undefined) and
**`RBUS`** (default `1` = one shared read bus per channel, today's DDR; HBM = `0`: each controller
port drives its own read data, one port a pseudo-channel half). With `RMW = 0` the output write-data
FIFO `u_of` widened to W = 576 to carry the head write's own enables. `ypcb-00338` / `bcu1525`
instantiate it with the defaults, so their behaviour is bit-for-bit unchanged.

## 2.2 Unit testbench — `sim/verilator/tb_hbmbdg.sv`, `tests/test_hbmbdg.py`

`otpu_mem_ch` (RMW `0`/`1`) + two `otpu_native_axi3` + `otpu_hbm_model` (NP = 2), wired exactly as
the board channel is. 18 random scenarios × 2 RMW (partial beats, read-back, credit stress, stalls,
DRAM timing, ECC, shared/split regions, accelerator-only / XDMA-only) over `tb_memch`'s masters with
a byte shadow and write counts; a directed script (`DIR = 1`) for full/partial writes, RAW both
orders, write-flag-read and a read burst past the credits; and a WSTRB assertion at the model's
pins. `tb_memch`'s XDMA master got an `NCH` parameter (default 2) so the same masters drive one
channel.

```
$ python3 -m pytest -q tests/test_hbmbdg.py
40 passed
```

## 2.3 Behavioural HBM model — `sim/verilator/otpu_hbm_model.sv`

`otpu_native_mem` / `otpu_chmem`'s structure at the AXI3 side: NP 256-bit AXI3 slave ports (6-bit
ID, 16-beat max), one channel's `mem[BEATS]` of 512-bit beats, WSTRB merge, in-order R/B per port,
a fatal on protocol violations (len > 16, out of range, W without AW, WLAST). Per-port operations
in arrival order, one a cycle, memory sampled at the read's turn (a later read sees an earlier
write); the channel's one read bus is a round-robin across ports with a beat due.
`+hbm_lat`/`+hbm_stall`/`+hbm_dram`/`+hbm_ecc`(+`_ce`/`_ue`)/`+hbm_seed` (+`+hbm_tr*`, `+hbm_nbk`).
Images `ch<CH>.bin` in / `ch<CH>_out.bin` out on `dump`, little-endian as `otpu_chmem`'s.

`sim/verilator/otpu_hbmch.sv` is the per-slice wrapper the board model takes: two channels each
`otpu_mem_ch` (RMW 0, RBUS 0) → two `otpu_native_axi3` → one `otpu_hbm_model`, with the HBM AXI
clock (100 MHz, its own phase) generated here.

## 2.4 Board RTL — `rtl/boards/admpcie9h3/`

- `otpu_admpcie9h3_sys.sv`: `otpu_board` at S = 2; per channel `otpu_mem_ch`; per native port one
  `otpu_native_axi3` (8 AXI3 masters total, `hbm_base = j * 2 GiB`); the XDMA AXI master per channel
  and the SLR-crossing register slices as `otpu_bcu_sys` has them.
- `otpu_fpga_top_admpcie9h3.sv`: the block-design wrapper's ports (XDMA PCIe + 4 × 128-bit DMA +
  AXI-Lite BAR0, SYSMONE4), the HBM IP instance (ports per PG276, stubbed offline), the
  AXI-Lite→APB bridge, clocks/resets/LEDs.

**Deviations from 2.4's sketch (deliberate, all M0-driven or shell-driven):**

1. **No MMCM.** `refclk300` (300 MHz, AY31/BA31) → `BUFGCE_DIV` ÷3 gives `core_clk` /
   `hbm_aclk` / `hbm_ref_clk` at 100 MHz, matching M0.2 #1/#3 and the board's own
   `refclk_bufg_div3.vhd`. One fabric clock; APB `PCLK` = `core_clk`. **Superseded in M3:** the
   ÷3's 33% duty misses the HBM IP's APB macro 5 ns pulse at 100 MHz, so the top now uses one MMCM
   (x4 / 12, 50% duty) — see `04-m3-vivado.md`, "Done".
2. **No `otpu_axil_iso`.** It sits in front of the LiteDRAM CSR port on the DDR boards; there is no
   LiteDRAM CSR here, so the AXI-Lite→APB path carries its own handshake.
3. **`core_clk2x` absent** → `TMEM_PMP` must be 0 (a `$fatal` guards a build that asks for 1).
4. The `AXI3` side-band signals the bridge does not drive (AWLOCK/AWCACHE/AWPROT/AWQOS/AR* /
   ARLOCK) are tied to 0 in the top.

`boards/admpcie9h3/sim/`: `hbm_ip_stub.sv` (PG276 ports), `otpu_bd_wrapper_stub.sv`,
`otpu_axi_apb_bridge_stub.sv`, `unisim_dsp48e2_stub.sv`, `unisim_stubs.sv` (IBUFDS/BUFG/MMCME4_BASE/
IOBUF). The `boards/admpcie9h3/Makefile` and its offline checks arrive in M3.

```
$ verilator --lint-only -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM -DSYNTHESIS <unisim stubs> --top-module otpu_fpga_top_admpcie9h3 \
    <sources("admpcie9h3")> <bd/hbm/apb stubs>
# RC 0 (only otpu_tmem's pre-existing UNOPTFLAT warning)
```

## 2.6 Board-model token-exact tests

`opentpu/rtlsim.py` / `opentpu/host/board.py`: `SimTransport(target=...)` builds the HBM model
(`platform["mem"] == "hbm"` → `otpu_native_axi3.sv`, `otpu_hbm_model.sv`, `otpu_hbmch.sv`, plus
`otpu_mem_ch.sv`), passes `+hbm_stall` / `+hbm_seed`, and sets `MEM_NATIVE = 3`.
`test_tiny_qwen3_two_slices_on_board_model` is parameterized by `OTPU_TARGET` (default `bcu1525`)
and by `nreg` ∈ {0, 0b1010}, asserting `platform == T.load(board).platform_id`.

The gate itself: `OTPU_TARGET=admpcie9h3 python3 -m pytest -q tests/test_board.py -k two_slices` →
**3 passed** (the qwen two-slice test at both `nreg` plus the fake-card map test); locally the HBM
board model is also verified token-exact against the ISA simulator at **both `NREG` settings** (the
2.6.3 requirement) with the demo / masked programs through the same `Board` + `SimTransport` path
(`run_demo`), which needs no torch:

```
admpcie9h3  NREG=0b0000   demo 9080 cyc / masked 10510 cyc   PASS
admpcie9h3  NREG=0b1010   demo 9080 cyc / masked 10575 cyc   PASS
bcu1525     NREG=0b1010   demo 9125 cyc / masked 11123 cyc   PASS
```

### The one M2 finding: write visibility at the dump (`sim/verilator/tb_board.sv`)

At `NREG = 0b1010` (channels 1 and 3 through their SLR slices) the HBM model's dump was missing the
tail of the program's stores (128 bytes at `0x32440` in slice 0), while `bcu1525` passed the same
setting. Cause: `n_wdone` counts a store when its command handshake enters `otpu_native_axi3`'s
command FIFO (2.1's definition, mirrored from `otpu_mem_ch`), so when the accelerator halts the
store may still be in the bridge's FIFOs, the AXI path or `otpu_hbm_model`'s queues and latency —
deeper than the DDR boards' `otpu_chmem` / `otpu_native_mem`. The board model serves the host's DRAM
read from the dumped image (`SimTransport.mem_read`), i.e. the dump *is* that read, and it was taken
before the writes landed.

Fix: `tb_board` lets the memory drain (`DRAIN`, 16384 cycles) after the host script and before
`dump`, for `MEM_NATIVE = 3` only. This is the model's side of 2.1 property (3); it does not weaken
the RTL's ordering (the command FIFO is still dispatched in order) and the real write-visibility
check stays the WAITW phase (`tools/qual/waitw.py`) in M4/M5.

### `otpu-selftest` / `otpu-diag` (`--sim`)

Both stop at the same stage/checks on `admpcie9h3` as on the established `bcu1525` model — the
`S = 2` board model cannot run `run_demo`'s single-slice ISA `Machine` (`checks.py:178`), a
pre-existing limitation, not an HBM regression. Stages before it pass on both (link, config, calib,
scrub, regs, addr, pattern; `bandwidth` skipped on the model). What a model cannot show (the HBM
switch's write visibility, real latency, PCIe) is 2.6.4's caveat, unchanged.

## No regression on the DDR boards

`ypcb-00338` / `bcu1525` instantiate `otpu_mem_ch` with `RMW`/`RBUS` at their defaults and never
build the HBM path; `tb_board`'s drain is `MEM_NATIVE = 3` only. bcu1525 `make lint` clean;
`tests/test_hbmbdg.py` (40), `tests/test_target.py` + `tests/test_tourney.py` (94) and
`tests/test_rtl.py -k "memch or native or dram or mem"` (47) green.
