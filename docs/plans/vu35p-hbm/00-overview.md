# Plan: openTPU on the xcvu35p-fsvh2104-2-e (HBM, no DDR)

Target part: **xcvu35p-fsvh2104-2-e** (Virtex UltraScale+ HBM).
Decisions taken with the user (2026-10-15):

- **S = 2 accelerator slices** (each with its own 4 GiB DRAM window; together the whole 8 GB HBM);
- **PCIe Gen3 x16** host link;
- **licensed Vivado** covering the VU35P is available;
- the board's **XDC / board file is available** (pins are not a blocker).

The board has **no DDR**: all DRAM is the in-package HBM, reached through AMD's hard HBM
controller and the **Xilinx HBM IP (PG276)** — AXI3 slave ports, no memory pins, no MIG,
no LiteDRAM, no calibration firmware.

Throughout this plan `<board>` is the target name (placeholder `vu35p`; rename to the real
board name once known — target name, directory names, module suffixes and `platform_id`
description all follow it).

## Silicon facts the plan is built on (PG276, AMD product tables)

| Item | Value |
|---|---|
| HBM | 8 GB, 2 × 4 GB stacks; 32 pseudo-channels of 256 MB |
| User interface | 32 **AXI3** slave ports, 256-bit each, independent clocks (per port ~1/16 of stack bandwidth: ~14.4 GB/s at 450 MHz) |
| Addressing | global: any port reaches any address; address bits [31:28] select the 256 MB region (pseudo-channel), [32] the stack, [27:5] inside the region |
| Controller | hard controller + crossbar per stack; the IP handles calibration and power-up; **zero memory pins** |
| Reliability | optional in-memory SECDED ECC, RMW for partial writes (WSTRB), scrubbing, per-controller bandwidth and ECC error registers on an APB bus |
| Device | 872K LUT, 1,743K FF, 5,952 DSP, 47.3 Mb block RAM, 180 Mb UltraRAM, PCIe Gen3 x16 (PCIE4C) |

## Memory architecture (what changes and what does not)

The whole proven chain is kept; only the last hop changes:

```
slice, native 512b port
  └─ otpu_native_dram            2-channel adapter, UNCHANGED (hash interleave, CHASH)
       └─ per channel: otpu_mem_ch    accelerator + XDMA merge, credits, ordering,
                                      partial-write RMW — UNCHANGED
            └─ LiteDRAM native out
                 └─ NEW rtl/shell/otpu_native_axi3.sv    native semantics -> AXI3 master
                      └─ AXI3 256b x 2 per channel  ──►  HBM IP (PG276), 8 of 32 ports
```

- `otpu_mem_ch` (the ~600-line battle-tested arbiter) is reused wholesale; the new module is
  a protocol translation only.
- Two AXI3 ports per channel (one per LiteDRAM native port) mirror the two-port bank-parity
  structure of the DDR boards, so every cross-port ordering guarantee carries over unchanged.
- Host DMA map unchanged: channel `j = 2s + c` at `j × 2 GiB`, exactly
  `opentpu/host/board.py::channel_map` and BCU1525's `bd.tcl` (XDMA 8 GiB window, address
  bits 32:31 pick the channel).
- The HBM IP's RMW and ECC subsume what `otpu_mem_ch` does for LiteDRAM; dropping the
  bridge's own RMW is a later optimization (parameter), not a bring-up item.

## Closest template

`boards/bcu1525` + `targets/bcu1525.toml` (UltraScale+, `xilinxus` DSP48E2 cells, multi-slice
`otpu_board` at S = 2, XDMA Gen3, `ipcheck` / `synthcheck` / `elab_check` scripts). The DDR4
subsystem of that board (pin XDC generation, LiteDRAM core generation, VexRiscv BIOS, UART,
`otpu-ddr4` tool) is *removed*, not cloned.

## Milestones

| # | Milestone | Needs hardware? | Gate |
|---|---|---|---|
| M0 | Facts: license preflight, PG276 numbers, XDC inventory, SLR layout | no | `preflight ok`; numbers recorded in `01` |
| M1 | `targets/<board>.toml` + host/sim plumbing | no | `pytest` green, `otpu.target show <board>` resolves |
| M2 | `otpu_native_axi3.sv`, board top, Verilator HBM model | no | `OTPU_TARGET=<board>` token-exact tests pass, `make lint` |
| M3 | `boards/<board>/` Vivado flow, BD with XDMA + HBM IP | license (part) | `ipcheck`/`synthcheck` pass, first bitstream builds |
| M4 | First light: program, PCIe, HBM status, selftest, chat | yes | `otpu-selftest`, token-exact vs ISA simulator on the card |
| M5 | Qualify: `qual.sh full`, bandwidth counters, docs | yes | `QUAL DONE <deploy> ... PASS` |

## Files touched per milestone (summary)

- M1: `targets/<board>.toml`, `opentpu/target.py`, `opentpu/host/*` (calib/ecc dispatch,
  `otpu-smi` counters), `tools/scoreboard.py` (already knows `hbm`).
- M2: `rtl/shell/otpu_native_axi3.sv` (new), `rtl/boards/<board>/otpu_<board>_sys.sv`
  (new), `rtl/boards/<board>/otpu_fpga_top_<board>.sv` (new), `sim/verilator/otpu_hbm_model.sv`
  (new), `sim/verilator/tb_board.sv` (parameterize), `tests/` (converter unit TB).
- M3: `boards/<board>/{Makefile,run_vivado.sh,vivado/*.tcl,scripts/*.tcl,sim/*_stub.sv,
  constraints/}`.
- M4/M5: `opentpu/host/hbm.py` + `otpu-hbm` CLI (new), `docs/<board>.md` (new),
  `docs/targets.md` (row), `tools/qual/qual.sh` (should work as-is).

Read in this order: `00-overview.md`, `01-m0-facts.md`, `02-m1-target.md`,
`03-m2-rtl.md`, `04-m3-vivado.md`, `05-m4-bringup.md`, `06-m5-qualify.md`,
`07-risks.md`.
