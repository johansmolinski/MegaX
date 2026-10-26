// MegaX simulation: CACHEMEMWN for tvram_ddr.sv, which instantiates it from
// SystemVerilog. In the Verilog that ghdl writes, the VHDL entity
// (rtl/mega65/x68k_rams.vhd) only exists as per-generic copies with hashed names,
// so the simulation needs this twin. Same behaviour: write port on wrclock,
// registered read on rdclock. Vivado binds tvram_ddr.sv to the VHDL entity.
module CACHEMEMWN #(
   parameter int awidth  = 8,
   parameter     ramtype = "AUTO"
) (
   input  [15:0]       data,
   input  [awidth-1:0] rdaddress,
   input               rdclock,
   input  [awidth-1:0] wraddress,
   input               wrclock,
   input               wren,
   output reg [15:0]   q
);
   reg [15:0] ram [0:(1<<awidth)-1];

   always @(posedge wrclock)
      if (wren)
         ram[wraddress] <= data;

   always @(posedge rdclock)
      q <= ram[rdaddress];
endmodule
