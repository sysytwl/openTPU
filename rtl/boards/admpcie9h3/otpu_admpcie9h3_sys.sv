// The accelerator and XDMA's DMA on the ADM-PCIE-9H3's HBM (otpu_fpga_top_admpcie9h3: the Xilinx
// HBM IP, PG276): otpu_board with S = 2 slices (slice s on the card's channels 2s and 2s + 1,
// otpu_native_dram each) and one otpu_mem_ch per channel -- the accelerator's native master n_* and
// XDMA's 128-bit AXI master for that channel (the block design's DMA split by card address bits
// 32:31, channel j at j * 2 GiB, as the DDR boards). No controller ports: each channel's two
// native controller ports c_* go through one otpu_native_axi3 each (RMW 0: the HBM IP does the
// partial beat's read-modify-write; RBUS 0: one read bus a native port) onto the channel's two
// 256-bit AXI3 masters, eight in all, into the HBM IP. The bridges run in the HBM AXI clock
// (hclk), so otpu_mem_ch's own clock-crossing FIFOs move the accelerator's core-clock and XDMA's
// traffic into it, exactly as they move it into a DDR controller's clock on the DDR boards.
//   hclk / hrst: the HBM AXI clock and reset (the top's MMCM; all eight ports share it).
//   calib: the HBM IP's apb_complete_0/1 ("HBM ready": the calib stage, STATUS CALIB0/1). ded:
//        each channel's ECC has counted an uncorrectable word (STATUS ECC_DED; the models' /
//        the IP's ECC counters' -- M4).
// The parameters are the target's (targets/admpcie9h3.toml through opentpu.target rtl_params; the
// defaults are its values, tests/test_target.py).
module otpu_admpcie9h3_sys #(
  parameter int S          = 2,
  parameter int D          = 128,
  parameter int MCOLS      = 4,
  parameter int ACT_ROWS   = MCOLS,
  parameter int ACT_BLOCKS = 128,
  parameter int TMEM_WORDS = 1 << 16,
  parameter int IMEM_WORDS = 1 << 15,
  parameter int FIFO_DEPTH = 1024,
  parameter int LANES      = 8,
  parameter int WIN        = 16,
  parameter int RPB        = 8 * LANES,
  parameter int WPB        = 1,
  parameter int TMEM_IMPL  = 0,           // TMEM: 0 a copy per read port, 3 one copy (otpu_board)
  parameter int TMEM_NSB   = 8,             // TMEM_IMPL 3 (one copy, docs/tmem_nocopy.md; otpu_board)
  parameter int TMEM_SBP   = 3,
  parameter int TMEM_SBH   = 0,
  parameter bit TMEM_RPL   = 1'b0,
  parameter bit TMEM_TDP   = 1'b0,
  parameter bit TMEM_GST   = 1'b0,
  parameter int TMEM_PMP   = 0,
  parameter int TMEM_PRK   = 0,
  parameter int TMEM_SDM   = -1,
  parameter int MXU_IMPL   = 2,
  parameter int MXU_CL     = 16,
  parameter int VPU_CL     = 2,
  parameter int ULANES     = 8,
  parameter int TRACE_DEPTH = 16384,
  parameter int PQ_WIN     = 1024,
  parameter bit CHASH      = 1'b1,
  parameter bit DSTEP      = 1'b1,
  parameter int CORE_KHZ   = 100000,
  parameter logic [31:0] BUILD_ID = 32'h0,
  parameter int DDR_MTS    = 1000,        // the HBM data rate the IP runs at (CFG DDR_MTS; mem_mts)
  parameter bit SEQ_WC     = 1'b0,        // otpu_seq's wait entries (WAITC, CFG_UARCH bit24)
  parameter int PLATFORM   = 3,
  parameter logic [31:0] ARCH_HASH = 32'h0,
  parameter int NC         = 2 * S        // memory channels (two per slice)
) (
  // core clock and reset (synchronous, high), XDMA's clock and reset
  input  logic                    clk,
  input  logic                    clk_f,        // TMEM_PMP 1: 2 x clk, rising with it (otpu_board)
  input  logic                    rst,
  input  logic                    ctl_mrst,     // the control master's reset, in clk (otpu_board)
  input  logic                    xclk,
  input  logic                    xrst,
  // the HBM AXI clock and reset (all eight AXI3 masters)
  input  logic                    hclk,
  input  logic                    hrst,
  // board status and pins (otpu_board)
  input  logic [NC-1:0]           calib,
  input  logic [NC-1:0]           ded,
  input  logic [11:0]             temp,
  output logic [2:0]              led,
  output logic [3:0]              i2c_lo,
  input  logic [4:0]              i2c_pin,
  // control registers: AXI4-Lite slave, clk (BAR0 0x0)
  input  logic [11:0]             s_ctl_awaddr,
  input  logic                    s_ctl_awvalid,
  output logic                    s_ctl_awready,
  input  logic [31:0]             s_ctl_wdata,
  input  logic [3:0]              s_ctl_wstrb,
  input  logic                    s_ctl_wvalid,
  output logic                    s_ctl_wready,
  output logic [1:0]              s_ctl_bresp,
  output logic                    s_ctl_bvalid,
  input  logic                    s_ctl_bready,
  input  logic [11:0]             s_ctl_araddr,
  input  logic                    s_ctl_arvalid,
  output logic                    s_ctl_arready,
  output logic [31:0]             s_ctl_rdata,
  output logic [1:0]              s_ctl_rresp,
  output logic                    s_ctl_rvalid,
  input  logic                    s_ctl_rready,
  // XDMA's DMA, one AXI4 master per channel: 128 bits, xclk, no IDs (answered in order), INCR
  // bursts of full-width beats; the channel's 2 GiB in address bits 30:0
  input  logic [NC-1:0]           x_awvalid,
  output logic [NC-1:0]           x_awready,
  input  logic [NC-1:0][30:0]     x_awaddr,
  input  logic [NC-1:0][7:0]      x_awlen,
  input  logic [NC-1:0]           x_wvalid,
  output logic [NC-1:0]           x_wready,
  input  logic [NC-1:0][127:0]    x_wdata,
  input  logic [NC-1:0][15:0]     x_wstrb,
  input  logic [NC-1:0]           x_wlast,
  output logic [NC-1:0]           x_bvalid,
  input  logic [NC-1:0]           x_bready,
  output logic [NC-1:0][1:0]      x_bresp,
  input  logic [NC-1:0]           x_arvalid,
  output logic [NC-1:0]           x_arready,
  input  logic [NC-1:0][30:0]     x_araddr,
  input  logic [NC-1:0][7:0]      x_arlen,
  output logic [NC-1:0]           x_rvalid,
  input  logic [NC-1:0]           x_rready,
  output logic [NC-1:0][127:0]    x_rdata,
  output logic [NC-1:0][1:0]      x_rresp,
  output logic [NC-1:0]           x_rlast,
  // the eight AXI3 masters, [channel][native port], hclk: the HBM IP's slave ports
  // (256-bit data, 6-bit ID; the channel's base j * 2 GiB is in otpu_native_axi3's HBM_BASE)
  output logic [NC-1:0][1:0]          m_arvalid,
  input  logic [NC-1:0][1:0]          m_arready,
  output logic [NC-1:0][1:0][32:0]    m_araddr,
  output logic [NC-1:0][1:0][5:0]     m_arid,
  output logic [NC-1:0][1:0][7:0]     m_arlen,
  output logic [NC-1:0][1:0][2:0]     m_arsize,
  output logic [NC-1:0][1:0][1:0]     m_arburst,
  output logic [NC-1:0][1:0]          m_awvalid,
  input  logic [NC-1:0][1:0]          m_awready,
  output logic [NC-1:0][1:0][32:0]    m_awaddr,
  output logic [NC-1:0][1:0][5:0]     m_awid,
  output logic [NC-1:0][1:0][7:0]     m_awlen,
  output logic [NC-1:0][1:0][2:0]     m_awsize,
  output logic [NC-1:0][1:0][1:0]     m_awburst,
  output logic [NC-1:0][1:0]          m_wvalid,
  input  logic [NC-1:0][1:0]          m_wready,
  output logic [NC-1:0][1:0][255:0]   m_wdata,
  output logic [NC-1:0][1:0][31:0]    m_wstrb,
  output logic [NC-1:0][1:0]          m_wlast,
  input  logic [NC-1:0][1:0]          m_bvalid,
  output logic [NC-1:0][1:0]          m_bready,
  input  logic [NC-1:0][1:0][5:0]     m_bid,
  input  logic [NC-1:0][1:0][1:0]     m_bresp,
  input  logic [NC-1:0][1:0]          m_rvalid,
  output logic [NC-1:0][1:0]          m_rready,
  input  logic [NC-1:0][1:0][5:0]     m_rid,
  input  logic [NC-1:0][1:0][255:0]   m_rdata,
  input  logic [NC-1:0][1:0][1:0]     m_rresp,
  input  logic [NC-1:0][1:0]          m_rlast
);
  // the accelerator's native masters, per channel (the board's side: b_*; the bridge's: n_*)
  logic [NC-1:0]        b_cvalid, b_cready, b_cwe, b_wvalid, b_wready, b_rvalid, b_err;
  logic [NC-1:0][24:0]  b_caddr;
  logic [NC-1:0][511:0] b_wdata, b_rdata;
  logic [NC-1:0][63:0]  b_wmask;
  logic [NC-1:0][15:0]  b_wdone;

  for (genvar j = 0; j < NC; j++) begin : g_ch
    logic bid, rid;                   // (XIDW 1: XDMA's IDs stay in the block design)
    // the channel's two controller ports, each onto one AXI3 master through its bridge
    logic [1:0]        cv, cr, cwe, wv, wr, rv;
    logic [1:0][24:0]  ca;
    logic [1:0][511:0] wd, rd;
    logic [1:0][63:0]  we;
    otpu_mem_ch #(.XIDW(1), .RMW(1'b0), .RBUS(1'b0)) u_ch (
      .clk, .rst,
      .n_cvalid(b_cvalid[j]), .n_cready(b_cready[j]), .n_cwe(b_cwe[j]), .n_caddr(b_caddr[j]),
      .n_wvalid(b_wvalid[j]), .n_wready(b_wready[j]), .n_wdata(b_wdata[j]),
      .n_wmask(b_wmask[j]), .n_rvalid(b_rvalid[j]), .n_rdata(b_rdata[j]),
      .n_wdone(b_wdone[j]), .n_err(b_err[j]),
      .xclk, .xrst,
      .x_awvalid(x_awvalid[j]), .x_awready(x_awready[j]), .x_awid(1'b0),
      .x_awaddr({1'b0, x_awaddr[j]}), .x_awlen(x_awlen[j]),
      .x_wvalid(x_wvalid[j]), .x_wready(x_wready[j]), .x_wdata(x_wdata[j]),
      .x_wstrb(x_wstrb[j]), .x_wlast(x_wlast[j]),
      .x_bvalid(x_bvalid[j]), .x_bready(x_bready[j]), .x_bid(bid), .x_bresp(x_bresp[j]),
      .x_arvalid(x_arvalid[j]), .x_arready(x_arready[j]), .x_arid(1'b0),
      .x_araddr({1'b0, x_araddr[j]}), .x_arlen(x_arlen[j]),
      .x_rvalid(x_rvalid[j]), .x_rready(x_rready[j]), .x_rid(rid), .x_rdata(x_rdata[j]),
      .x_rresp(x_rresp[j]), .x_rlast(x_rlast[j]),
      .uclk(hclk), .urst(hrst),
      .c_cmd_valid(cv), .c_cmd_ready(cr), .c_cmd_we(cwe), .c_cmd_addr(ca),
      .c_wdata_valid(wv), .c_wdata_ready(wr), .c_wdata_data(wd), .c_wdata_we(we),
      .c_rdata_valid(rv), .c_rdata_data(rd));
    for (genvar p = 0; p < 2; p++) begin : g_port
      otpu_native_axi3 #(.AW(33), .HBM_BASE(33'(j) << 31)) u_axi (
        .clk(hclk), .rst(hrst),
        .n_cmd_valid(cv[p]), .n_cmd_ready(cr[p]), .n_cmd_we(cwe[p]), .n_cmd_addr(ca[p]),
        .n_wvalid(wv[p]), .n_wready(wr[p]), .n_wdata(wd[p]), .n_wmask(we[p]),
        .n_rvalid(rv[p]), .n_rdata(rd[p]),
        .m_arvalid(m_arvalid[j][p]), .m_arready(m_arready[j][p]), .m_araddr(m_araddr[j][p]),
        .m_arid(m_arid[j][p]), .m_arlen(m_arlen[j][p]), .m_arsize(m_arsize[j][p]),
        .m_arburst(m_arburst[j][p]),
        .m_awvalid(m_awvalid[j][p]), .m_awready(m_awready[j][p]), .m_awaddr(m_awaddr[j][p]),
        .m_awid(m_awid[j][p]), .m_awlen(m_awlen[j][p]), .m_awsize(m_awsize[j][p]),
        .m_awburst(m_awburst[j][p]),
        .m_wvalid(m_wvalid[j][p]), .m_wready(m_wready[j][p]), .m_wdata(m_wdata[j][p]),
        .m_wstrb(m_wstrb[j][p]), .m_wlast(m_wlast[j][p]),
        .m_bvalid(m_bvalid[j][p]), .m_bready(m_bready[j][p]), .m_bid(m_bid[j][p]),
        .m_bresp(m_bresp[j][p]),
        .m_rvalid(m_rvalid[j][p]), .m_rready(m_rready[j][p]), .m_rid(m_rid[j][p]),
        .m_rdata(m_rdata[j][p]), .m_rresp(m_rresp[j][p]), .m_rlast(m_rlast[j][p]));
    end
  end

  otpu_board #(.S(S), .D(D), .MCOLS(MCOLS), .ACT_ROWS(ACT_ROWS), .ACT_BLOCKS(ACT_BLOCKS),
               .TMEM_WORDS(TMEM_WORDS), .IMEM_WORDS(IMEM_WORDS), .FIFO_DEPTH(FIFO_DEPTH),
               .LANES(LANES), .WIN(WIN), .RPB(RPB), .WPB(WPB), .MXU_IMPL(MXU_IMPL),
               .MXU_CL(MXU_CL), .VPU_CL(VPU_CL), .ULANES(ULANES), .CORE_KHZ(CORE_KHZ),
               .BUILD_ID(BUILD_ID), .DDR_MTS(DDR_MTS), .TRACE_DEPTH(TRACE_DEPTH),
               .PQ_WIN(PQ_WIN), .HAS_I2C(1'b0), .CHASH(CHASH), .DSTEP(DSTEP),
               .HOSTCAL(1'b0), .SEQ_WC(SEQ_WC), .PLATFORM(PLATFORM), .ARCH_HASH(ARCH_HASH),
               .TMEM_IMPL(TMEM_IMPL),
               .TMEM_NSB(TMEM_NSB), .TMEM_SBP(TMEM_SBP), .TMEM_SBH(TMEM_SBH), .TMEM_RPL(TMEM_RPL),
               .TMEM_TDP(TMEM_TDP),
               .TMEM_GST(TMEM_GST), .TMEM_PMP(TMEM_PMP), .TMEM_PRK(TMEM_PRK), .TMEM_SDM(TMEM_SDM))
               u_board (
    .clk, .clk_f, .rst, .ctl_mrst, .calib, .ded, .temp, .led, .i2c_lo, .i2c_pin,
    .s_ctl_awaddr, .s_ctl_awvalid, .s_ctl_awready, .s_ctl_wdata, .s_ctl_wstrb, .s_ctl_wvalid,
    .s_ctl_wready, .s_ctl_bresp, .s_ctl_bvalid, .s_ctl_bready, .s_ctl_araddr, .s_ctl_arvalid,
    .s_ctl_arready, .s_ctl_rdata, .s_ctl_rresp, .s_ctl_rvalid, .s_ctl_rready,
    .n_cvalid(b_cvalid), .n_cready(b_cready), .n_cwe(b_cwe), .n_caddr(b_caddr),
    .n_wvalid(b_wvalid), .n_wready(b_wready), .n_wdata(b_wdata), .n_wmask(b_wmask),
    .n_rvalid(b_rvalid), .n_rdata(b_rdata), .n_wdone(b_wdone), .n_err(b_err));
endmodule
