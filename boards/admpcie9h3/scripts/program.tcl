# Program the ADM-PCIE-9H3 over JTAG through Vivado's hardware manager (openFPGALoader has no board
# definition for the ADM-PCIE-9H3; the YPCB's program.sh falls back to this too):
#   vivado -mode batch -source program.tcl -tclargs FILE bit
#   vivado -mode batch -source program.tcl -tclargs MCS  flash
# bit: loads the bitstream into the FPGA (volatile). flash: writes the SPI configuration flash
# (Micron MT25QU512, 512 Mb / 64 MiB, mt25qu512-spi-x1_x2_x4_x8) through the FPGA (permanent; loads
# at power-up). The JTAG clock is 10 MHz: the HBM stacks do not enumerate at the default 15 MHz
# (docs/plans/vu35p-hbm/01-m0-facts.md 0.3).
set file [lindex $argv 0]
set mode [expr {[llength $argv] > 1 ? [lindex $argv 1] : "bit"}]
if {![file exists $file]} { error "program.tcl: no such file: $file" }
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
current_hw_target [lindex [get_hw_targets] 0]
set_property PARAM.FREQUENCY 10000000 [current_hw_target]
set dev [lindex [get_hw_devices xcvu35p*] 0]
if {$dev eq ""} { error "program.tcl: no xcvu35p device on the JTAG chain: [get_hw_devices]" }
current_hw_device $dev
if {$mode eq "flash"} {
  # the SPI flash: Micron MT25QU512 (M0.3). The .mcs (build.tcl) is written at the flash's offset 0.
  set part [lindex [get_cfgmem_parts {mt25qu512-spi-x1_x2_x4_x8}] 0]
  if {$part eq ""} { error "program.tcl: no mt25qu512-spi-x1_x2_x4_x8 in this Vivado's cfgmem parts" }
  create_hw_cfgmem -hw_device $dev $part
  set cfg [get_property PROGRAM.HW_CFGMEM $dev]
  set_property PROGRAM.BLANK_CHECK  0 $cfg
  set_property PROGRAM.ERASE        1 $cfg
  set_property PROGRAM.CFG_PROGRAM  1 $cfg
  set_property PROGRAM.VERIFY       1 $cfg
  set_property PROGRAM.CHECKSUM     0 $cfg
  set_property PROGRAM.FILES        [list $file] $cfg
  set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
  set_property PROGRAM.PRM_FILE     {} $cfg
  set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg
  program_hw_cfgmem -hw_cfgmem $cfg
  puts "program.tcl: wrote $file to the MT25QU512"
} else {
  set_property PROGRAM.FILE $file $dev
  program_hw_devices $dev
  puts "program.tcl: programmed $file"
}
close_hw_manager
