# M4 — First light on the card: license to first tokens

Goal: the bitstream runs on the real board, the host sees it over PCIe, HBM answers, and
the accelerator decodes Qwen3 token-for-token against the ISA simulator. Cloned from
`docs/bcu1525.md` section 12, with the DDR4-specific steps replaced by HBM ones.

This file also specifies the small host tool M4 needs: **`opentpu/host/hbm.py` + the
`otpu-hbm` command** (the `otpu-ddr4` analogue), because "is the HBM up?" needs an answer
before `otpu-selftest` can mean anything.

## 4.0 New host tool (write during M3, use in M4)

`opentpu/host/hbm.py`, registered as `otpu-hbm`, modeled on `opentpu/host/ddr4.py`:

- reaches the HBM IP's registers through BAR0 at `R_HBM` (0x40000, from `bd.tcl`) via the
  AXI-Lite→APB bridge (2.1/3.3);
- runs only on a card whose bitstream (register map 4, `CFG_PLATFORM`) names this target;
- subcommands:
  - `otpu-hbm` (status): the IP's identifier/scratch (a scratch register written and read
    back through APB — the register-path check, the analogue of the DDR4 core's
    identifier + scratch), **calibrated / initialized** (the PG276 status bit M0.2
    identified — the selftest's `calib` stage reads the same), ECC enabled or not, the
    error counters, and per-MC bandwidth counter sanity;
  - `otpu-hbm ecc [--clear]`: correctable / uncorrectable counts since the last clear;
  - `otpu-hbm bw [--seconds N]`: read the IP's per-memory-controller bandwidth monitors
    (min/max/avg per PG276) — this is the `otpu-smi` DRAM counter source in M5;
  - `otpu-hbm bist [--gib G] [--passes N]`: optional; if the IP's own scrub/background
    test (PG276 RAS features) is usable, wrap it; otherwise the DMA pattern tests in
    `otpu-diag --mem full` cover it and `bist` is not implemented (decide at M0.2).
- the selftest's `calib` stage dispatches (by the target's `mem`/`mem_ctrl`, per M1's
  list) to `hbm.ready()`; `hostcal` is false so no host calibration runs.

## 4.1 Day one, in order

**1. Load and enumerate (card's host).**
```sh
cd boards/<board>
make program BIT=$PWD/../../build/vivado/otpu.bit      # or --vivado / --flash
sudo otpu-setup --rescan
otpu-setup --check
```
Expect: card `[10ee:7028]` subsystem `10ee:4f54` class `120000`; link `8.0 GT/s PCIe x16`
(the card's own `LnkCap`; x8 or Gen1 = slot/lane problem, `0xffffffff` = reprogrammed
after enumeration → rescan); `/dev/xdma0_*` bound to xdma; ID register `0x4F545055`.
The flash route (`make flash`, spiOverJtag or Vivado `program_hw_cfgmem`, M0.3) comes
later — JTAG is enough for bring-up.

**2. HBM up.**
```sh
otpu-hbm                 # identifier, scratch ok, initialized, ECC on/off, counters 0
otpu-hbm ecc             # both counts 0
```
A failed scratch check is the register path (BAR0 map in `bd.tcl`, the APB bridge, or the
IP held in reset). "Not initialized" is the HBM IP's init sequence — check its generated
soft-IP requirements (PG276) and the refclk (M0.3 pin!) before anything else.

**3. Memory over the host path.**
```sh
otpu-diag --mem full --soak 10      # march C- over each slice's 4 GiB, byte-lane hints
otpu-selftest                       # link, config, calib, scrub, regs, addr, pattern,
                                    # bandwidth, kernel, vops, stream, ecc
```
Watch specifically:
- `addr`: channel 0..3 ok (every slice's channels at `j × 2 GiB`);
- `pattern` and `--mem full`: with `RMW=0` + WSTRB this is the first real exercise of the
  HBM IP's RMW on partial writes (the quantizer's gathered stores depend on it);
- `bandwidth`: H2C/C2H GB/s at Gen3 x16 (expect ~11-12 GB/s H2C placed, per BCU1525's
  expectations; `docs/host.md` section 2);
- `ecc`: only if ECC is on (M0.2); counts must stay 0.

**4. The accelerator.**
```sh
otpu-smi                       # '<board> (S=2, 4 channels x 2048 MiB), core 100 MHz, HBM-<rate>'
otpu-selftest --model qwen3    # greedy decode == the ISA simulator, token for token
otpu-chat --backend board --model lfm2
```

**5. First failure playbook** (in likely order): link down → rescan/warm-reboot
(`docs/board.md` section 2); HBM not initialized → refclk/reset/init sequence; channel
data errors confined to one region → that region's AXI port wiring (the address map,
3.2's port enable count, `hbm_base` per channel); partial-write corruption → WSTRB path
(`RMW` parameter test on hardware); read data slips → the bridge's read FIFO/credits
(the unit TB's credit case, re-run with the card's latency `+hbm_lat`).

## 4.2 Record (then straight to M5)

BUILD_ID, `SUMMARY.txt` / `timing_summary.rpt` WNS/WHS at 100 MHz, `util.rpt` (LUT/BRAM/
DSP/URAM per SLR if `util_slr` exists), `otpu-hbm` output, `otpu-selftest` and
`otpu-diag --json` output, the first `tools/qual/perf.py` numbers (decode tok/s, DRAM GB/s
from the card's counters — with HBM expect DRAM efficiency well above the DDR3 boards'
82-94% and the MXU starvation counters to drop).
