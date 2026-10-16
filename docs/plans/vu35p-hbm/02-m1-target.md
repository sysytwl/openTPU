# M1 — Target file and host/sim plumbing (offline, `pytest` green)

Goal: the new target exists as a first-class citizen of the multi-target flow — simulators,
tests and the host read it — before any RTL is written. No hardware, no Vivado.

## 1.1 `targets/<board>.toml`

Clone `targets/bcu1525.toml` and edit. Full intended content with the reasoning:

```toml
[target]
name = "<board>"
kind = "fpga"
platform_id = 3                 # 1 = ypcb-00338, 2 = bcu1525, 3 = <board>
description = "<board>: xcvu35p, 8 GB HBM (Xilinx HBM IP), XDMA Gen3 x16; 2 slices x 2 channels"

[arch]
S = 2                           # two slices, together on the whole 8 GB HBM
D = 128
MCOLS = 4
ACT_BLOCKS = 128
ACT_ROWS = 0
TMEM_WORDS = 65536
IMEM_WORDS = 32768
DRAM_BYTES = 4294967296         # per slice: the ISA's 32-bit DRAM addresses = 4 GiB
LANES = 8
PAIR = true
DSTEP = true
STREAM = true
SEQ_WC = false                  # bring-up: WAITC off (as bcu1525); enable after qual

[uarch]
MXU_IMPL = 2
MXU_CL = 16
VPU_CL = 2
ULANES = 8
TMEM_IMPL = 0                   # bring-up: one copy per read port (bcu1525's choice);
                                # TMEM_URAM=1 (vivado/tmem_uram.xdc) moves them to UltraRAM
RPB = 0
WPB = 1
WIN = 16
FIFO_DEPTH = 1024
TRACE_DEPTH = 16384
PQ_WIN = 1024
CHASH = true

[tech]
family = "xilinxus"             # rtl/tech/xilinxus: DSP48E2 cells
part = "xcvu35p-fsvh2104-2-e"
vendor = "xilinx"

[platform]
board = "<board>"
core_mhz = 100.0                # development builds first (docs/bcu1525.md section 2 rule)
mem = "hbm"
mem_mts = 1000                  # from M0.2 item 4; the HBM data rate the IP is configured for
mem_ctrl = "xilinx-hbm"
hostcal = false                 # the HBM IP calibrates itself at power-up
channels_per_slice = 2          # the shell's structure (slice s on channels 2s, 2s+1)
channel_bytes = 2147483648      # 2 GiB per channel; channel j at j x this (host DMA map)
channel_phys_bytes = 2147483648 # channel j occupies HBM regions j*8 .. j*8+7 of 32 x 256 MB
beat_bytes = 64
host = "pcie"
pcie_gen = 3
pcie_lanes = 16
```

Notes:

- `mem = "hbm"` is a new value for the platform layer; `tools/scoreboard.py` already
  accepts `hbm`, everything else is checked in 1.3.
- `channels_per_slice = 2` / `channel_bytes = 2 GiB` keeps the host's `channel_map()` and
  BCU1525's DMA address decode (bits 32:31 → channel) valid **unchanged**.
- If M0.2 decides ECC costs capacity, adjust `channel_phys_bytes` and note it here.
- Later variants (not now): `[variants.m8]` (8 MX columns, 128K TMEM) and an ECC/large-image
  variant if needed.

## 1.2 `opentpu/target.py`

1. `BOARDS` dict: add the board's RTL top pair (they exist after M2, but register the names
   now and add the files as empty-ish stubs so `sources()` and `tests/test_target.py` can
   see them):

   ```python
   BOARDS = {..., "<board>": ["boards/<board>/otpu_<board>_sys.sv",
                              "boards/<board>/otpu_fpga_top_<board>.sv"]}
   ```

2. The new converter goes into `SHELL` (it is board-shared shell logic, like
   `otpu_mem_ch`), appended after `shell/otpu_mem_ch.sv`:

   ```python
   SHELL = [..., "shell/otpu_mem_ch.sv", "shell/otpu_axi_split2.sv",
            "shell/otpu_native_axi3.sv"]
   ```

3. `PLATFORM_KEYS`: no change needed unless M0 found a new platform knob (e.g. an explicit
   `hbm_ports_per_channel`); prefer deriving it, not adding it.
4. `python3 -m opentpu.target env <board>` must print the shell vars a `run_vivado.sh`
   reads (same shape as the other boards: `OTPU_PLATFORM_ID`, `OTPU_ARCH_HASH`, knob
   defaults). Check `env`'s output covers `mem = "hbm"` (no `DDR_MTS`-only assumptions).

## 1.3 Sweep the `mem` / platform dispatch points

Everywhere the platform memory type is switched on, add `hbm`:

1. `opentpu/host/board.py`:
   - `device_config()` / `channel_map()` — already generic (CFG registers). Verify no
     hard-coded "2 channels, MIG at 0/2 GiB" assumptions beyond `channel_bytes`.
   - `Board.scrub` — must still run (zeros over the DRAM once after load); with HBM ECC on
     it also clears ECC counters if the IP needs it (M4 wires the details).
   - `Board.info` — `temp_c(code, family)`: the UltraScale+ branch exists for BCU1525;
     confirm the platform-id dispatch reaches it for `platform_id = 3`.
2. `opentpu/host/setup*` / selftest stages (`docs/host.md` sections 4-5): the `calib`
   stage must dispatch to a new HBM status check instead of LiteDRAM calibration (the
   implementation lands in M4 with `opentpu/host/hbm.py`; here just make sure the dispatch
   key — `mem` or `mem_ctrl` from the target — is what the stage reads, and that
   `mem_ctrl = "xilinx-hbm"` is a legal value in the loader).
3. `opentpu/profile.py`, `tools/scoreboard.py`: `--mem` already lists `hbm`; add/verify a
   `f2`-style hardware profile for this target if useful (`scoreboard.py` has `f2` at
   115 GB/s/slice as a reference).
4. `opentpu/host/regs.py` (or wherever `CAPS` bits are decoded): no `hostcal` (bit 27)
   set by this target; record in `docs/<board>.md` later.

## 1.4 Tests

Run and keep green:

```sh
python3 -m opentpu.target list                       # shows <board>
python3 -m opentpu.target show <board>               # resolves, CFG_HASH printed
python3 -m opentpu.target files <board>              # the file list (stubs + new shell file)
python3 -m pytest -q tests/test_target.py tests/test_config_matrix.py
python3 -m pytest -q                                 # the whole suite, no regressions
```

`tests/test_target.py` cross-checks `sources()` against `rtlsim.RTL_SOURCES`, the board
Makefiles and `create_project.tcl` — for the new board it will fail until M2/M3 add the
lists; keep the new board out of those checks until its flow exists, or add the lists in
the same commits as the files (preferred: follow whatever mechanism exempts `bcu1525`
before its hardware existed — check how the test treats targets without a `boards/` dir).

## Deliverable

- `targets/<board>.toml` reviewed; `otpu.target show <board>` output archived in the PR;
- full `pytest` green;
- a short note in the M1 file: which dispatch points needed `hbm` (they are the list M4
  must not forget).

---

# Done (2026-10-15)

`<board>` = **`admpcie9h3`** (M0.3; the name follows the card, not the plan directory).

## Deliverable

- `targets/admpcie9h3.toml` — written to 1.1 verbatim (all user decisions from M0.2:
  ECC on / no capacity cost → `channel_phys_bytes = 2 GiB`, `mem_mts = 1000`,
  `mem_ctrl = "xilinx-hbm"`, `TMEM_URAM = 1` is the M3 XDC's business, target keeps
  `TMEM_IMPL = 0` for bring-up as 1.1 says). `otpu.target show admpcie9h3`:
  ```
  admpcie9h3 (fpga): ADM-PCIE-9H3: xcvu35p, 8 GB HBM (Xilinx HBM IP), XDMA Gen3 x16; 2 slices x 2 channels
    [arch] S=2 D=128 MCOLS=4 ACT_BLOCKS=128 ACT_ROWS=0 TMEM_WORDS=65536 IMEM_WORDS=32768 DRAM_BYTES=4294967296 LANES=8 PAIR=1 DSTEP=1 STREAM=1 SEQ_WC=0
    [uarch] MXU_IMPL=2 MXU_CL=16 VPU_CL=2 ULANES=8 TMEM_IMPL=0 RPB=0 WPB=1 WIN=16 FIFO_DEPTH=1024 TRACE_DEPTH=16384 PQ_WIN=1024 CHASH=1
    [tech] family=xilinxus part=xcvu35p-fsvh2104-2-e vendor=xilinx
    [platform] board=admpcie9h3 core_mhz=100.0 mem=hbm mem_mts=1000 mem_ctrl=xilinx-hbm hostcal=0 channels_per_slice=2 channel_bytes=2147483648 channel_phys_bytes=2147483648 beat_bytes=64 host=pcie pcie_gen=3 pcie_lanes=16
    arch_hash c6166c02
  ```
- `opentpu/target.py` — `BOARDS["admpcie9h3"]` (the two tops, M2 stubs) and
  `shell/otpu_native_axi3.sv` appended to `SHELL` (1.2). Because it went into `SHELL`, the
  two existing flows list it too, so `test_rtl_file_lists_agree` stays green:
  `boards/{ypcb-00338,bcu1525}/{Makefile,vivado/create_project.tcl}` were updated in the
  same commit. The M2-stub files are `rtl/shell/otpu_native_axi3.sv`,
  `rtl/boards/admpcie9h3/otpu_admpcie9h3_sys.sv`, `rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv`.
- `env` (1.2 item 4): no `DDR_MTS`-only assumption — `mem` is not consulted there;
  `mem_mts` flows to the `DDR_MTS` shell var (CFG/CAPS bit3) exactly as the DDR boards.
- Tests: `tests/test_target.py::test_admpcie9h3_target_is_the_hbm_board` added (resolves,
  `platform_id == 3` / `by_platform(3)`, file list, `memcal.hostcal` false,
  `ddr4.present` false, `config_summary` = `… admpcie9h3 (S=2, 2 channels x 2048 MiB) …
  HBM-1000`). Nothing needed exempting: `test_rtl_file_lists_agree` only walks the
  `ypcb-00338` / `bcu1525` flows, so the new board (no `boards/admpcie9h3/` yet) is out of
  it until M3 adds those lists.
- `tools/tourney/components/otpu_xunit.yaml`, `tools/tourney/gen_components.py`,
  `tests/test_tourney.py`: because the new converter is in the shared `SHELL`, it is in
  `ypcb-00338`'s card file list, which the fmax tournament enumerates — every card file must
  belong to a component (`test_every_module_has_a_component`). `otpu_native_axi3.sv` joined
  the `otpu_xunit` component's `allowed` (beside `otpu_mem_ch` / `otpu_afifo` /
  `otpu_axi_split2`) in both the YAML and its generator, and the hard-coded `rtl/shell/*.sv`
  list in `test_fmax_prompt_and_xunit` gained it. The YAML is also hand-edited: per
  `gen_components.py`'s header, edit the YAML and port the edit to the generator — never
  regenerate blindly.

## Dispatch points that needed `hbm` — the list M4 must not forget

1. **`opentpu/host/selftest.py` stage 3 `calib`** — *the one real change here*. Was
   `if memcal.hostcal(t):`; now gated on the target's `mem_ctrl`
   (`mem_ctrl() in (None, "litedram") and memcal.hostcal(t)`), with `mem_ctrl()` reading
   `CFG_PLATFORM` → `by_platform().platform["mem_ctrl"]` and falling back to CAPS bit27 for
   map < 4. HBM (`xilinx-hbm`) skips the host `memcal` and waits on STATUS `CALIB0/1`; **M4
   replaces that wait with `opentpu.host.hbm.ready()`** (the IP's `apb_complete_0/1`). The
   docstring and `HINTS["calib"]` were generalized to name the HBM path.
2. **`opentpu/host/board.py` `Board.scrub`** — unchanged code path, breadcrumb comment
   added: **M4 adds `hbm.ecc(clear=True)`** (clear the IP's SECDED counters) beside the
   existing `memcal.ecc` / `ddr4.ecc`.
3. **`opentpu/host/board.py` `Board.__init__` calibrate** — line ~680 calls
   `memcal.ensure` unconditionally when `memcal.hostcal(t)`. For HBM `hostcal` is false so
   it is already skipped; **M4 decides whether the HBM IP's init needs the same
   open-time wait** as `calib`.
4. **`opentpu/host/board.py` `Board.info`** — `temp_c(code, family)` dispatch reaches the
   UltraScale+ branch for `platform_id = 3` already (line ~817: `by_platform(...).family !=
   "xilinx7"`); no change, verify on hardware.
5. **`opentpu/host/board.py` `Board.start`** — the run gate reads STATUS `CALIB0/1` and
   errors with "DDR3 channel N not calibrated". Already generic (bits, not DDR3-specific);
   the message wording is the only DDR3 assumption — cosmetic, revisit in M4.
6. **`opentpu/host/board.py` `config_summary`** — already generic: names the target and,
   keyed on CAPS bit3 (`CAP_DDR`), prints `HBM-1000` from the target's `mem`.
7. **`opentpu/host/board.py` `channel_map` / `device_config`** — generic (CFG registers);
   `channel_bytes = 2 GiB` keeps the BCU1525 DMA decode (bits 32:31 → channel) valid
   unchanged, as 1.1 predicted. No change.
8. **`opentpu/host/memcal.py` `hostcal`** — reads CAPS bit27 (unset for this target) →
   false; its callers (selftest above, `Board.__init__`) will not run it. No change.
9. **`opentpu/host/ddr4.py` `present`** — requires `mem_ctrl == "litedram"` → false for
   `xilinx-hbm` (already generic; confirmed by the new test). No change.
10. **`opentpu/host/regs.py`** — `CAP_HOSTCAL` (bit27) is never set by this target; the
    target records `mem_ctrl = "xilinx-hbm"` in CFG instead. Record in `docs/admpcie9h3.md`
    in M4.
11. **`opentpu/profile.py` / `tools/scoreboard.py`** — `--mem` already accepts `hbm`; no
    new hardware profile added (1.3 item 3 leaves it optional; `f2` stays the reference).
12. **Diagnostics** (`opentpu/host/smi.py`, `board.py` diag hints) — the `hostcal` / `ddr`
    columns are capability-derived and read false on this target; no `hbm` column added
    yet (M4, with `opentpu/host/hbm.py`).

`mem_ctrl = "xilinx-hbm"` is already a legal value: `opentpu.target.load()` does not
validate `mem` / `mem_ctrl`, so no loader change was needed.

Full-suite `pytest` (1.4), after the environment was completed (2026-10-15):
**1353 passed, 59 skipped, 1 xfailed, 0 failed** (exit 0). (This run was over the working
tree as it stood, which also carries in-progress M2 RTL work from a parallel session; the
M1-only check is the scoped run below.)

- RTL tests need **Verilator 5.046+**: this repo's RTL is written for 5.046/5.047, and the
  distro's 5.032 wrongly rejects `rtl/mxu/otpu_mxu.sv` (a variable `mk` beside a function
  `mk`, commit `be6c5542`) and hits a Verilator internal error in
  `sim/verilator/tb_se_vpu.sv`; 5.046 was built into `~/.local` and the whole suite re-run.
- `test_waits.py::test_entries_are_kept` needs `TMPDIR` on a filesystem with the
  `progcache.FREE_FLOOR` of 20 GiB free (it exercises the program cache's disk write); this
  host's `/tmp` is a 16 GiB tmpfs, so the suite ran with `TMPDIR` on the build disk. Not a
  code issue (it also fails on the pristine tree there).
- The 59 skips are all environmental: 41 no `torch`, 11 `--runslow`, plus checkpoints,
  Chrome, `yosys`, the Mac-only script and a config-specific `PAIR` case.
- `tests/test_target.py` scoped run: 24 passed, 1 skipped (no `torch`).
