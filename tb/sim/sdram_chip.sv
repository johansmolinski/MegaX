// MegaX simulation: the MEGA65 R6's SDRAM (ISSI IS42S16320, 32M x 16, 4 banks,
// 8192 rows, 1024 columns) as the core's SDRAMC sees it.
//
// The FPGA clocks the SDRAM with clk_ram inverted (X68000.sv's altddio_out), so the
// chip samples commands on the falling edge of clk. Data of a READ registered at
// falling edge E0 is driven at E0 + (CL-1) and stays until the next falling edge;
// the controller samples it with the rising edge in between (rddat <= PMEMDAT).
//
// Board delay: SDRAMC takes the first word of a READ issued at clock edge t0 with
// the rising edge t0 + 3T (clkstate 5: addr_rc <= start address, rddat <= pins).
// A CL2 chip on an inverted clock holds that word on its pins only until about
// t0 + 2.5T; on the MiSTer the SDRAM board's clock and data path delays move it
// past t0 + 3T. Without them every read returns the next word (seen: the 68000's
// reset vectors one word off). The model therefore drives read data
// +sdram_rd_delay=<n> falling edges later (default 1). The MEGA65's clocking has
// to put the data at the same place (phase 2).
//
// Instantiated inside the simulation copy of SDRAMC (tb/sim/sdramc_sim.py): ghdl's
// synthesis cannot carry the inout data bus through the hierarchy, so the model gets
// the controller's MDATA (dq_w) and returns dq_r directly.
//
// Modelled: mode register (CAS latency, burst length incl. full page), bursts with
// READ/WRITE interruption, BURST STOP and PRECHARGE termination (data of the column
// addressed at the terminating edge is still delivered), DQM on writes.
// Checked (counted, first 20 printed): command on a wrong bank state, tRCD, tRP,
// tRAS, tRC, tRRD, tRFC, tMRD, tWR, the initialisation sequence and the refresh
// rule (8192 AUTO REFRESH in any 64 ms window), bursts crossing column 511 -> 512
// (the core's controller is written for a 512-column chip). Timing values: ISSI
// IS42S16320F -7 grade as assumed here, to be confirmed against the datasheet.
`timescale 1ps/1ps

module sdram_chip (
   input             clk,
   input             ras_n,
   input             cas_n,
   input             we_n,
   input      [1:0]  ba,
   input      [12:0] a,
   input      [1:0]  dqm,
   input      [15:0] dq_w,
   output reg [15:0] dq_r
);
   localparam longint T_RCD = 15000, T_RP = 15000, T_RAS = 37000, T_RC = 60000,
                      T_RRD = 14000, T_RFC = 60000, T_WR = 14000, T_POWERUP = 64'd100_000_000,
                      T_REFWIN = 64'd64_000_000_000;
   localparam int     REF_N = 8192, MAX_SHOWN = 20;

   reg [15:0] mem [0:(1<<25)-1];          // {bank, row, column}

   // bank state
   reg        open_  [0:3];
   reg [12:0] row    [0:3];
   longint    t_act  [0:3];
   longint    t_pre  [0:3];
   longint    t_act_any = -1_000_000, t_ref = -1_000_000, t_mrs = -1_000_000,
              t_wr_last [0:3];

   // mode register
   int cl = 2;
   int rd_delay = 1;                      // extra falling edges of read latency (board)
   // +sdram_watch=<lo>:<hi> (hex model indices {bank, row, column}): print each
   // write and each read word of that range
   int unsigned watch_lo = 1, watch_hi = 0;
   int bl = 1;                            // 1/2/4/8, 0 = full page
   bit mrs_done = 0;
   int init_pall = 0, init_ref = 0;

   // bursts
   bit        rd_active = 0, wr_active = 0;
   reg [1:0]  bst_bank;
   reg [9:0]  bst_col;
   int        bst_left;                   // words left for BL < full page
   // read data pipeline: entry 0 is driven at the next falling edge
   bit        pipe_v [0:7];
   reg [24:0] pipe_i [0:7];

   // refresh window: times of the last REF_N refreshes
   longint    ref_ring [0:REF_N-1];
   int        ref_ptr = 0, ref_cnt = 0;
   longint    ref_gap_max = 0, t_ref_prev = -1;

   // statistics
   longint    n_err = 0, n_act = 0, n_rd = 0, n_wr = 0, n_ref = 0, n_words_rd = 0, n_words_wr = 0;
   longint    t_first_cmd = -1;
   bit        wrap_warned = 0;

   initial begin
      string f;
      // +sdram_init=<file>: preload (tb/sim/mkbootimg.py writes boot.rom this way)
      if ($value$plusargs("sdram_watch=%s", f)) begin
         void'($sscanf(f, "%h:%h", watch_lo, watch_hi));
         $display("SDRAM: watching %h..%h", watch_lo, watch_hi);
      end
      if ($value$plusargs("sdram_rd_delay=%d", rd_delay))
         $display("SDRAM: read delay %0d falling edges", rd_delay);
      if ($value$plusargs("sdram_init=%s", f)) begin
         $readmemh(f, mem);
         $display("SDRAM: preloaded %s", f);
      end
      for (int b = 0; b < 4; b++) begin
         open_[b] = 0; t_act[b] = -1_000_000; t_pre[b] = -1_000_000; t_wr_last[b] = -1_000_000;
      end
      for (int i = 0; i < 8; i++) pipe_v[i] = 0;
      dq_r = 16'hdead;
   end

   function automatic void err(input string msg);
      n_err++;
      if (n_err <= MAX_SHOWN)
         $display("SDRAM ERROR @%0t ps: %s", $time, msg);
      if (n_err == MAX_SHOWN)
         $display("SDRAM: further errors are only counted");
   endfunction

   function automatic [24:0] idx(input [1:0] b, input [12:0] r, input [9:0] c);
      idx = {b, r, c};
   endfunction

   // one column step of a running burst; wraps inside the 1024-column page.
   // The core's controller was written for a 512-column chip (CAWIDTH 9, column
   // bit 9 always 0): a burst that steps from column 511 to 512 would wrap to 0
   // there. Harmless for read words after the last one the controller takes;
   // a write there lands elsewhere than on the MiSTer: warned.
   bit beyond = 0;                        // the running burst has left columns 0..511
   longint n_rd_beyond = 0, n_wr_beyond = 0;
   function automatic void step_col();
      if (bst_col == 10'd511) beyond = 1;
      bst_col = bst_col + 1'b1;
   endfunction

   function automatic void stop_bursts();
      rd_active = 0;
      wr_active = 0;
   endfunction

   wire [2:0] cmd = {ras_n, cas_n, we_n};
   localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100,
                    C_BST = 3'b110, C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

   always @(negedge clk) begin
      longint now;
      bit sched_v;
      reg [24:0] sched_i;
      now = $time;

      // read data out
      dq_r <= pipe_v[0] ? mem[pipe_i[0]] : 16'hdead;
      if (pipe_v[0] && pipe_i[0] >= watch_lo && pipe_i[0] <= watch_hi)
         $display("SDRAM watch @%0t ps: read  %h => %h", $time, pipe_i[0], mem[pipe_i[0]]);
      for (int i = 0; i < 7; i++) begin
         pipe_v[i] = pipe_v[i+1];
         pipe_i[i] = pipe_i[i+1];
      end
      pipe_v[7] = 0;
      sched_v = 0;
      sched_i = '0;

      if (cmd != C_NOP && t_first_cmd < 0) begin
         t_first_cmd = now;
         if (now < T_POWERUP)
            $display("SDRAM WARNING: first command %0d ns after the clock started (datasheet: 100 us)", now / 1000);
      end

      case (cmd)
      C_ACT: begin
         n_act++;
         if (!mrs_done) err("ACTIVE before the mode register was set");
         if (open_[ba]) err($sformatf("ACTIVE on open bank %0d", ba));
         if (now - t_pre[ba] < T_RP) err($sformatf("tRP: ACTIVE %0d ps after PRECHARGE", now - t_pre[ba]));
         if (now - t_act[ba] < T_RC) err($sformatf("tRC: ACTIVE %0d ps after ACTIVE", now - t_act[ba]));
         if (now - t_act_any < T_RRD) err("tRRD");
         if (now - t_ref < T_RFC) err($sformatf("tRFC: ACTIVE %0d ps after REFRESH", now - t_ref));
         open_[ba] = 1; row[ba] = a; t_act[ba] = now; t_act_any = now;
      end
      C_READ, C_WRITE: begin
         if (!open_[ba]) err($sformatf("%s on closed bank %0d", cmd == C_READ ? "READ" : "WRITE", ba));
         if (now - t_act[ba] < T_RCD) err($sformatf("tRCD: %0d ps", now - t_act[ba]));
         stop_bursts();
         bst_bank = ba; bst_col = a[9:0]; bst_left = (bl == 0) ? -1 : bl;
         beyond = 0;
         if (cmd == C_READ) begin
            n_rd++;
            rd_active = 1;
         end else begin
            n_wr++;
            wr_active = 1;
         end
         if (a[10]) err("auto precharge (not used by this controller, not modelled)");
      end
      C_BST: begin
         if (rd_active) begin           // the column addressed now is still delivered
            sched_v = 1; sched_i = idx(bst_bank, row[bst_bank], bst_col);
         end
         stop_bursts();
      end
      C_PRE: begin
         if (rd_active && (a[10] || ba == bst_bank)) begin
            sched_v = 1; sched_i = idx(bst_bank, row[bst_bank], bst_col);
         end
         if (wr_active && (a[10] || ba == bst_bank)) err("PRECHARGE during a write burst");
         if (a[10] || ba == bst_bank) stop_bursts();
         for (int b = 0; b < 4; b++)
            if (a[10] || b == ba) begin
               if (open_[b] && now - t_act[b] < T_RAS) err($sformatf("tRAS: PRECHARGE %0d ps after ACTIVE", now - t_act[b]));
               if (open_[b] && now - t_wr_last[b] < T_WR) err($sformatf("tWR: PRECHARGE %0d ps after write data", now - t_wr_last[b]));
               open_[b] = 0; t_pre[b] = now;
            end
         if (!mrs_done && a[10]) init_pall++;
      end
      C_REF: begin
         n_ref++;
         for (int b = 0; b < 4; b++) begin
            if (open_[b]) err("REFRESH with an open bank");
            if (now - t_pre[b] < T_RP) err("tRP before REFRESH");
         end
         if (now - t_ref < T_RFC) err("tRFC: REFRESH after REFRESH");
         if (!mrs_done) init_ref++;
         if (t_ref_prev >= 0 && now - t_ref_prev > ref_gap_max) ref_gap_max = now - t_ref_prev;
         t_ref_prev = now;
         t_ref = now;
         if (ref_cnt == REF_N && now - ref_ring[ref_ptr] > T_REFWIN)
            err($sformatf("refresh: only %0d AUTO REFRESH in the last %0d us", REF_N, (now - ref_ring[ref_ptr]) / 1_000_000));
         ref_ring[ref_ptr] = now;
         ref_ptr = (ref_ptr + 1) % REF_N;
         if (ref_cnt < REF_N) ref_cnt++;
      end
      C_MRS: begin
         for (int b = 0; b < 4; b++) if (open_[b]) err("MODE REGISTER SET with an open bank");
         if (!mrs_done && (init_pall < 1 || init_ref < 2))
            err($sformatf("initialisation: MRS after %0d PRECHARGE ALL and %0d REFRESH", init_pall, init_ref));
         cl = a[6:4];
         case (a[2:0])
            3'd0: bl = 1; 3'd1: bl = 2; 3'd2: bl = 4; 3'd3: bl = 8; 3'd7: bl = 0;
            default: err("reserved burst length");
         endcase
         if (cl != 2 && cl != 3) err($sformatf("CAS latency %0d not supported", cl));
         if (a[3]) err("interleaved bursts not modelled");
         if (a[9]) err("single-location write mode not modelled");
         $display("SDRAM: mode register CL=%0d BL=%s @%0t ps", cl, bl == 0 ? "full page" : $sformatf("%0d", bl), now);
         mrs_done = 1;
         t_mrs = now;
      end
      default: ;
      endcase

      // the running burst (the command edge itself included)
      if (rd_active && !sched_v) begin
         sched_v = 1; sched_i = idx(bst_bank, row[bst_bank], bst_col);
         if (beyond) n_rd_beyond++;
         n_words_rd++;
         step_col();
         if (bst_left > 0) begin
            bst_left = bst_left - 1;
            if (bst_left == 0) rd_active = 0;
         end
      end
      if (wr_active && (cmd == C_WRITE || cmd == C_NOP)) begin
         reg [24:0] w;
         w = idx(bst_bank, row[bst_bank], bst_col);
         if (beyond && dqm != 2'b11) begin     // masked words do not count
            n_wr_beyond++;
            if (!wrap_warned) begin
               wrap_warned = 1;
               $display("SDRAM WARNING @%0t ps: write burst past column 511 (a 512-column chip would wrap to column 0)", $time);
            end
         end
         if (w >= watch_lo && w <= watch_hi)
            $display("SDRAM watch @%0t ps: write %h <= %h dqm %b (col %0d)", now, w, dq_w, dqm, bst_col);
         if (!dqm[1]) mem[w][15:8] = dq_w[15:8];
         if (!dqm[0]) mem[w][7:0]  = dq_w[7:0];
         t_wr_last[bst_bank] = now;
         n_words_wr++;
         step_col();
         if (bst_left > 0) begin
            bst_left = bst_left - 1;
            if (bst_left == 0) wr_active = 0;
         end
      end
      if (sched_v) begin
         pipe_v[cl-2+rd_delay] = 1;
         pipe_i[cl-2+rd_delay] = sched_i;
      end
   end

   final begin
      $display("SDRAM: %0d ACTIVE, %0d READ (%0d words), %0d WRITE (%0d words), %0d REFRESH, longest REFRESH gap %0d ns, %0d errors",
               n_act, n_rd, n_words_rd, n_wr, n_words_wr, n_ref, ref_gap_max / 1000, n_err);
      $display("SDRAM: words past column 511 (would wrap on a 512-column chip): %0d read, %0d written",
               n_rd_beyond, n_wr_beyond);
   end
endmodule
