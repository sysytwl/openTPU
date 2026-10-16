# Clock-domain crossings of the ADM-PCIE-9H3 top (otpu_fpga_top_admpcie9h3) outside otpu_mem_ch
# (whose own are boards/ypcb-00338/constraints/otpu_mem_ch.tcl, scoped to the module:
# create_project.tcl adds it for every otpu_mem_ch here too). Unmanaged Tcl, read in implementation
# only and late, as the BCU1525 top's (constraints/bcu1525_top.tcl), whose reasoning it follows: no
# clock pair is declared asynchronous (that would take priority over otpu_mem_ch's
# set_max_delay -datapath_only), so every path between two clocks is a max delay without skew,
# here, in otpu_mem_ch.tcl or in the IPs' own constraints.
#
# The clocks: core_clk (the top's MMCM from refclk300: the accelerator, the block design's control
# interconnect, the HBM AXI clock and the APB PCLK) and xdma_aclk (XDMA's, 250 MHz, from the PCIe
# reference clock). The HBM IP's HBM_REF_CLK_0/1 clock (its scoped XDC's create_clock) only drives
# the IP's reference input; the IP constrains its own crossing. Each channel's otpu_mem_ch runs its
# controller side (uclk) in core_clk -- the HBM AXI clock -- so only its xdma_aclk side crosses,
# which otpu_mem_ch.tcl bounds. UNVERIFIED: written before a VU35P build.
set c_core [get_clocks -quiet -of_objects [get_pins -quiet {u_sys/g_ch[0].u_ch/clk}]]
set c_x    [get_clocks -quiet -of_objects [get_pins -quiet {u_sys/g_ch[0].u_ch/xclk}]]
foreach v {c_core c_x} {
  if {[llength [set $v]] != 1} {
    puts "CRITICAL WARNING: \[admpcie9h3_top.tcl\] $v is '[set $v]', expected one clock: crossings unconstrained"
  }
}
set t_core [get_property -quiet -min PERIOD $c_core]

# XDMA's AXI reset (xdma_aclk) into core_clk (lrs1 / lrs2: the control masters' reset for the
# SmartConnect's control side): one core_clk period
set lrs1 [get_cells -quiet lrs1_reg]
if {[llength $lrs1] && [llength $c_x] == 1 && [llength $c_core] == 1} {
  set_max_delay -datapath_only -from $c_x -to $lrs1 $t_core
} else {
  puts "CRITICAL WARNING: \[admpcie9h3_top.tcl\] the control masters' reset: [llength $lrs1] synchronizer cells"
}

# report_cdc waivers for XDMA's read data: each channel's u_xr (distributed RAM written in its
# controller clock, core_clk) read asynchronously onto its R channel into sc_dma (xdma_aclk;
# otpu_mem_ch.tcl bounds the paths); safe by the pointer protocol
set xr_ram [get_cells -quiet -hierarchical -filter {NAME =~ u_sys/g_ch*.u_ch/u_xr/mem_reg*}]
set xr_src [get_pins -quiet -filter {IS_LEAF && REF_PIN_NAME == CLK} -of_objects $xr_ram]
set xr_out [get_pins -quiet -filter {IS_LEAF && DIRECTION == OUT} -of_objects $xr_ram]
set xr_dst {}
if {[llength $xr_out]} {
  set xr_dst [filter [all_fanout -quiet -from $xr_out -endpoints_only -flat] {NAME !~ u_sys/g_ch*.u_ch/*}]
}
if {[llength $xr_src] && [llength $xr_dst]} {
  foreach id {CDC-1 CDC-4 CDC-13 CDC-14 CDC-15 CDC-16 CDC-26} {
    if {[catch {create_waiver -type CDC -id $id -user "otpu_admpcie9h3_sys" -description "otpu_mem_ch u_xr's head read asynchronously onto XDMA's R channel (sc_dma); taken only with x_rvalid, the FIFO's registered not-empty in xdma_aclk" -from $xr_src -to $xr_dst} msg]} {
      puts "CRITICAL WARNING: \[admpcie9h3_top.tcl\] $id waiver not created: $msg"
    }
  }
} else {
  puts "CRITICAL WARNING: \[admpcie9h3_top.tcl\] XDMA read-data waivers: [llength $xr_src] RAM clock pins, [llength $xr_dst] endpoints"
}
if {[catch {create_waiver -type METHODOLOGY -id {TIMING-9} -user "otpu_admpcie9h3_sys" -description "otpu_mem_ch's FIFO heads and XDMA's read data from them; each crossing is waived in report_cdc by its two ends"} msg]} {
  puts "CRITICAL WARNING: \[admpcie9h3_top.tcl\] TIMING-9 waiver not created: $msg"
}
