# Block design "otpu_bd" for the ADM-PCIE-9H3 (create_project.tcl; boards/bcu1525/vivado/bd.tcl is
# its model): PCIe (XDMA, Gen3 x16), resets, the SYSMONE4 and the control interconnect. No memory
# controllers: the accelerator and XDMA's DMA meet on each HBM channel in front of the Xilinx HBM IP
# (outside the block design, rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv) -- the HBM stacks are
# in the package, so there are no memory pins. External interfaces:
#   M_AXI_CTL       AXI4-Lite master -> the accelerator's control registers (BAR0 0x00000, core_clk)
#   M_AXI_HBM       AXI4-Lite master -> the HBM IP's APB registers through the top's
#                   otpu_axi_apb_bridge (BAR0 0x800000, 8 MiB: APB_AW 22, stack = AXI bit 22;
#                   core_clk)
#   M_AXI_DMA<j>    AXI4 masters, 128 bits, no IDs, xdma_aclk -> board channel j = 2s + c's bridge
#                   (otpu_mem_ch): XDMA's DMA (512 bits at x16, 256 at x8) through the SmartConnect
#                   sc_dma, which decodes card address bits 32:31 (channel j at j * 2 GiB: what
#                   slice s addresses of its channel c; opentpu.host.board.channel_map) and
#                   converts the width
# and device_temp (the SYSMONE4's die temperature, 10 bits, core_clk; BAR0 0x30000: its registers).
# The BAR0 layout keeps the YPCB's (control at 0x0, the system monitor at 0x30000); 0x10000 (the
# YPCB core's CSRs, R_MEMCAL) is left unmapped, as are 0x40000-0x7FFFFF. The HBM APB window is at
# 0x800000, not the plan's 0x40000: Vivado requires a segment's offset to be a multiple of its
# range, and the window is 8 MiB (2 stacks x 4 MiB of APB registers, APB_AW 22).
#
# Clocks: core_clk is an *input* port: the top's refclk300 through one MMCM (x4 / 12 = 100 MHz,
# 50% duty), at once the fabric clock, the HBM IP's AXI clock and its APB PCLK. xdma_aclk: 250 MHz
# (from the PCIe reference clock). The block design's control masters run in core_clk (aclk1), as
# the BCU1525's do.
#
# Variables (set before sourcing): CORE_MHZ (100; the HBM IP is configured for it). Environment:
# PCIE_LANES, 16 (Gen3 x16, 512-bit AXI, the default) or 8 (Gen3 x8, 256 bits).
# Checked (vivado/ip_check.tcl) on a non-HBM UltraScale+ part until a VU35P build: the PCIe block
# location and GTY quad selection that only the real part needs (PCIE4C_X1Y0 / GTY_Quad_227) are
# applied only on the VU35P.

proc ip_vlnv {name} {
  set defs [lsort -decreasing [get_ipdefs -all "xilinx.com:ip:${name}:*"]]
  if {[llength $defs] == 0} { error "IP $name not found in this Vivado installation" }
  return [lindex $defs 0]
}

create_bd_design otpu_bd
current_bd_design otpu_bd

# core_clk: the top's refclk300 through its MMCM (no MMCM here). The HBM IP is configured for
# 100 MHz (hbm_ip.tcl), so it must be 100.
if {![info exists CORE_MHZ]} { set CORE_MHZ 100 }
if {$CORE_MHZ != 100} { error "bd.tcl: CORE_MHZ $CORE_MHZ (the HBM IP is configured for 100; regenerate it, hbm_ip.tcl)" }
set CORE_HZ [expr {int($CORE_MHZ * 1.0e6)}]
set PCIE_LANES [expr {[info exists ::env(PCIE_LANES)] && $::env(PCIE_LANES) ne "" ? $::env(PCIE_LANES) : 16}]
if {$PCIE_LANES ni {8 16}} { error "bd.tcl: PCIE_LANES $PCIE_LANES (8 or 16)" }
set AXI_BITS [expr {$PCIE_LANES == 16 ? 512 : 256}]
set XDMA_MHZ 250
set XDMA_HZ [expr {$XDMA_MHZ * 1000000}]
# NB: a distinct name: create_project.tcl's $VU35P is the *part string* (its default part), and it
# sources this file -- reusing the name here clobbered it, so create_project.tcl's pin-constraint
# test ($PART ne $VU35P) was always true and the VU35P's pins were dropped from the build.
set IS_VU35P [string match -nocase xcvu35p* [get_property PART [current_project]]]
puts "core_clk: $CORE_MHZ MHz; PCIe: Gen3 x$PCIE_LANES, $AXI_BITS-bit AXI, xdma_aclk $XDMA_MHZ MHz (VU35P: $IS_VU35P)"

# ------------------------------------------------------------------ external ports
# core_clk comes from the top (its MMCM), not from an MMCM in here
create_bd_port -dir I -type clk core_clk
set_property CONFIG.FREQ_HZ $CORE_HZ [get_bd_ports core_clk]
# The PCIe reference clock: the diff_clock interface port is named `sys`, so the wrapper's pins are
# sys_clk_p / sys_clk_n -- the board kit's pcie.xdc names (AF9/AF8) and the top's ports.
set pcie_refclk [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 sys]
set_property CONFIG.FREQ_HZ 100000000 $pcie_refclk
# PCIe PERST# (the board kit's sys_rst_n, AW27, active low): XDMA's sys_rst_n and the core reset
create_bd_port -dir I -type rst sys_rst_n
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports sys_rst_n]
create_bd_port -dir O -type clk xdma_aclk
create_bd_port -dir O -type rst xdma_aresetn
create_bd_port -dir O -from 9 -to 0 device_temp
create_bd_port -dir O pcie_link_up

set lites {M_AXI_CTL M_AXI_HBM}
foreach p $lites {
  set m [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 $p]
  set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32 \
    CONFIG.HAS_BURST 0 CONFIG.HAS_LOCK 0 CONFIG.HAS_PROT 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_QOS 0 \
    CONFIG.HAS_REGION 0 CONFIG.FREQ_HZ $CORE_HZ] $m
}
set_property CONFIG.ASSOCIATED_BUSIF [join $lites :] [get_bd_ports core_clk]
set_property CONFIG.FREQ_HZ $CORE_HZ [get_bd_ports core_clk]

# ------------------------------------------------------------------ resets
# core reset: while the host asserts PCIe PERST# (sys_rst_n), released synchronously to core_clk.
# The top makes its own core_rstn / core_rst from the same pin for the fabric and the HBM IP; this
# one resets the block design's control interconnect and the SYSMONE4.
set rst_core [create_bd_cell -type ip -vlnv [ip_vlnv proc_sys_reset] rst_core]
connect_bd_net [get_bd_ports core_clk] [get_bd_pins rst_core/slowest_sync_clk]
connect_bd_net [get_bd_ports sys_rst_n] [get_bd_pins rst_core/ext_reset_in]

# ------------------------------------------------------------------ PCIe: XDMA, Gen3 x16 (x8)
# The YPCB's identity (device 7028, class 1200, subsystem 10EE:4F54: the host's driver binding and
# opentpu/host find the card the same way) and its H2C setting (xdma_rnum_rids 8: docs/host.md,
# "XDMA's H2C overrun"). The x16 lanes are GTY quads 224-227 (SLR0, PCIE4C_X1Y0); the board kit's
# select_quad is GTY_Quad_227 (the PCIe reference clock's quad 226 sits inside the four). Only the
# VU35P has it, and the block location is set first (see the VU35P branch below).
set ibuf [create_bd_cell -type ip -vlnv [ip_vlnv util_ds_buf] refclk_buf]
set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $ibuf
connect_bd_intf_net $pcie_refclk [get_bd_intf_pins refclk_buf/CLK_IN_D]

set xdma [create_bd_cell -type ip -vlnv [ip_vlnv xdma] xdma_0]
set cfg [list \
  CONFIG.mode_selection {Advanced} \
  CONFIG.pl_link_cap_max_link_width "X$PCIE_LANES" \
  CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
  CONFIG.axi_data_width "${AXI_BITS}_bit" \
  CONFIG.axisten_freq $XDMA_MHZ \
  CONFIG.ref_clk_freq {100_MHz} \
  CONFIG.pf0_device_id {7028} \
  CONFIG.pf0_class_code_base {12} CONFIG.pf0_class_code_sub {00} \
  CONFIG.pf0_class_code_interface {00} \
  CONFIG.pf0_subsystem_vendor_id {10EE} CONFIG.pf0_subsystem_id {4F54} \
  CONFIG.pf0_revision_id {01} \
  CONFIG.xdma_rnum_chnl {1} CONFIG.xdma_wnum_chnl {1} CONFIG.xdma_rnum_rids {8} \
  CONFIG.axilite_master_en {true} CONFIG.axilite_master_size {16} \
  CONFIG.axilite_master_scale {Megabytes} \
  CONFIG.pciebar2axibar_axil_master {0x00000000} \
  CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
  CONFIG.plltype {QPLL1} \
]
if {$IS_VU35P} {
  # The board's PCIe block is PCIE4C_X1Y0 (its GTY refclk quad 226 sits inside the x16 lanes'
  # 224-227). The block location is part of the same -dict as select_quad: the IP's default block
  # (PCIE4C_X0Y0) only offers quads 124-127, and GTY_Quad_227 is out of range there.
  lappend cfg CONFIG.pcie_blk_locn {PCIE4C_X1Y0} \
    CONFIG.en_gt_selection {true} CONFIG.select_quad {GTY_Quad_227}
}
set_property -dict $cfg $xdma
connect_bd_net [get_bd_pins refclk_buf/IBUF_DS_ODIV2] [get_bd_pins xdma_0/sys_clk]
connect_bd_net [get_bd_pins refclk_buf/IBUF_OUT] [get_bd_pins xdma_0/sys_clk_gt]
connect_bd_net [get_bd_ports sys_rst_n] [get_bd_pins xdma_0/sys_rst_n]
make_bd_intf_pins_external [get_bd_intf_pins xdma_0/pcie_mgt]
set_property NAME pcie_mgt [get_bd_intf_ports -of [get_bd_intf_nets -of [get_bd_intf_pins xdma_0/pcie_mgt]]]
connect_bd_net [get_bd_pins xdma_0/user_lnk_up] [get_bd_ports pcie_link_up]
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_ports xdma_aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_ports xdma_aresetn]

# XDMA's DMA onto the four channels: one 128-bit AXI4 master each (otpu_mem_ch's XDMA side), in
# xdma_aclk; INCR bursts of full-width beats (otpu_mem_ch relies on it: no burst type port), in
# order per master (no IDs: otpu_mem_ch answers in order)
set dmas {M_AXI_DMA0 M_AXI_DMA1 M_AXI_DMA2 M_AXI_DMA3}
set scd [create_bd_cell -type ip -vlnv [ip_vlnv smartconnect] sc_dma]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {4} CONFIG.NUM_CLKS {1}] $scd
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins sc_dma/aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins sc_dma/aresetn]
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins sc_dma/S00_AXI]
foreach p $dmas {
  set m [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 $p]
  set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 128 CONFIG.ADDR_WIDTH 33 \
    CONFIG.HAS_BURST 0 CONFIG.HAS_LOCK 0 CONFIG.HAS_PROT 0 CONFIG.HAS_CACHE 0 \
    CONFIG.HAS_QOS 0 CONFIG.HAS_REGION 0 CONFIG.FREQ_HZ $XDMA_HZ] $m
  connect_bd_intf_net [get_bd_intf_pins sc_dma/M0[string index $p end]_AXI] $m
}
set_property CONFIG.ASSOCIATED_BUSIF [join $dmas :] [get_bd_ports xdma_aclk]
set_property CONFIG.ASSOCIATED_RESET {xdma_aresetn} [get_bd_ports xdma_aclk]
set_property CONFIG.FREQ_HZ $XDMA_HZ [get_bd_ports xdma_aclk]

# ------------------------------------------------------------------ SYSMON (die temperature)
# UltraScale+: the System Management Wizard (SYSMONE4; the XADC's successor). temp_out is its 10-bit
# code (UG580: T = code * 509.3140064 / 1024 - 280.23087870 with the internal reference), not the
# XADC's 12-bit one: the host takes the formula from the platform (CFG_PLATFORM).
set sysmon [create_bd_cell -type ip -vlnv [ip_vlnv system_management_wiz] sysmon]
set_property -dict [list CONFIG.INTERFACE_SELECTION {Enable_AXI} \
  CONFIG.DCLK_FREQUENCY [expr {int(ceil($CORE_HZ / 1.0e6))}] \
  CONFIG.SEQUENCER_MODE {Default} CONFIG.CHANNEL_ENABLE_VP_VN {false} \
  CONFIG.ENABLE_TEMP_BUS {true} CONFIG.OT_ALARM {false} CONFIG.USER_TEMP_ALARM {false} \
  CONFIG.VCCINT_ALARM {false} CONFIG.VCCAUX_ALARM {false}] $sysmon
connect_bd_net [get_bd_ports core_clk] [get_bd_pins sysmon/s_axi_aclk]
connect_bd_net [get_bd_pins rst_core/peripheral_aresetn] [get_bd_pins sysmon/s_axi_aresetn]
connect_bd_net [get_bd_pins sysmon/temp_out] [get_bd_ports device_temp]

# ------------------------------------------------------------------ control interconnect
set scl [create_bd_cell -type ip -vlnv [ip_vlnv smartconnect] sc_ctl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3} CONFIG.NUM_CLKS {2}] $scl
connect_bd_net [get_bd_pins xdma_0/axi_aclk] [get_bd_pins sc_ctl/aclk]
connect_bd_net [get_bd_ports core_clk] [get_bd_pins sc_ctl/aclk1]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins sc_ctl/aresetn]
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI_LITE] [get_bd_intf_pins sc_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M00_AXI] [get_bd_intf_ports M_AXI_CTL]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M01_AXI] [get_bd_intf_pins sysmon/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M02_AXI] [get_bd_intf_ports M_AXI_HBM]

# ------------------------------------------------------------------ address map
# BAR0: 0x00000 the control registers (64 KB), 0x30000 the SYSMONE4, 0x800000-0xFFFFFF the HBM IP's
# two APB register ports (8 MiB: APB_AW 22, the stack is address bit 22; 8 MiB-aligned, Vivado
# requires a segment's offset to be a multiple of its range). XDMA's DMA: 8 GiB,
# M_AXI_DMA<j> at j * 2 GiB (the 2 GiB of each channel the slices address; address bits 32:31)
set lite [get_bd_addr_spaces xdma_0/M_AXI_LITE]
assign_bd_address -offset 0x00000000 -range 64K -target_address_space $lite [get_bd_addr_segs M_AXI_CTL/Reg] -force
assign_bd_address -offset 0x00030000 -range 64K -target_address_space $lite \
  [get_bd_addr_segs -of [get_bd_intf_pins sysmon/S_AXI_LITE]] -force
assign_bd_address -offset 0x00800000 -range 8M -target_address_space $lite \
  [get_bd_addr_segs M_AXI_HBM/Reg] -force
foreach j {0 1 2 3} {
  assign_bd_address -offset [format 0x%09X [expr {$j * 0x80000000}]] -range 2G \
    -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] [get_bd_addr_segs M_AXI_DMA$j/Reg] -force
}

validate_bd_design

foreach p [concat {pcie_mgt sys} $dmas $lites] {
  if {[get_bd_intf_ports $p] eq ""} { error "block design port $p missing: [get_bd_intf_ports]" }
}
foreach {k want} [list pf0_device_id 7028 pf0_class_code 120000 pf0_subsystem_id 4F54 \
                       pf0_revision_id 01 axisten_freq $XDMA_MHZ \
                       pl_link_cap_max_link_width X$PCIE_LANES axi_data_width ${AXI_BITS}_bit] {
  set got [get_property CONFIG.$k [get_bd_cells xdma_0]]
  if {$got ne $want} { error "xdma_0: $k is $got, expected $want" }
}
foreach p $dmas {
  set w [get_property CONFIG.DATA_WIDTH [get_bd_intf_ports $p]]
  if {$w != 128} { error "$p is $w bits, expected 128 (otpu_mem_ch's XDMA side)" }
  # read-only on a master port (the SmartConnect sets it): the top has no ID signals, and
  # otpu_mem_ch answers in order
  set id [get_property CONFIG.ID_WIDTH [get_bd_intf_ports $p]]
  if {$id != 0} { error "$p has $id ID bits, expected none (otpu_fpga_top_admpcie9h3 wires no IDs)" }
}
puts "M_AXI_DMA0..3: 128 bits from XDMA's $AXI_BITS"
save_bd_design
