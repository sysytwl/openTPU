// Unit test of the HBM memory path (docs/plans/vu35p-hbm/03-m2-rtl.md 2.2): one otpu_mem_ch (the
// accelerator's native port, core clock, and XDMA's 128-bit AXI master, its own clock) with one
// otpu_native_axi3 per native port (the HBM AXI clock), in front of otpu_hbm_model (one channel,
// two AXI3 slave ports). This is exactly the integration an HBM board's channel has, and it makes
// otpu_mem_ch's RMW parameter's off-state (RMW = 0: the partial beat's byte enables go out on
// c_wdata_we and the HBM model's WSTRB merge fills the beat) testable against the on-state
// (RMW = 1: otpu_mem_ch read-modify-writes, the model sees whole beats only).
//
// The masters are tb_memch's (sim/verilator/tb_memch.sv, compiled alongside): tb_memch_nat (a
// random native stream with a byte shadow, full and partial beats, reads back, n_wdone's exact
// check) and tb_memch_axi (random 128-bit INCR bursts, the host's 16-byte beats, whole and partial,
// the shared and split regions across the two masters). Their scenarios come from plusargs:
// +acc0_ntx / +xdma_ntx turn a master off, +ppct / +xfull / +psh / +psp / +rbuf / +gapc / +mstall /
// +seq / +ntx select the directed case (see tools/memch_test.py). The XDMA master uses a single
// channel here (its NCH = 1), since the tb has one otpu_mem_ch and no split.
//
// The build parameter DIR selects the accelerator: DIR = 1 replaces tb_memch_nat with the
// directed master tb_hbmbdg_dir, a fixed script over the native port checked against a byte
// shadow: full-beat writes then reads back-to-back; a full write then a partial write (one byte,
// all but one, a range, none) then a read, so the old bytes must survive the partial write;
// read-after-write and write-after-read to the same beat; write data beats, write a flag, read the
// flag, read the data beats (the host protocol's order); and a read burst of 4 * ARD beats issued
// back-to-back (the read credits must hold the port, the FIFO must not overflow, no beat dropped).
// Run it with +xdma_ntx=0.
//
// The RMW distinction is also checked at the model's pins: with RMW = 0 a partial write's WSTRB is
// partial; with RMW = 1 every W beat's WSTRB is all ones. +want_partial=1 asserts it (0: partial
// writes were not issued). The bridges' error bits (n_err) must stay clear.
// Prints "PASS" or the first mismatches.
module tb_hbmbdg #(
  parameter bit RMW = 1'b1,
  parameter bit DIR = 1'b0,                // the accelerator: the directed master (tb_hbmbdg_dir), else random
  parameter int ARD = 64,                  // otpu_mem_ch's accelerator read-data FIFO (credits)
  parameter int XRD = 16,
  parameter int BEATS = 1 << 15,           // the HBM model's channel (2 MiB)
  parameter int NB = 512                   // the accelerator's window (beats)
);
  int cp = 500, ap = 300, xp = 400;        // half periods: 100 / 166.7 / 125 MHz
  logic clk = 1'b0, aclk = 1'b0, xclk = 1'b0;
  initial begin
    int seed;
    void'($value$plusargs("cp=%d", cp));
    void'($value$plusargs("ap=%d", ap));
    void'($value$plusargs("xp=%d", xp));
    if ($value$plusargs("seed=%d", seed)) void'($urandom(seed));
  end
  always #(cp) clk = ~clk;
  always #(ap) aclk = ~aclk;
  always #(xp) xclk = ~xclk;

  // the accelerator's and XDMA's windows (bytes)
  localparam int XWIN = 'h0010_0000, SPAN = 'h8000;
  localparam int A2X = 'h6000, X2A = 'h6100, NS = 256, SPL = 'h6200, NSP = 64;

  // resets
  logic rst = 1'b1, arst = 1'b1, xrst = 1'b1;
  longint ccyc = 0, acyc = 0, xcyc = 0;
  always @(posedge clk) begin ccyc <= ccyc + 1; if (ccyc == 30) rst <= 1'b0; end
  always @(posedge aclk) begin acyc <= acyc + 1; if (acyc == 20) arst <= 1'b0; end
  always @(posedge xclk) begin xcyc <= xcyc + 1; if (xcyc == 40) xrst <= 1'b0; end

  // accelerator native master
  logic        n_cvalid, n_cready, n_cwe, n_wvalid, n_wready, n_rvalid;
  logic [24:0] n_caddr;
  logic [511:0] n_wdata, n_rdata;
  logic [63:0]  n_wmask;
  logic [15:0]  n_wdone;
  logic [1:0][31:0] a2x_pub, x2a_pub;
  logic         acc_done, acc_bad;

  // otpu_mem_ch's controller side (the two native ports), HBM AXI clock
  logic [1:0]          ccv, ccr, ccwe, cwv, cwr, crv;
  logic [1:0][24:0]    cca;
  logic [1:0][511:0]   cwd, crd;
  logic [1:0][63:0]    cwe;
  logic                n_err;

  otpu_mem_ch #(.XIDW(4), .ARD(ARD), .XRD(XRD), .RMW(RMW), .RBUS(1'b0)) u_ch (
    .clk, .rst,
    .n_cvalid, .n_cready, .n_cwe, .n_caddr, .n_wvalid, .n_wready, .n_wdata, .n_wmask,
    .n_rvalid, .n_rdata, .n_wdone, .n_err,
    .xclk, .xrst,
    .x_awvalid(xawv), .x_awready(xawr), .x_awid(xawi), .x_awaddr(xawa), .x_awlen(xawl),
    .x_wvalid(xwv), .x_wready(xwr), .x_wdata(xwd), .x_wstrb(xws), .x_wlast(xwl),
    .x_bvalid(xbv), .x_bready(xbr), .x_bid(xbi), .x_bresp(xbre),
    .x_arvalid(xarv), .x_arready(xarr), .x_arid(xari), .x_araddr(xara), .x_arlen(xarl),
    .x_rvalid(xrv), .x_rready(xrr), .x_rid(xri), .x_rdata(xrd), .x_rresp(xrre), .x_rlast(xrl),
    .uclk(aclk), .urst(arst),
    .c_cmd_valid(ccv), .c_cmd_ready(ccr), .c_cmd_we(ccwe), .c_cmd_addr(cca),
    .c_wdata_valid(cwv), .c_wdata_ready(cwr), .c_wdata_data(cwd), .c_wdata_we(cwe),
    .c_rdata_valid(crv), .c_rdata_data(crd));

  // the two native->AXI3 bridges (the HBM AXI clock) and the model's two AXI3 slave ports
  logic [1:0]        h_awvalid, h_awready, h_wvalid, h_wready, h_bvalid, h_bready;
  logic [1:0]        h_arvalid, h_arready, h_rvalid, h_rready, h_wlast, h_rlast;
  logic [1:0][32:0]  h_awaddr, h_araddr;
  logic [1:0][5:0]   h_awid, h_arid, h_bid, h_rid;
  logic [1:0][7:0]   h_awlen, h_arlen;
  logic [1:0][2:0]   h_awsize, h_arsize;
  logic [1:0][1:0]   h_awburst, h_arburst, h_bresp, h_rresp;
  logic [1:0][255:0] h_wdata, h_rdata;
  logic [1:0][31:0]  h_wstrb;
  for (genvar p = 0; p < 2; p++) begin : g_bdg
    otpu_native_axi3 #(.AW(33), .HBM_BASE(33'h0), .ID(6'(p))) u_bdg (
      .clk(aclk), .rst(arst),
      .n_cmd_valid(ccv[p]), .n_cmd_ready(ccr[p]), .n_cmd_we(ccwe[p]), .n_cmd_addr(cca[p]),
      .n_wvalid(cwv[p]), .n_wready(cwr[p]), .n_wdata(cwd[p]), .n_wmask(cwe[p]),
      .n_rvalid(crv[p]), .n_rdata(crd[p]),
      .m_arvalid(h_arvalid[p]), .m_arready(h_arready[p]), .m_araddr(h_araddr[p]),
      .m_arid(h_arid[p]), .m_arlen(h_arlen[p]), .m_arsize(h_arsize[p]), .m_arburst(h_arburst[p]),
      .m_awvalid(h_awvalid[p]), .m_awready(h_awready[p]), .m_awaddr(h_awaddr[p]),
      .m_awid(h_awid[p]), .m_awlen(h_awlen[p]), .m_awsize(h_awsize[p]), .m_awburst(h_arburst[p]),
      .m_wvalid(h_wvalid[p]), .m_wready(h_wready[p]), .m_wdata(h_wdata[p]), .m_wstrb(h_wstrb[p]),
      .m_wlast(h_wlast[p]),
      .m_bvalid(h_bvalid[p]), .m_bready(h_bready[p]), .m_bid(h_bid[p]), .m_bresp(h_bresp[p]),
      .m_rvalid(h_rvalid[p]), .m_rready(h_rready[p]), .m_rid(h_rid[p]), .m_rdata(h_rdata[p]),
      .m_rresp(h_rresp[p]), .m_rlast(h_rlast[p]));
  end

  logic dump = 1'b0;
  otpu_hbm_model #(.BEATS(BEATS), .CH(0), .NP(2), .AW(33)) u_hbm (
    .clk(aclk), .rst(arst),
    .s_awvalid(h_awvalid), .s_awready(h_awready), .s_awaddr(h_awaddr), .s_awid(h_awid),
    .s_awlen(h_awlen),
    .s_wvalid(h_wvalid), .s_wready(h_wready), .s_wdata(h_wdata), .s_wstrb(h_wstrb),
    .s_wlast(h_wlast),
    .s_bvalid(h_bvalid), .s_bready(h_bready), .s_bid(h_bid),
    .s_arvalid(h_arvalid), .s_arready(h_arready), .s_araddr(h_araddr), .s_arid(h_arid),
    .s_arlen(h_arlen),
    .s_rvalid(h_rvalid), .s_rready(h_rready), .s_rid(h_rid), .s_rdata(h_rdata),
    .s_rlast(h_rlast), .dump);

  // XDMA's 128-bit AXI master (host traffic), its own clock
  logic        xawv, xawr, xwv, xwr, xwl, xbv, xbr, xarv, xarr, xrv, xrr, xrl, xdone, xbad;
  logic [3:0]  xawi, xbi, xari, xri;
  logic [31:0] xawa, xara;
  logic [7:0]  xawl, xarl;
  logic [127:0] xwd, xrd;
  logic [15:0] xws;
  logic [1:0]  xbre, xrre;
  tb_memch_axi #(.IDW(4), .WIN0(XWIN), .WIN1(XWIN), .SPAN(SPAN), .LMAX(64), .NCH(1),
                 .A2X(A2X), .X2A(X2A), .NS(NS), .SPL(SPL), .NSP(NSP), .NAME("xdma")) u_xdma (
    .clk(xclk), .rst(xrst),
    .awvalid(xawv), .awready(xawr), .awid(xawi), .awaddr(xawa), .awlen(xawl),
    .wvalid(xwv), .wready(xwr), .wdata(xwd), .wstrb(xws), .wlast(xwl),
    .bvalid(xbv), .bready(xbr), .bid(xbi), .bresp(xbre),
    .arvalid(xarv), .arready(xarr), .arid(xari), .araddr(xara), .arlen(xarl),
    .rvalid(xrv), .rready(xrr), .rid(xri), .rdata(xrd), .rresp(xrre), .rlast(xrl),
    .a2x_pub(a2x_pub), .x2a_pub(x2a_pub), .done(xdone), .bad(xbad));

  generate
  if (DIR) begin : g_dir
    tb_hbmbdg_dir #(.NB(NB), .CRED(ARD), .NAME("acc0")) u_acc (
      .clk, .rst,
      .n_cvalid, .n_cready, .n_cwe, .n_caddr, .n_wvalid, .n_wready, .n_wdata, .n_wmask,
      .n_rvalid, .n_rdata, .n_wdone, .done(acc_done), .bad(acc_bad));
  end else begin : g_rand
    tb_memch_nat #(.CH(0), .NB(NB), .A2X(A2X), .X2A(X2A), .NS(NS), .SPL(SPL), .NSP(NSP),
                   .NAME("acc0")) u_acc (
      .clk, .rst,
      .n_cvalid, .n_cready, .n_cwe, .n_caddr, .n_wvalid, .n_wready, .n_wdata, .n_wmask,
      .n_rvalid, .n_rdata, .n_wdone, .a2x_pub(a2x_pub[0]), .x2a_pub(x2a_pub[0]),
      .done(acc_done), .bad(acc_bad));
  end
  endgenerate

  // the model's WSTRB as the RMW distinction: RMW 0 keeps a partial write's byte enables (the
  // HBM model merges), RMW 1 read-modify-writes in otpu_mem_ch (every beat whole)
  longint n_wex = 0, n_partial_w = 0;
  for (genvar p = 0; p < 2; p++)
    always @(posedge aclk)
      if (!arst && h_wvalid[p] && h_wready[p]) begin
        n_wex++;
        if (h_wstrb[p] != '1) n_partial_w++;
      end

  // the end: every master done (or the error bits); +want_partial checks the RMW distinction
  longint tmax = 2000000;
  int want_partial = -1;                    // -1: do not check; 0: none; 1: some
  initial begin
    void'($value$plusargs("tmax=%d", tmax));
    void'($value$plusargs("want_partial=%d", want_partial));
  end
  int errs = 0;
  always @(posedge clk) begin
    if (n_err) begin
      $display("FAIL n_err: the bridge saw its controller break the port contract");
      $finish;
    end
    if ((acc_done && xdone) || (acc_bad || xbad)) begin
      dump <= 1'b1;
      repeat (4) @(posedge aclk);
      if (want_partial == 1 && RMW == 1'b0 && n_partial_w == 0)
        begin $display("ERROR: RMW=0 but no partial WSTRB reached the model"); errs++; end
      if (want_partial == 1 && RMW == 1'b1 && n_partial_w != 0)
        begin $display("ERROR: RMW=1 but %0d partial WSTRB reached the model", n_partial_w); errs++; end
      if (acc_bad || xbad) errs++;
      $display("%s cycles=%0d wex=%0d partial_w=%0d", errs == 0 ? "PASS" : "FAIL", ccyc, n_wex,
               n_partial_w);
      $finish;
    end
    if (ccyc > tmax) begin
      $display("TIMEOUT acc done %b xdma done %b", acc_done, xdone);
      $finish;
    end
  end
endmodule

// The directed accelerator master (+dir build: tb_hbmbdg's DIR = 1): a fixed script over the
// native port with a byte shadow, each read checked against the beat's value at the read's place
// in the program (one master's commands run in order). The cases the header lists: full-beat
// writes then reads back-to-back; a full write then a partial write (one byte, all but one, a
// range, none) then a read, so the old bytes must survive the partial write; read-after-write and
// write-after-read to the same beat; write data beats, write a flag beat, read the flag, read the
// data beats (the host protocol's order); and a read burst of 4 * CRED beats issued back-to-back
// (the read credits must hold the port, the FIFO must not overflow, no beat dropped).
module tb_hbmbdg_dir #(
  parameter int NB = 512,                  // the accelerator's window (beats)
  parameter int CRED = 64,                 // otpu_mem_ch's accelerator read credits (ARD)
  parameter string NAME = "dir"
) (
  input  logic         clk,
  input  logic         rst,
  output logic         n_cvalid,
  input  logic         n_cready,
  output logic         n_cwe,
  output logic [24:0]  n_caddr,
  output logic         n_wvalid,
  input  logic         n_wready,
  output logic [511:0] n_wdata,
  output logic [63:0]  n_wmask,
  input  logic         n_rvalid,
  input  logic [511:0] n_rdata,
  input  logic [15:0]  n_wdone,
  output logic         done,
  output logic         bad
);
  logic [7:0] sh [NB * 64];                // the byte shadow
  typedef struct { bit we; int b; } op_t;
  typedef struct { logic [511:0] d; logic [63:0] m; } wd_t;
  typedef struct { logic [511:0] d; logic [63:0] m; } rd_t;
  op_t cq [$];
  wd_t dq [$];
  rd_t rq [$];
  int nerr = 0, nrb = 0, nwb = 0, nrun = 0;
  longint wacc = 0, wdat = 0, wdone_tot = 0;
  logic [15:0] wd_prev = '0;
  bit built = 1'b0;

  function automatic logic [511:0] rnd();
    logic [511:0] d;
    for (int k = 0; k < 16; k++) d[32 * k +: 32] = 32'($urandom);
    return d;
  endfunction

  // a read command, checked against the shadow as of the program's order
  task automatic rd(input int b);
    logic [511:0] d;
    for (int k = 0; k < 64; k++) d[8 * k +: 8] = sh[64 * b + k];
    cq.push_back('{1'b0, b});
    rq.push_back('{d, '1});
    nrun++;
  endtask

  // a write command: its data on n_wdata/n_wmask, its bytes into the shadow
  task automatic wr(input int b, input logic [63:0] m, input logic [511:0] d);
    cq.push_back('{1'b1, b});
    dq.push_back('{d, m});
    for (int k = 0; k < 64; k++) if (m[k]) sh[64 * b + k] = d[8 * k +: 8];
    nrun++;
  endtask

  initial begin
    logic [63:0] m;
    int a, b;
    for (int i = 0; i < NB * 64; i++) sh[i] = 8'h00;
    n_cvalid = 1'b0; n_wvalid = 1'b0;
    wait (!rst);
    // full-beat writes then reads back-to-back
    for (int i = 0; i < 8; i++) begin wr(i, '1, rnd()); rd(i); end
    // a full write, then a partial write, then a read: the old bytes survive
    // one byte
    wr(16, '1, rnd());
    m = 64'h1 << ($urandom % 64); wr(16, m, rnd()); rd(16);
    // all but one
    wr(17, '1, rnd());
    m = ~(64'h1 << ($urandom % 64)); wr(17, m, rnd()); rd(17);
    // a range
    wr(18, '1, rnd());
    a = $urandom % 64; b = $urandom % 64;
    if (a > b) begin int t; t = a; a = b; b = t; end
    m = '0; for (int k = a; k <= b; k++) m[k] = 1'b1;
    wr(18, m, rnd()); rd(18);
    // none
    wr(19, '1, rnd()); wr(19, '0, rnd()); rd(19);
    // read-after-write and write-after-read to the same beat
    wr(32, '1, rnd()); rd(32);
    rd(33); wr(33, '1, rnd()); rd(33);
    // the host protocol: write data beats, write a flag, read the flag, read the data beats
    wr(40, '1, rnd()); wr(41, '1, rnd()); wr(42, '1, rnd());
    rd(42); rd(40); rd(41);
    // a read burst back to back: the credits hold the port and no beat is dropped
    for (int k = 0; k < 4 * CRED; k++) rd($urandom % NB);
    built = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cq.delete(); dq.delete(); rq.delete();
      built <= 1'b0; n_cvalid <= 1'b0; n_wvalid <= 1'b0;
      wacc = 0; wdat = 0; wdone_tot = 0; wd_prev = '0;
    end else if (built) begin
      // n_wdone never ahead of the writes given (command and data), each counted once
      begin
        logic [15:0] d;
        longint lim;
        d = n_wdone - wd_prev;
        lim = ((wacc < wdat) ? wacc : wdat) - wdone_tot;
        if (longint'(d) > lim) begin
          if (nerr < 20) $display("ERROR %s: n_wdone %0d -> %0d too far", NAME, wd_prev, n_wdone);
          nerr++;
        end else if (d != 0) begin wdone_tot += longint'(d); nwb += int'(d); end
        wd_prev = n_wdone;
      end
      // read data, in command order
      if (n_rvalid) begin
        if (rq.size() == 0) begin $display("ERROR %s: read data without a read", NAME); nerr++; end
        else begin
          for (int k = 0; k < 64; k++)
            if (n_rdata[8 * k +: 8] !== rq[0].d[8 * k +: 8]) begin
              if (nerr < 20)
                $display("ERROR %s: read beat byte %0d: %h, expected %h", NAME, k,
                         n_rdata[8 * k +: 8], rq[0].d[8 * k +: 8]);
              nerr++;
            end
          void'(rq.pop_front()); nrb++;
        end
      end
      // write data, in write order, independent of the commands
      if (n_wvalid && n_wready) begin void'(dq.pop_front()); wdat++; end
      if (!n_wvalid || n_wready) begin
        if (dq.size() != 0) begin n_wvalid <= 1'b1; n_wdata <= dq[0].d; n_wmask <= dq[0].m; end
        else n_wvalid <= 1'b0;
      end
      // commands, back to back (the credits are mem_ch's)
      if (n_cvalid && n_cready) begin
        if (cq[0].we) wacc++;
        void'(cq.pop_front());
      end
      if (!n_cvalid || n_cready) begin
        if (cq.size() != 0) begin n_cvalid <= 1'b1; n_cwe <= cq[0].we; n_caddr <= 25'(cq[0].b); end
        else n_cvalid <= 1'b0;
      end
    end
  end

  assign done = (built && cq.size() == 0 && dq.size() == 0 && rq.size() == 0 && !n_cvalid &&
                 !n_wvalid && wdone_tot == wacc && wacc == wdat) || nerr != 0;
  assign bad  = nerr != 0;

  final if (nrb + nwb > 0)
    $display("%s: %0d runs, %0d read beats, %0d write beats counted, %0d errors", NAME, nrun, nrb, nwb,
             nerr);
endmodule
