# openTPU on the Alpha Data ADM-PCIE-9H3 (xcvu35p-fsvh2104-2-e, 8 GB in-package HBM through the
# Xilinx HBM IP, PCIe Gen3 x16; docs/plans/vu35p-hbm/).
#   make lint       offline: Tcl syntax, XDC pins / ports vs the top, Verilator lint of the top
#                   (-DSYNTHESIS, the DSP48E2 cells of rtl/tech/xilinxus) with stand-ins for the
#                   block design, the HBM IP and the unisim primitives (sim/; no memory pins: the
#                   HBM stacks are in the package)
#   make ipcheck    the block design in Vivado on PART (any UltraScale+ part: the free tier's
#                   xcku5p is not installed here, so a licensed non-HBM UltraScale+ part) and the
#                   HBM IP on the real xcvu35p (IPCHECK_STEPS: bd,bdsynth,hbm)
#   make synthcheck the whole project synthesized on PART (scripts/synth_check.tcl: the top against
#                   the generated block design wrapper and sim/hbm_ip_stub.sv, the DSP48E2 mapping,
#                   Vivado's utilization)
#   make bit        Vivado batch build (CORE_MHZ=100, PCIE_LANES=16, FAST=1: run_vivado.sh)
#   make impl       rerun implementation on the existing project
#   make program    JTAG load through Vivado's hardware manager (the board's Xilinx/Alpha-Data
#                   cable -> hw_server; BIT=path; no openFPGALoader board definition exists)
#   make flash      write the SPI flash (Micron MT25QU512, 64 MiB) -- permanent. Vivado's hardware
#                   manager (scripts/program.tcl flash: program_hw_cfgmem, part
#                   mt25qu512-spi-x1_x2_x4_x8, MCS=path); 10 MHz JTAG, as the board's own script
#                   (the HBM stacks do not enumerate at the default 15 MHz)
ROOT := $(abspath ../..)
# The check part: a non-HBM UltraScale+ part for the block design and the whole-project synthesis.
# This host has no Kintex UltraScale+ (the free xcku5p) device files; VU5P shares the VU35P's
# package and PCIE4/GTY blocks (docs/plans/vu35p-hbm/04-m3-vivado.md 3.5).
PART ?= xcvu5p-flvb2104-2-e
IPCHECK_STEPS ?= bd,bdsynth,hbm
OUT ?= $(ROOT)/build/vivado
BIT ?= $(OUT)/otpu.bit
MCS ?= $(OUT)/otpu.mcs

# the RTL: opentpu.target sources("admpcie9h3") (tests/test_target.py checks it), the top linted last
RTL := $(addprefix $(ROOT)/rtl/, vpu/otpu_fp.sv vpu/otpu_fpipe.sv top/otpu_pkg.sv \
  mem/otpu_tmem.sv mem/otpu_actram.sv seq/otpu_seq.sv vpu/otpu_vtree.sv dma/otpu_dma.sv \
  mxu/otpu_mxu.sv tech/xilinxus/otpu_tech_dsp.sv tech/generic/otpu_tech_ram.sv \
  vpu/otpu_quant.sv vpu/otpu_se_comp.sv vpu/otpu_se_tail.sv vpu/otpu_vpu.sv \
  top/otpu_coll.sv top/otpu_slice.sv shell/otpu_ctrl.sv shell/otpu_trace.sv \
  shell/otpu_board.sv mem/otpu_native_dram.sv shell/otpu_afifo.sv shell/otpu_mem_ch.sv \
  shell/otpu_axi_split2.sv shell/otpu_native_axi3.sv boards/admpcie9h3/otpu_axi_apb_bridge.sv \
  boards/admpcie9h3/otpu_admpcie9h3_sys.sv)
LINT := verilator --lint-only -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM -DSYNTHESIS sim/unisim_dsp48e2_stub.sv sim/unisim_stubs.sv

.PHONY: lint ipcheck synthcheck bit impl program flash
lint:
	python3 scripts/check_offline.py
	$(LINT) --top-module otpu_fpga_top_admpcie9h3 $(RTL) sim/otpu_bd_wrapper_stub.sv \
	  sim/hbm_ip_stub.sv $(ROOT)/rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv

ipcheck:
	vivado -mode batch -nojournal -log $(OUT)_ipcheck.log -source vivado/ip_check.tcl \
	  -tclargs $(PART) $(OUT)_ipcheck $(IPCHECK_STEPS)

synthcheck:
	vivado -mode batch -nojournal -log $(OUT)_synthcheck.log -source scripts/synth_check.tcl \
	  -tclargs $(PART) $(OUT)_synthcheck

bit:
	./run_vivado.sh

impl:
	STEP=impl ./run_vivado.sh

program:
	vivado -mode batch -nojournal -log $(OUT)_program.log -source scripts/program.tcl \
	  -tclargs $(BIT) bit

flash:
	vivado -mode batch -nojournal -log $(OUT)_flash.log -source scripts/program.tcl \
	  -tclargs $(MCS) flash
