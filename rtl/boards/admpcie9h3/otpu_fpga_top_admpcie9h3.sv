// FPGA top for the ADM-PCIE-9H3 (xcvu35p-fsvh2104-2-e; docs/admpcie9h3.md, planned): the block
// design (XDMA Gen3 x16, the SYSMONE4 and the control interconnect: boards/admpcie9h3/vivado/
// bd.tcl), the Xilinx HBM IP (8 used 256-bit AXI3 slave ports + the two APB register ports +
// HBM_REF_CLK), the AXI4-Lite -> APB bridge that reaches those registers from BAR0 0x800000, and
// otpu_admpcie9h3_sys: the accelerator (otpu_board, S = 2) and XDMA's DMA, meeting in one
// otpu_mem_ch per channel and one otpu_native_axi3 per native port (eight 256-bit AXI3 masters
// into the HBM IP). Cloned from otpu_fpga_top_bcu minus DDR4 and its four otpu_ld4 cores; there
// are no memory pins -- the HBM stacks are in the package.
//
// Clocks: the board's 300 MHz refclk300 (AY31/BA31, LVDS) on one IBUFDS feeds one MMCM (VCO
// 1200 MHz: x4 / 12, an even output divide, so the duty cycle is 50%) whose two 100 MHz outputs
// are the design's fabric clock and the IP's reference clock (M0.2 #1/#3; the board's own ES1
// build divides the same pin by three into HBM_REF_CLK, the 900 m build feeds 300 straight in --
// 100 is the only HBM_REF_CLK the 2024.2 catalog enumerates). core_clk is at once the
// accelerator's clock, the block design's control interconnect, the HBM AXI clock (hclk: all
// eight otpu_native_axi3 and the HBM IP's SAXI_*_ACLK) and the APB PCLK (100 MHz, within PG276's
// 50-100), so no HBM AXI or APB crossing is needed; hbm_ref_clk is HBM_REF_CLK_0/1 on its own
// buffer (the IP's scoped XDC owns that clock). The MMCM is not decoration: the HBM IP's APB
// macro (BLI_HBM_APB_INTF) wants a 5 ns pulse at 100 MHz, which M2's BUFGCE_DIV / 3 (33% duty)
// missed by 1.667 ns (WPWS, 2 endpoints). otpu_mem_ch still crosses the accelerator's core domain
// into xdma_aclk as the DDR boards do. XDMA's clocks come from the block design. There is no 2x
// clock, so TMEM_PMP is 0 (the TMEM is not pumped).
// Resets: sys_rst_n (AW27, the board's reset) synchronised into core_clk is core_rstn, the
// asynchronous-assert / synchronous-release reset of the fabric, the HBM IP's SAXI_*_ARESET_N and
// the APB PRESET_N; xdma_aresetn from the block design is XDMA's, registered into core_clk as the
// block design's reset (ctl_mrst), as the BCU1525 top brings its SmartConnect's reset into
// core_clk.
//
// The HBM IP is a Vivado-generated IP (M3): lint needs the port-list stand-in
// boards/admpcie9h3/sim/hbm_ip_stub.sv. The AXI4-Lite -> APB bridge is real RTL
// (rtl/boards/admpcie9h3/otpu_axi_apb_bridge.sv: the catalog xilinx.com:ip:axi_apb_bridge v3.0 does
// not offer the two APB masters with the stack decode this needs, M3).
//
// LEDs (the board's USER_LEDs are active low): USER_LED_A0 the accelerator's heartbeat
// (board_led[0]), USER_LED_G0 PCIe link up and every channel's HBM ready (apb_complete_0/1),
// USER_LED_G1 the accelerator runs or halted cleanly (as the BCU1525 top's led[2]). There is no
// UART or I2C in the design (the HBM IP brings itself up and reports through apb_complete_0/1 and
// its APB registers; the ADM's AVR UART is unused).
//
// The parameters are the target's (targets/admpcie9h3.toml: opentpu.target rtl_params; the
// defaults are its values, tests/test_target.py).
module otpu_fpga_top_admpcie9h3 #(
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
  parameter int TMEM_IMPL  = 0,             // TMEM: 0 a copy per read port, 3 one copy (otpu_board)
  parameter int TMEM_NSB   = 8,
  parameter int TMEM_SBP   = 3,
  parameter int TMEM_SBH   = 0,
  parameter bit TMEM_RPL   = 1'b0,
  parameter bit TMEM_TDP   = 1'b0,
  parameter bit TMEM_GST   = 1'b0,
  parameter int TMEM_PMP   = 0,             // must be 0: the HBM top makes no 2x clock
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
  parameter int CORE_KHZ   = 100000,        // core_clk as the MMCM makes it
  parameter logic [31:0] BUILD_ID = 32'h0,  // the git commit (BUILD_ID register)
  parameter int DDR_MTS    = 1000,          // the HBM data rate the IP runs at (DDR_MTS; mem_mts)
  parameter bit SEQ_WC     = 1'b0,          // otpu_seq's wait entries (WAITC, CFG_UARCH bit24)
  parameter int PLATFORM   = 3,             // targets/admpcie9h3.toml (CFG_PLATFORM)
  parameter logic [31:0] ARCH_HASH = 32'h0, // its arch_hash (CFG_HASH; M3)
  parameter int PCIE_LANES = 16             // Gen3 x16
) (
  // ---- board: the 300 MHz fabric clock and the PCIe pins
  input  logic        refclk300_p,
  input  logic        refclk300_n,
  input  logic        sys_clk_p,
  input  logic        sys_clk_n,
  input  logic        sys_rst_n,
  input  logic [PCIE_LANES-1:0] pcie_mgt_rxp,
  input  logic [PCIE_LANES-1:0] pcie_mgt_rxn,
  output logic [PCIE_LANES-1:0] pcie_mgt_txp,
  output logic [PCIE_LANES-1:0] pcie_mgt_txn,
  // the board's active-low USER_LED_G0/G1/A0
  output logic        user_led_g0_l,
  output logic        user_led_g1_l,
  output logic        user_led_a0_l
);
  localparam int NC = 2 * S;
`ifndef SYNTHESIS
  initial begin
    if (S != 2) $fatal(1, "otpu_fpga_top_admpcie9h3: S = 2 (four HBM channels, two per slice)");
    if (TMEM_PMP != 0) $fatal(1, "otpu_fpga_top_admpcie9h3: TMEM_PMP 0 (the HBM top makes no 2x clock)");
  end
`endif

  // ---- clocks: refclk300 -> one MMCM (VCO 1200 MHz = 300 x 4 / 1, output divide 12) = 100 MHz,
  // twice: core_clk (the fabric clock, the HBM AXI clock and the APB PCLK) and hbm_ref_clk (the
  // IP's HBM_REF_CLK_0/1, 100 MHz). The output divide is even, so the duty cycle is 50%: the HBM
  // IP's APB macro (BLI_HBM_APB_INTF) wants a 5 ns pulse at 100 MHz, which a BUFGCE_DIV / 3 (33%)
  // does not give. They are the same frequency from the same VCO but on their own buffers: the
  // IP's scoped XDC (hdl/par/hbm_ip.xdc, `create_clock -period 10.00 [get_ports HBM_REF_CLK_0/1]`)
  // then owns the reference clock without colliding with the fabric clock that runs everywhere
  // else.
  logic refclk300_ib, core_clk_mmcm, hbm_ref_clk_mmcm, mmcm_fb, mmcm_locked;
  logic core_clk, hbm_ref_clk;
  IBUFDS u_ib300 (.I(refclk300_p), .IB(refclk300_n), .O(refclk300_ib));
  // MMCME4_BASE: internal feedback (the BASE primitive has no COMPENSATION knob; CLKFBOUT loops
  // straight back to CLKFBIN).
  MMCME4_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT_F(4.0),      // VCO = 300 MHz x 4 / 1 = 1200 MHz
    .CLKIN1_PERIOD(3.334),
    .CLKOUT0_DIVIDE_F(12.0),    // 1200 / 12 = 100 MHz (even: 50% duty)
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT1_DIVIDE(12),        // 100 MHz for HBM_REF_CLK_0/1
    .CLKOUT1_DUTY_CYCLE(0.5)
  ) u_mmcm (
    .CLKIN1(refclk300_ib), .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb),
    .CLKOUT0(core_clk_mmcm), .CLKOUT1(hbm_ref_clk_mmcm),
    .LOCKED(mmcm_locked), .PWRDWN(1'b0), .RST(1'b0)
  );
  BUFG u_bufg_core (.I(core_clk_mmcm), .O(core_clk));
  BUFG u_bufg_hbm  (.I(hbm_ref_clk_mmcm), .O(hbm_ref_clk));

  // reset: sys_rst_n (asynchronous) and the MMCM's lock, synchronised into core_clk
  (* ASYNC_REG = "TRUE" *) logic [2:0] core_rstn_s = '0;
  always_ff @(posedge core_clk) core_rstn_s <= {core_rstn_s[1:0], sys_rst_n & mmcm_locked};
  logic core_rstn, core_rst;
  assign core_rstn = core_rstn_s[2];
  always_ff @(posedge core_clk) core_rst <= !core_rstn;

  // ---- the block design (XDMA PCIe + SYSMONE4, its DMA and the control interconnect)
  logic        pcie_link_up, xdma_aclk, xdma_aresetn;
  logic [9:0]  device_temp;                 // SYSMONE4 die-temperature code
  // control (AXI4-Lite, core_clk): the accelerator's registers, and the HBM APB window
  logic [31:0] ctl_awaddr, ctl_araddr, ctl_wdata, ctl_rdata;
  logic [31:0] hbm_awaddr, hbm_araddr, hbm_wdata, hbm_rdata;
  logic [3:0]  ctl_wstrb, hbm_wstrb;
  logic [1:0]  ctl_bresp, ctl_rresp, hbm_bresp, hbm_rresp;
  logic ctl_awvalid, ctl_awready, ctl_wvalid, ctl_wready, ctl_bvalid, ctl_bready;
  logic ctl_arvalid, ctl_arready, ctl_rvalid, ctl_rready;
  logic hbm_awvalid, hbm_awready, hbm_wvalid, hbm_wready, hbm_bvalid, hbm_bready;
  logic hbm_arvalid, hbm_arready, hbm_rvalid, hbm_rready;
  // XDMA's DMA per board channel (AXI4, 128 bits, xdma_aclk), [j]
  logic [NC-1:0][32:0]  dm_awaddr, dm_araddr;
  logic [NC-1:0][7:0]   dm_awlen, dm_arlen;
  logic [NC-1:0][127:0] dm_wdata, dm_rdata;
  logic [NC-1:0][15:0]  dm_wstrb;
  logic [NC-1:0][1:0]   dm_bresp, dm_rresp;
  logic [NC-1:0] dm_awvalid, dm_awready, dm_wvalid, dm_wready, dm_wlast, dm_bvalid, dm_bready;
  logic [NC-1:0] dm_arvalid, dm_arready, dm_rvalid, dm_rready, dm_rlast;

`define BD_LITE(P, Q) \
    .P``_awaddr(Q``_awaddr), .P``_awvalid(Q``_awvalid), .P``_awready(Q``_awready), \
    .P``_wdata(Q``_wdata), .P``_wstrb(Q``_wstrb), .P``_wvalid(Q``_wvalid), \
    .P``_wready(Q``_wready), .P``_bresp(Q``_bresp), .P``_bvalid(Q``_bvalid), \
    .P``_bready(Q``_bready), .P``_araddr(Q``_araddr), .P``_arvalid(Q``_arvalid), \
    .P``_arready(Q``_arready), .P``_rdata(Q``_rdata), .P``_rresp(Q``_rresp), \
    .P``_rvalid(Q``_rvalid), .P``_rready(Q``_rready)
`define BD_DMA(J) \
    .M_AXI_DMA``J``_awaddr(dm_awaddr[J]), .M_AXI_DMA``J``_awlen(dm_awlen[J]), \
    .M_AXI_DMA``J``_awvalid(dm_awvalid[J]), .M_AXI_DMA``J``_awready(dm_awready[J]), \
    .M_AXI_DMA``J``_wdata(dm_wdata[J]), .M_AXI_DMA``J``_wstrb(dm_wstrb[J]), \
    .M_AXI_DMA``J``_wlast(dm_wlast[J]), .M_AXI_DMA``J``_wvalid(dm_wvalid[J]), \
    .M_AXI_DMA``J``_wready(dm_wready[J]), .M_AXI_DMA``J``_bresp(dm_bresp[J]), \
    .M_AXI_DMA``J``_bvalid(dm_bvalid[J]), .M_AXI_DMA``J``_bready(dm_bready[J]), \
    .M_AXI_DMA``J``_araddr(dm_araddr[J]), .M_AXI_DMA``J``_arlen(dm_arlen[J]), \
    .M_AXI_DMA``J``_arvalid(dm_arvalid[J]), .M_AXI_DMA``J``_arready(dm_arready[J]), \
    .M_AXI_DMA``J``_rdata(dm_rdata[J]), .M_AXI_DMA``J``_rresp(dm_rresp[J]), \
    .M_AXI_DMA``J``_rlast(dm_rlast[J]), .M_AXI_DMA``J``_rvalid(dm_rvalid[J]), \
    .M_AXI_DMA``J``_rready(dm_rready[J])
  otpu_bd_wrapper u_bd (
    .core_clk(core_clk),
    .sys_clk_p(sys_clk_p), .sys_clk_n(sys_clk_n), .sys_rst_n(sys_rst_n),
    .pcie_mgt_rxp, .pcie_mgt_rxn, .pcie_mgt_txp, .pcie_mgt_txn,
    .pcie_link_up, .xdma_aclk, .xdma_aresetn, .device_temp,
    `BD_LITE(M_AXI_CTL, ctl),
    `BD_LITE(M_AXI_HBM, hbm),
    `BD_DMA(0), `BD_DMA(1), `BD_DMA(2), `BD_DMA(3));
`undef BD_LITE
`undef BD_DMA

  // resets: xdma_aresetn registered in its domain, then in core_clk where the block design's
  // control masters are (the SmartConnect's reset, as the BCU1525 top)
  logic xrst;
  always_ff @(posedge xdma_aclk) xrst <= !xdma_aresetn;
  (* ASYNC_REG = "TRUE" *) logic lrs1 = 1'b1, lrs2 = 1'b1;
  always_ff @(posedge core_clk) begin lrs1 <= xrst; lrs2 <= lrs1; end

  // ---- board channel j <-> the card's HBM channels (channel j at j * 2 GiB), and the
  // accelerator's native masters
  logic [NC-1:0]             calib, ded;
  logic                      apb_complete_0, apb_complete_1;   // the HBM IP's "HBM ready"
  // the eight AXI3 masters into the HBM IP, [channel][native port]
  logic [NC-1:0][1:0]          m_arvalid, m_awvalid, m_wvalid, m_bready, m_rready;
  logic [NC-1:0][1:0][32:0]    m_araddr, m_awaddr;
  logic [NC-1:0][1:0][5:0]     m_arid, m_awid, m_bid, m_rid;
  logic [NC-1:0][1:0][7:0]     m_arlen, m_awlen;
  logic [NC-1:0][1:0][2:0]     m_arsize, m_awsize;
  logic [NC-1:0][1:0][1:0]     m_arburst, m_awburst, m_bresp, m_rresp;
  logic [NC-1:0][1:0][255:0]   m_wdata, m_rdata;
  logic [NC-1:0][1:0][31:0]    m_wstrb;
  logic [NC-1:0][1:0]          m_arready, m_awready, m_wready, m_wlast, m_bvalid, m_rvalid, m_rlast;
  // the accelerator and XDMA on the channels: XDMA's DMA in xclk, the bridges in hclk
  logic [NC-1:0][30:0] dm_awaddr_c, dm_araddr_c;
  for (genvar j = 0; j < NC; j++) begin : g_dma
    assign dm_awaddr_c[j] = dm_awaddr[j][30:0];
    assign dm_araddr_c[j] = dm_araddr[j][30:0];
  end
  wire clk_f = 1'b0;                        // TMEM_PMP 0 (no 2x clock)
  logic [2:0] board_led;
  logic [3:0] i2c_lo;                       // HAS_I2C 0: unused (held out of reset/high by the shell)
  otpu_admpcie9h3_sys #(.S(S), .D(D), .MCOLS(MCOLS), .ACT_ROWS(ACT_ROWS),
                 .ACT_BLOCKS(ACT_BLOCKS), .TMEM_WORDS(TMEM_WORDS), .IMEM_WORDS(IMEM_WORDS),
                 .FIFO_DEPTH(FIFO_DEPTH), .LANES(LANES), .WIN(WIN), .RPB(RPB), .WPB(WPB),
                 .MXU_IMPL(MXU_IMPL), .MXU_CL(MXU_CL), .VPU_CL(VPU_CL), .ULANES(ULANES),
                 .TRACE_DEPTH(TRACE_DEPTH), .PQ_WIN(PQ_WIN), .CHASH(CHASH), .DSTEP(DSTEP),
                 .CORE_KHZ(CORE_KHZ), .BUILD_ID(BUILD_ID), .SEQ_WC(SEQ_WC), .DDR_MTS(DDR_MTS),
                 .PLATFORM(PLATFORM), .ARCH_HASH(ARCH_HASH), .TMEM_IMPL(TMEM_IMPL),
                 .TMEM_NSB(TMEM_NSB), .TMEM_SBP(TMEM_SBP), .TMEM_SBH(TMEM_SBH), .TMEM_RPL(TMEM_RPL),
                 .TMEM_TDP(TMEM_TDP), .TMEM_GST(TMEM_GST), .TMEM_PMP(TMEM_PMP), .TMEM_PRK(TMEM_PRK),
                 .TMEM_SDM(TMEM_SDM)) u_sys (
    .clk(core_clk), .clk_f, .rst(core_rst), .ctl_mrst(lrs2), .xclk(xdma_aclk), .xrst,
    .hclk(core_clk), .hrst(core_rst),
    .calib, .ded, .temp({device_temp, 2'b00}), .led(board_led), .i2c_lo(i2c_lo),
    .i2c_pin(5'b11111),
    .s_ctl_awaddr(ctl_awaddr[11:0]), .s_ctl_awvalid(ctl_awvalid), .s_ctl_awready(ctl_awready),
    .s_ctl_wdata(ctl_wdata), .s_ctl_wstrb(ctl_wstrb), .s_ctl_wvalid(ctl_wvalid),
    .s_ctl_wready(ctl_wready), .s_ctl_bresp(ctl_bresp), .s_ctl_bvalid(ctl_bvalid),
    .s_ctl_bready(ctl_bready), .s_ctl_araddr(ctl_araddr[11:0]), .s_ctl_arvalid(ctl_arvalid),
    .s_ctl_arready(ctl_arready), .s_ctl_rdata(ctl_rdata), .s_ctl_rresp(ctl_rresp),
    .s_ctl_rvalid(ctl_rvalid), .s_ctl_rready(ctl_rready),
    .x_awvalid(dm_awvalid), .x_awready(dm_awready), .x_awaddr(dm_awaddr_c), .x_awlen(dm_awlen),
    .x_wvalid(dm_wvalid), .x_wready(dm_wready), .x_wdata(dm_wdata), .x_wstrb(dm_wstrb),
    .x_wlast(dm_wlast), .x_bvalid(dm_bvalid), .x_bready(dm_bready), .x_bresp(dm_bresp),
    .x_arvalid(dm_arvalid), .x_arready(dm_arready), .x_araddr(dm_araddr_c), .x_arlen(dm_arlen),
    .x_rvalid(dm_rvalid), .x_rready(dm_rready), .x_rdata(dm_rdata), .x_rresp(dm_rresp),
    .x_rlast(dm_rlast),
    .m_arvalid, .m_arready, .m_araddr, .m_arid, .m_arlen, .m_arsize, .m_arburst,
    .m_awvalid, .m_awready, .m_awaddr, .m_awid, .m_awlen, .m_awsize, .m_awburst,
    .m_wvalid, .m_wready, .m_wdata, .m_wstrb, .m_wlast,
    .m_bvalid, .m_bready, .m_bid, .m_bresp,
    .m_rvalid, .m_rready, .m_rid, .m_rdata, .m_rresp, .m_rlast);

  // HBM ready: stack 0 covers channels 0-1 (0-4 GiB) and stack 1 channels 2-3 (4-8 GiB); there is
  // no ECC counter to read yet (ded 0)
  for (genvar j = 0; j < NC; j++) begin : g_status
    assign calib[j] = j < NC / 2 ? apb_complete_0 : apb_complete_1;
  end
  assign ded = '0;

  // ---- the AXI4-Lite -> APB bridge into the HBM IP's registers (BAR0 0x800000)
  logic [21:0] apb0_paddr, apb1_paddr;
  logic [31:0] apb0_pwdata, apb1_pwdata, apb0_prdata, apb1_prdata;
  logic apb0_penable, apb0_psel, apb0_pwrite, apb1_penable, apb1_psel, apb1_pwrite;
  logic apb0_pready, apb0_pslverr, apb1_pready, apb1_pslverr;
  otpu_axi_apb_bridge u_apb (
    .clk(core_clk), .rst(core_rst),
    .s_axi_awaddr(hbm_awaddr), .s_axi_awvalid(hbm_awvalid), .s_axi_awready(hbm_awready),
    .s_axi_wdata(hbm_wdata), .s_axi_wstrb(hbm_wstrb), .s_axi_wvalid(hbm_wvalid),
    .s_axi_wready(hbm_wready), .s_axi_bresp(hbm_bresp), .s_axi_bvalid(hbm_bvalid),
    .s_axi_bready(hbm_bready), .s_axi_araddr(hbm_araddr), .s_axi_arvalid(hbm_arvalid),
    .s_axi_arready(hbm_arready), .s_axi_rdata(hbm_rdata), .s_axi_rresp(hbm_rresp),
    .s_axi_rvalid(hbm_rvalid), .s_axi_rready(hbm_rready),
    .apb0_paddr, .apb0_penable, .apb0_psel, .apb0_pwrite, .apb0_pwdata,
    .apb0_prdata, .apb0_pready, .apb0_pslverr,
    .apb1_paddr, .apb1_penable, .apb1_psel, .apb1_pwrite, .apb1_pwdata,
    .apb1_prdata, .apb1_pready, .apb1_pslverr);

  // ---- the HBM IP (the generated `hbm_ip` IP in Vivado; sim/hbm_ip_stub.sv for lint, same
  // module name): the eight AXI3 masters, one per native port, onto AXI_00..07. AXI3 per PG276:
  // 4-bit AWLEN/ARLEN (the bridge bursts are two beats), no AWLOCK/AWCACHE/AWPROT/AWQOS (the IP
  // has none), a 32-bit WDATA_PARITY (tied 0: the IP's parity is off) and a 32-bit RDATA_PARITY
  // output (unused). AXI_0n_ACLK / ARESET_N and the APB PCLK/PRESET_N are all core_clk/core_rstn.
`define HBM_AXI(N, J, P) \
    .AXI_``N``_ACLK(core_clk), .AXI_``N``_ARESET_N(core_rstn), \
    .AXI_``N``_AWADDR(m_awaddr[J][P]), .AXI_``N``_AWID(m_awid[J][P]), \
    .AXI_``N``_AWLEN(m_awlen[J][P][3:0]), .AXI_``N``_AWSIZE(m_awsize[J][P]), \
    .AXI_``N``_AWBURST(m_awburst[J][P]), \
    .AXI_``N``_AWVALID(m_awvalid[J][P]), .AXI_``N``_AWREADY(m_awready[J][P]), \
    .AXI_``N``_WDATA(m_wdata[J][P]), .AXI_``N``_WSTRB(m_wstrb[J][P]), \
    .AXI_``N``_WDATA_PARITY(32'h0), \
    .AXI_``N``_WLAST(m_wlast[J][P]), .AXI_``N``_WVALID(m_wvalid[J][P]), \
    .AXI_``N``_WREADY(m_wready[J][P]), \
    .AXI_``N``_BID(m_bid[J][P]), .AXI_``N``_BRESP(m_bresp[J][P]), \
    .AXI_``N``_BVALID(m_bvalid[J][P]), .AXI_``N``_BREADY(m_bready[J][P]), \
    .AXI_``N``_ARADDR(m_araddr[J][P]), .AXI_``N``_ARID(m_arid[J][P]), \
    .AXI_``N``_ARLEN(m_arlen[J][P][3:0]), .AXI_``N``_ARSIZE(m_arsize[J][P]), \
    .AXI_``N``_ARBURST(m_arburst[J][P]), \
    .AXI_``N``_ARVALID(m_arvalid[J][P]), .AXI_``N``_ARREADY(m_arready[J][P]), \
    .AXI_``N``_RID(m_rid[J][P]), .AXI_``N``_RDATA(m_rdata[J][P]), \
    .AXI_``N``_RDATA_PARITY(), \
    .AXI_``N``_RRESP(m_rresp[J][P]), .AXI_``N``_RLAST(m_rlast[J][P]), \
    .AXI_``N``_RVALID(m_rvalid[J][P]), .AXI_``N``_RREADY(m_rready[J][P])
  hbm_ip u_hbm (
    .HBM_REF_CLK_0(hbm_ref_clk), .HBM_REF_CLK_1(hbm_ref_clk),
    .apb_complete_0(apb_complete_0), .apb_complete_1(apb_complete_1),
    .DRAM_0_STAT_CATTRIP(), .DRAM_0_STAT_TEMP(), .DRAM_1_STAT_CATTRIP(), .DRAM_1_STAT_TEMP(),
    .APB_0_PCLK(core_clk), .APB_0_PRESET_N(core_rstn), .APB_0_PADDR(apb0_paddr),
    .APB_0_PENABLE(apb0_penable), .APB_0_PSEL(apb0_psel), .APB_0_PWRITE(apb0_pwrite),
    .APB_0_PWDATA(apb0_pwdata), .APB_0_PRDATA(apb0_prdata), .APB_0_PREADY(apb0_pready),
    .APB_0_PSLVERR(apb0_pslverr),
    .APB_1_PCLK(core_clk), .APB_1_PRESET_N(core_rstn), .APB_1_PADDR(apb1_paddr),
    .APB_1_PENABLE(apb1_penable), .APB_1_PSEL(apb1_psel), .APB_1_PWRITE(apb1_pwrite),
    .APB_1_PWDATA(apb1_pwdata), .APB_1_PRDATA(apb1_prdata), .APB_1_PREADY(apb1_pready),
    .APB_1_PSLVERR(apb1_pslverr),
    `HBM_AXI(00, 0, 0),
    `HBM_AXI(01, 0, 1),
    `HBM_AXI(02, 1, 0),
    `HBM_AXI(03, 1, 1),
    `HBM_AXI(04, 2, 0),
    `HBM_AXI(05, 2, 1),
    `HBM_AXI(06, 3, 0),
    `HBM_AXI(07, 3, 1)
  );
`undef HBM_AXI

  // LEDs: USER_LED_A0 heartbeat, G0 PCIe link up and every channel's HBM ready, G1 the
  // accelerator runs or halted cleanly (the board's USER_LEDs are active low)
  assign user_led_a0_l = ~board_led[0];
  assign user_led_g0_l = ~(pcie_link_up & (&calib));
  assign user_led_g1_l = ~(board_led[2] | board_led[1]);
endmodule
