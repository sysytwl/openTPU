// Simulation model of the board memory behind the two channels' native ports n_* on an HBM board
// (tb_board MEM_NATIVE=3): per channel the board's bridge, otpu_mem_ch (RMW 0: the HBM IP does the
// read-modify-write; RBUS 0: one read bus a native port), its two controller ports each through an
// otpu_native_axi3 onto the channel's AXI3 slave model (otpu_hbm_model), as the board wires them.
// otpu_native_mem's parameters and ports, so the board model (tb_board) takes any of the three.
//
// Clocks: the core clock is the caller's (tb_board: a period of 10 time units). The HBM AXI clock
// is 100 MHz (USER_AXI_CLK_FREQ 100: docs/plans/vu35p-hbm/01-m0-facts.md 0.2), the same rate as the
// core but its own phase (the board's HBM IP AXI clock is refclk300 / its divider, not the core's:
// M0.4). XDMA's clock (125 MHz) has half periods of 4; XDMA's side of each bridge is idle. Its
// reset and the bridges' follow the caller's rst through two flip-flops of their clocks.
// The models' arguments: +hbm_lat=N (read / write-response latency), +hbm_stall=P (ready withheld,
// percent), +hbm_dram=1 (per-port bank timing), +hbm_ecc=1 and +hbm_ecc_ce=0..100 /
// +hbm_ecc_ue=0..100 (the ECC counters' semantics), +hbm_seed=N.
// PHYS = 1 only: the files are the channels' own memories, as otpu_native_mem's with PHYS = 1
// (ch<c>.bin in, big-endian words; ch<c>_out.bin out on dump, little-endian), WORDS / 2 words each.
module otpu_hbmch #(
  parameter int WORDS = 1 << 18,
  parameter int PHYS  = 0,
  parameter int LAT   = 32,              // minimum read / write-response latency (AXI cycles)
  parameter int SID   = 0,               // the slice: its channels' files are ch<2 SID + c>
  parameter bit CHASH = 1'b1             // (otpu_native_mem's; unused: the images are physical)
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic [1:0]            n_cvalid,
  output logic [1:0]            n_cready,
  input  logic [1:0]            n_cwe,
  input  logic [1:0][24:0]      n_caddr,
  input  logic [1:0]            n_wvalid,
  output logic [1:0]            n_wready,
  input  logic [1:0][511:0]     n_wdata,
  input  logic [1:0][63:0]      n_wmask,
  output logic [1:0]            n_rvalid,
  output logic [1:0][511:0]     n_rdata,
  output logic [1:0][15:0]      n_wdone,
  output logic [1:0]            n_err,
  input  logic                  dump
);
  localparam int BEATS = WORDS / 32;     // per channel: WORDS / 2 words, 16 a beat
  initial if (PHYS != 1) $fatal(1, "otpu_hbmch: PHYS = 1 only (the channels' own images)");

  // the HBM AXI clock: 100 MHz, its own phase against the core's
  logic aclk = 1'b0, xclk = 1'b0;
  always begin #4 aclk = 1'b1; #6 aclk = 1'b0; end
  always #4 xclk = ~xclk;
  logic xrst = 1'b1, xr1 = 1'b1;
  always @(posedge xclk) {xrst, xr1} <= {xr1, rst};

  initial begin
    int seed;
    if ($value$plusargs("hbm_seed=%d", seed)) void'($urandom(seed));
  end

  for (genvar c = 0; c < 2; c++) begin : g_ch
    logic         arst = 1'b1, ar1 = 1'b1;
    logic [1:0]   cv, cr, cwe, wv, wr, rv;          // the channel's two ports
    logic [1:0][24:0]  ca;
    logic [1:0][511:0] wd, rd;
    logic [1:0][63:0]  we;
    always @(posedge aclk) {arst, ar1} <= {ar1, rst};
    otpu_mem_ch #(.XIDW(4), .RMW(1'b0), .RBUS(1'b0)) u_ch (
      .clk, .rst,
      .n_cvalid(n_cvalid[c]), .n_cready(n_cready[c]), .n_cwe(n_cwe[c]), .n_caddr(n_caddr[c]),
      .n_wvalid(n_wvalid[c]), .n_wready(n_wready[c]), .n_wdata(n_wdata[c]), .n_wmask(n_wmask[c]),
      .n_rvalid(n_rvalid[c]), .n_rdata(n_rdata[c]), .n_wdone(n_wdone[c]), .n_err(n_err[c]),
      .xclk, .xrst,
      .x_awvalid(1'b0), .x_awready(), .x_awid(4'h0), .x_awaddr(32'h0), .x_awlen(8'h0),
      .x_wvalid(1'b0), .x_wready(), .x_wdata(128'h0), .x_wstrb(16'h0), .x_wlast(1'b0),
      .x_bvalid(), .x_bready(1'b1), .x_bid(), .x_bresp(),
      .x_arvalid(1'b0), .x_arready(), .x_arid(4'h0), .x_araddr(32'h0), .x_arlen(8'h0),
      .x_rvalid(), .x_rready(1'b1), .x_rid(), .x_rdata(), .x_rresp(), .x_rlast(),
      .uclk(aclk), .urst(arst),
      .c_cmd_valid(cv), .c_cmd_ready(cr), .c_cmd_we(cwe), .c_cmd_addr(ca),
      .c_wdata_valid(wv), .c_wdata_ready(wr), .c_wdata_data(wd), .c_wdata_we(we),
      .c_rdata_valid(rv), .c_rdata_data(rd));
    // the channel's two controller ports, each onto one AXI3 master of the HBM model; the base is
    // the channel's 2 GiB (board channel j at j * 2 GiB: the host DMA map)
    logic [1:0]      m_arvalid, m_arready, m_awvalid, m_awready;
    logic [1:0]      m_wvalid, m_wready, m_bvalid, m_bready, m_rvalid, m_rready;
    logic [1:0][32:0] m_araddr, m_awaddr;
    logic [1:0][7:0]  m_arlen, m_awlen;
    logic [1:0][2:0]  m_arsize, m_awsize;
    logic [1:0][1:0]  m_arburst, m_awburst, m_bresp, m_rresp;
    logic [1:0][5:0]  m_arid, m_awid, m_bid, m_rid;
    logic [1:0]       m_wlast, m_rlast;
    logic [1:0][255:0] m_wdata, m_rdata;
    logic [1:0][31:0] m_wstrb;
    for (genvar p = 0; p < 2; p++) begin : g_port
      otpu_native_axi3 #(.AW(33), .HBM_BASE(33'(2 * SID + c) << 31)) u_axi (
        .clk(aclk), .rst(arst),
        .n_cmd_valid(cv[p]), .n_cmd_ready(cr[p]), .n_cmd_we(cwe[p]), .n_cmd_addr(ca[p]),
        .n_wvalid(wv[p]), .n_wready(wr[p]), .n_wdata(wd[p]), .n_wmask(we[p]),
        .n_rvalid(rv[p]), .n_rdata(rd[p]),
        .m_arvalid(m_arvalid[p]), .m_arready(m_arready[p]), .m_araddr(m_araddr[p]),
        .m_arid(m_arid[p]), .m_arlen(m_arlen[p]), .m_arsize(m_arsize[p]), .m_arburst(m_arburst[p]),
        .m_awvalid(m_awvalid[p]), .m_awready(m_awready[p]), .m_awaddr(m_awaddr[p]),
        .m_awid(m_awid[p]), .m_awlen(m_awlen[p]), .m_awsize(m_awsize[p]), .m_awburst(m_awburst[p]),
        .m_wvalid(m_wvalid[p]), .m_wready(m_wready[p]), .m_wdata(m_wdata[p]),
        .m_wstrb(m_wstrb[p]), .m_wlast(m_wlast[p]),
        .m_bvalid(m_bvalid[p]), .m_bready(m_bready[p]), .m_bid(m_bid[p]), .m_bresp(m_bresp[p]),
        .m_rvalid(m_rvalid[p]), .m_rready(m_rready[p]), .m_rid(m_rid[p]), .m_rdata(m_rdata[p]),
        .m_rresp(m_rresp[p]), .m_rlast(m_rlast[p]));
    end
    otpu_hbm_model #(.BEATS(BEATS), .LAT(LAT), .CH(2 * SID + c), .NP(2), .AW(33)) u_mem (
      .clk(aclk), .rst(arst),
      .s_awvalid(m_awvalid), .s_awready(m_awready), .s_awaddr(m_awaddr), .s_awid(m_awid),
      .s_awlen(m_awlen),
      .s_wvalid(m_wvalid), .s_wready(m_wready), .s_wdata(m_wdata), .s_wstrb(m_wstrb),
      .s_wlast(m_wlast),
      .s_bvalid(m_bvalid), .s_bready(m_bready), .s_bid(m_bid),
      .s_arvalid(m_arvalid), .s_arready(m_arready), .s_araddr(m_araddr), .s_arid(m_arid),
      .s_arlen(m_arlen),
      .s_rvalid(m_rvalid), .s_rready(m_rready), .s_rid(m_rid), .s_rdata(m_rdata),
      .s_rlast(m_rlast), .dump);
  end
endmodule
