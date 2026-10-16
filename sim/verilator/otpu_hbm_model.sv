// Simulation model of one HBM channel behind the AXI3 masters otpu_native_axi3 presents (one per
// native port of otpu_mem_ch). It is the AXI3 analogue of otpu_ldn_model / otpu_native_mem: a flat
// 64-byte-beat memory with NP AXI3 slave ports (256-bit data, 6-bit ID), WSTRB merge, in-order R
// and B per port, a fatal on protocol violations, and optional latency / timing / ECC.
//
// Traffic: the bridge (otpu_native_axi3) issues one INCR transaction per native beat, 64-byte
// aligned, and its two 256-bit beats are the native beat's low then high half; the model also
// handles arbitrary 32-byte-aligned INCR bursts up to 16 beats (AXI3's maximum), of which the
// bridge uses len = 1. A write's AW and its W beats are taken in order and the write's data is
// merged into memory with WSTRB (1 = write the byte). Per port the model performs the operations
// in arrival order, one an op a cycle, sampling memory at the read's turn: a later read sees an
// earlier write applied, which is the ordering tools/qual/waitw.py's property needs. Across
// ports the operations are independent (a native beat's bank parity keeps a beat on one port, so
// no beat is ever shared); the two ports' turns are unordered, as the DDR boards' two native
// ports are, but the channel has one read bus: at most one port returns an R beat a cycle (a
// round-robin between ports with a beat due), so otpu_mem_ch's one read decoder is satisfied.
//
// Latency: an operation is performed in arrival order and its response is due LAT + 0..7 cycles
// later (+hbm_lat=N); a read's beats come back to back, in order, one a cycle. +hbm_stall=P
// withholds each port's AR/AW/W ready P percent of the time.
// +hbm_dram=1: a per-port bank model (row buffers, tRCD/tRP/tRAS/tRC/tRTP/tREFI/tRFC, read/write
// turnarounds; the names and the algorithm are otpu_native_mem's DDR3 model's) so perf_qwen.py-
// style projections can be fitted. +hbm_ecc=1: count correctable / uncorrectable words (no
// injection by default; +hbm_ecc_ce=P / +hbm_ecc_ue=P inject on P percent of the operations), so
// otpu-diag --sim can exercise the ECC stage; the counts print at the dump.
//
// Images: with IMG = 1 the channel's memory loads from <dir>/ch<CH>.bin (big-endian 32-bit words,
// as $fread reads) and dumps to <dir>/ch<CH>_out.bin on dump (little-endian, as otpu_chmem's
// physical images). +hbm_seed=N seeds the random ready gates.
module otpu_hbm_model #(
  parameter int  BEATS = 1 << 12,        // 64-byte beats (one channel)
  parameter int  LAT   = 32,             // minimum read / write-response latency, cycles
  parameter int  CH    = 0,              // the channel (its image files)
  parameter int  NP    = 2,              // AXI3 slave ports (one per native port)
  parameter int  AW    = 33,
  parameter bit  IMG   = 1'b1
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic [NP-1:0]         s_awvalid,
  output logic [NP-1:0]         s_awready,
  input  logic [NP-1:0][AW-1:0] s_awaddr,
  input  logic [NP-1:0][5:0]    s_awid,
  input  logic [NP-1:0][7:0]    s_awlen,
  input  logic [NP-1:0]         s_wvalid,
  output logic [NP-1:0]         s_wready,
  input  logic [NP-1:0][255:0]  s_wdata,
  input  logic [NP-1:0][31:0]   s_wstrb,
  input  logic [NP-1:0]         s_wlast,
  output logic [NP-1:0]         s_bvalid,
  input  logic [NP-1:0]         s_bready,
  output logic [NP-1:0][5:0]    s_bid,
  input  logic [NP-1:0]         s_arvalid,
  output logic [NP-1:0]         s_arready,
  input  logic [NP-1:0][AW-1:0] s_araddr,
  input  logic [NP-1:0][5:0]    s_arid,
  input  logic [NP-1:0][7:0]    s_arlen,
  output logic [NP-1:0]         s_rvalid,
  input  logic [NP-1:0]         s_rready,
  output logic [NP-1:0][5:0]    s_rid,
  output logic [NP-1:0][255:0]  s_rdata,
  output logic [NP-1:0]         s_rlast,
  input  logic                  dump
);
  // the channel's memory: one 512-bit native beat a word
  logic [511:0] mem [BEATS];
  int stall = 0, lat = LAT, qd = 64;
  longint cyc = 0;
  longint n_rd [NP], n_wr [NP];
  // DRAM timing (+hbm_dram=1): one bank model a port (a pseudo-channel's two halves)
  int dram = 0, nbk = 8;
  int trcd = 12, trp = 12, tras = 28, trc = 40, trtp = 6, trefi = 780, trfc = 16, tturn = 2;
  longint dbus [NP], dnref [NP], dtact [NP][8], dtcol [NP][8];
  bit     dwdir [NP];
  int     dorow [NP][8];
  // ECC (+hbm_ecc=1)
  int ecc = 0, ecc_ce = 0, ecc_ue = 0;
  longint n_ce [NP], n_ue [NP];

  // the channel's one read bus: at most one port drives an R beat a cycle (round-robin over the
  // ports with a beat due; a port holding an unaccepted beat blocks the others)
  logic [NP-1:0] r_req, r_gnt, r_have;
  logic [5:0]    r_id [NP];
  logic [255:0]  r_d [NP];
  logic          r_last [NP];
  logic [$clog2(NP + 1)-1:0] r_rr;
  always_comb begin
    r_gnt = '0;
    for (int i = 0; i < NP; i++) begin
      int k;
      k = (int'(r_rr) + i) % NP;
      if (r_req[k] && r_gnt == '0) r_gnt[k] = 1'b1;
    end
  end
  always_ff @(posedge clk)
    if (rst) r_rr <= '0;
    else if (|r_gnt) r_rr <= (r_rr == ($clog2(NP + 1))'(NP - 1)) ? '0 : r_rr + 1'b1;

  always_ff @(posedge clk) cyc <= cyc + 1;

  function automatic int bank_of(input int b);
    return (b >> 3) % nbk;
  endfunction
  function automatic int row_of(input int b);
    return b >> 3;
  endfunction

  // The column command's cycle for the beat `b` on port `p`, applied `wr`, arriving at `arrive`:
  // otpu_native_mem's DDR3 model, at one tick a cycle (a native beat is the column command).
  function automatic longint dram_slot(input int p, input int b, input bit wr,
                                       input longint arrive);
    int bk, row;
    longint t;
    bk = bank_of(b); row = row_of(b);
    t = arrive > dbus[p] ? arrive : dbus[p];
    while (t >= dnref[p]) begin
      if (dbus[p] < dnref[p]) dbus[p] = dnref[p];
      dbus[p] = dbus[p] + trfc;
      for (int k = 0; k < nbk; k++) begin dorow[p][k] = -1; dtact[p][k] = dbus[p] - trc; end
      dnref[p] = dnref[p] + trefi;
      t = arrive > dbus[p] ? arrive : dbus[p];
    end
    if (wr != dwdir[p]) begin t = t + tturn; dwdir[p] = wr; end
    if (dorow[p][bk] != row) begin
      longint tp, ta;
      if (dorow[p][bk] < 0) tp = arrive - trp;
      else begin
        tp = dtcol[p][bk] + trtp;
        if (dtact[p][bk] + tras > tp) tp = dtact[p][bk] + tras;
        if (arrive > tp) tp = arrive;
      end
      ta = tp + trp;
      if (dtact[p][bk] + trc > ta) ta = dtact[p][bk] + trc;
      dorow[p][bk] = row;
      dtact[p][bk] = ta;
      if (ta + trcd > t) t = ta + trcd;
    end
    dtcol[p][bk] = t;
    dbus[p] = t + 1;
    return t;
  endfunction

  for (genvar p = 0; p < NP; p++) begin : g_port
    // operations in arrival order, one native-beat-aligned set of AXI beats each
    typedef struct { bit we; logic [5:0] id; logic [AW-1:0] a0; int n2; } op_t;
    typedef struct { longint t; logic [5:0] id; logic [255:0] d; bit last; } rr_t;
    typedef struct { longint t; logic [5:0] id; } br_t;
    op_t oq [$];
    logic [287:0] wa [$];                      // write AXI beats taken: {strb[31:0], data[255:0]}
    rr_t rq [$];
    br_t bq [$];
    logic aw_v; logic [5:0] awid; logic [AW-1:0] awaddr; int awn2, wcnt;
    longint busy = 0, rlast = 0, blast = 0;
    logic ar_rdy, aw_rdy, w_rdy;

    assign s_arready[p] = ar_rdy && oq.size() < qd;
    assign s_awready[p] = !aw_v && aw_rdy;
    assign s_wready[p]  = aw_v && w_rdy;
    // the read bus: this port wants it if it holds a beat or has one due and no port holds one
    assign r_req[p]   = r_have[p] || (!(|r_have) && rq.size() != 0 && rq[0].t <= cyc);
    assign s_rvalid[p] = r_have[p];
    assign s_rid[p]    = r_id[p];
    assign s_rdata[p]  = r_d[p];
    assign s_rlast[p]  = r_last[p];

    always_ff @(posedge clk) begin
      if (rst) begin
        oq.delete(); wa.delete(); rq.delete(); bq.delete();
        aw_v <= 1'b0; awid <= '0; awaddr <= '0; awn2 <= 0; wcnt <= 0;
        busy = 0; rlast = 0; blast = 0;
        ar_rdy <= 1'b1; aw_rdy <= 1'b1; w_rdy <= 1'b1;
        r_have[p] <= 1'b0; r_id[p] <= '0; r_d[p] <= '0; r_last[p] <= 1'b0;
        s_bvalid[p] <= 1'b0; s_bid[p] <= '0;
        dbus[p] = 0; dnref[p] = trefi; dwdir[p] = 1'b0;
        for (int k = 0; k < 8; k++) begin dorow[p][k] = -1; dtact[p][k] = -1000; dtcol[p][k] = -1000; end
      end else begin
        ar_rdy <= ($urandom % 100) >= stall;
        aw_rdy <= ($urandom % 100) >= stall;
        w_rdy  <= ($urandom % 100) >= stall;

        // AR / AW accepted: an operation in arrival order. A read or write may not arrive while
        // the pending write's data is still coming (the bridge never does; the model's ordering
        // would be undefined otherwise)
        if (s_arvalid[p] && s_arready[p]) begin
          if (aw_v) $fatal(1, "otpu_hbm_model ch%0d p%0d: AR during a write's data", CH, p);
          if (int'(s_arlen[p]) + 1 > 16)
            $fatal(1, "otpu_hbm_model ch%0d p%0d: AR len %0d over 16 beats", CH, p, s_arlen[p]);
          if (int'(s_araddr[p][30:6]) + (int'(s_arlen[p]) + 1) * 32 / 64 + 1 > BEATS)
            $fatal(1, "otpu_hbm_model ch%0d p%0d: AR address %h beyond the memory", CH, p, s_araddr[p]);
          oq.push_back('{1'b0, s_arid[p], s_araddr[p], int'(s_arlen[p]) + 1});
        end
        if (s_awvalid[p] && s_awready[p]) begin
          if (int'(s_awlen[p]) + 1 > 16)
            $fatal(1, "otpu_hbm_model ch%0d p%0d: AW len %0d over 16 beats", CH, p, s_awlen[p]);
          if (int'(s_awaddr[p][30:6]) + (int'(s_awlen[p]) + 1) * 32 / 64 + 1 > BEATS)
            $fatal(1, "otpu_hbm_model ch%0d p%0d: AW address %h beyond the memory", CH, p, s_awaddr[p]);
          aw_v <= 1'b1; awid <= s_awid[p]; awaddr <= s_awaddr[p];
          awn2 <= int'(s_awlen[p]) + 1; wcnt <= 0;
          oq.push_back('{1'b1, s_awid[p], s_awaddr[p], int'(s_awlen[p]) + 1});
        end
        // W beats: the pending AW's, WLAST on its last
        if (s_wvalid[p] && s_wready[p]) begin
          if (!aw_v) $fatal(1, "otpu_hbm_model ch%0d p%0d: W without AW", CH, p);
          wa.push_back({s_wstrb[p], s_wdata[p]});
          if (wcnt == awn2 - 1) begin
            if (!s_wlast[p]) $fatal(1, "otpu_hbm_model ch%0d p%0d: WLAST missing on the last beat", CH, p);
            aw_v <= 1'b0;
          end else begin
            if (s_wlast[p]) $fatal(1, "otpu_hbm_model ch%0d p%0d: WLAST early", CH, p);
            wcnt <= wcnt + 1;
          end
        end

        // perform the head operation, one a cycle, in arrival order (a write waits for its beats:
        // the bridge keeps one write in flight, so the queue's front is its first beat)
        if (oq.size() != 0 && cyc >= busy && (!oq[0].we || wa.size() >= oq[0].n2)) begin
          op_t o;
          longint t;
          o = oq[0];
          t = cyc;
          if (dram != 0) t = dram_slot(p, int'(o.a0[30:6]), o.we, cyc);
          busy = t + 1;
          if (!o.we) begin
            longint due;
            due = t + longint'(lat) + longint'($urandom % 8);
            if (due <= rlast) due = rlast + 1;
            rlast = due + longint'(o.n2 - 1);
            for (int j = 0; j < o.n2; j++) begin
              longint a;
              int bt, h;
              a = longint'(o.a0) + 32 * j;
              bt = int'(a[30:6]); h = int'(a[5]);
              rq.push_back('{due + j, o.id, mem[bt][256 * h +: 256], 1'(j == o.n2 - 1)});
            end
            if (ecc != 0) begin
              if (ecc_ce != 0 && ($urandom % 100) < ecc_ce) n_ce[p]++;
              if (ecc_ue != 0 && ($urandom % 100) < ecc_ue) n_ue[p]++;
            end
            n_rd[p]++;
          end else begin
            longint due;
            due = t + longint'(lat) + longint'($urandom % 8);
            if (due <= blast) due = blast + 1;
            blast = due;
            for (int j = 0; j < o.n2; j++) begin
              longint a;
              int bt, h;
              logic [287:0] w;
              a = longint'(o.a0) + 32 * j;
              bt = int'(a[30:6]); h = int'(a[5]);
              w = wa[0]; void'(wa.pop_front());
              for (int q = 0; q < 32; q++)
                if (w[256 + q]) mem[bt][256 * h + 8 * q +: 8] <= w[8 * q +: 8];
            end
            bq.push_back('{due, o.id});
            n_wr[p]++;
          end
          void'(oq.pop_front());
        end

        // R beats out (in order within the port), on the channel's one read bus: the round-robin
        // grants at most one port a cycle; a beat accepted this cycle frees the port to load the
        // next, an unaccepted one holds the bus
        if (r_gnt[p]) begin
          if (!r_have[p]) begin
            r_have[p] <= 1'b1; r_id[p] <= rq[0].id; r_d[p] <= rq[0].d; r_last[p] <= rq[0].last;
            void'(rq.pop_front());
          end else if (s_rready[p]) begin
            if (rq.size() != 0 && rq[0].t <= cyc) begin
              r_id[p] <= rq[0].id; r_d[p] <= rq[0].d; r_last[p] <= rq[0].last;
              void'(rq.pop_front());
            end else begin
              r_have[p] <= 1'b0;
            end
          end
        end
        // B responses out (in order)
        if (!s_bvalid[p] || s_bready[p]) begin
          s_bvalid[p] <= 1'b0;
          if (bq.size() != 0 && bq[0].t <= cyc) begin
            s_bvalid[p] <= 1'b1; s_bid[p] <= bq[0].id;
            void'(bq.pop_front());
          end
        end
      end
    end
  end

  string dir;
  integer fd, nread;
  logic [31:0] words [BEATS * 16];
  initial begin
    int seed;
    void'($value$plusargs("hbm_lat=%d", lat));
    void'($value$plusargs("hbm_stall=%d", stall));
    void'($value$plusargs("hbm_dram=%d", dram));
    void'($value$plusargs("hbm_ecc=%d", ecc));
    void'($value$plusargs("hbm_ecc_ce=%d", ecc_ce));
    void'($value$plusargs("hbm_ecc_ue=%d", ecc_ue));
    void'($value$plusargs("hbm_trcd=%d", trcd));
    void'($value$plusargs("hbm_trp=%d", trp));
    void'($value$plusargs("hbm_tras=%d", tras));
    void'($value$plusargs("hbm_trc=%d", trc));
    void'($value$plusargs("hbm_trtp=%d", trtp));
    void'($value$plusargs("hbm_trefi=%d", trefi));
    void'($value$plusargs("hbm_trfc=%d", trfc));
    void'($value$plusargs("hbm_tturn=%d", tturn));
    void'($value$plusargs("hbm_nbk=%d", nbk));
    if ($value$plusargs("hbm_seed=%d", seed)) void'($urandom(seed));
    for (int i = 0; i < BEATS; i++) mem[i] = '0;
    if (IMG && $value$plusargs("dir=%s", dir)) begin
      for (int i = 0; i < BEATS * 16; i++) words[i] = '0;
      fd = $fopen($sformatf("%s/ch%0d.bin", dir, CH), "rb");
      if (fd != 0) begin
        nread = $fread(words, fd);
        $fclose(fd);
      end
      for (int i = 0; i < BEATS * 16; i++) mem[i / 16][32 * (i % 16) +: 32] = words[i];
    end
  end
  // dump may span several cycles (it is driven in the caller's clock): its first
  logic dump_q = 1'b0;
  always_ff @(posedge clk) dump_q <= dump;
  always_ff @(posedge clk) if (dump && !dump_q) begin
    longint trd, twr, tce, tue;
    trd = 0; twr = 0; tce = 0; tue = 0;
    for (int i = 0; i < NP; i++) begin
      trd += n_rd[i]; twr += n_wr[i]; tce += n_ce[i]; tue += n_ue[i];
    end
    $display("HBM ch%0d rd=%0d wr=%0d ce=%0d ue=%0d", CH, trd, twr, tce, tue);
    if (IMG) begin
      fd = $fopen($sformatf("%s/ch%0d_out.bin", dir, CH), "wb");
      for (int i = 0; i < BEATS * 16; i++) $fwrite(fd, "%u", mem[i / 16][32 * (i % 16) +: 32]);
      $fclose(fd);
    end
  end
endmodule
