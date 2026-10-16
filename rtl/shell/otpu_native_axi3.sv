// otpu_native_axi3: the one new piece of hardware on an HBM board -- one LiteDRAM native port
// (the controller side of otpu_mem_ch) to one AXI3 master, 256 bits wide, single ID.
//
// ============================================================ contract (the spec)
//
// Input side -- one LiteDRAM native port, exactly as otpu_mem_ch drives it today:
//   - command: {n_cmd_we, n_cmd_addr} handshake, one command per cycle when n_cmd_ready;
//   - write data: taken some cycles after its command, in write-command order (n_wvalid/n_wready);
//   - read data: in command order, no backpressure (n_rvalid, always accepted);
//   - byte enables on writes: n_wmask, 1 = write the byte. With otpu_mem_ch RMW = 0 the native
//     port carries a partial beat's enables (and undefined bytes for the rest); the bridge passes
//     them through as AXI WSTRB and the HBM IP's own read-modify-write fills the beat. With
//     RMW = 1 the native port carries whole beats only (otpu_mem_ch merged the read).
//
// Output side -- one AXI3 master (the HBM IP's slave: 256-bit data, 6-bit ID), in:
//   - AR: one transaction per native beat, INCR, len = 1 (2 x 256 bits = 64 bytes), 64-byte
//     aligned; araddr = hbm_base + (beat_addr << 6);
//   - AW/W: the same shape (awlen = 1, WSTRB from the byte enables, WLAST on the second beat);
//   - R: always accepted, its two 256-bit beats reassembled into the 512-bit native beat, in
//     order (single ID: the controller returns them in AR order, so no reordering is needed);
//   - B: counted (bready tied high);
//   - credits: a read command is taken only while the read-data path has room for its beat and
//     every read not yet through (the same rule otpu_mem_ch applies to its masters).
//
// The native write-visibility count (n_wdone in otpu_mem_ch) keeps working unchanged: a native
// write is "taken" when its command handshake (n_cmd_valid/n_cmd_ready) is accepted here -- the
// same definition otpu_mem_ch uses for its own controller ports (command handshake, not B).
//
// Clocking: the bridge runs entirely in the HBM AXI clock domain. The board wires it to
// otpu_mem_ch's controller side (uclk = the AXI clock), so otpu_mem_ch's own clock-crossing FIFOs
// move the accelerator's core-clock and XDMA's traffic into this domain, exactly as they move it
// into a DDR controller's clock on the DDR boards. (docs/plans/vu35p-hbm/03-m2-rtl.md 2.1 allows
// this "run it in the AXI clock and skip the FIFOs" alternative; M0 found the card's HBM AXI
// clock is refclk300 / its divider, not the core clock.)
//
// Ordering: every write of a channel goes through the same bridge instances (two per channel, one
// per native port -- otpu_mem_ch's existing bank-parity split), the per-port AXI ID is single, and
// a read command is only dispatched behind every earlier command of the same port (this module
// dispatches the native command FIFO strictly in order), so the earlier write is in the HBM
// controller's queue before a later read to the same region: tools/qual/waitw.py's property.
module otpu_native_axi3 #(
  parameter int AW = 33,                 // AXI address width (hbm_base + 31-bit byte offset)
  parameter logic [AW-1:0] HBM_BASE = '0,// the channel's base (j * 2 GiB)
  parameter int CQ = 32,                 // native command FIFO (beats)
  parameter int WQ = 32,                 // native write-data FIFO (beats)
  parameter int RD = 32,                 // read-data FIFO (native beats) -- the credit limit
  parameter logic [5:0] ID = 6'h00       // the AXI ID (single per port)
) (
  // native side: otpu_mem_ch's controller port (uclk = the AXI clock)
  input  logic         clk,
  input  logic         rst,
  input  logic         n_cmd_valid,
  output logic         n_cmd_ready,
  input  logic         n_cmd_we,
  input  logic [24:0]  n_cmd_addr,
  input  logic         n_wvalid,
  output logic         n_wready,
  input  logic [511:0] n_wdata,
  input  logic [63:0]  n_wmask,
  output logic         n_rvalid,
  output logic [511:0] n_rdata,
  // AXI3 master, 256-bit, single ID
  output logic         m_arvalid,
  input  logic         m_arready,
  output logic [AW-1:0] m_araddr,
  output logic [5:0]   m_arid,
  output logic [7:0]   m_arlen,
  output logic [2:0]   m_arsize,
  output logic [1:0]   m_arburst,
  output logic         m_awvalid,
  input  logic         m_awready,
  output logic [AW-1:0] m_awaddr,
  output logic [5:0]   m_awid,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic [1:0]   m_awburst,
  output logic         m_wvalid,
  input  logic         m_wready,
  output logic [255:0] m_wdata,
  output logic [31:0]  m_wstrb,
  output logic         m_wlast,
  input  logic         m_bvalid,
  output logic         m_bready,
  input  logic [5:0]   m_bid,
  input  logic [1:0]   m_bresp,
  input  logic         m_rvalid,
  output logic         m_rready,
  input  logic [5:0]   m_rid,
  input  logic [255:0] m_rdata,
  input  logic [1:0]   m_rresp,
  input  logic         m_rlast
);
  localparam int CW = 26;                // command: {write, beat[24:0]}
  localparam int DW = 576;               // write data: {byte enables[63:0], data[511:0]}
  localparam int CRW = $clog2(RD) + 1;   // read credits

  // ================================================================ native side
  logic          cq_wv, cq_wr, cq_rv, cq_rr;  logic [CW-1:0] cq_wd, cq_rd;
  logic          wd_wv, wd_wr, wd_rv, wd_rr;  logic [DW-1:0] wd_wd, wd_rd;
  logic          rd_wv, rd_wr, rd_rv, rd_rr;  logic [511:0]  rd_wd, rd_rd;
  logic [CRW-1:0] rd_cred;

  // A read is taken only while the read-data path has room for its beat (and, since at most one
  // is taken a cycle, one spare); a write only needs the command FIFO. The write data is taken
  // while its FIFO has room.
  assign n_cmd_ready = cq_wr && (!n_cmd_we || rd_cred != 0);
  assign cq_wv       = n_cmd_valid && n_cmd_ready;
  assign cq_wd       = {n_cmd_we, n_cmd_addr};
  assign n_wready    = wd_wr;
  assign wd_wv       = n_wvalid && n_wready;
  assign wd_wd       = {n_wmask, n_wdata};
  assign n_rvalid    = rd_rv;
  assign n_rdata     = rd_rd;
  assign rd_rr       = 1'b1;             // no backpressure
  // the credits: a read command takes one, a completed beat (pushed into the read-data FIFO)
  // gives it back
  always_ff @(posedge clk) begin
    if (rst) rd_cred <= CRW'(RD);
    else rd_cred <= rd_cred + CRW'(rd_wv) - CRW'(cq_wv && !n_cmd_we);
  end

  otpu_sfifo #(.W(CW), .DEPTH(CQ)) u_cq (.clk, .rst, .wvalid(cq_wv), .wready(cq_wr),
    .wdata(cq_wd), .rvalid(cq_rv), .rready(cq_rr), .rdata(cq_rd));
  otpu_sfifo #(.W(DW), .DEPTH(WQ)) u_wd (.clk, .rst, .wvalid(wd_wv), .wready(wd_wr),
    .wdata(wd_wd), .rvalid(wd_rv), .rready(wd_rr), .rdata(wd_rd));
  otpu_sfifo #(.W(512), .DEPTH(RD)) u_rd (.clk, .rst, .wvalid(rd_wv), .wready(rd_wr),
    .wdata(rd_wd), .rvalid(rd_rv), .rready(rd_rr), .rdata(rd_rd));

  // ================================================================ AXI read: AR (in order)
  logic        head_we;
  logic [24:0] head_addr;
  assign head_we   = cq_rd[CW-1];
  assign head_addr = cq_rd[24:0];
  // dispatch the head command strictly in order; a read goes as soon as the AR channel is free
  assign m_arvalid = cq_rv && !head_we;
  assign m_araddr  = HBM_BASE + AW'(32'(head_addr) << 6);
  assign m_arid    = ID;
  assign m_arlen   = 8'd1;
  assign m_arsize  = 3'd5;               // 2^5 = 32 bytes a beat
  assign m_arburst = 2'b01;              // INCR
  assign m_rready  = 1'b1;               // always accepted

  // reassemble the two 256-bit R beats into the 512-bit native beat, in order (single ID): the
  // second half of a pair pushes a whole native beat into the read-data FIFO
  logic         r_lo_v;
  logic [255:0] r_lo;
  always_ff @(posedge clk) begin
    if (rst) begin
      r_lo_v <= 1'b0;
      rd_wv  <= 1'b0;
    end else begin
      rd_wv <= 1'b0;
      if (m_rvalid) begin
        if (!r_lo_v) begin
          r_lo   <= m_rdata;
          r_lo_v <= 1'b1;
        end else begin
          rd_wd  <= {m_rdata, r_lo};
          rd_wv  <= 1'b1;
          r_lo_v <= 1'b0;
        end
      end
    end
  end

  // ================================================================ AXI write: AW/W (in order)
  // The head write goes out as one AW and two W beats; the native write data at the head of its
  // FIFO is the oldest write (write data comes in write-command order). Commands dispatch in
  // order, so a later read never passes an earlier write.
  typedef enum logic [1:0] {W_IDLE, W_AW, W_W0, W_W1} wst_t;
  wst_t        wst;
  logic [24:0] w_addr;
  assign m_awid    = ID;
  assign m_awlen   = 8'd1;
  assign m_awsize  = 3'd5;
  assign m_awburst = 2'b01;

  always_ff @(posedge clk) begin
    if (rst) begin
      wst <= W_IDLE; w_addr <= '0;
    end else begin
      case (wst)
        W_IDLE: if (cq_rv && head_we && wd_rv) begin
                  w_addr <= head_addr;
                  wst    <= W_AW;
                end
        W_AW:   if (m_awready) wst <= W_W0;
        W_W0:   if (m_wready) wst <= W_W1;
        W_W1:   if (m_wready) wst <= W_IDLE;
        default: wst <= W_IDLE;
      endcase
    end
  end
  assign m_awvalid = wst == W_AW;
  assign m_awaddr  = HBM_BASE + AW'(32'(w_addr) << 6);
  assign m_wvalid  = (wst == W_W0) || (wst == W_W1);
  assign m_wdata   = (wst == W_W1) ? wd_rd[511:256] : wd_rd[255:0];
  assign m_wstrb   = (wst == W_W1) ? wd_rd[575:544] : wd_rd[543:512];
  assign m_wlast   = (wst == W_W1);
  // the head command and its write data leave together when the last beat is taken
  assign cq_rr = (cq_rv && !head_we && m_arready) || (wst == W_W1 && m_wready);
  assign wd_rr = (wst == W_W1 && m_wready);

  // B responses: counted, always accepted
  logic [15:0] bcnt;
  assign m_bready = 1'b1;
  always_ff @(posedge clk) begin
    if (rst) bcnt <= '0;
    else if (m_bvalid) bcnt <= bcnt + 1'b1;
  end

`ifndef SYNTHESIS
  // the controller's side of the port contract: R beats in order, a completed pair has room,
  // responses carry the single ID
  logic rd_seen;
  always_ff @(posedge clk)
    if (rst) rd_seen <= 1'b0;
    else if (m_rvalid && m_rlast) rd_seen <= 1'b0;
    else if (m_rvalid && !m_rlast) rd_seen <= 1'b1;
  always_ff @(posedge clk)
    if (!rst) begin
      if (rd_wv && !rd_wr) $error("otpu_native_axi3: read-data FIFO overflow");
      if (m_rvalid && m_rlast && !rd_seen) $error("otpu_native_axi3: R beat 1 without beat 0");
      if (m_rvalid && m_rid != ID) $error("otpu_native_axi3: R id %h", m_rid);
      if (m_bvalid && (m_bid != ID || m_bresp != 2'b00))
        $error("otpu_native_axi3: B id %h resp %h", m_bid, m_bresp);
    end
`endif
endmodule
