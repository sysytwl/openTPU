# Check the ADM-PCIE-9H3's block design and HBM IP in Vivado. The block design is checked on any
# UltraScale+ part (PART), so it can be validated before a VU35P build (this host has no free
# Kintex UltraScale+ device files: a non-HBM Virtex UltraScale+ part with PCIE4C blocks and GTY
# quads, e.g. xcvu5p-flvb2104-2-e, stands in). The HBM IP exists only on the HBM parts, so its
# step always runs on the real xcvu35p-fsvh2104-2-e (needs the VU35P license):
#   vivado -mode batch -source ip_check.tcl -tclargs PART OUT_DIR [STEPS]
# STEPS (comma separated, default bd): bd = source bd.tcl (validate_bd_design and its checks) and
# generate the block design's IP output products; bdsynth = also synthesize the block design's IP
# out of context; hbm = create and configure the HBM IP (vivado/hbm_ip.tcl) on the real VU35P,
# synthesize it out of context and report its utilization (PG276's order of magnitude: ~1.5K LUTs
# per stack + switch for a minimal config, more with all MCs/ports).
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../../..]
set part [lindex $argv 0]
set out [file normalize [lindex $argv 1]]
set steps [split [expr {[llength $argv] > 2 ? [lindex $argv 2] : "bd"}] ,]
set VU35P xcvu35p-fsvh2104-2-e
file mkdir $out
if {"bd" in $steps || "bdsynth" in $steps} {
  create_project -force ipcheck $out/ipcheck -part $part
  set CORE_MHZ 100
  source $here/bd.tcl
  set bd [get_files otpu_bd.bd]
  generate_target all $bd
  foreach ip [get_ips -all] {
    puts "IP [get_property NAME $ip]: [get_property IPDEF $ip]"
  }
  report_ip_status -file $out/ip_status.txt
  if {"bdsynth" in $steps} {
    create_ip_run $bd
    set runs [get_runs -filter {IS_SYNTHESIS && NAME != synth_1}]
    launch_runs $runs -jobs 4
    foreach r $runs { wait_on_run $r }
    foreach r $runs {
      puts "run $r: [get_property STATUS $r] [get_property PROGRESS $r]"
      if {[get_property PROGRESS $r] ne "100%"} { error "$r failed" }
    }
  }
}
if {"hbm" in $steps} {
  # the HBM IP only exists on the HBM parts: always on the real VU35P, whatever PART was
  create_project -force ipcheck_hbm $out/ipcheck_hbm -part $VU35P
  source $here/hbm_ip.tcl
  set hbm [create_hbm_ip]
  generate_target all $hbm
  # create_ip_run returns the run's name as a string; get_property (and report_utilization) need
  # the run object, so resolve it through get_runs
  set run [get_runs -quiet [create_ip_run $hbm]]
  launch_runs $run -jobs 4
  wait_on_run $run
  puts "run $run: [get_property STATUS $run] [get_property PROGRESS $run]"
  if {[get_property PROGRESS $run] ne "100%"} { error "$run failed" }
  open_run $run
  report_utilization -file $out/hbm_util.txt
  report_utilization -hierarchical -hierarchical_depth 2 -file $out/hbm_util_hier.txt
  set fh [open $out/hbm_util.txt]; set util [read $fh]; close $fh
  foreach l [split $util "\n"] {
    if {[regexp {^\|\s*(CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)\s*\|} $l]} { puts "HBM IP on $VU35P: [string trim $l]" }
  }
  puts "hbm IP synthesized on $VU35P (utilization: $out/hbm_util.txt)"
}
puts "ip_check done: $steps on $part"
