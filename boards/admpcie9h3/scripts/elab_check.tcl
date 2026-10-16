# Vivado RTL elaboration of the ADM-PCIE-9H3 top on any installed part (no UltraScale+ part or
# license needed: synth_design -rtl does not map), with the lint stand-ins for the block design
# wrapper, the HBM IP and DSP48E2 (boards/admpcie9h3/sim), then a check that every cell the crossing
# constraints (constraints/admpcie9h3_top.tcl) name exists in Vivado's hierarchy, with Vivado's
# names for the generate blocks. The board's pin XDC is not read here (another part's package).
#   vivado -mode batch -source elab_check.tcl -tclargs PART
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set part [expr {[llength $argv] ? [lindex $argv 0] : "xcvu35p-fsvh2104-2-e"}]
set files [split [string trim [exec env PYTHONPATH=$root python3 -m opentpu.target files admpcie9h3]] "\n"]
foreach f $files { read_verilog -sv $root/$f }
foreach f {otpu_bd_wrapper_stub.sv hbm_ip_stub.sv unisim_dsp48e2_stub.sv} {
  read_verilog -sv $root/boards/admpcie9h3/sim/$f
}
synth_design -rtl -top otpu_fpga_top_admpcie9h3 -part $part -verilog_define SYNTHESIS
set bad 0
foreach c {u_bd u_hbm u_apb u_sys u_sys/u_board/u_slice u_sys/u_board/u_mem u_sys/u_board/u_ctrl
           u_sys/u_board/g_coll.u_coll u_sys/u_board/g_trace.u_trace u_sys/u_board/u_iso
           u_sys/u_board/g_xs.u_chub {u_sys/u_board/g_xs.g_x[0].g_pf.u_pf_tx}
           {u_sys/u_board/g_xs.g_x[0].g_pf.u_pf_rx} {u_sys/u_board/g_slice[1].u_slice}
           {u_sys/u_board/g_slice[1].u_mem} {u_sys/g_ch[0].u_ch} {u_sys/g_ch[1].u_ch}
           {u_sys/g_ch[2].u_ch} {u_sys/g_ch[3].u_ch}} {
  if {[llength [get_cells -quiet $c]] != 1} { puts "ELAB-CHECK missing cell $c"; incr bad }
}
# the board's own crossing stages and collective ports (otpu_board g_xs), per slice
foreach s {0 1} {
  foreach u {u_dn_tx u_dn_rx u_up_tx u_up_rx u_cport} {
    set c "u_sys/u_board/g_xs.g_x\[$s\].$u"
    if {[llength [get_cells -quiet $c]] != 1} { puts "ELAB-CHECK missing cell $c"; incr bad }
  }
  foreach u {u_dn_tx u_dn_rx u_up_tx u_up_rx} {
    if {[llength [get_cells -quiet "u_sys/u_board/g_xs.g_x\[$s\].$u/r_reg*"]] == 0} {
      puts "ELAB-CHECK missing register g_x\[$s\].$u/r_reg"; incr bad
    }
  }
}
# the two native AXI3 bridges of every channel
foreach j {0 1 2 3} {
  foreach p {0 1} {
    set c "u_sys/g_ch\[$j\].g_port\[$p\].u_axi"
    if {[llength [get_cells -quiet $c]] != 1} { puts "ELAB-CHECK missing cell $c"; incr bad }
  }
}
foreach r {lrs1_reg {u_sys/u_board/cal_s1_reg} {u_sys/u_board/ded_s1_reg}} {
  if {[llength [get_cells -quiet $r*]] == 0} { puts "ELAB-CHECK missing register $r"; incr bad }
}
foreach p {{u_sys/g_ch[0].u_ch/clk} {u_sys/g_ch[0].u_ch/xclk} {u_sys/g_ch[3].u_ch/uclk}} {
  if {[llength [get_pins -quiet $p]] != 1} { puts "ELAB-CHECK missing pin $p"; incr bad }
}
# the TMEM banks tmem_uram.xdc marks (8 banks x the copies, per slice)
set nb [llength [get_cells -quiet -hierarchical -filter {NAME =~ *u_tmem/g_port*.g_bank*.mem_reg*}]]
puts "ELAB-CHECK TMEM bank memories: $nb"
if {$nb == 0} { incr bad }
puts "ELAB-CHECK done: $bad missing"
