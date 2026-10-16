# Create the Vivado project for openTPU on the ADM-PCIE-9H3 (xcvu35p-fsvh2104-2-e;
# docs/plans/vu35p-hbm/): the Xilinx HBM IP (hbm_ip.tcl, 8 GB, 8 AXI3 ports, the two APB register
# ports), the block design (bd.tcl: XDMA Gen3, its DMA split, the SYSMONE4, the BAR0 map) and the
# board top (rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv: S slices, two HBM channels each,
# the AXI4-Lite -> APB bridge to the HBM registers). No memory pins: the HBM stacks are in the
# package.
#   vivado -mode batch -source create_project.tcl -tclargs OUT_DIR MCOLS CORE_MHZ BUILD_ID VPU_CL \
#     LANES ACT_ROWS DSTEP S PLATFORM ARCH_HASH DDR_MTS
# (run_vivado.sh takes them from the target, targets/admpcie9h3.toml; the RTL list below is
# opentpu.target sources("admpcie9h3"): tests/test_target.py)
# Environment: PCIE_LANES (bd.tcl), OTPU_FAST (development strategies), OTPU_IP_CACHE, OTPU_PART
# (another part, for scripts/synth_check.tcl: without the VU35P's pin constraints),
# OTPU_HBM_STUB=1 (scripts/synth_check.tcl: sim/hbm_ip_stub.sv instead of generating the IP, which
# exists only on HBM parts), TMEM_URAM (the TMEM in UltraRAM).
# The VU35P needs a Vivado license that covers it (not the free tier) and the Virtex UltraScale+
# HBM device files.

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
# hexarg I: argument I as given ("" when absent). Not through expr's ?:, which reads a
# numeric-looking string as a number: BUILD_ID 83740e79 came out 8.374e+83, failed the hex
# check and was built as 0 (dev build 83740e79, 2026-10-12); 01234567 would be octal
proc hexarg {i} {
  if {[llength $::argv] > $i} { return [lindex $::argv $i] }
  return ""
}
set out [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$root/build/vivado"}]
set MCOLS [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]
set CORE_MHZ [expr {[llength $argv] > 2 ? [lindex $argv 2] : 100}]
set BUILD_ID [hexarg 3]
set VPU_CL [expr {[llength $argv] > 4 ? [lindex $argv 4] : 2}]
set LANES [expr {[llength $argv] > 5 ? [lindex $argv 5] : 8}]
set ACT_ROWS [expr {[llength $argv] > 6 ? [lindex $argv 6] : $MCOLS}]
set DSTEP [expr {[llength $argv] > 7 ? [lindex $argv 7] : 1}]
set S [expr {[llength $argv] > 8 ? [lindex $argv 8] : 2}]
# PLATFORM, ARCH_HASH: the CFG_PLATFORM / CFG_HASH registers (run_vivado.sh: targets/admpcie9h3.toml
# through opentpu/target.py; ARCH_HASH 8 hex digits); DDR_MTS: the HBM data rate (CFG DDR_MTS)
set PLATFORM [expr {[llength $argv] > 9 ? [lindex $argv 9] : 3}]
set ARCH_HASH [hexarg 10]
if {$ARCH_HASH eq ""} { set ARCH_HASH 0 }
if {![regexp {^[0-9a-fA-F]{1,8}$} $ARCH_HASH]} { error "ARCH_HASH $ARCH_HASH: 1 to 8 hex digits" }
set DDR_MTS [expr {[llength $argv] > 11 ? [lindex $argv 11] : 1000}]
set VU35P xcvu35p-fsvh2104-2-e
set PART [expr {[info exists ::env(OTPU_PART)] && $::env(OTPU_PART) ne "" ? $::env(OTPU_PART) : $VU35P}]
if {$BUILD_ID eq ""} {
  if {[catch {exec git -C $root rev-parse HEAD} BUILD_ID]} { set BUILD_ID 0 }
  set BUILD_ID [string range $BUILD_ID 0 7]
}
if {![regexp {^[0-9a-fA-F]{1,8}$} $BUILD_ID]} { error "BUILD_ID $BUILD_ID: 1 to 8 hex digits" }
# core_clk: the top's MMCM (refclk300 x4 / 12). CORE_KHZ is the control block's register; the HBM IP
# is configured for 100 MHz (hbm_ip.tcl), so core_clk must be 100.
set CORE_KHZ [expr {round($CORE_MHZ * 1000.0)}]
puts "CORE_KHZ $CORE_KHZ, BUILD_ID $BUILD_ID, S $S, PLATFORM $PLATFORM, ARCH_HASH $ARCH_HASH, HBM-$DDR_MTS"

create_project -force otpu $out -part $PART
# threads for this process and the runs it launches: launch_runs writes the launching process's
# general.maxThreads into each run's script. Parallel synthesis is separately capped at 8
# (synth.maxThreads), but implementation (place / route / phys_opt) uses this; OTPU_MAX_THREADS
# overrides (default: min(nproc, 24), the free cores on the build host).
proc otpu_max_threads {} {
  if {[info exists ::env(OTPU_MAX_THREADS)] && $::env(OTPU_MAX_THREADS) ne ""} {
    return $::env(OTPU_MAX_THREADS)
  }
  if {![catch {exec nproc} nc] && [string is integer -strict $nc]} {
    return [expr {$nc > 24 ? 24 : $nc}]
  }
  return 8
}
set_param general.maxThreads [otpu_max_threads]
if {[info exists ::env(OTPU_IP_CACHE)] && $::env(OTPU_IP_CACHE) ne ""} {
  file mkdir $::env(OTPU_IP_CACHE)
  config_ip_cache -use_cache_location $::env(OTPU_IP_CACHE)
}
set_property target_language Verilog [current_project]

# ---- RTL: the accelerator's core and tech cells (UltraScale+: DSP48E2), the shell shared with the
# YPCB, the AXI4-Lite -> APB bridge, the board's sys wrapper and top
set rtl [list \
  rtl/vpu/otpu_fp.sv rtl/vpu/otpu_fpipe.sv rtl/top/otpu_pkg.sv \
  rtl/mem/otpu_tmem.sv rtl/mem/otpu_actram.sv \
  rtl/seq/otpu_seq.sv rtl/vpu/otpu_vtree.sv rtl/dma/otpu_dma.sv \
  rtl/mxu/otpu_mxu.sv rtl/tech/xilinxus/otpu_tech_dsp.sv rtl/tech/generic/otpu_tech_ram.sv \
  rtl/vpu/otpu_quant.sv rtl/vpu/otpu_se_comp.sv rtl/vpu/otpu_se_tail.sv rtl/vpu/otpu_vpu.sv \
  rtl/top/otpu_coll.sv rtl/top/otpu_slice.sv \
  rtl/shell/otpu_ctrl.sv rtl/shell/otpu_trace.sv \
  rtl/shell/otpu_board.sv rtl/mem/otpu_native_dram.sv \
  rtl/shell/otpu_afifo.sv rtl/shell/otpu_mem_ch.sv \
  rtl/shell/otpu_axi_split2.sv rtl/shell/otpu_native_axi3.sv \
  rtl/boards/admpcie9h3/otpu_axi_apb_bridge.sv \
  rtl/boards/admpcie9h3/otpu_admpcie9h3_sys.sv \
  rtl/boards/admpcie9h3/otpu_fpga_top_admpcie9h3.sv]
foreach f $rtl {
  add_files -norecurse $root/$f
  set_property file_type SystemVerilog [get_files $root/$f]
}
set_property verilog_define {SYNTHESIS} [get_filesets sources_1]

# ---- the HBM IP (M0.2): a Vivado-generated IP, instantiated in the project (non-BD) so its
# scoped XDC (hdl/par/hbm_ip.xdc: HBM_REF_CLK_0/1 at 10 ns) applies to its own instance. With
# OTPU_HBM_STUB=1 (synth_check on a non-HBM part) the lint stand-in stands in for it instead.
if {[info exists ::env(OTPU_HBM_STUB)] && $::env(OTPU_HBM_STUB) eq "1"} {
  add_files -norecurse $root/boards/admpcie9h3/sim/hbm_ip_stub.sv
  set_property file_type SystemVerilog [get_files $root/boards/admpcie9h3/sim/hbm_ip_stub.sv]
  puts "HBM IP stubbed (sim/hbm_ip_stub.sv): no IP generation"
} else {
  source $here/hbm_ip.tcl
  set hbm [create_hbm_ip]
  generate_target all $hbm
  create_ip_run $hbm
  puts "HBM IP generated: [get_property IP_DIR $hbm]"
}

# ---- block design
source $here/bd.tcl
make_wrapper -files [get_files otpu_bd.bd] -top
add_files -norecurse [glob $out/otpu.gen/sources_1/bd/otpu_bd/hdl/otpu_bd_wrapper.v]
set_property top otpu_fpga_top_admpcie9h3 [current_fileset]
# otpu_seq WAITC (run_vivado.sh: the target's [arch] SEQ_WC, or SEQ_WC=1; CFG_UARCH bit24)
set SEQ_WC [expr {[info exists ::env(OTPU_SEQ_WC_GEN)] && $::env(OTPU_SEQ_WC_GEN) eq "1" ? 1 : 0}]
set_property generic "SEQ_WC=1'b$SEQ_WC S=$S MCOLS=$MCOLS ACT_ROWS=$ACT_ROWS VPU_CL=$VPU_CL LANES=$LANES CORE_KHZ=$CORE_KHZ BUILD_ID=32'h$BUILD_ID DDR_MTS=$DDR_MTS DSTEP=1'b$DSTEP PCIE_LANES=$PCIE_LANES PLATFORM=$PLATFORM ARCH_HASH=32'h$ARCH_HASH" [current_fileset]

# ---- constraints: the pins, the top's clocks and crossings (no memory pins: the HBM stacks are in
# the package)
set cons $root/boards/admpcie9h3/constraints
set xdcs [glob $cons/*.xdc]
if {$PART ne $VU35P} {                    ;# another package: the VU35P's pins do not exist there
  set xdcs [lsearch -all -inline -not $xdcs *pins.xdc]
  # but the clocks (and the PERST false path) stay: the top's and the IPs' timing constraints name
  # them
  set fi [open $cons/admpcie9h3_pins.xdc]
  set fo [open $out/admpcie9h3_clocks.xdc w]
  foreach l [split [read $fi] "\n"] {
    if {[regexp {^(create_clock|set_false_path) } $l]} { puts $fo $l }
  }
  close $fi
  close $fo
  lappend xdcs $out/admpcie9h3_clocks.xdc
  puts "part $PART: the VU35P's pin constraints left out (its clocks kept: $out/admpcie9h3_clocks.xdc)"
}
add_files -fileset constrs_1 -norecurse $xdcs
# TMEM_URAM=1 (environment, run_vivado.sh): the TMEM copies in UltraRAM (a synthesis property:
# vivado/tmem_uram.xdc)
if {[info exists ::env(TMEM_URAM)] && $::env(TMEM_URAM) eq "1"} {
  add_files -fileset constrs_1 -norecurse $here/tmem_uram.xdc
  set_property USED_IN_IMPLEMENTATION false [get_files $here/tmem_uram.xdc]
  puts "TMEM in UltraRAM (tmem_uram.xdc)"
}
# then, after the IP's constraints, as unmanaged Tcl on the synthesized netlist: each otpu_mem_ch's
# crossings (the YPCB's file, scoped to the module), the top's crossings
set memch $root/boards/ypcb-00338/constraints/otpu_mem_ch.tcl
set late [list $memch $cons/admpcie9h3_top.tcl]
add_files -fileset constrs_1 -norecurse $late
set_property SCOPED_TO_REF otpu_mem_ch [get_files $memch]
set_property PROCESSING_ORDER LATE [get_files $late]
set_property USED_IN_SYNTHESIS false [get_files $late]
foreach f $late {
  if {![string match -nocase *tcl* [get_property FILE_TYPE [get_files $f]]]} {
    error "$f: FILE_TYPE [get_property FILE_TYPE [get_files $f]], expected TCL (unmanaged)"
  }
}

if {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"} {
  set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
  set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
} else {
  set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
  set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
  set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
}
set_property report_strategy {No Reports} [get_runs synth_1]
set_property report_strategy {No Reports} [get_runs impl_1]
puts "project created in $out (ADM-PCIE-9H3, S=$S, Gen3 x$PCIE_LANES, HBM-$DDR_MTS)"
