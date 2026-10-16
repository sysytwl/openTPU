# M0 — Facts before code (half a day, no repository changes)

Goal: close every unknown that would otherwise be discovered mid-build: license/part
availability, the three PG276 numbers that gate the RTL (AXI clock, ECC cost, register
access path), and the board's pins.

## 0.1 License and device files

1. On the build host, run the BCU1525 preflight with the VU35P part:

   ```sh
   vivado -mode batch -nojournal -nolog -source boards/bcu1525/scripts/preflight.tcl \
       -tclargs xcvu35p-fsvh2104-2-e
   ```

   Expected: `PREFLIGHT ok: xcvu35p-fsvh2104-2-e is installed and licensed`.
   Exit 2 = device files missing (install via Help > Add Design Tools or Devices);
   exit 3 = license does not cover the part (Vivado hides parts its license does not
   enable).
2. Record the Vivado version this host runs (the flow pins nothing today, but `04` assumes
   a 2026.x flow like the other boards).

## 0.2 PG276 numbers that gate the design

Read PG276 (AXI High Bandwidth Memory Controller LogiCORE IP Product Guide) and record in
this file (append a "Measured/Confirmed" section):

1. **Max AXI ACLK per port.** One 256-bit port at 450 MHz is ~14.4 GB/s; at 300 MHz it is
   9.6 GB/s. Two ports per channel (the plan) cover both cases, but the number decides the
   MMCM outputs and the `[platform] mem_mts` value.
2. **ECC cost.** Does optional SECDED ECC consume HBM capacity (halving 8 GB to 4 GB), or
   does it use the stack's ECC bits? Decide here:
   - no capacity cost → ECC on, `channel_phys_bytes = 2 GiB`, S = 2 uses the whole HBM;
   - capacity cost → either S = 2 at 2 GiB/channel with ECC off for big images, or S = 1
     variant with ECC on. Record the decision; it sets `02`'s target values.
3. **Register access path.** The IP exposes its performance/ECC/error-log registers on an
   APB bus. Confirm how the design reaches them from BAR0 (AXI-Lite):
   - is there a catalog AXI-Lite→APB bridge usable in the flow, or
   - do we write ~100 lines of `axi_apb` master RTL (fine: put it in `rtl/shell/`).
   Also confirm the *user access port* / generated soft init block: who drives init
   (automatic at configuration?), what status bit means "HBM ready" (this becomes the
   selftest's `calib` stage), and whether the JTAG hardware manager alone can read the
   registers (fallback for bring-up).
4. **Data rate options** for the -2 speed grade (UG1556 lists controller rates
   100–1800 Mb/s, 1600 max on -1). Pick a conservative first rate (e.g. 1000 Mb/s) and
   record it; it goes into `[platform] mem_mts`.

## 0.3 Board inventory (from your XDC / board file)

Fill this table (it becomes the top of `docs/<board>.md`):

| Item | Value | Needed by |
|---|---|---|
| PCIe refclk (pin, quad, frequency) | | `bd.tcl`, pins XDC |
| PERST# pin | | `bd.tcl` |
| PCIe lane-to-quad mapping (Gen3 x16) | | XDMA `select_quad` |
| System clock (pin, frequency, I/O standard) | | MMCM input, pins XDC |
| **HBM reference clock (pin, 100 MHz?)** | | HBM IP port |
| Configuration mode, flash part (SPI x4? BPI?) | | `build.tcl` flash image, `program.sh` |
| JTAG (cable, chain: CPLD in front?) | | `make program` |
| UART (FTDI channel, pins) | | optional: HBM has no BIOS log, but keep for the control block's trace |
| LEDs, I2C/SMBus | | optional bring-up visibility |
| Cooling / slot power | | bring-up environment |

## 0.4 SLR layout of the VU35P

1. From AMD's package/die files (`xcvu35pfsvh2104pkg.txt` style, as BCU1525 used
   `xcvu9pfsgd2104pkg.txt`), record: number of logic SLRs, which SLR holds the 32 HBM AXI
   interfaces, which holds the PCIe block/GTY quads.
2. Planning assumption to confirm: like the VU37P (UG949), the HBM AXI interfaces and the
   PCIe block sit in one SLR; slices then go to the remaining SLRs. No floorplan is written
   in M3 — this section only informs it later.

## 0.5 Sanity checks on the parts we clone

1. Diff mentally against `docs/bcu1525.md` sections 1–6: everything about DDR4 pins,
   RDIMMs, `gen_pins.py`, LiteDRAM core generation and `otpu-ddr4` does **not** apply.
   Everything about `otpu_board` S = 2, XDMA Gen3 identity, `sc_dma`, SYSMONE4, floorplan
   methodology does.
2. Confirm the target slice sizing from `docs/bcu1525.md` section 7: one slice ≈ 176K LUT /
   713 DSP / 561.5 BRAM36 (or 177.5 with `TMEM_URAM=1`). VU35P (872K LUT, 47.3 Mb BRAM ≈
   1,356 BRAM36 tiles, 180 Mb URAM) fits two slices plus the shell with `TMEM_URAM=1`;
   record the intended `TMEM_URAM` choice here for M1.

## Deliverable

A filled-in copy of this file's tables ("Confirmed" section appended), plus a go/no-go on:

- [ ] part installed and licensed;
- [ ] AXI ACLK target known, MMCM plan sketched;
- [ ] ECC on/off decision taken;
- [ ] register access path (existing IP vs new bridge RTL) decided;
- [ ] HBM refclk pin known;
- [ ] SLR layout known.

---

# Measured / Confirmed (build host, 2026-10-15)

Read with the sections above. All Vivado output below is from the host's default `vivado`
(2024.2); the part and IP also exist in the 2025.2 install.

## 0.1 License and device files — PASS

| Item | Value |
|---|---|
| Host Vivado (`vivado` on PATH) | **2024.2** (SW Build 5239630, IP Build 5239520; Tool Version Limit 2024.11) |
| Second install | **2025.2** (`/tools/Xilinx/2025.2/Vivado/bin/vivado`, SW Build 6299465) |
| Part | `xcvu35p-fsvh2104-2-e` → DEVICE `xcvu35p`, FAMILY `virtexuplusHBM`, PACKAGE `fsvh2104`, SPEED `-2` |
| License | `Vivado_ML_Enterprise_Edition`, permanent, START=26-Apr-2026, node-locked (HOSTID 40c2ba7a09ea); `~/Xilinx.lic` = `/tools/Xilinx/Xilinx.lic` |
| HBM IP | `xilinx.com:ip:hbm` **v1.0** (the PG276 core), present in 2024.2 and 2025.2; siblings `hbm_memory_subsystem_v2_0`, `hbm_phyio_control_v1_0` |

```
$ vivado -mode batch -nojournal -nolog -source boards/bcu1525/scripts/preflight.tcl \
      -tclargs xcvu35p-fsvh2104-2-e
PREFLIGHT ok: xcvu35p-fsvh2104-2-e is installed and licensed (synthesis and implementation)
# exit 0
```

`04` assumes a 2026.x flow; this host's default is 2024.2 (2025.2 also installed). The flow
pins nothing, so either is usable — the HBM IP is the same `hbm` v1.0 in both. Record which
one M3 runs.

## 0.2 PG276 numbers (installed `hbm` v1.0 `component.xml`; PG276 1.0)

| # | Item | Value |
|---|---|---|
| 1 | AXI clock, per port | `USER_AXI_CLK_FREQ` **13–450 MHz** (default 450). Ports are 256-bit (fixed `AxSIZE` 0x5) → **14.4 GB/s at 450 MHz**, 9.6 at 300. MMCM must produce the AXI clock; 450 MHz is the ceiling. |
| 2 | ECC | On by default (`USER_MC0_ECC_BYPASS=false`). HBM2 stores the SECDED check bits in the device's dedicated ECC storage (16 check bits per 128-bit atom, carried on the DM lanes when ECC is on), so **user capacity is unaffected**; the IP's memory map is a fixed 256 MB per pseudo-channel either way. |
| 3 | Register access | IP exposes **two APB ports** (`APB_0`/`APB_1`, one per stack), `USER_APB_PCLK_0` **50–100 MHz** (default 100), plus `MON_APB_*` mirrors. A catalog bridge exists — **`xilinx.com:ip:axi_apb_bridge` v3.0** (AXI4-Lite → APB) — so no new RTL is required; ~100 lines of `axi_apb` in `rtl/shell/` stays the fallback. **Init is automatic after configuration** (the IP + `hbm_phyio_control` carry the init sequence); **`apb_complete_0/1` is the "HBM ready" indication** — the `calib` stage for M4. AMD's example design also offers an external APB sequencer (not needed). **JTAG fallback**: the IP has an optional XSDB hardware-debug interface (`USER_XSDB_INTF_EN`) the Vivado hardware manager can read. |
| 4 | Data rate | `USER_HBM_TCK` **25–900 MHz** → **50–1800 Mb/s**; the `-2` grade takes all of it. First rate: **1000 Mb/s (TCK 500 MHz)** → `[platform] mem_mts = 1000` (as `02` assumes). |

Decisions taken (with the user, 2026-10-15):

- **ECC on; no capacity cost** → `channel_phys_bytes = 2 GiB`; S = 2 uses the whole 8 GB.
- HBM IP config: density **4 GB/stack**, `USER_HBM_STACK = 2` (8 GB), `HBM_REF_CLK` **100 MHz**
  (the only choice in the 2024.2 `hbm` v1.0 catalog; the board source is the 300 MHz
  `refclk300`, ÷3 — see 0.3), AXI input clock 100 MHz (of 100/200/300).
- Register path: **`axi_apb_bridge`** from BAR0; RTL bridge is the fallback.

## 0.3 Board inventory — PASS (Alpha Data ADM-PCIE-9H3)

The board file arrived as `host_hbm-admpcie9h3-v1_0_0.zip` (repo root, 2026-10-15). It is Alpha
Data's *Host Interface to HBM* reference design for the **ADM-PCIE-9H3**, a VU35P HBM card.
Sources used: its design UG `doc/ad-ug-0124_v1_2.pdf`, `fpga/src/*.xdc`, and
`fpga/proj/mkbd-900m.tcl` (the VU35P **production** 900 m build; the pins are identical to the
800 m ES1 build). Board IP: `alpha-data.com:user:bci_admpcie9h3` v2.0.

| Item | Value | Needed by |
|---|---|---|
| PCIe refclk (pin, quad, frequency) | `sys_clk_p/n` = **AF9 / AF8**, **100 MHz** (`create_clock -period 10`), differential → `IBUFDS_GTE4` → XDMA `sys_clk_gt`/`sys_clk`; `select_quad {GTY_Quad_227}` | `bd.tcl`, pins XDC |
| PERST# pin | `sys_rst_n` = **AW27**, `LVCMOS18` (active-low, async); XDMA `sys_rst_n` | `bd.tcl` |
| PCIe lane-to-quad mapping (Gen3 x16) | Gen3 **x16 @ 8.0 GT/s**, block `PCIE4C_X1Y0` = `PCIEC4E4_X1Y0` (**SLR0**), quad group `GTY_Quad_227`; device ID 0x0906 | XDMA `select_quad` |
| System clock (pin, frequency, I/O standard) | `refclk300_p/n` = **AY31 / BA31**, **300 MHz**, `LVDS`, `DIFF_TERM_ADV TERM_100` → BUFG (the design's only fabric clock; no MMCM) | MMCM input, pins XDC |
| **HBM reference clock** | **sourced from `refclk300`** (AY31/BA31), **not** a dedicated HBM_REF_CLK pad: ÷3 (`BUFGCE_DIV`) → **100 MHz** into `HBM_REF_CLK_0/1`. The 2024.2 `hbm` v1.0 catalog enumerates **100 only**; the board's own 900 m build feeds the IP 300 MHz directly and its ES1 build feeds ÷3 = 100 MHz. | HBM IP port |
| Configuration mode, flash part | **SPIx8** (`CONFIG_MODE SPIx8`), **Micron MT25QU512** (`mt25qu512-spi-x1_x2_x4_x8`, 512 Mb / 64 MiB), `SPI_32BIT_ADDR YES`, `SPI_FALL_EDGE`, `CONFIG_VOLTAGE 1.8`, `CFGBVS GND`, `EXTMASTERCCLK DIV-1`; **Tandem PROM** for production (Vivado ≥ 2019.1) | `build.tcl` flash image, `program.sh` |
| JTAG (cable, chain) | single Xilinx/Alpha-Data JTAG **cable → `hw_server`**; FPGA-only chain (no CPLD in the chain); set target speed **10 MHz** (APB is 75 MHz); debug hub `dbg_hub/clk` = 75 MHz | `make program` |
| UART (channel, pins) | **no FTDI UART**; Alpha Data **AVR/BCI** serial: `avr_ck` = **BA33**, `avr_rx` = **BF34**, `avr_tx` = **BF33** (`LVCMOS18`) → `avr2util` + `bci_admpcie9h3` IP | control/trace |
| LEDs, I2C/SMBus | `USER_LED_G0` = **AY30**, `USER_LED_G1` = **AV31**, `USER_LED_A0` = **AV32** (`LVCMOS18`); `USER_LED_A1` = AW32 (present, unused). I2C/SMBus not exposed in this kit | bring-up visibility |
| Cooling / slot power | not in this design kit — see the ADM-PCIE-9H3 *card* manual | bring-up environment |

Board-level confirmation of the 0.2 decisions:

- `USER_HBM_DENSITY 8GB`, `USER_HBM_STACK 2`, `USER_MEMORY_DISPLAY **8192**` with ECC on →
  **8 GB of user HBM with ECC enabled** — proves **ECC costs no capacity** (0.2 #2).
- It drives a **single 256-bit AXI3 port (`SAXI_23`) at 300 MHz** (prod build) → 9.6 GB/s/port,
  far under the 450 MHz ceiling, and uses no MMCM: the 300 MHz `refclk300` is the AXI clock
  (÷4 → 75 MHz APB). This is the simplest clock plan for M3 (0.2 #1/#3).
- It does **not** implement APB register access (APB inputs tied to `0`; `apb_complete_0/1`
  only drive LEDs) and reads HBM registers via the hardware manager — confirming the **JTAG
  fallback** of 0.2 #3. Our design still adds an `axi_apb_bridge` (0.2 #3).
- `SAXI_23` (of the 32) sits near `PCIEC4E4_X1Y0` in SLR0 (UG §2.1.1): consistent with 0.4.

## 0.4 SLR layout of the VU35P (Vivado, xcvu35p-fsvh2104-2-e)

| Fact | Value |
|---|---|
| SLRs | **2**: SLR0 = clock-region rows **Y0–Y3** (tile Y 0–284), SLR1 = rows **Y4–Y7** (Y 285–534); the split is horizontal. Site counts 87,016 / 90,014. |
| Clock-region grid | 8 columns × 8 rows (X0…X7, Y0…Y7), ~62 tiles a row. |
| HBM interfaces | 32 × `BLI_HBM_AXI_INTF`, 32 × `BLI_HBM_APB_INTF`, 2 × `HBM_REF_CLK` — **all in row Y0 (X0…X7) → SLR0**. |
| PCIe / GTY | `PCIE4CE4` ×4 in X0Y0, X0Y3, X7Y0, X7Y3 (**SLR0**); `PCIE40E4` ×1 in X7Y4 (**SLR1**); `GTYE4` 4 ch per CR at both edges, rows Y0–Y7 (**both SLRs**). |

Planning assumption, refined: **all 32 HBM AXI interfaces are in SLR0**, and a Gen3 x16
PCIe4C block with its four GTY quads is reachable in SLR0 (e.g. X0Y0–X0Y3) — so the shell
(HBM + XDMA) fits in one SLR. Note GTY/PCIe resources also exist in SLR1 (the boundary is
real); SLR1 plus the fabric part of SLR0 carry the slices. No floorplan in M0.

## 0.5 Sanity checks on the parts we clone

Device totals (Vivado site counts; agree with `00-overview.md`):

| Resource | VU35P |
|---|---|
| LUT / FF | 108,960 slices → **871,680 LUT / 1,743,360 FF** |
| DSP48E2 | **5,952** |
| BRAM36 | **1,344 tiles (47.3 Mb)** |
| URAM288 | **640 (180 Mb)** |
| GTY / PCIe | 64 ch / 16 common; PCIE4CE4 ×4 + PCIE40E4 ×1 |

- Two slices + shell: ≈360K LUT (41 %), ≈1,430 DSP (24 %); block RAM is the only tight
  resource and only without UltraRAM (≈1,215 / 1,344 = 90 %). → **`TMEM_URAM=1`** (`02`
  already notes it): ≈355 tiles (26 %), leaving room for MCOLS = 8 or a later variant.
- `docs/bcu1525.md` sections 1–6 diff: DDR4 pins, RDIMMs, `gen_pins.py`, LiteDRAM core
  generation, the VexRiscv BIOS, UART calibration and `otpu-ddr4` do **not** apply. What
  carries over: `otpu_board` at S = 2, XDMA Gen3 identity + `sc_dma` DMA split, SYSMONE4
  temperature, the SLR floorplan/`USER_SLL_REG` methodology. Section 7 sizing agrees
  (production slice: 176K LUT / 713 DSP / 607.5 BRAM36; 177.5 with TMEM_URAM).

## Go / no-go

- [x] part installed and licensed;
- [x] AXI ACLK target known (≤450 MHz; 14.4 GB/s/port at 450), MMCM plan sketched;
- [x] ECC on/off decision taken (ECC **on**, no capacity cost);
- [x] register access path decided (catalog `axi_apb_bridge`, RTL fallback);
- [x] HBM refclk pin known (board source `refclk300` = AY31/BA31, 300 MHz; ÷3 → 100 MHz to
  `HBM_REF_CLK_0/1`);
- [x] SLR layout known.

**M0 complete — GO.** Every deliverable is closed. Board identified: **Alpha Data ADM-PCIE-9H3**.

Decisions taken with the user (2026-10-15), carried into M1+:

- **`<board>` = `admpcie9h3`** — the target name, directory, module suffixes and `platform_id`
  description follow the real card (`docs/admpcie9h3.md`, `targets/admpcie9h3.toml`). The plan
  directory stays `docs/plans/vu35p-hbm/` for now.
- The 280 MB kit (`host_hbm-admpcie9h3-v1_0_0.zip`) stays **out of git**; at **M3** copy only
  the XDC/clock sources it needs into `boards/admpcie9h3/` (pins XDC from
  `fpga/src/{pcie,refclk300,user_led,avr,bitstream,tandem}.xdc`, clock dividers from
  `fpga/src/{refclk_bufg_div3,refclk_bufg_div4}.vhd`).

