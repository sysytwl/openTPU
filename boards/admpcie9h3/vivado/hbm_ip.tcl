# The Xilinx HBM IP (PG276, the `hbm` v1.0 catalog) for the ADM-PCIE-9H3's 8 GB (2 x 4 GB stacks,
# 32 pseudo-channels of 256 MB), configured as M0.2 decided (docs/plans/vu35p-hbm/01-m0-facts.md):
#   - 2 stacks, 4 GB each (USER_HBM_DENSITY 8GB -> 8192 MB of user memory), ECC on (the IP's
#     SECDED uses the stack's dedicated check bits: no capacity cost);
#   - global addressing (the default), the switch on (USER_SWITCH_ENABLE_01), all 16 memory
#     controllers and PHYs of each stack enabled (USER_AUTO_POPULATE then USER_MC_ENABLE_* /
#     USER_PHY_ENABLE_*);
#   - 8 of the 32 AXI3 slave ports (USER_SAXI_00..07 true, 08..31 false): two per channel, one per
#     native port of each otpu_mem_ch (M2);
#   - both APB register ports on (USER_MC_ENABLE_APB_00/01), 100 MHz (USER_APB_PCLK_0/1);
#   - the XSDB debug interface off (USER_XSDB_INTF_EN FALSE). The IP's RTL otherwise hard-codes
#     `EN_DBG_HUB` and instantiates its chipscope XSDB hub, which makes Vivado auto-create a
#     top-level dbg_hub whose clk we do not drive (opt_design then fails, Chipscope 16-213). M3
#     does not use XSDB (the host reaches the HBM registers over the APB ports); apb_complete_0/1
#     still come from the IP's own APB arbiter, not the hub.
#   - HBM_REF_CLK_0/1 100 MHz (the only rate the 2024.2 catalog enumerates; the board's refclk300
#     divided by three), the HBM data rate 1000 Mb/s (USER_HBM_TCK_0/1 500), and the AXI input
#     clock 100 MHz (USER_AXI_INPUT_CLK_FREQ default: the generated hbm_ip.xdc constrains
#     HBM_REF_CLK_0/1 to 10 ns and the AXI input to 10 ns). core_clk is 100 MHz for this reason
#     (run_vivado.sh).
# A proc, so create_project.tcl (the real build) and ip_check.tcl (the `hbm` step on the licensed
# VU35P) configure it identically. The caller generates the target and creates the IP run.
proc create_hbm_ip {} {
  create_ip -name hbm -vendor xilinx.com -library ip -version 1.0 -module_name hbm_ip
  set ip [get_ips hbm_ip]
  set cfg [list \
    CONFIG.USER_HBM_STACK {2} \
    CONFIG.USER_HBM_DENSITY {8GB} \
    CONFIG.USER_MEMORY_DISPLAY {8192} \
    CONFIG.USER_HBM_REF_CLK_0 {100} \
    CONFIG.USER_HBM_REF_CLK_1 {100} \
    CONFIG.USER_APB_PCLK_0 {100} \
    CONFIG.USER_APB_PCLK_1 {100} \
    CONFIG.USER_HBM_TCK_0 {500} \
    CONFIG.USER_HBM_TCK_1 {500} \
    CONFIG.USER_SWITCH_ENABLE_01 {TRUE} \
    CONFIG.USER_MC_ENABLE_APB_00 {TRUE} \
    CONFIG.USER_MC_ENABLE_APB_01 {TRUE} \
    CONFIG.USER_AUTO_POPULATE {yes} \
    CONFIG.USER_XSDB_INTF_EN {FALSE} \
  ]
  for {set i 0} {$i < 32} {incr i} {
    set n [format %02d $i]
    lappend cfg CONFIG.USER_SAXI_$n [expr {$i < 8 ? "true" : "false"}]
  }
  for {set i 0} {$i < 16} {incr i} {
    set n [format %02d $i]
    lappend cfg CONFIG.USER_MC_ENABLE_$n {TRUE}
    lappend cfg CONFIG.USER_PHY_ENABLE_$n {TRUE}
  }
  set_property -dict $cfg $ip
  puts "HBM IP hbm_ip: 8 GB (2 stacks, ECC on), 8 AXI3 ports, 2 APB ports, 1000 Mb/s"
  return $ip
}
