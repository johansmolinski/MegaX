// MegaX tb/hrmem: the HyperRAM arbiter's core port as x68_hrmem sees it (Avalon, 16-bit words,
// 4M words). Random waitrequest, read latency 10..39 clocks, random gaps between read words,
// and every 3000 clocks a 250-clock stretch with waitrequest held (ascal's bursts first).
`timescale 1ps/1ps
module avl_model (
   input             clk,
   input             write,
   input             read,
   input      [31:0] address,
   input      [15:0] writedata,
   input      [1:0]  byteenable,
   input      [7:0]  burstcount,
   output reg [15:0] readdata,
   output reg        readdatavalid,
   output            waitrequest
);
   reg [15:0] mem [0:(1<<22)-1];
   int unsigned seed = 7;
   int  cyc = 0;
   int  rd_pend = 0, rd_lat = 0;          // read words still to come, clocks until the first
   reg [21:0] rd_addr;
   int  wr_left = 0;
   reg [21:0] wr_addr;
   reg  wait_r = 1;
   wire hog = (cyc % 3000) < 250;
   assign waitrequest = wait_r | hog | (rd_pend != 0);
   int  n_rd = 0, n_wr = 0, n_rw = 0, n_ww = 0;

   always @(posedge clk) begin
      cyc <= cyc + 1;
      readdatavalid <= 0;
      // a read in progress
      if (rd_pend != 0) begin
         if (rd_lat > 0) rd_lat <= rd_lat - 1;
         else if ($urandom() % 8 != 0) begin
            readdata <= mem[rd_addr];
            readdatavalid <= 1;
            rd_addr <= rd_addr + 1;
            rd_pend <= rd_pend - 1;
            n_rw <= n_rw + 1;
         end
      end
      if (!waitrequest && read) begin
         if (write) $fatal(1, "avl_model: read and write together");
         if (burstcount == 0) $fatal(1, "avl_model: read burstcount 0");
         rd_addr <= address[21:0];
         rd_pend <= burstcount;
         rd_lat  <= 10 + $urandom() % 30;
         n_rd <= n_rd + 1;
      end
      if (!waitrequest && write) begin
         reg [21:0] a;
         int left;
         if (wr_left == 0) begin
            if (burstcount == 0) $fatal(1, "avl_model: write burstcount 0");
            a = address[21:0]; left = burstcount; n_wr <= n_wr + 1;
         end else begin
            a = wr_addr; left = wr_left;
         end
         if (byteenable[1]) mem[a][15:8] <= writedata[15:8];
         if (byteenable[0]) mem[a][7:0]  <= writedata[7:0];
         wr_addr <= a + 1;
         wr_left <= left - 1;
         n_ww <= n_ww + 1;
      end
      wait_r <= ($urandom() % 4 == 0);
   end
endmodule
