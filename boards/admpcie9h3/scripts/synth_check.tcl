# Synthesize the ADM-PCIE-9H3 project (vivado/create_project.tcl: the real block design, the HBM IP
# replaced by its lint stand-in, the board top at S = 2) on another UltraScale+ part, before a VU35P
# build: the top against the generated block design wrapper (the lint stand-in's ports,
# boards/admpcie9h3/sim), the DSP48E2 mapping of the systolic MXU's cells (rtl/tech/xilinxus: one
# DSP48E2 per PE and column end) and Vivado's utilization. The HBM IP cannot be synthesized here (it
# exists only on HBM parts), so OTPU_HBM_STUB=1 substitutes sim/hbm_ip_stub.sv; the HBM IP's own
# synthesis is `make ipcheck IPCHECK_STEPS=hbm` on the real part. The part need not fit the design:
# synthesis maps, placement would not. Development strategies (OTPU_FAST), the target's defaults
# (create_project.tcl's), no VU35P pins.
#   vivado -mode batch -source synth_check.tcl -tclargs PART OUT_DIR
set here [file normalize [file dirname [info script]]]
set part [lindex $argv 0]
set out [file normalize [lindex $argv 1]]
set ::env(OTPU_PART) $part
set ::env(OTPU_FAST) 1
set ::env(OTPU_HBM_STUB) 1
set argv [list $out]
source $here/../vivado/create_project.tcl
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synth_1: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
report_utilization -file $out/synth_util.txt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/synth_util_hier.txt
set slices [get_cells -quiet {u_sys/u_board/u_slice u_sys/u_board/g_slice[*].u_slice}]
foreach c $slices {
  puts "SYNTH-CHECK $c: [llength [get_cells -hier -quiet -filter "REF_NAME == DSP48E2 && NAME =~ $c/*"]] DSP48E2"
}
puts "SYNTH-CHECK DSP48E2 [llength [get_cells -hier -quiet -filter {REF_NAME == DSP48E2}]], URAM288\
      [llength [get_cells -hier -quiet -filter {REF_NAME == URAM288}]], RAMB36E2\
      [llength [get_cells -hier -quiet -filter {REF_NAME == RAMB36E2}]], RAMB18E2\
      [llength [get_cells -hier -quiet -filter {REF_NAME == RAMB18E2}]]"
puts "SYNTH-CHECK done on $part"
