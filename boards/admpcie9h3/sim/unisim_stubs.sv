// Lint-only stand-ins for the unisim buffers otpu_fpga_top_admpcie9h3 instantiates (no behaviour):
// `make lint` checks the top offline; Vivado builds with the real primitives. MMCME4_BASE is the
// board's clock generator (refclk300 x 4 / 12 = 100 MHz, an even divide: 50% duty), BUFG its output
// buffer.
module IBUFDS (input logic I, input logic IB, output logic O);
  assign O = I;
endmodule

module BUFG (input logic I, output logic O);
  assign O = I;
endmodule

module MMCME4_BASE #(
  parameter BANDWIDTH              = "OPTIMIZED",
  parameter real CLKFBOUT_MULT_F   = 5.000,
  parameter real CLKFBOUT_PHASE    = 0.000,
  parameter real CLKIN1_PERIOD     = 0.000,
  parameter real CLKOUT0_DIVIDE_F  = 1.000,
  parameter real CLKOUT0_DUTY_CYCLE = 0.500,
  parameter real CLKOUT0_PHASE     = 0.000,
  parameter integer CLKOUT1_DIVIDE = 1,
  parameter real CLKOUT1_DUTY_CYCLE = 0.500,
  parameter real CLKOUT1_PHASE     = 0.000,
  parameter integer DIVCLK_DIVIDE  = 1,
  parameter real REF_JITTER1       = 0.010,
  parameter STARTUP_WAIT           = "FALSE"
) (
  input  logic CLKIN1,
  input  logic CLKFBIN,
  input  logic PWRDWN,
  input  logic RST,
  output logic CLKFBOUT,
  output logic CLKOUT0,
  output logic CLKOUT1,
  output logic LOCKED
);
  assign CLKFBOUT = CLKIN1;
  assign CLKOUT0  = CLKIN1;
  assign CLKOUT1  = CLKIN1;
  assign LOCKED   = 1'b1;
endmodule

module IOBUF (inout wire IO, input logic I, input logic T, output logic O);
  assign IO = T ? 1'bz : I;
  assign O = IO;
endmodule
