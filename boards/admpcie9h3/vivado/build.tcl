# Build the ADM-PCIE-9H3 bitstream from create_project.tcl's project: synthesis, implementation,
# reports, the bitstream and the SPI flash image (the Micron MT25QU512, 512 Mb / 64 MiB, x8:
# docs/plans/vu35p-hbm/01-m0-facts.md 0.3).
#   vivado -mode batch -source build.tcl -tclargs [OUT_DIR] [JOBS] [impl|full] [IMPL_STRATEGY]
# The BCU1525's build.tcl is the model; the block-RAM collision check is the same.
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set out [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$root/build/vivado"}]
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]
set impl_only [expr {[lindex $argv 2] eq "impl"}]
set strategy [lindex $argv 3]

open_project $out/otpu.xpr
# threads for this process and the runs it launches: launch_runs writes the launching process's
# general.maxThreads into each run's script (see create_project.tcl; synthesis is separately capped
# at 8 by synth.maxThreads, implementation uses this)
if {[info exists ::env(OTPU_MAX_THREADS)] && $::env(OTPU_MAX_THREADS) ne ""} {
  set_param general.maxThreads $::env(OTPU_MAX_THREADS)
} elseif {![catch {exec nproc} nc] && [string is integer -strict $nc]} {
  set_param general.maxThreads [expr {$nc > 24 ? 24 : $nc}]
}
file mkdir $out/reports
set fast [expr {[info exists ::env(OTPU_FAST)] && $::env(OTPU_FAST) eq "1"}]

if {!$impl_only} {
  generate_target all [get_files otpu_bd.bd]
  export_ip_user_files -of_objects [get_files otpu_bd.bd] -no_script -sync -force -quiet
  create_ip_run [get_files otpu_bd.bd]
  reset_run synth_1
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synthesis failed" }
  set fh [open $out/otpu.runs/synth_1/runme.log]; set slog [read $fh]; close $fh
  set coll [regexp -all -inline {Synth 8-6430\] The Block RAM "[^"]*"} $slog]
  if {[llength $coll]} {
    error "synthesis made asynchronous-read memories block RAMs with a read-address register: [join $coll {; }]"
  }
  open_run synth_1
  report_utilization -hierarchical -hierarchical_depth 4 -file $out/reports/synth_util_hier.rpt
  report_utilization -slr -file $out/reports/synth_util_slr.rpt
  report_timing_summary -max_paths 20 -file $out/reports/synth_timing.rpt
  close_design
} else {
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "impl: no finished synthesis to reuse" }
  set_property NEEDS_REFRESH false [get_runs synth_1]
}

if {$strategy ne ""} { set_property strategy $strategy [get_runs impl_1] }
if {!$fast} { set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1] }
# The implementation run's flow always ends in its write_bitstream step (a required step, so it has
# no IS_ENABLED property): the .bit is left in otpu.runs/impl_1 as soon as routing/bitgen finish, so
# a kill of this batch process after wait_on_run does not lose it. Below we copy that .bit to
# $out/otpu.bit instead of running bitgen a second time.
reset_run impl_1
launch_runs impl_1 -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "implementation failed" }
open_run impl_1

report_timing_summary -max_paths 50 -report_unconstrained -warn_on_violation \
  -file $out/reports/timing_summary.rpt
report_timing -max_paths 30 -sort_by group -nworst 1 -file $out/reports/timing_worst.rpt
report_design_analysis -congestion -file $out/reports/congestion.rpt
report_clock_interaction -file $out/reports/clock_interaction.rpt
report_cdc -details -file $out/reports/cdc.rpt
report_utilization -file $out/reports/util.rpt
report_utilization -slr -file $out/reports/util_slr.rpt
report_utilization -hierarchical -hierarchical_depth 5 -file $out/reports/util_hier.rpt
report_drc -file $out/reports/drc.rpt
report_methodology -file $out/reports/methodology.rpt
report_power -hierarchical_depth 12 -file $out/reports/power.rpt
report_io -file $out/reports/io.rpt

set fh [open $out/reports/SUMMARY.txt w]
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -max_paths 1 -nworst 1 -hold] 0]]
puts $fh "WNS $wns ns   WHS $whs ns"
foreach clk [get_clocks] {
  set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup -to $clk] 0]
  if {$p ne ""} {
    set period [get_property PERIOD $clk]
    set slack [get_property SLACK $p]
    set fmax [expr {$slack eq "" ? "n/a" : [format %.1f [expr {1000.0 / ($period - $slack)}]]}]
    puts $fh [format "%-40s period %7.3f ns  slack %8s ns  fmax %s MHz" $clk $period $slack $fmax]
  }
}
close $fh
puts [exec cat $out/reports/SUMMARY.txt]

# the bitstream the impl run's own write_bitstream step wrote: copy it to $out/otpu.bit, so the
# bitstream survives a kill of this process between wait_on_run and here (a second write_bitstream
# only if the run left none)
set runbits [glob -nocomplain $out/otpu.runs/impl_1/*.bit]
if {[llength $runbits]} {
  file copy -force [lindex $runbits 0] $out/otpu.bit
  puts "bitstream: copied [lindex $runbits 0] -> $out/otpu.bit"
} else {
  write_bitstream -force $out/otpu.bit
}
if {[llength [get_debug_cores -quiet]]} { write_debug_probes -force $out/otpu.ltx }
# the configuration flash: Micron MT25QU512, 512 Mb (64 MB), SPI x8 (M0.3; XAPP1233)
write_cfgmem -force -format mcs -size 64 -interface SPIx8 -loadbit "up 0x0 $out/otpu.bit" $out/otpu.mcs
puts "bitstream: $out/otpu.bit"
if {$wns < 0} { puts "WARNING: timing not met (WNS $wns ns) -- see reports/timing_summary.rpt" }
