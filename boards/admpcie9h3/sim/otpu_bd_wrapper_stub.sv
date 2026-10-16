// Lint-only stand-in for the Vivado-generated wrapper of the ADM-PCIE-9H3's block design
// (boards/admpcie9h3/vivado/bd.tcl, M3): the ports Vivado will generate, no behaviour. `make lint`
// checks otpu_fpga_top_admpcie9h3 offline against it; Vivado builds with the real
// otpu_bd_wrapper.v. The block design is the BCU1525's minus the four DDR4 cores' CSR masters:
// XDMA Gen3 (PCIe + SYSMONE4) and its DMA, whose masters are sc_dma's, made external as declared
// in bd.tcl: AXI4, 33-bit address, 128-bit data, no IDs and no burst / lock / cache / prot / qos /
// region signals (the top leaves their size signals, full-width beats, unconnected: not listed
// here). Two AXI4-Lite masters replace the DDR4 cores': M_AXI_CTL (BAR0 0x0, otpu_admpcie9h3_sys's
// control registers) and M_AXI_HBM (BAR0 0x800000, the HBM IP's APB registers through the top's
// otpu_axi_apb_bridge). core_clk is the top's fabric clock (its MMCM), so the control
// interconnect's masters run in it, as the BCU1525's block design runs its own in its core_clk.
module otpu_bd_wrapper #(parameter int PCIE_LANES = 16) (
  input  logic        core_clk,
  input  logic        sys_clk_p, sys_clk_n,
  input  logic        sys_rst_n,
  input  logic [PCIE_LANES-1:0] pcie_mgt_rxp, pcie_mgt_rxn,
  output logic [PCIE_LANES-1:0] pcie_mgt_txp, pcie_mgt_txn,
  output logic        pcie_link_up, xdma_aclk, xdma_aresetn,
  output logic [9:0]  device_temp,
`define STUB_L(P) \
  output logic [31:0] P``_awaddr, P``_araddr, P``_wdata, \
  output logic [3:0]  P``_wstrb, \
  output logic        P``_awvalid, P``_wvalid, P``_bready, P``_arvalid, P``_rready, \
  input  logic        P``_awready, P``_wready, P``_bvalid, P``_arready, P``_rvalid, \
  input  logic [1:0]  P``_bresp, P``_rresp, \
  input  logic [31:0] P``_rdata
`define STUB_D(P) \
  output logic [32:0]  P``_awaddr, P``_araddr, \
  output logic [7:0]   P``_awlen, P``_arlen, \
  output logic         P``_awvalid, P``_arvalid, P``_wvalid, P``_wlast, P``_bready, P``_rready, \
  output logic [127:0] P``_wdata, \
  output logic [15:0]  P``_wstrb, \
  input  logic         P``_awready, P``_arready, P``_wready, P``_bvalid, P``_rvalid, P``_rlast, \
  input  logic [1:0]   P``_bresp, P``_rresp, \
  input  logic [127:0] P``_rdata
  `STUB_L(M_AXI_CTL),
  `STUB_L(M_AXI_HBM),
  `STUB_D(M_AXI_DMA0),
  `STUB_D(M_AXI_DMA1),
  `STUB_D(M_AXI_DMA2),
  `STUB_D(M_AXI_DMA3)
);
`undef STUB_L
`undef STUB_D
endmodule
