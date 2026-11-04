----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- x68_r3probe (temporary, 2026-11-03): the measurement for the R3 port study (doc/plan.md
-- section 4 item 8). R3 has no SDRAM, so everything the core keeps there would move into the
-- HyperRAM that ascal already uses. On the R6 this probe
--
--   1. counts the core's SDRAM traffic (clk_ram): per class of cachecont's state the busy
--      cycles, the commands and their words; per line (HCOMP to HCOMP) the GVRAM line read
--      words and all busy cycles; the CPU's SDRAM reads, its stall cycles and the longest
--      stall;
--   2. mirrors every SDRAM read and write command into the HyperRAM (hr_clk), through the
--      framework's unused core port (the arbiter serves ascal first, then the core, then
--      QNICE), to words 0x200000.. (the upper 4 MB; ascal's three frame buffers are in the
--      lower 3 MB): the same class, the same number of words, in the same order. The latency
--      of each mirrored command from its arrival (the SDRAM command's start plus the CDC, a few
--      clocks) to its last word, the maximum per class; for the GVRAM line reads also from
--      the HCOMP that started their line (the deadline is the next HCOMP: a line read that
--      takes longer than a line shows wrong graphics on R3). The mirror's backlog.
--
-- The SDRAM keeps working as before: the probe only watches it. The mirror runs open loop
-- (the core does not wait for it), so a slow HyperRAM shows as backlog and latency here,
-- whereas on R3 it would slow the CPU down and so reduce the traffic: the numbers are an
-- upper bound.
--
-- QNICE (device C_DEV_X68_DEBUG, window 4; tools/r3probe.py):
--   0x000 (W) bit 0: clear all counters, bit 1: take a snapshot (both are toggles here)
--   0x000 (R) bit 0: the clk_ram side has taken the last snapshot, bit 1: the hr_clk side
--   0x010 + 2i, 0x011 + 2i (R): snapshot register i, bits 15..0 and 31..16 (see C_* below)
--
-- done by Johan Smolinski in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity x68_r3probe is
   port (
      clk_ram_i               : in  std_logic;
      mem_i                   : in  std_logic_vector(51 downto 0);   -- X68K_top's dbg_mem

      hr_clk_i                : in  std_logic;
      hr_rst_i                : in  std_logic;
      hr_write_o              : out std_logic;
      hr_read_o               : out std_logic;
      hr_address_o            : out std_logic_vector(31 downto 0);
      hr_writedata_o          : out std_logic_vector(15 downto 0);
      hr_byteenable_o         : out std_logic_vector( 1 downto 0);
      hr_burstcount_o         : out std_logic_vector( 7 downto 0);
      hr_readdata_i           : in  std_logic_vector(15 downto 0);
      hr_readdatavalid_i      : in  std_logic;
      hr_waitrequest_i        : in  std_logic;

      qnice_clk_i             : in  std_logic;
      qnice_addr_i            : in  std_logic_vector(27 downto 0);
      qnice_data_i            : in  std_logic_vector(15 downto 0);
      qnice_data_o            : out std_logic_vector(15 downto 0);
      qnice_ce_i              : in  std_logic;
      qnice_we_i              : in  std_logic
   );
end entity x68_r3probe;

architecture synthesis of x68_r3probe is

   -- the snapshot registers: 0..30 the clk_ram side, 31..45 the hr_clk side
   constant C_R_CYC        : natural := 0;    -- clk_ram cycles since the clear
   constant C_R_FRAMES     : natural := 1;    -- VPSTART pulses
   constant C_R_BUSY       : natural := 2;    -- 2..8: cycles in class 1..7
   constant C_R_OPS        : natural := 9;    -- 9..15: commands in class 1..7
   constant C_R_WORDS      : natural := 16;   -- 16..22: their words
   constant C_R_DEWORDS    : natural := 23;   -- cycles with SDRAMC's de (the read words, a check)
   constant C_R_GLINE      : natural := 24;   -- the most GVRAM line read words in one line
   constant C_R_BUSYLINE   : natural := 25;   -- the most busy cycles (not idle, not refresh) in one line
   constant C_R_LINEPER    : natural := 26;   -- the last line's length (clk_ram cycles)
   constant C_R_CPURD      : natural := 27;   -- the CPU's SDRAM reads
   constant C_R_CPUSTALL   : natural := 28;   -- cycles a CPU read waited for its acknowledge
   constant C_R_CPUMAX     : natural := 29;   -- the longest wait
   constant C_R_OVF        : natural := 30;   -- commands lost: the CDC FIFO was full
   constant C_H_CYC        : natural := 31;   -- hr_clk cycles since the clear
   constant C_H_OPS        : natural := 32;   -- mirrored commands done
   constant C_H_WORDS      : natural := 33;   -- their words
   constant C_H_BUSY       : natural := 34;   -- cycles with a mirrored command under way
   constant C_H_LAT        : natural := 35;   -- 35..41: the longest latency in class 1..7 (hr_clk)
   constant C_H_GLINE      : natural := 42;   -- the latest end of a GVRAM line read after its HCOMP
   constant C_H_QMAX       : natural := 43;   -- the longest backlog (commands)
   constant C_H_QOVF       : natural := 44;   -- commands lost: the backlog queue was full
   constant C_H_LATSUM     : natural := 45;   -- the sum of the GVRAM line read latencies
   constant C_NREGS        : natural := 46;

   type t_regs is array (natural range <>) of unsigned(31 downto 0);
   type t_cls  is array (1 to 7) of unsigned(31 downto 0);

   -- QNICE side
   signal q_win            : std_logic_vector(15 downto 0);
   signal q_clr_t          : std_logic := '0';
   signal q_snap_t         : std_logic := '0';
   signal q_rack           : std_logic;
   signal q_hack           : std_logic;

   -- clk_ram side
   signal r_clr_s          : std_logic;
   signal r_snap_s         : std_logic;
   signal r_clr_d          : std_logic := '0';
   signal r_snap_d         : std_logic := '0';
   signal r_snap_ack       : std_logic := '0';
   signal r_cyc, r_frames, r_dewords, r_gline, r_busyline, r_lineper,
          r_cpurd, r_cpustall, r_cpumax, r_ovf : unsigned(31 downto 0) := (others => '0');
   signal r_busy, r_ops, r_words : t_cls := (others => (others => '0'));
   signal r_gl_cur, r_bl_cur, r_lp_cur, r_stall_cur : unsigned(31 downto 0) := (others => '0');
   signal r_hcomp_d, r_vp_d, r_cpurd_d : std_logic := '0';
   signal r_mark_pend      : std_logic := '0';
   signal r_snap           : t_regs(0 to 30) := (others => (others => '0'));

   -- the CDC FIFO: 37 marker, 36..34 class, 33 write, 32..9 word address, 8..0 words
   signal f_din, f_dout    : std_logic_vector(37 downto 0);
   signal f_wr, f_full, f_empty, f_rd, f_wr_busy, f_rd_busy : std_logic;

   -- hr_clk side
   signal h_clr_s          : std_logic;
   signal h_snap_s         : std_logic;
   signal h_clr_d          : std_logic := '0';
   signal h_snap_d         : std_logic := '0';
   signal h_snap_ack       : std_logic := '0';
   signal h_now            : unsigned(31 downto 0) := (others => '0');
   signal h_line_ts        : unsigned(31 downto 0) := (others => '0');
   signal h_cyc, h_ops, h_words, h_busy, h_gline, h_qmax, h_qovf, h_latsum
                           : unsigned(31 downto 0) := (others => '0');
   signal h_lat            : t_cls := (others => (others => '0'));
   signal h_snap           : t_regs(31 to C_NREGS - 1) := (others => (others => '0'));

   -- the backlog queue (hr_clk): class, write, address, words, arrival, line start
   constant C_QBITS        : natural := 6;                 -- 64 entries
   type t_qcmd is array (0 to 2**C_QBITS - 1) of std_logic_vector(36 downto 0);
   type t_qts  is array (0 to 2**C_QBITS - 1) of unsigned(31 downto 0);
   signal q_cmd            : t_qcmd;
   signal q_arr, q_lts     : t_qts;
   signal q_wp, q_rp       : unsigned(C_QBITS - 1 downto 0) := (others => '0');
   signal q_cnt            : unsigned(C_QBITS downto 0) := (others => '0');

   -- the mirror engine
   type t_state is (S_IDLE, S_ISSUE, S_RDATA, S_WDATA);
   signal e_state          : t_state := S_IDLE;
   signal e_cls            : natural range 0 to 7 := 0;
   signal e_wr             : std_logic := '0';
   signal e_addr           : unsigned(21 downto 0) := (others => '0');
   signal e_left           : unsigned(8 downto 0) := (others => '0');   -- words not yet issued
   signal e_chunk          : unsigned(8 downto 0) := (others => '0');   -- words of this burst left
   signal e_bc             : std_logic_vector(7 downto 0) := (others => '0');  -- its burst count
   signal e_arr, e_lts     : unsigned(31 downto 0) := (others => '0');

   attribute ASYNC_REG     : string;

   function words_of(rd : std_logic; bw : std_logic_vector(3 downto 0);
                     bgn, en : std_logic_vector(7 downto 0)) return unsigned is
      variable mask : unsigned(7 downto 0);
      variable d    : unsigned(7 downto 0);
   begin
      mask := shift_right(to_unsigned(255, 8), 8 - to_integer(unsigned(bw)));
      if rd = '1' and bgn = en then
         return ('0' & mask) + 1;                              -- the whole block
      end if;
      d := (unsigned(en) - unsigned(bgn)) and mask;
      return ('0' & d) + 1;
   end function words_of;

begin

   ---------------------------------------------------------------------------------------------
   -- QNICE side
   ---------------------------------------------------------------------------------------------

   q_win <= qnice_addr_i(27 downto 12);

   p_qwrite : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' and q_win = x"0004" and
            qnice_addr_i(11 downto 0) = x"000" then
            if qnice_data_i(0) = '1' then
               q_clr_t <= not q_clr_t;
            end if;
            if qnice_data_i(1) = '1' then
               q_snap_t <= not q_snap_t;
            end if;
         end if;
      end if;
   end process p_qwrite;

   -- the snapshot registers stand still while QNICE reads them (CORE.xdc: false path)
   p_qread : process (all)
      variable i : natural;
      variable v : unsigned(31 downto 0);
   begin
      qnice_data_o <= x"0000";
      if qnice_addr_i(11 downto 0) = x"000" then
         qnice_data_o <= "00000000000000" & (q_hack xnor q_snap_t) & (q_rack xnor q_snap_t);
      elsif unsigned(qnice_addr_i(11 downto 0)) >= 16 and
            unsigned(qnice_addr_i(11 downto 0)) < 16 + 2 * C_NREGS then
         i := (to_integer(unsigned(qnice_addr_i(11 downto 0))) - 16) / 2;
         if i <= 30 then
            v := r_snap(i);
         else
            v := h_snap(i);
         end if;
         if qnice_addr_i(0) = '0' then
            qnice_data_o <= std_logic_vector(v(15 downto 0));
         else
            qnice_data_o <= std_logic_vector(v(31 downto 16));
         end if;
      end if;
   end process p_qread;

   i_cdc_rclr  : xpm_cdc_single generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => q_clr_t,    dest_clk => clk_ram_i,   dest_out => r_clr_s);
   i_cdc_rsnap : xpm_cdc_single generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => q_snap_t,   dest_clk => clk_ram_i,   dest_out => r_snap_s);
   i_cdc_hclr  : xpm_cdc_single generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => q_clr_t,    dest_clk => hr_clk_i,    dest_out => h_clr_s);
   i_cdc_hsnap : xpm_cdc_single generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => q_snap_t,   dest_clk => hr_clk_i,    dest_out => h_snap_s);
   i_cdc_rack  : xpm_cdc_single generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => r_snap_ack, dest_clk => qnice_clk_i, dest_out => q_rack);
   i_cdc_hack  : xpm_cdc_single generic map (DEST_SYNC_FF => 3, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => h_snap_ack, dest_clk => qnice_clk_i, dest_out => q_hack);

   ---------------------------------------------------------------------------------------------
   -- clk_ram side: the SDRAM traffic
   ---------------------------------------------------------------------------------------------

   p_ram : process (clk_ram_i)
      variable cls   : natural range 0 to 7;
      variable rd    : std_logic;
      variable wr    : std_logic;
      variable w     : unsigned(8 downto 0);
      variable hcomp : std_logic;
   begin
      if rising_edge(clk_ram_i) then
         cls   := to_integer(unsigned(mem_i(47 downto 45)));
         rd    := mem_i(44);
         wr    := mem_i(43);
         hcomp := mem_i(49);
         w     := words_of(rd, mem_i(39 downto 36), mem_i(15 downto 8), mem_i(7 downto 0));
         f_wr  <= '0';

         r_cyc <= r_cyc + 1;
         if cls /= 0 then
            r_busy(maximum(cls, 1)) <= r_busy(maximum(cls, 1)) + 1;
         end if;
         if mem_i(41) = '1' then
            r_dewords <= r_dewords + 1;
         end if;

         -- frames
         r_vp_d <= mem_i(48);
         if mem_i(48) = '1' and r_vp_d = '0' then
            r_frames <= r_frames + 1;
         end if;

         -- commands: counted and sent to the mirror; a line start goes as a marker
         r_hcomp_d <= hcomp;
         if (rd = '1' or wr = '1') and cls /= 0 then
            r_ops(cls)   <= r_ops(cls) + 1;
            r_words(cls) <= r_words(cls) + w;
            f_din <= '0' & mem_i(47 downto 45) & wr & mem_i(31 downto 16) & mem_i(15 downto 8) &
                     std_logic_vector(w);
            if f_full = '0' and f_wr_busy = '0' then
               f_wr <= '1';
            else
               r_ovf <= r_ovf + 1;
            end if;
            if hcomp = '1' and r_hcomp_d = '0' then
               r_mark_pend <= '1';
            end if;
         elsif (hcomp = '1' and r_hcomp_d = '0') or r_mark_pend = '1' then
            r_mark_pend <= '0';
            f_din <= (37 => '1', others => '0');
            if f_full = '0' and f_wr_busy = '0' then
               f_wr <= '1';
            else
               r_ovf <= r_ovf + 1;
            end if;
         end if;

         -- per line
         if cls = 2 and (rd = '1' or wr = '1') then
            r_gl_cur <= r_gl_cur + w;
         end if;
         if cls > 1 then
            r_bl_cur <= r_bl_cur + 1;
         end if;
         r_lp_cur <= r_lp_cur + 1;
         if hcomp = '1' and r_hcomp_d = '0' then
            if r_gl_cur > r_gline then
               r_gline <= r_gl_cur;
            end if;
            if r_bl_cur > r_busyline then
               r_busyline <= r_bl_cur;
            end if;
            r_lineper <= r_lp_cur;
            r_gl_cur  <= (others => '0');
            r_bl_cur  <= (others => '0');
            r_lp_cur  <= to_unsigned(1, 32);
         end if;

         -- the CPU
         r_cpurd_d <= mem_i(51);
         if mem_i(51) = '1' and r_cpurd_d = '0' then
            r_cpurd <= r_cpurd + 1;
         end if;
         if mem_i(51) = '1' and mem_i(50) = '0' then
            r_cpustall  <= r_cpustall + 1;
            r_stall_cur <= r_stall_cur + 1;
            if r_stall_cur + 1 > r_cpumax then
               r_cpumax <= r_stall_cur + 1;
            end if;
         else
            r_stall_cur <= (others => '0');
         end if;

         -- snapshot and clear
         r_snap_d <= r_snap_s;
         if r_snap_s /= r_snap_d then
            r_snap(C_R_CYC)      <= r_cyc;
            r_snap(C_R_FRAMES)   <= r_frames;
            for k in 1 to 7 loop
               r_snap(C_R_BUSY + k - 1)  <= r_busy(k);
               r_snap(C_R_OPS + k - 1)   <= r_ops(k);
               r_snap(C_R_WORDS + k - 1) <= r_words(k);
            end loop;
            r_snap(C_R_DEWORDS)  <= r_dewords;
            r_snap(C_R_GLINE)    <= r_gline;
            r_snap(C_R_BUSYLINE) <= r_busyline;
            r_snap(C_R_LINEPER)  <= r_lineper;
            r_snap(C_R_CPURD)    <= r_cpurd;
            r_snap(C_R_CPUSTALL) <= r_cpustall;
            r_snap(C_R_CPUMAX)   <= r_cpumax;
            r_snap(C_R_OVF)      <= r_ovf;
            r_snap_ack           <= r_snap_s;
         end if;
         r_clr_d <= r_clr_s;
         if r_clr_s /= r_clr_d then
            r_cyc      <= (others => '0');
            r_frames   <= (others => '0');
            r_busy     <= (others => (others => '0'));
            r_ops      <= (others => (others => '0'));
            r_words    <= (others => (others => '0'));
            r_dewords  <= (others => '0');
            r_gline    <= (others => '0');
            r_busyline <= (others => '0');
            r_cpurd    <= (others => '0');
            r_cpustall <= (others => '0');
            r_cpumax   <= (others => '0');
            r_ovf      <= (others => '0');
         end if;
      end if;
   end process p_ram;

   i_fifo : xpm_fifo_async
      generic map (
         FIFO_MEMORY_TYPE    => "distributed",
         FIFO_WRITE_DEPTH    => 16,
         WRITE_DATA_WIDTH    => 38,
         READ_DATA_WIDTH     => 38,
         READ_MODE           => "fwft",
         FIFO_READ_LATENCY   => 0,
         CDC_SYNC_STAGES     => 2,
         RELATED_CLOCKS      => 0,
         USE_ADV_FEATURES    => "0000",
         WAKEUP_TIME         => 0
      )
      port map (
         sleep         => '0',
         rst           => '0',
         wr_clk        => clk_ram_i,
         wr_en         => f_wr,
         din           => f_din,
         full          => f_full,
         wr_rst_busy   => f_wr_busy,
         rd_clk        => hr_clk_i,
         rd_en         => f_rd,
         dout          => f_dout,
         empty         => f_empty,
         rd_rst_busy   => f_rd_busy,
         injectsbiterr => '0',
         injectdbiterr => '0'
      ); -- i_fifo

   ---------------------------------------------------------------------------------------------
   -- hr_clk side: the mirror
   ---------------------------------------------------------------------------------------------

   f_rd <= '1' when f_empty = '0' and f_rd_busy = '0' else '0';

   hr_byteenable_o <= "11";
   hr_writedata_o  <= std_logic_vector(e_addr(15 downto 0));
   hr_address_o    <= "0000000000" & std_logic_vector(e_addr);
   hr_burstcount_o <= e_bc;

   p_hr : process (hr_clk_i)
      variable lat  : unsigned(31 downto 0);
      variable latl : unsigned(31 downto 0);
      variable done : boolean;
      variable push : boolean;
      variable pop  : boolean;
      variable n    : unsigned(8 downto 0);
   begin
      if rising_edge(hr_clk_i) then
         h_now <= h_now + 1;
         h_cyc <= h_cyc + 1;
         done  := false;
         push  := false;
         pop   := false;

         -- arrivals: a marker sets the line start, a command joins the queue
         if f_rd = '1' then
            if f_dout(37) = '1' then
               h_line_ts <= h_now;
            elsif q_cnt < 2**C_QBITS then
               q_cmd(to_integer(q_wp)) <= f_dout(36 downto 0);
               q_arr(to_integer(q_wp)) <= h_now;
               q_lts(to_integer(q_wp)) <= h_line_ts;
               q_wp <= q_wp + 1;
               push := true;
            else
               h_qovf <= h_qovf + 1;
            end if;
         end if;

         -- the engine: bursts of at most 128 words
         case e_state is
            when S_IDLE =>
               hr_read_o  <= '0';
               hr_write_o <= '0';
               if q_cnt /= 0 then
                  e_cls  <= to_integer(unsigned(q_cmd(to_integer(q_rp))(36 downto 34)));
                  e_wr   <= q_cmd(to_integer(q_rp))(33);
                  e_addr <= '1' & unsigned(q_cmd(to_integer(q_rp))(29 downto 9));
                  e_left <= unsigned(q_cmd(to_integer(q_rp))(8 downto 0));
                  e_arr  <= q_arr(to_integer(q_rp));
                  e_lts  <= q_lts(to_integer(q_rp));
                  q_rp   <= q_rp + 1;
                  pop    := true;
                  e_state <= S_ISSUE;
               end if;

            when S_ISSUE =>
               n := e_left;
               if n > 128 then
                  n := to_unsigned(128, 9);
               end if;
               e_chunk <= n;
               e_bc    <= std_logic_vector(n(7 downto 0));
               e_left  <= e_left - n;
               if e_wr = '1' then
                  hr_write_o <= '1';
                  e_state    <= S_WDATA;
               else
                  hr_read_o  <= '1';
                  e_state    <= S_RDATA;
               end if;

            when S_RDATA =>
               if hr_waitrequest_i = '0' then
                  hr_read_o <= '0';
               end if;
               if hr_readdatavalid_i = '1' then
                  e_chunk <= e_chunk - 1;
                  if e_chunk = 1 then
                     e_addr <= e_addr + 128;
                     if e_left = 0 then
                        done := true;
                        e_state <= S_IDLE;
                     else
                        e_state <= S_ISSUE;
                     end if;
                  end if;
               end if;

            when S_WDATA =>
               if hr_waitrequest_i = '0' then
                  e_chunk <= e_chunk - 1;
                  if e_chunk = 1 then
                     hr_write_o <= '0';
                     e_addr <= e_addr + 128;
                     if e_left = 0 then
                        done := true;
                        e_state <= S_IDLE;
                     else
                        e_state <= S_ISSUE;
                     end if;
                  end if;
               end if;
         end case;

         if e_state /= S_IDLE then
            h_busy <= h_busy + 1;
         end if;

         if done then
            lat  := h_now - e_arr;
            latl := h_now - e_lts;
            h_ops <= h_ops + 1;
            if e_cls >= 1 and lat > h_lat(maximum(e_cls, 1)) then
               h_lat(maximum(e_cls, 1)) <= lat;
            end if;
            if e_cls = 2 then
               h_latsum <= h_latsum + lat;
               if latl > h_gline then
                  h_gline <= latl;
               end if;
            end if;
         end if;
         if e_state = S_RDATA and hr_readdatavalid_i = '1' then
            h_words <= h_words + 1;
         elsif e_state = S_WDATA and hr_waitrequest_i = '0' then
            h_words <= h_words + 1;
         end if;

         if push and not pop then
            q_cnt <= q_cnt + 1;
            if q_cnt + 1 > h_qmax then
               h_qmax <= resize(q_cnt + 1, 32);
            end if;
         elsif pop and not push then
            q_cnt <= q_cnt - 1;
         end if;

         -- snapshot and clear
         h_snap_d <= h_snap_s;
         if h_snap_s /= h_snap_d then
            h_snap(C_H_CYC)    <= h_cyc;
            h_snap(C_H_OPS)    <= h_ops;
            h_snap(C_H_WORDS)  <= h_words;
            h_snap(C_H_BUSY)   <= h_busy;
            for k in 1 to 7 loop
               h_snap(C_H_LAT + k - 1) <= h_lat(k);
            end loop;
            h_snap(C_H_GLINE)  <= h_gline;
            h_snap(C_H_QMAX)   <= h_qmax;
            h_snap(C_H_QOVF)   <= h_qovf;
            h_snap(C_H_LATSUM) <= h_latsum;
            h_snap_ack         <= h_snap_s;
         end if;
         h_clr_d <= h_clr_s;
         if h_clr_s /= h_clr_d then
            h_cyc    <= (others => '0');
            h_ops    <= (others => '0');
            h_words  <= (others => '0');
            h_busy   <= (others => '0');
            h_lat    <= (others => (others => '0'));
            h_gline  <= (others => '0');
            h_qmax   <= (others => '0');
            h_qovf   <= (others => '0');
            h_latsum <= (others => '0');
         end if;

         if hr_rst_i = '1' then
            e_state    <= S_IDLE;
            hr_read_o  <= '0';
            hr_write_o <= '0';
            q_wp       <= (others => '0');
            q_rp       <= (others => '0');
            q_cnt      <= (others => '0');
         end if;
      end if;
   end process p_hr;

end architecture synthesis;
