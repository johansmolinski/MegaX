// MegaX tb/hrmem: x68_hrmem against the core's own SDRAM controller. The same random command
// stream (cachecont's kinds: whole-block and partial reads with wrap, bwidth 7 and 8, writes of
// 1..256 words with byte enables, refreshes, aborted reads) runs through SDRAMC with its chip
// model and through x68_hrmem with an Avalon HyperRAM model; every read's de words (addr_rc,
// rddat) and the word after them must agree. The HyperRAM side leaves its reset 30 us after the
// clk_ram side, so the first commands wait in the FIFO. Write data comes from a "cache RAM" with one
// clock of latency on addr_wc, as in cachecont.
`timescale 1ps/1ps
module tb_hrmem;
   localparam int NBLK = 12, NOPS = 4000;
   reg clk = 0;  always #6250 clk = ~clk;         // clk_ram 80 MHz
   reg hclk = 0; always #5000 hclk = ~hclk;        // hr_clk 100 MHz
   reg rstn = 0;
   reg hr_rst = 1;                                 // the HyperRAM side leaves reset 30 us later
   initial #30100000 hr_rst = 0;                   // (the first commands come before: tb/sim found them lost)

   // the command list
   typedef struct { int kind; int h; int b; int e; int bw; int abort_at; int seed; } cmd_t;
   cmd_t cmds [0:NOPS+NBLK-1];
   int  blk [0:NBLK-1] = '{'h0000, 'h0001, 'h0123, 'h1FFE, 'h1FFF, 'h7600, 'h7601,
                           'h77FE, 'h77FF, 'h7800, 'h7A55, 'h7FFF};
   int unsigned gseed = 12345;

   // results: per read the words (addr_rc << 16 | rddat), de words then the word after
   int unsigned res_s [0:NOPS+NBLK-1][0:259];
   int unsigned res_h [0:NOPS+NBLK-1][0:259];
   int          num_s [0:NOPS+NBLK-1];
   int          num_h [0:NOPS+NBLK-1];

   initial begin
      for (int i = 0; i < NBLK; i++) begin
         cmds[i] = '{kind: 1, h: blk[i], b: 0, e: 255, bw: 8, abort_at: 0, seed: 1000 + i};
      end
      for (int i = NBLK; i < NOPS + NBLK; i++) begin
         int r = $urandom() % 100;
         cmd_t c;
         c.h = blk[$urandom() % NBLK];
         c.seed = $urandom();
         c.abort_at = 0;
         if (r < 40) begin                                // write
            int len = ($urandom() % 4 == 0) ? 1 + $urandom() % 256 : 1 + $urandom() % 8;
            c.kind = 1; c.bw = 8;
            c.b = $urandom() % 256;
            if (c.b + len > 256) c.b = 256 - len;
            c.e = c.b + len - 1;
            if (c.b == 255 && c.e == 255) c.b = 254;      // SDRAMC writes bgn+1 too: not across the row
         end else if (r < 95) begin                       // read
            c.kind = 0; c.bw = ($urandom() % 2) ? 7 : 8;
            c.b = $urandom() % 256;
            if ($urandom() % 2) c.e = c.b;
            else begin
               c.e = $urandom() % 256;
               if (c.bw == 7) c.e = (c.e & 'h7F) | (c.b & 'h80);
            end
            if (r >= 90) c.abort_at = 3 + $urandom() % 100;
         end else begin
            c.kind = 2; c.b = 0; c.e = 0; c.bw = 8;       // refresh
         end
         cmds[i] = c;
      end
   end

   // the write data of command i, word w (both DUTs see the same)
   function automatic [17:0] wdata(int i, int w);
      int unsigned s = cmds[i].seed ^ (w * 2654435761);
      reg [1:0] we;
      s = s * 1103515245 + 12345;
      we = (cmds[i].kind == 1 && i < NBLK) ? 2'b11 : s[17:16];
      return {we, s[31:16] ^ w[15:0]};
   endfunction

   ////////////////////////////////////////////////////////////////////////////////////////
   // SDRAMC
   reg  [15:0] s_h = 0; reg [7:0] s_b = 0, s_e = 0; reg [3:0] s_bw = 8;
   reg  s_rd = 0, s_wr = 0, s_ref = 0, s_ab = 0;
   wire [7:0] s_arc, s_awc; wire [15:0] s_rddat; wire s_de, s_busy, s_init;
   reg  [15:0] s_wrdat; reg [1:0] s_we; int s_cur = 0;
   wire cke, csn, rasn, casn, wen, udq, ldq, ba1, ba0; wire [12:0] adr; wire [15:0] dat;
   SDRAMC u_s(.PMEMCKE(cke), .PMEMCS_N(csn), .PMEMRAS_N(rasn), .PMEMCAS_N(casn), .PMEMWE_N(wen),
      .PMemUdq(udq), .PMemLdq(ldq), .PMEMBA1(ba1), .PMEMBA0(ba0), .PMEMADR(adr), .PMEMDAT(dat),
      .addr_high(s_h), .bgnaddr(s_b), .endaddr(s_e), .bwidth(s_bw), .addr_rc(s_arc), .addr_wc(s_awc),
      .rddat(s_rddat), .wrdat(s_wrdat), .de(s_de), .we(s_we), .rd(s_rd), .wr(s_wr), .refrsh(s_ref),
      .abort(s_ab), .busy(s_busy), .initdone(s_init), .clk(clk), .ce(1'b1), .rstn(rstn));
   always @(posedge clk) {s_we, s_wrdat} <= wdata(s_cur, (s_awc - s_b) & 255);

   ////////////////////////////////////////////////////////////////////////////////////////
   // x68_hrmem
   reg  [15:0] h_h = 0; reg [7:0] h_b = 0, h_e = 0; reg [3:0] h_bw = 8;
   reg  h_rd = 0, h_wr = 0, h_ref = 0, h_ab = 0;
   wire [7:0] h_arc, h_awc; wire [15:0] h_rddat; wire h_de, h_busy, h_init;
   reg  [15:0] h_wrdat; reg [1:0] h_we; int h_cur = 0;
   wire a_wr, a_rd, a_val, a_wait; wire [31:0] a_addr; wire [15:0] a_wd, a_rdd; wire [1:0] a_be;
   wire [7:0] a_bc;
   x68_hrmem u_h(.clk_i(clk), .rstn_i(rstn), .addr_high_i(h_h), .bgnaddr_i(h_b), .endaddr_i(h_e),
      .bwidth_i(h_bw), .addr_rc_o(h_arc), .addr_wc_o(h_awc), .rddat_o(h_rddat), .wrdat_i(h_wrdat),
      .de_o(h_de), .we_i(h_we), .rd_i(h_rd), .wr_i(h_wr), .refrsh_i(h_ref), .abort_i(h_ab),
      .busy_o(h_busy), .initdone_o(h_init),
      .hr_clk_i(hclk), .hr_rst_i(hr_rst), .hr_write_o(a_wr), .hr_read_o(a_rd), .hr_address_o(a_addr),
      .hr_writedata_o(a_wd), .hr_byteenable_o(a_be), .hr_burstcount_o(a_bc), .hr_readdata_i(a_rdd),
      .hr_readdatavalid_i(a_val), .hr_waitrequest_i(a_wait));
   avl_model u_m(.clk(hclk), .write(a_wr), .read(a_rd), .address(a_addr), .writedata(a_wd),
      .byteenable(a_be), .burstcount(a_bc), .readdata(a_rdd), .readdatavalid(a_val), .waitrequest(a_wait));
   always @(posedge clk) {h_we, h_wrdat} <= wdata(h_cur, (h_awc - h_b) & 255);

   ////////////////////////////////////////////////////////////////////////////////////////
   // the drivers (cachecont's way: a one-clock request, then wait for busy low)
   int s_done = 0, h_done = 0;
   longint s_busy_clk = 0, h_busy_clk = 0;

   initial begin : drv_s
      #100000 rstn = 1;
      wait (s_init);
      for (int i = 0; i < NOPS + NBLK; i++) begin
         int t = 0; int n = 0;
         @(negedge clk);
         while (s_busy) @(negedge clk);
         s_cur = i; s_h = cmds[i].h; s_b = cmds[i].b; s_e = cmds[i].e; s_bw = cmds[i].bw;
         s_rd = cmds[i].kind == 0; s_wr = cmds[i].kind == 1; s_ref = cmds[i].kind == 2;
         @(negedge clk); s_rd = 0; s_wr = 0; s_ref = 0;
         while (s_busy) begin
            if (s_de && n < 260) begin res_s[i][n] = {s_arc, s_rddat}; n++; end
            t++; s_ab = cmds[i].abort_at != 0 && t == cmds[i].abort_at;
            if (t > 100000) $fatal(1, "SDRAMC: cmd %0d busy for 100000 clocks", i);
            @(negedge clk);
         end
         s_ab = 0;
         // the clock busy dropped: the word after the last de word
         if (cmds[i].kind == 0 && cmds[i].abort_at == 0 && n < 260) begin res_s[i][n] = {8'h1, s_arc, s_rddat}; n++; end
         num_s[i] = n; s_busy_clk += t;
      end
      s_done = 1;
   end

   initial begin : drv_h
      wait (rstn); wait (h_init);
      for (int i = 0; i < NOPS + NBLK; i++) begin
         int t = 0; int n = 0;
         @(negedge clk);
         while (h_busy) @(negedge clk);
         h_cur = i; h_h = cmds[i].h; h_b = cmds[i].b; h_e = cmds[i].e; h_bw = cmds[i].bw;
         h_rd = cmds[i].kind == 0; h_wr = cmds[i].kind == 1; h_ref = cmds[i].kind == 2;
         @(negedge clk); h_rd = 0; h_wr = 0; h_ref = 0;
         while (h_busy) begin
            if (h_de && n < 260) begin res_h[i][n] = {h_arc, h_rddat}; n++; end
            t++; h_ab = cmds[i].abort_at != 0 && t == cmds[i].abort_at;
            if (t > 100000) $fatal(1, "x68_hrmem: cmd %0d (kind %0d h=%04x b=%02x e=%02x bw=%0d) busy for 100000 clocks, state %0d hstate %0d",
                                   i, cmds[i].kind, cmds[i].h, cmds[i].b, cmds[i].e, cmds[i].bw, u_h.state, u_h.hstate,
                                   " htag=%0d head=%05x wcnt=%0d nlen=%0d left=%0d addr=%06x cfree=%0d ccnt=%0d tag=%0d",
                                   u_h.h_tag, u_h.w_rd_data, u_h.w_rd_count, u_h.h_next_len, u_h.h_left, u_h.h_addr, u_h.c_wr_free, u_h.c_rd_count, u_h.tag);
            @(negedge clk);
         end
         h_ab = 0;
         if (cmds[i].kind == 0 && cmds[i].abort_at == 0 && n < 260) begin res_h[i][n] = {8'h1, h_arc, h_rddat}; n++; end
         num_h[i] = n; h_busy_clk += t;
      end
      h_done = 1;
   end

   // the reference: every write applied in order (SDRAMC's way: at least two words), every
   // read's words computed from it; both controllers are compared against it
   reg [15:0] ref_mem [int];
   function automatic [15:0] ref_rd(int a);
      return ref_mem.exists(a) ? ref_mem[a] : 16'h0000;
   endfunction

   task automatic check(string who, int i, int n, ref int unsigned res [0:NOPS+NBLK-1][0:259], ref int errs);
      int mask = (1 << cmds[i].bw) - 1;
      int b = cmds[i].b, e = cmds[i].e, base = cmds[i].h << 8;
      int m = ((e - b - 2) & mask) + 2;                   // SDRAMC: the end two words ahead
      int unsigned exp;
      if (n != m + 1) begin
         if (errs < 12) $display("%s cmd %0d h=%04x b=%02x e=%02x bw=%0d: %0d words, expected %0d",
                                 who, i, cmds[i].h, b, e, cmds[i].bw, n, m + 1);
         errs++;
         return;
      end
      for (int k = 0; k <= m; k++) begin
         int a = base | (b & ~mask & 255) | ((b + k) & mask);
         exp = {(k == m) ? 8'h1 : 8'h0, 8'((b + k) & 255), ref_rd(a)};
         if (res[i][k] != exp) begin
            if (errs < 12) $display("%s cmd %0d h=%04x b=%02x e=%02x bw=%0d word %0d (addr %06x): %06x, expected %06x",
                                    who, i, cmds[i].h, b, e, cmds[i].bw, k, a, res[i][k], exp);
            errs++;
            if (errs <= 2) for (int j = (i > 12 ? i - 12 : 0); j < i; j++)
               $display("   before: cmd %0d kind %0d h=%04x b=%02x e=%02x bw=%0d abort_at %0d, words %0d/%0d first %06x",
                        j, cmds[j].kind, cmds[j].h, cmds[j].b, cmds[j].e, cmds[j].bw, cmds[j].abort_at,
                        num_s[j], num_h[j], res_h[j][0]);
            return;
         end
      end
   endtask

   initial begin
      int errs_s = 0, errs_h = 0, reads = 0, words = 0;
      wait (s_done && h_done);
      for (int i = 0; i < NOPS + NBLK; i++) begin
         if (cmds[i].kind == 1) begin
            int b = cmds[i].b, e = cmds[i].e, n = e - b + 1;
            if (n < 2) n = 2;
            for (int w = 0; w < n; w++) begin
               reg [17:0] d = wdata(i, w);
               int a = (cmds[i].h << 8) + b + w;
               reg [15:0] old = ref_rd(a);
               if (d[17]) old[15:8] = d[15:8];
               if (d[16]) old[7:0] = d[7:0];
               ref_mem[a] = old;
            end
         end else if (cmds[i].kind == 0 && cmds[i].abort_at == 0) begin
            reads++; words += num_s[i];
            check("SDRAMC   ", i, num_s[i], res_s, errs_s);
            check("x68_hrmem", i, num_h[i], res_h, errs_h);
         end
      end
      $display("tb_hrmem: %0d commands, %0d reads checked (%0d words); busy clocks SDRAMC %0d, x68_hrmem %0d",
               NOPS + NBLK, reads, words, s_busy_clk, h_busy_clk);
      $display("avalon: %0d read bursts (%0d words), %0d write bursts (%0d words)", u_m.n_rd, u_m.n_rw, u_m.n_wr, u_m.n_ww);
      $display("errors: SDRAMC %0d, x68_hrmem %0d", errs_s, errs_h);
      if (errs_h == 0) $display("TB_HRMEM: PASS"); else $display("TB_HRMEM: FAIL");
      $finish;
   end
endmodule
