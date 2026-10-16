// Lint-only stand-in for the Vivado-generated Xilinx HBM IP (`hbm_ip`, PG276, the `hbm` v1.0
// catalog: 8 GB at 2 stacks with ECC, 256-bit AXI3 slave ports, 100 MHz AXI / reference clock):
// the ports of the generated IP this design uses, no behaviour. `make lint` (M3) checks
// otpu_fpga_top_admpcie9h3 offline against it; Vivado builds with the generated IP (M3 creates
// and configures it in vivado/create_project.tcl, module `hbm_ip` -- the same module name this
// file defines, as boards/bcu1525/sim/otpu_ld4_stub.sv does for the LiteDRAM core).
//
// The port list is the generated wrapper's (2024.2, `hbm` v1.0, 8 SAXI ports, USER_MON_APB_EN 0,
// USER_XSDB_INTF_EN 0: the IP's chipscope debug hub off, so no top-level dbg_hub and no scan-chain
// ports): HBM_REF_CLK_0/1, AXI_00..07 (each AXI3: 33-bit address, 6-bit ID, 4-bit AWLEN/ARLEN =
// 16-beat bursts, no AWLOCK/AWCACHE/AWPROT/AWQOS, plus the 32-bit WDATA_PARITY
// input and RDATA_PARITY output), the two APB register ports (APB_0/APB_1, 22-bit PADDR), the
// apb_complete_0/1 "HBM ready" outputs and the DRAM_0/1_STAT_CATTRIP/TEMP outputs.
module hbm_ip (
  input  logic        HBM_REF_CLK_0,
  input  logic        HBM_REF_CLK_1,
`define AXI(N) \
  input  logic         AXI_``N``_ACLK, \
  input  logic         AXI_``N``_ARESET_N, \
  input  logic [32:0]  AXI_``N``_ARADDR, \
  input  logic [1:0]   AXI_``N``_ARBURST, \
  input  logic [5:0]   AXI_``N``_ARID, \
  input  logic [3:0]   AXI_``N``_ARLEN, \
  input  logic [2:0]   AXI_``N``_ARSIZE, \
  input  logic         AXI_``N``_ARVALID, \
  input  logic [32:0]  AXI_``N``_AWADDR, \
  input  logic [1:0]   AXI_``N``_AWBURST, \
  input  logic [5:0]   AXI_``N``_AWID, \
  input  logic [3:0]   AXI_``N``_AWLEN, \
  input  logic [2:0]   AXI_``N``_AWSIZE, \
  input  logic         AXI_``N``_AWVALID, \
  input  logic         AXI_``N``_RREADY, \
  input  logic         AXI_``N``_BREADY, \
  input  logic [255:0] AXI_``N``_WDATA, \
  input  logic         AXI_``N``_WLAST, \
  input  logic [31:0]  AXI_``N``_WSTRB, \
  input  logic [31:0]  AXI_``N``_WDATA_PARITY, \
  input  logic         AXI_``N``_WVALID, \
  output logic         AXI_``N``_ARREADY, \
  output logic         AXI_``N``_AWREADY, \
  output logic [31:0]  AXI_``N``_RDATA_PARITY, \
  output logic [255:0] AXI_``N``_RDATA, \
  output logic [5:0]   AXI_``N``_RID, \
  output logic         AXI_``N``_RLAST, \
  output logic [1:0]   AXI_``N``_RRESP, \
  output logic         AXI_``N``_RVALID, \
  output logic         AXI_``N``_WREADY, \
  output logic [5:0]   AXI_``N``_BID, \
  output logic [1:0]   AXI_``N``_BRESP, \
  output logic         AXI_``N``_BVALID
  `AXI(00),
  `AXI(01),
  `AXI(02),
  `AXI(03),
  `AXI(04),
  `AXI(05),
  `AXI(06),
  `AXI(07),
`undef AXI
`define APB(N) \
  input  logic [31:0]  APB_``N``_PWDATA, \
  input  logic [21:0]  APB_``N``_PADDR, \
  input  logic         APB_``N``_PCLK, \
  input  logic         APB_``N``_PENABLE, \
  input  logic         APB_``N``_PRESET_N, \
  input  logic         APB_``N``_PSEL, \
  input  logic         APB_``N``_PWRITE, \
  output logic [31:0]  APB_``N``_PRDATA, \
  output logic         APB_``N``_PREADY, \
  output logic         APB_``N``_PSLVERR
  `APB(0),
  `APB(1),
`undef APB
  output logic        apb_complete_0,
  output logic        apb_complete_1,
  output logic        DRAM_0_STAT_CATTRIP,
  output logic [6:0]  DRAM_0_STAT_TEMP,
  output logic        DRAM_1_STAT_CATTRIP,
  output logic [6:0]  DRAM_1_STAT_TEMP
);
  assign apb_complete_0 = 1'b1;          // (the model: ready at once)
  assign apb_complete_1 = 1'b1;
  assign DRAM_0_STAT_CATTRIP = 1'b0;
  assign DRAM_0_STAT_TEMP    = 7'h0;
  assign DRAM_1_STAT_CATTRIP = 1'b0;
  assign DRAM_1_STAT_TEMP    = 7'h0;
  assign APB_0_PRDATA  = 32'h0;
  assign APB_0_PREADY  = 1'b1;
  assign APB_0_PSLVERR = 1'b0;
  assign APB_1_PRDATA  = 32'h0;
  assign APB_1_PREADY  = 1'b1;
  assign APB_1_PSLVERR = 1'b0;
`define AXI_OUT(N) \
  assign AXI_``N``_AWREADY      = 1'b1; \
  assign AXI_``N``_WREADY       = 1'b1; \
  assign AXI_``N``_BID          = 6'h0; \
  assign AXI_``N``_BRESP        = 2'b0; \
  assign AXI_``N``_BVALID       = 1'b0; \
  assign AXI_``N``_ARREADY      = 1'b1; \
  assign AXI_``N``_RID          = 6'h0; \
  assign AXI_``N``_RDATA        = 256'h0; \
  assign AXI_``N``_RDATA_PARITY = 32'h0; \
  assign AXI_``N``_RRESP        = 2'b0; \
  assign AXI_``N``_RLAST        = 1'b0; \
  assign AXI_``N``_RVALID       = 1'b0;
  `AXI_OUT(00)
  `AXI_OUT(01)
  `AXI_OUT(02)
  `AXI_OUT(03)
  `AXI_OUT(04)
  `AXI_OUT(05)
  `AXI_OUT(06)
  `AXI_OUT(07)
`undef AXI_OUT
endmodule
