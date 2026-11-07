// MegaX tb/hrmem (M2M=1): the core port as on the board. x68_hrmem's Avalon lines go to slave 1
// of the framework's real arbiter and HyperRAM controller logic (m2m_hr.vhd, synthesised by
// ghdl); slave 0 is a QNICE-like master (single-word reads and writes, one at a time, as through
// avm_fifo), slave 2 a scaler-like master (64-word read and write bursts, ascal's 128 bytes behind
// avm_decrease; a write burst pauses at random after every 8th word, as avm_decrease does when
// ascal's next 128-bit word is late), each in its own area and checking its own data; a hang of either is reported
// (on the board a lost QNICE response freezes the Shell). The PHY and the chip are modelled at
// the controller's hb_* lines: hyperram_tx puts the clock out on clk_del (90 degrees), so the chip
// sees the controller's dq word of clock t with its clock pulse of clock t+1.
`timescale 1ps/1ps
module avl_m2m (
   input             clk,
   input             rst,
   input             write,
   input             read,
   input      [31:0] address,
   input      [15:0] writedata,
   input      [1:0]  byteenable,
   input      [7:0]  burstcount,
   output     [15:0] readdata,
   output            readdatavalid,
   output            waitrequest
);
   // the three masters on the arbiter
   reg        q_write = 0, q_read = 0; reg [31:0] q_addr = 0; reg [15:0] q_wd = 0;
   reg        d_write = 0, d_read = 0; reg [31:0] d_addr = 0; reg [15:0] d_wd = 0;
   wire [47:0] s_rdata; wire [2:0] s_rdv, s_wait;
   wire hb_rstn, hb_csn, hb_dq_oe, hb_rwds_oe, hb_read;
   wire [1:0] hb_ck, hb_rwds_out; wire [15:0] hb_dq_out;
   reg  [15:0] hb_dq_in = 0; reg hb_dq_ie = 0, hb_rwds_in = 0;

   m2m_hr u_hr(.clk_i(clk), .rst_i(rst),
      .s_write_i({d_write, write, q_write}), .s_read_i({d_read, read, q_read}),
      .s_address_i({d_addr, address, q_addr}), .s_writedata_i({d_wd, writedata, q_wd}),
      .s_byteenable_i({2'b11, byteenable, 2'b11}), .s_burstcount_i({8'd64, burstcount, 8'd1}),
      .s_readdata_o(s_rdata), .s_readdatavalid_o(s_rdv), .s_waitrequest_o(s_wait),
      .hb_rstn_o(hb_rstn), .hb_csn_o(hb_csn), .hb_ck_ddr_o(hb_ck), .hb_dq_ddr_in_i(hb_dq_in),
      .hb_dq_ddr_out_o(hb_dq_out), .hb_dq_oe_o(hb_dq_oe), .hb_dq_ie_i(hb_dq_ie),
      .hb_rwds_ddr_out_o(hb_rwds_out), .hb_rwds_oe_o(hb_rwds_oe), .hb_rwds_in_i(hb_rwds_in),
      .hb_read_o(hb_read));
   assign readdata      = s_rdata[31:16];
   assign readdatavalid = s_rdv[1];
   assign waitrequest   = s_wait[1];

   // RESET# (M2M-UPSTREAM hr-reset-pulse): the device refreshes itself only while RESET# is high,
   // so RESET# must not stay low for long (on the board a long press of the reset button held it
   // low for seconds and the IPL ROM lost bits, megax-hr19); 1 us here is far beyond tRP (200 ns)
   int rstn_low = 0, rstn_low_max = 0;
   always @(posedge clk) begin
      if (!hb_rstn) begin
         rstn_low <= rstn_low + 1;
         if (rstn_low + 1 > rstn_low_max) rstn_low_max <= rstn_low + 1;
         if (rstn_low == 100) $fatal(1, "avl_m2m: RESET# low for more than 1 us");
      end else rstn_low <= 0;
   end
   final $display("avl_m2m: RESET# low for at most %0d clocks", rstn_low_max);

   // the core port's statistics (as avl_model)
   int n_rd = 0, n_wr = 0, n_rw = 0, n_ww = 0;
   int c_wleft = 0;
   always @(posedge clk) begin
      if (readdatavalid) n_rw <= n_rw + 1;
      if (!waitrequest && read) begin
         if (write) $fatal(1, "avl_m2m: core read and write together");
         n_rd <= n_rd + 1;
      end
      if (!waitrequest && write) begin
         n_ww <= n_ww + 1;
         if (c_wleft == 0) begin n_wr <= n_wr + 1; c_wleft <= burstcount - 1; end
         else c_wleft <= c_wleft - 1;
      end
   end

   ////////////////////////////////////////////////////////////////////////////////////////
   // the chip
   reg [15:0] mem [0:(1<<22)-1];
   reg  p_csn = 1, p_dq_oe = 0, p_rwds_oe = 0; reg [15:0] p_dq = 0; reg [1:0] p_rwds = 0;
   int  ca_n = 0; reg [47:0] ca = 0; reg [21:0] m_addr = 0;
   int  m_kind = 0;              // 0 idle, 1 command/address, 2 write, 3 read, 4 config
   int  rd_delay = 0;
   int  n_cfg = 0, n_mrd = 0, n_mwr = 0;
   always @(posedge clk) begin
      p_csn <= hb_csn; p_dq <= hb_dq_out; p_dq_oe <= hb_dq_oe; p_rwds_oe <= hb_rwds_oe; p_rwds <= hb_rwds_out;
      hb_dq_ie <= 0;
      if (hb_csn) begin
         m_kind <= 0; ca_n <= 0;
      end else begin
         if (m_kind == 0) begin m_kind <= 1; ca_n <= 0; hb_rwds_in <= $urandom() % 2; end
         // a clock pulse now carries the word of the clock before
         if (hb_ck == 2'b10 && !p_csn) begin
            if (m_kind == 1 && p_dq_oe) begin
               reg [47:0] c;
               c = {ca[31:0], p_dq};
               ca <= c;
               ca_n <= ca_n + 1;
               if (ca_n == 2) begin
                  m_addr <= {c[34:16], c[2:0]};          // the controller's address(21 downto 3), (2 downto 0)
                  if (c[46]) begin m_kind <= 4; n_cfg <= n_cfg + 1; end
                  else if (c[47]) begin m_kind <= 3; rd_delay <= 2 + $urandom() % 4; n_mrd <= n_mrd + 1; end
                  else begin m_kind <= 2; n_mwr <= n_mwr + 1; end
                  if (c[44:35] != 0) $display("chip: address bits above 8 MB: CA %012x", c);
               end
            end else if (m_kind == 2 && p_rwds_oe) begin
               if (!p_rwds[1]) mem[m_addr][15:8] <= p_dq[15:8];
               if (!p_rwds[0]) mem[m_addr][7:0]  <= p_dq[7:0];
               m_addr <= m_addr + 1;
            end
         end
         // reads: the words come back while the controller reads (one-clock gaps now and then)
         if (m_kind == 3 && hb_read) begin
            if (rd_delay > 0) rd_delay <= rd_delay - 1;
            else if ($urandom() % 8 != 0) begin
               hb_dq_in <= mem[m_addr];
               hb_dq_ie <= 1;
               m_addr <= m_addr + 1;
            end
         end
      end
   end

   // the last 64 clocks, for the dump
   typedef struct packed { longint t; bit [3:0] st; bit [1:0] cac; bit [7:0] wcc; bit wq; bit csn; bit [1:0] ck;
                           bit cw; bit cr; bit [7:0] cbc; bit [2:0] w; bit [2:0] r; bit [2:0] wt; bit g0, g1, g01_0, g01_1; bit [2:0] es; } tr_t;
   tr_t ring [0:63]; int rp = 0;
   always @(posedge clk) begin
      ring[rp] <= '{t: $time, st: u_hr.i_ctrl.state, cac: u_hr.i_ctrl.ca_count, wcc: u_hr.i_ctrl.write_clk_count,
                    wq: u_hr.i_ctrl.waitreq_r, csn: hb_csn, ck: hb_ck, cw: u_hr.c_write, cr: u_hr.c_read, cbc: u_hr.c_bc,
                    w: {d_write, write, q_write}, r: {d_read, read, q_read}, wt: s_wait,
                    g0: u_hr.i_arbit.i_avm_arbit.s0_active_grant, g1: u_hr.i_arbit.i_avm_arbit.s1_active_grant,
                    g01_0: u_hr.i_arbit.i_avm_arbit_01.s0_active_grant, g01_1: u_hr.i_arbit.i_avm_arbit_01.s1_active_grant,
                    es: {u_hr.i_errata.state, u_hr.i_config.state}};
      rp <= (rp + 1) % 64;
   end

   // the state of everything at a hang
   task automatic dump(string why);
      for (int k = 0; k < 64; k++) begin
         tr_t e = ring[(rp + k) % 64];
         $display("  %0t ctrl st %0d ca %0d wcc %0d wq %0d csn %0d ck %b | ctrl in w%0d r%0d bc %0d | w(s,c,q) %b r %b wait %b | top g %0d%0d  01 g %0d%0d | errata/config %b",
                  e.t, e.st, e.cac, e.wcc, e.wq, e.csn, e.ck, e.cw, e.cr, e.cbc, e.w, e.r, e.wt, e.g0, e.g1, e.g01_0, e.g01_1, e.es);
      end
      $display("[%0t] %s", $time, why);
      $display("  top arbiter: grant s0(qnice+core) %0d s1(scaler) %0d last %0d burstcount %0d",
               u_hr.i_arbit.i_avm_arbit.s0_active_grant, u_hr.i_arbit.i_avm_arbit.s1_active_grant,
               u_hr.i_arbit.i_avm_arbit.last_grant, u_hr.i_arbit.i_avm_arbit.burstcount);
      $display("  arbiter 01:  grant s0(qnice) %0d s1(core) %0d last %0d burstcount %0d",
               u_hr.i_arbit.i_avm_arbit_01.s0_active_grant, u_hr.i_arbit.i_avm_arbit_01.s1_active_grant,
               u_hr.i_arbit.i_avm_arbit_01.last_grant, u_hr.i_arbit.i_avm_arbit_01.burstcount);
      $display("  ctrl state %0d (0 init 1 ca 2 wait 3 rwds 4 lat 5 read 6 write 7 wburst 8 recov), errata %0d, config %0d, chip kind %0d csn %0d",
               u_hr.i_ctrl.state, u_hr.i_errata.state, u_hr.i_config.state, m_kind, hb_csn);
      $display("  requests: qnice w%0d r%0d  core w%0d r%0d bc %0d addr %06x  scaler w%0d r%0d; waitrequest %b",
               q_write, q_read, write, read, burstcount, address, d_write, d_read, s_wait);
      $display("  x68_hrmem hstate %0d h_beats %0d h_len %0d h_left %0d", $root.tb_hrmem.u_h.hstate,
               $root.tb_hrmem.u_h.h_beats, $root.tb_hrmem.u_h.h_len, $root.tb_hrmem.u_h.h_left);
   endtask

   ////////////////////////////////////////////////////////////////////////////////////////
   // QNICE: single words in 0x040000..0x04FFFF, one at a time (clocked: the inputs are the
   // values before the edge, as in RTL)
   reg [15:0] q_shadow [int];
   int q_ops = 0, q_maxwait = 0, q_st = 0, q_idle = 100, q_t = 0;
   always @(posedge clk) begin
      if (rst) begin
         q_st <= 0; q_write <= 0; q_read <= 0;
      end else case (q_st)
         0: if (q_idle > 0) q_idle <= q_idle - 1;
            else begin
               q_addr <= 32'h040000 + ($urandom() % 'h10000);
               q_t <= 0;
               if ($urandom() % 2) begin q_wd <= $urandom(); q_write <= 1; end
               else q_read <= 1;
               q_st <= 1;
            end
         1: begin
               q_t <= q_t + 1;
               if (!s_wait[0]) begin
                  if (q_write) begin
                     q_shadow[q_addr] = q_wd;
                     q_write <= 0; q_st <= 3;
                  end else begin
                     q_read <= 0; q_st <= 2;
                  end
               end else if (q_t > 50000) begin dump("QNICE: waitrequest for 50000 clocks"); $fatal(1); end
            end
         2: begin
               q_t <= q_t + 1;
               if (s_rdv[0]) begin
                  if (q_shadow.exists(q_addr) && s_rdata[15:0] !== q_shadow[q_addr])
                     begin dump($sformatf("QNICE: read %06x = %04x, expected %04x", q_addr, s_rdata[15:0], q_shadow[q_addr])); $fatal(1); end
                  q_st <= 3;
               end else if (q_t > 50000)
                  begin dump($sformatf("QNICE: read %06x without an answer for 50000 clocks (the Shell would freeze)", q_addr)); $fatal(1); end
            end
         default: begin
               q_ops <= q_ops + 1; if (q_t > q_maxwait) q_maxwait <= q_t;
               q_idle <= $urandom() % 300; q_st <= 0;
            end
      endcase
   end

   ////////////////////////////////////////////////////////////////////////////////////////
   // the scaler: 64-word bursts in 0x000000..0x03FFFF, one every 200..600 clocks
   reg [15:0] d_shadow [int];
   int d_ops = 0, d_maxwait = 0, d_st = 0, d_idle = 300, d_t = 0, d_k = 0, d_seed = 0, d_pause = 0;
   always @(posedge clk) begin
      if (rst) begin
         d_st <= 0; d_write <= 0; d_read <= 0;
      end else case (d_st)
         0: if (d_idle > 0) d_idle <= d_idle - 1;
            else begin
               int sd = $urandom();
               d_addr <= ($urandom() % 'h40000) & ~32'h3F;
               d_t <= 0; d_k <= 0;
               if ($urandom() % 2) begin d_seed <= sd; d_wd <= sd[15:0]; d_write <= 1; d_st <= 1; end
               else begin d_read <= 1; d_st <= 2; end
            end
         1: begin                                   // write beats
               d_t <= d_t + 1;
               if (d_pause > 0) begin
                  d_pause <= d_pause - 1;
                  if (d_pause == 1) d_write <= 1;
               end else if (!s_wait[2]) begin
                  d_shadow[d_addr + d_k] = d_wd;
                  d_k <= d_k + 1;
                  d_wd <= 16'(d_seed + (d_k + 1) * 40503);
                  if (d_k == 63) begin d_write <= 0; d_st <= 4; end
                  else if (d_k % 8 == 7 && $urandom() % 3 == 0) begin d_write <= 0; d_pause <= 1 + $urandom() % 8; end
               end else if (d_t > 50000) begin dump($sformatf("scaler: write burst stuck at beat %0d", d_k)); $fatal(1); end
            end
         2: begin                                   // read command
               d_t <= d_t + 1;
               if (!s_wait[2]) begin d_read <= 0; d_st <= 3; end
               else if (d_t > 50000) begin dump("scaler: read command waits for 50000 clocks"); $fatal(1); end
            end
         3: begin                                   // read words
               d_t <= d_t + 1;
               if (s_rdv[2]) begin
                  if (d_shadow.exists(d_addr + d_k) && s_rdata[47:32] !== d_shadow[d_addr + d_k])
                     begin dump($sformatf("scaler: read %06x = %04x, expected %04x", d_addr + d_k, s_rdata[47:32], d_shadow[d_addr + d_k])); $fatal(1); end
                  d_k <= d_k + 1;
                  if (d_k == 63) d_st <= 4;
               end else if (d_t > 50000) begin dump($sformatf("scaler: read burst %06x stuck after %0d words", d_addr, d_k)); $fatal(1); end
            end
         default: begin
               d_ops <= d_ops + 1; if (d_t > d_maxwait) d_maxwait <= d_t;
               d_idle <= 200 + $urandom() % 400; d_st <= 0;
            end
      endcase
   end

   final $display("avl_m2m: chip %0d config, %0d read, %0d write commands; QNICE %0d ops (longest %0d clocks); scaler %0d bursts (longest %0d clocks)",
                  n_cfg, n_mrd, n_mwr, q_ops, q_maxwait, d_ops, d_maxwait);
endmodule
