// otpu_axi_apb_bridge: an AXI4-Lite slave to two APB masters, the path from BAR0 to the Xilinx HBM
// IP's register ports (PG276). The block design's M_AXI_HBM master (AXI4-Lite, core_clk) reaches
// this from the top (otpu_fpga_top_admpcie9h3, BAR0 0x800000); APB_0 drives the IP's stack-0
// register port and APB_1 its stack-1 (HBM_IP APB_0_PADDR/APB_1_PADDR, 22 bits each).
//
// The HBM register space is a window of APB_AW bits per stack (M0.2 #3 / M2's stub): the stack is
// AXI address bit APB_AW, the APB address the low APB_AW bits. The window the block design assigns
// is 2 x 2^APB_AW (create_project.tcl: M_AXI_HBM at BAR0 0x800000, 8 MiB for APB_AW 22); the
// interconnect translates the BAR offset into a 0-based address here, so the low APB_AW bits are
// the IP's own PADDR (the top passes the full AXI address through).
//
// APB timing (AMBA): in SETUP, PSEL and PADDR/PWRITE/PWDATA are driven and PENABLE low; in ACCESS,
// PENABLE is high until PREADY. One transaction is outstanding at a time; an AXI write is taken
// when AW and W are both valid, an AXI read when AR is valid. BRESP/RRESP is OKAY, or SLVERR when
// the slave asserts PSLVERR. PCLK is core_clk (100 MHz, within PG276's 50-100), so no clock
// crossing: the two APB ports share it.
module otpu_axi_apb_bridge #(
  parameter int AW     = 32,             // AXI address width (the top's, and the bridge's, 32)
  parameter int DW     = 32,             // AXI / APB data width
  parameter int APB_AW = 22              // APB address width; bit APB_AW selects the stack
) (
  input  logic              clk,
  input  logic              rst,
  // AXI4-Lite slave (the block design's M_AXI_HBM master)
  input  logic [AW-1:0]     s_axi_awaddr,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [DW-1:0]     s_axi_wdata,
  input  logic [DW/8-1:0]   s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,
  input  logic [AW-1:0]     s_axi_araddr,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [DW-1:0]     s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,
  // APB master 0 (the IP's stack 0) and 1 (stack 1)
  output logic [APB_AW-1:0] apb0_paddr,
  output logic              apb0_penable, apb0_psel, apb0_pwrite,
  output logic [DW-1:0]     apb0_pwdata,
  input  logic [DW-1:0]     apb0_prdata,
  input  logic              apb0_pready, apb0_pslverr,
  output logic [APB_AW-1:0] apb1_paddr,
  output logic              apb1_penable, apb1_psel, apb1_pwrite,
  output logic [DW-1:0]     apb1_pwdata,
  input  logic [DW-1:0]     apb1_prdata,
  input  logic              apb1_pready, apb1_pslverr
);
  typedef enum logic [1:0] {T_IDLE, T_SETUP, T_ACCESS, T_RESP} st_t;
  st_t         st;
  logic        we;                       // the latched transaction: 1 write
  logic        sel;                      // ... its stack (APB_1 when 1)
  logic [APB_AW-1:0] paddr;              // ... its APB address
  logic [DW-1:0]     wdata;
  logic [31:0]       rdata;              // the read data, latched in ACCESS
  logic [1:0]        resp;

  // a write is taken when AW and W are both valid (and no read is ahead); a read otherwise
  logic wr_cmd;
  assign wr_cmd        = s_axi_awvalid && s_axi_wvalid;
  assign s_axi_awready = (st == T_IDLE) && s_axi_wvalid && !s_axi_arvalid;
  assign s_axi_wready  = (st == T_IDLE) && s_axi_awvalid && !s_axi_arvalid;
  assign s_axi_arready = (st == T_IDLE) && !wr_cmd;

  wire take_w = (st == T_IDLE) && wr_cmd;
  wire take_r = (st == T_IDLE) && s_axi_arvalid && !wr_cmd;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= T_IDLE;
    end else begin
      case (st)
        T_IDLE: if (take_w) begin
                  we    <= 1'b1;
                  sel   <= s_axi_awaddr[APB_AW];
                  paddr <= s_axi_awaddr[APB_AW-1:0];
                  wdata <= s_axi_wdata;
                  st    <= T_SETUP;
                end else if (take_r) begin
                  we    <= 1'b0;
                  sel   <= s_axi_araddr[APB_AW];
                  paddr <= s_axi_araddr[APB_AW-1:0];
                  st    <= T_SETUP;
                end
        T_SETUP:  st <= T_ACCESS;
        T_ACCESS: if (sel ? apb1_pready : apb0_pready) begin
                    rdata <= sel ? apb1_prdata : apb0_prdata;
                    resp  <= (sel ? apb1_pslverr : apb0_pslverr) ? 2'b10 : 2'b00;
                    st    <= T_RESP;
                  end
        T_RESP:   if (we ? s_axi_bready : s_axi_rready) st <= T_IDLE;
        default:  st <= T_IDLE;
      endcase
    end
  end

  // APB: the selected port is in SETUP (PSEL, PENABLE low) then ACCESS (PENABLE high)
  wire apb_act = (st == T_SETUP) || (st == T_ACCESS);
  always_comb begin
    apb0_psel    = apb_act && !sel;
    apb0_penable = (st == T_ACCESS) && !sel;
    apb0_pwrite  = we;
    apb0_paddr   = paddr;
    apb0_pwdata  = wdata;
    apb1_psel    = apb_act && sel;
    apb1_penable = (st == T_ACCESS) && sel;
    apb1_pwrite  = we;
    apb1_paddr   = paddr;
    apb1_pwdata  = wdata;
  end

  assign s_axi_bresp  = resp;
  assign s_axi_bvalid = (st == T_RESP) && we;
  assign s_axi_rdata  = rdata;
  assign s_axi_rresp  = resp;
  assign s_axi_rvalid = (st == T_RESP) && !we;

`ifndef SYNTHESIS
  // one outstanding APB transaction: PSEL implies the port is the selected one, and the returned
  // data is only used after PREADY
  always_ff @(posedge clk) if (!rst) begin
    if (apb0_psel && apb1_psel) $error("otpu_axi_apb_bridge: both stacks selected");
  end
`endif
endmodule
