# Pins and configuration of the Alpha Data ADM-PCIE-9H3 (xcvu35p-fsvh2104-2-e): the board kit's
# fpga/src/{refclk300,pcie,user_led,bitstream}.xdc (host_hbm-admpcie9h3-v1_0_0, M0.3). No memory
# pins: the 8 GB of HBM are in the package, reached through the Xilinx HBM IP (PG276).
#
# Clocks, PCIe and the active-low USER_LEDs.

# 300 MHz fabric clock (LVDS): the top's IBUFDS feeds one MMCM (x4 / 12 = 100 MHz, an even divide:
# 50% duty) whose two outputs are core_clk and hbm_ref_clk (the IP's scoped XDC owns
# HBM_REF_CLK_0/1). 50% duty matters: the HBM IP's APB macro (BLI_HBM_APB_INTF) wants a 5 ns pulse
# at 100 MHz, which the board's own / 3 (refclk_bufg_div3.vhd) misses. The period is the board
# kit's 3.333 rounded up to 3.334: Vivado rounds the input to ps, so 3.333..3.3334 propagate the
# MMCM's 100 MHz output as 9.999 and 3.334 as 10.002 (0.02% conservative; the macro's minimum
# period is 10.000).
set_property PACKAGE_PIN AY31 [get_ports refclk300_p]
set_property IOSTANDARD LVDS [get_ports refclk300_p]
set_property DIFF_TERM_ADV TERM_100 [get_ports refclk300_p]
set_property PACKAGE_PIN BA31 [get_ports refclk300_n]
set_property IOSTANDARD LVDS [get_ports refclk300_n]
set_property DIFF_TERM_ADV TERM_100 [get_ports refclk300_n]
create_clock -period 3.334 -name refclk300 [get_ports refclk300_p]

# PCIe: the reference clock (GTY quad 227, 100 MHz) and PERST#. The Gen3 x16 lanes are placed by
# the XDMA IP (select_quad GTY_Quad_227 on the VU35P, bd.tcl), so pcie_mgt has no pins here.
set_property LOC AF9 [get_ports sys_clk_p]
set_property LOC AF8 [get_ports sys_clk_n]
create_clock -name sys_clk -period 10 [get_ports sys_clk_p]
set_property LOC AW27 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports sys_rst_n]
set_false_path -from [get_ports sys_rst_n]

# USER_LEDs (active low, LVCMOS18): G0 PCIe link up and HBM ready, G1 the accelerator runs or
# halted cleanly, A0 the heartbeat (otpu_fpga_top_admpcie9h3)
set_property PACKAGE_PIN AY30 [get_ports user_led_g0_l]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_g0_l]
set_property PACKAGE_PIN AV31 [get_ports user_led_g1_l]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_g1_l]
set_property PACKAGE_PIN AV32 [get_ports user_led_a0_l]
set_property IOSTANDARD LVCMOS18 [get_ports user_led_a0_l]

# configuration: Master SPI x8 from the Micron MT25QU512 (512 Mb / 64 MiB, 1.8 V), as the board's
# bitstream.xdc (XAPP1233); the over-temperature shutdown, as the board's own design (a card
# without airflow overheats)
set_property CONFIG_MODE SPIx8 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 8 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN DIV-1 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN Enable [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CFGBVS GND [current_design]
