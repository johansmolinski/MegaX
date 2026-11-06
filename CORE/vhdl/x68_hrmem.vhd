-- MegaX: the R3 memory path. Takes the place of the core's SDRAM controller (SDRAMC.vhd) under
-- cachecont (fork memcont.vhd, generic EXT_RAMC) and keeps everything the SDRAM held in the
-- HyperRAM instead, through the framework's core port of the HyperRAM arbiter (doc/plan.md
-- section 4 item 8, step 2).
--
-- The clk_ram side behaves as SDRAMC towards cachecont (measured on SDRAMC with its chip model,
-- 2026-11-04):
--   - busy while a command runs, and in the very clock rd, wr or refrsh is high;
--   - a read from bgnaddr up, wrapping inside the 2**bwidth block, gives
--     ((end - bgn - 2) mod 2**bwidth) + 2 words with de, each with addr_rc (bgn + n, 8 bits)
--     and rddat: end - bgn words, the whole block when bgn = end, and one round more when
--     end = bgn + 1 (SDRAMC looks for the end two words ahead); in the clock after the last de
--     word, with busy already low, addr_rc and rddat carry one more word, the one at end, with
--     de low: cachecont's fast clear takes that word on de's falling edge;
--   - during a read addr_wc runs one clock ahead of addr_rc: it is the column of the next word
--     (SDRAMC: addr_wc <= curaddr, addr_rc <= curaddr one clock later). cachecont reads its write
--     cache and the dirty bits there (block RAM, one clock) and merges dirty words into the fill
--     and the GVRAM/TVRAM line reads. (megax-hr10/11 left addr_wc where the last write had put it:
--     when that word was dirty, every word of a fill became that word, and Human68k crashed at its
--     disk boot, 2026-11-06);
--   - abort stops the de words of a read;
--   - a write takes the words bgnaddr .. endaddr (no wrap), each one clock after addr_wc
--     pointed at it (cachecont's write data comes from block RAM), at least two: SDRAMC's write
--     burst always writes the word after bgnaddr too;
--   - refrsh is answered at once (HyperRAM refreshes itself);
--   - initdone only while the HyperRAM side is out of reset (hr_rst, synchronised): the M2M
--     reset holds hr_rst at power-on (the blue power LED, tens of ms) while clk_ram already
--     runs, and memcont, its GVRAM clear and the video start at initdone (megax-hr3 did not
--     boot: the reads issued then timed out, their commands stayed in the FIFO and ran after
--     the reset, and from then on every read got the words of the read four before it, the
--     tags being two bits). A read does not time out while hr_rst is high either.
-- Unlike SDRAMC, read words can come with gaps (de low, addr_rc and rddat held: the fast clear
-- then writes the held word again), and a write is posted: busy drops once its words are in the
-- FIFO; the HyperRAM side keeps the order of all commands.
--
-- HyperRAM layout (16-bit word addresses; the SDRAM's word address in brackets):
--   0x000000-0x07FFFF  ascal's frame buffer (1 MB, triple buffering off)
--   0x080000-0x0FFFFF  everything else, aliased (main RAM above 4 MB, TVRAM's unused SDRAM
--                      area, the D88 areas: R3 has no D88, the user 2026-11-04)
--   0x100000-0x13FFFF  GVRAM [0x740000-0x77FFFF] (cachecont uses the upper half)
--   0x180000-0x1FFFFF  IPL ROM and CGROM [0x780000-0x7FFFFF]
--   0x200000-0x3FFFFF  main RAM, 4 MB [0x000000-0x1FFFFF]
-- The machine must see at most 4 MB (x68_system sets vis_mem).
--
-- Clock domains: clk_ram (cachecont) and hr_clk (the arbiter), crossed by three x68_afifo:
-- commands (clk_ram -> hr_clk), write words (clk_ram -> hr_clk) and read words (hr_clk ->
-- clk_ram). An aborted read still delivers all its words: the clk_ram side counts them
-- (skip) and throws exactly that many away before it takes words again (the HyperRAM side
-- keeps the order). Besides, read commands and read words carry a 2-bit tag that counts the
-- reads, write commands and write words one that counts the writes, and a side throws away
-- words of another tag: words left over from a reset of one side. (Tags alone went wrong in
-- tb/hrmem: four aborted reads in a row, and the next read had the first one's tag.)
-- The HyperRAM side splits a command into bursts of at most 2**G_BURST_LOG2 words, aligned,
-- one at a time, so that ascal (the arbiter's first slave) never waits long behind the core.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_hrmem is
   generic (
      G_BURST_LOG2 : natural := 6           -- bursts of at most 64 words (at most 7: 8-bit burstcount)
   );
   port (
      -- cachecont's side (SDRAMC's port list), clk_ram
      clk_i               : in  std_logic;
      rstn_i              : in  std_logic;
      addr_high_i         : in  std_logic_vector(15 downto 0);
      bgnaddr_i           : in  std_logic_vector(7 downto 0);
      endaddr_i           : in  std_logic_vector(7 downto 0);
      bwidth_i            : in  std_logic_vector(3 downto 0);     -- 1 .. 8
      addr_rc_o           : out std_logic_vector(7 downto 0);
      addr_wc_o           : out std_logic_vector(7 downto 0);
      rddat_o             : out std_logic_vector(15 downto 0);
      wrdat_i             : in  std_logic_vector(15 downto 0);
      de_o                : out std_logic;
      we_i                : in  std_logic_vector(1 downto 0);
      rd_i                : in  std_logic;
      wr_i                : in  std_logic;
      refrsh_i            : in  std_logic;
      abort_i             : in  std_logic;
      busy_o              : out std_logic;
      initdone_o          : out std_logic;

      -- the HyperRAM arbiter's core port (Avalon, 16-bit words), hr_clk
      hr_clk_i            : in  std_logic;
      hr_rst_i            : in  std_logic;
      hr_write_o          : out std_logic;
      hr_read_o           : out std_logic;
      hr_address_o        : out std_logic_vector(31 downto 0);
      hr_writedata_o      : out std_logic_vector(15 downto 0);
      hr_byteenable_o     : out std_logic_vector(1 downto 0);
      hr_burstcount_o     : out std_logic_vector(7 downto 0);
      hr_readdata_i       : in  std_logic_vector(15 downto 0);
      hr_readdatavalid_i  : in  std_logic;
      hr_waitrequest_i    : in  std_logic;

      -- the bring-up flags (sticky, for the LEDs, mega65.vhd): 7 a read timed out, 6 commands
      -- waited 10 ms in the FIFO with the HyperRAM side idle, 5 a read waited 10 ms for its
      -- words, 4 waitrequest held 10 ms, 3 hr_rst (live), 2 a burst has completed, 1 busy
      -- 13 ms without a break, 0 initdone (live)
      dbg_o               : out std_logic_vector(7 downto 0);
      -- the bring-up state (temporary, QNICE device C_DEV_X68_DEBUG window 5, tools/hrstate.py):
      -- words 0..15 the clk_ram side, 16..31 the hr_clk side (see p_dbgx_*)
      dbgx_o              : out std_logic_vector(511 downto 0)
   );
end entity x68_hrmem;

architecture rtl of x68_hrmem is

   constant C_BURST : natural := 2**G_BURST_LOG2;

   function hr_map(a : unsigned(23 downto 0)) return unsigned is
   begin
      if a(23 downto 21) = "000" then
         return "1" & a(20 downto 0);                        -- main RAM, first 4 MB
      elsif a(23 downto 18) = "011101" then
         return "0100" & a(17 downto 0);                     -- GVRAM
      elsif a(23 downto 19) = "01111" then
         return "011" & a(18 downto 0);                      -- IPL ROM, CGROM
      else
         return "001" & a(18 downto 0);                      -- the rest, aliased
      end if;
   end function hr_map;

   function u9(n : natural) return unsigned is
   begin
      return to_unsigned(n, 9);
   end function u9;

   -- command FIFO: 41..40 tag, 39 write, 38..17 start address, 16..9 wrap mask, 8..0 words
   signal c_wr_en      : std_logic := '0';
   signal c_wr_data    : std_logic_vector(41 downto 0);
   signal c_wr_free    : unsigned(4 downto 0);
   signal c_rd_en      : std_logic := '0';
   signal c_rd_data    : std_logic_vector(41 downto 0);
   signal c_rd_count   : unsigned(4 downto 0);

   -- write words: 19..18 tag, 17..16 byte enables, 15..0 data
   signal w_wr_en      : std_logic := '0';
   signal w_wr_data    : std_logic_vector(19 downto 0);
   signal w_wr_free    : unsigned(9 downto 0);
   signal w_rd_en      : std_logic;
   signal w_rd_data    : std_logic_vector(19 downto 0);
   signal w_rd_count   : unsigned(9 downto 0);

   -- read words: 17..16 tag, 15..0 data
   signal r_wr_en      : std_logic := '0';
   signal r_wr_data    : std_logic_vector(17 downto 0);
   signal r_wr_free    : unsigned(8 downto 0);
   signal r_rd_en      : std_logic;
   signal r_rd_data    : std_logic_vector(17 downto 0);
   signal r_rd_count   : unsigned(8 downto 0);

   ------------------------------------------------------------------------------------------
   -- clk_ram side
   type t_state is (S_IDLE, S_RCMD, S_RDATA, S_RLAST, S_WWAIT, S_WCAP, S_WCMD);
   signal state        : t_state := S_IDLE;
   signal tag          : unsigned(1 downto 0) := "00";            -- of the reads
   signal wtag         : unsigned(1 downto 0) := "00";            -- of the writes
   signal l_bgn        : unsigned(7 downto 0) := (others => '0');
   signal l_m          : unsigned(8 downto 0) := (others => '0');   -- de words of a read
   signal l_n          : unsigned(8 downto 0) := (others => '0');   -- words to the HyperRAM side
   signal l_start      : unsigned(21 downto 0) := (others => '0');
   signal l_mask       : unsigned(7 downto 0) := (others => '0');
   signal cnt          : unsigned(8 downto 0) := (others => '0');
   signal wc           : unsigned(7 downto 0) := (others => '0');
   signal cap_on       : std_logic := '0';
   signal idle_cnt     : unsigned(15 downto 0) := (others => '0');
   signal skip         : unsigned(11 downto 0) := (others => '0');   -- words of aborted reads still due
   signal r_skip_pop   : std_logic;
   signal init_cnt     : unsigned(8 downto 0) := (others => '0');
   signal hrrst_s1     : std_logic := '1';                         -- hr_rst into clk_ram
   signal hrrst_s2     : std_logic := '1';
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of hrrst_s1, hrrst_s2 : signal is "TRUE";
   signal de_r         : std_logic := '0';
   signal addr_rc_r    : std_logic_vector(7 downto 0) := (others => '0');
   signal rddat_r      : std_logic_vector(15 downto 0) := (others => '0');
   signal r_head_ok    : std_logic;
   signal r_head_stale : std_logic;
   signal r_pop        : std_logic;
   signal r_take       : std_logic;

   ------------------------------------------------------------------------------------------
   -- hr_clk side
   type t_hstate is (H_IDLE, H_RWAIT, H_RREQ, H_RDATA, H_WWAIT, H_WBURST);
   signal hstate       : t_hstate := H_IDLE;
   signal h_tag        : std_logic_vector(1 downto 0) := "00";
   signal h_wr         : std_logic := '0';
   signal h_addr       : unsigned(21 downto 0) := (others => '0');
   signal h_mask       : unsigned(7 downto 0) := (others => '0');
   signal h_left       : unsigned(8 downto 0) := (others => '0');
   signal h_len        : unsigned(8 downto 0) := (others => '0');
   signal h_beats      : unsigned(8 downto 0) := (others => '0');
   signal h_write      : std_logic := '0';
   signal h_read       : std_logic := '0';
   signal h_wdata      : std_logic_vector(15 downto 0) := (others => '0');
   signal h_be         : std_logic_vector(1 downto 0) := "11";
   signal h_wpop       : std_logic;
   signal h_wstart     : std_logic;
   signal h_next_len   : unsigned(8 downto 0);
   signal h_len_r      : unsigned(8 downto 0) := (others => '0');   -- h_next_len, registered
   signal h_prep       : std_logic := '1';                          -- h_len_r not yet valid

   -- the bring-up flags (dbg_o)
   signal d_busy_cnt   : unsigned(20 downto 0) := (others => '0');
   signal d_stuck      : std_logic := '0';
   signal d_tmo        : std_logic := '0';
   signal d_wq_cnt     : unsigned(20 downto 0) := (others => '0');
   signal d_rd_cnt     : unsigned(20 downto 0) := (others => '0');
   signal d_id_cnt     : unsigned(20 downto 0) := (others => '0');
   signal d_wq_stuck   : std_logic := '0';
   signal d_rd_stuck   : std_logic := '0';
   signal d_id_stuck   : std_logic := '0';
   signal d_burst      : std_logic := '0';

   -- the bring-up state (dbgx_o)
   type t_w16 is array (natural range <>) of std_logic_vector(15 downto 0);
   signal x_ram        : t_w16(0 to 15) := (others => (others => '0'));
   signal x_hr         : t_w16(0 to 15) := (others => (others => '0'));
   signal x_nrd, x_nrdone, x_nabort, x_ntmo, x_nwr : unsigned(15 downto 0) := (others => '0');
   signal x_lrd_addrh  : std_logic_vector(15 downto 0) := (others => '0');
   signal x_lrd_be     : std_logic_vector(15 downto 0) := (others => '0');
   signal x_lrd_bw     : std_logic_vector(3 downto 0) := (others => '0');
   signal x_ndew       : unsigned(15 downto 0) := (others => '0');
   signal x_hcmd, x_hrdw, x_hbst, x_hwrw : unsigned(15 downto 0) := (others => '0');

begin

   ------------------------------------------------------------------------------------------
   -- the FIFOs
   ------------------------------------------------------------------------------------------

   i_cmd : entity work.x68_afifo
      generic map (G_WIDTH => 42, G_LOG2 => 4)
      port map (
         wr_clk_i => clk_i, wr_en_i => c_wr_en, wr_data_i => c_wr_data, wr_free_o => c_wr_free,
         rd_clk_i => hr_clk_i, rd_en_i => c_rd_en, rd_data_o => c_rd_data, rd_count_o => c_rd_count);

   i_wdat : entity work.x68_afifo
      generic map (G_WIDTH => 20, G_LOG2 => 9)
      port map (
         wr_clk_i => clk_i, wr_en_i => w_wr_en, wr_data_i => w_wr_data, wr_free_o => w_wr_free,
         rd_clk_i => hr_clk_i, rd_en_i => w_rd_en, rd_data_o => w_rd_data, rd_count_o => w_rd_count);

   i_rdat : entity work.x68_afifo
      generic map (G_WIDTH => 18, G_LOG2 => 8)
      port map (
         wr_clk_i => hr_clk_i, wr_en_i => r_wr_en, wr_data_i => r_wr_data, wr_free_o => r_wr_free,
         rd_clk_i => clk_i, rd_en_i => r_rd_en, rd_data_o => r_rd_data, rd_count_o => r_rd_count);

   ------------------------------------------------------------------------------------------
   -- clk_ram side
   ------------------------------------------------------------------------------------------

   busy_o     <= '0' when state = S_IDLE and rd_i = '0' and wr_i = '0' and refrsh_i = '0' else '1';
   de_o       <= de_r;
   addr_rc_o  <= addr_rc_r;
   rddat_o    <= rddat_r;
   addr_wc_o  <= std_logic_vector(wc);
   initdone_o <= init_cnt(8) and not hrrst_s2;

   -- read words: the head belongs to the read in progress, or it is stale (an aborted read,
   -- a reset): stale words go at once, in every state
   r_skip_pop   <= '1' when skip /= 0 and r_rd_count /= 0 else '0';
   r_head_ok    <= '1' when skip = 0 and (state = S_RDATA or state = S_RLAST) and r_rd_count /= 0 and
                            unsigned(r_rd_data(17 downto 16)) = tag else '0';
   r_head_stale <= '1' when skip = 0 and r_rd_count /= 0 and
                            ((state /= S_RDATA and state /= S_RLAST) or
                             unsigned(r_rd_data(17 downto 16)) /= tag) else '0';
   r_rd_en      <= r_skip_pop or r_head_stale or r_pop;

   -- a read word goes to cachecont (S_RDATA: the last de word only when the word after it is
   -- here too), or the word after the last one (S_RLAST)
   r_take <= '1' when state = S_RDATA and abort_i = '0' and r_head_ok = '1' and
                      (cnt /= l_m - 1 or r_rd_count >= 2) else '0';
   r_pop  <= '1' when r_take = '1' or (state = S_RLAST and r_head_ok = '1') else '0';

   p_ram : process (clk_i)
      variable v_mask  : unsigned(7 downto 0);
      variable v_bgn   : unsigned(7 downto 0);
      variable v_end   : unsigned(7 downto 0);
      variable v_m     : unsigned(8 downto 0);
      variable v_n     : unsigned(8 downto 0);
      variable v_last  : boolean;
      variable v_skip  : unsigned(11 downto 0);
   begin
      if rising_edge(clk_i) then
         v_skip := skip;
         if r_skip_pop = '1' then
            v_skip := v_skip - 1;
         end if;
         c_wr_en  <= '0';
         w_wr_en  <= '0';
         de_r     <= '0';
         hrrst_s1 <= hr_rst_i;
         hrrst_s2 <= hrrst_s1;

         if init_cnt(8) = '0' then
            init_cnt <= init_cnt + 1;
         end if;

         case state is
            when S_IDLE =>
               idle_cnt <= (others => '0');
               v_bgn  := unsigned(bgnaddr_i);
               v_end  := unsigned(endaddr_i);
               v_mask := shift_right(to_unsigned(255, 8), 8 - to_integer(unsigned(bwidth_i)));
               l_bgn  <= v_bgn;
               l_mask <= v_mask;
               l_start <= hr_map(unsigned(addr_high_i) & v_bgn);
               if rd_i = '1' then
                  v_m := ('0' & ((v_end - v_bgn - 2) and v_mask)) + 2;
                  l_m   <= v_m;
                  l_n   <= v_m + 1;                          -- the word after them too
                  cnt   <= (others => '0');
                  wc    <= v_bgn;                            -- addr_wc: the next word (see S_RDATA)
                  tag   <= tag + 1;
                  state <= S_RCMD;
               elsif wr_i = '1' then
                  if v_end >= v_bgn then
                     v_n := ('0' & v_end) - ('0' & v_bgn) + 1;
                  else
                     v_n := u9(256) - ('0' & v_bgn);
                  end if;
                  if v_n < 2 then
                     v_n := u9(2);
                  end if;
                  l_n    <= v_n;
                  cnt    <= (others => '0');
                  wtag   <= wtag + 1;
                  wc     <= v_bgn;
                  cap_on <= '0';
                  state  <= S_WWAIT;
               end if;

            -- reads
            when S_RCMD =>
               if c_wr_free /= 0 then
                  c_wr_data <= std_logic_vector(tag) & '0' & std_logic_vector(l_start) &
                               std_logic_vector(l_mask) & std_logic_vector(l_n);
                  c_wr_en   <= '1';
                  state     <= S_RDATA;
               end if;

            when S_RDATA =>
               idle_cnt <= idle_cnt + 1;
               v_last := cnt = l_m - 1;
               if abort_i = '1' then
                  v_skip := v_skip + resize(l_n - cnt, 12);     -- its words still come
                  state  <= S_IDLE;
               elsif r_take = '1' then
                  idle_cnt  <= (others => '0');
                  de_r      <= '1';
                  addr_rc_r <= std_logic_vector(l_bgn + cnt(7 downto 0));
                  rddat_r   <= r_rd_data(15 downto 0);
                  cnt <= cnt + 1;
                  wc  <= wc + 1;
                  if v_last then
                     state <= S_RLAST;
                  end if;
               elsif idle_cnt = x"FFFF" then
                  state <= S_IDLE;                              -- lost: never hang cachecont
               end if;
               if hrrst_s2 = '1' then
                  idle_cnt <= (others => '0');                  -- its words come after the reset
               end if;

            when S_RLAST =>
               -- the word after the last de word, de low (busy drops with it)
               addr_rc_r <= std_logic_vector(l_bgn + cnt(7 downto 0));
               if r_head_ok = '1' then
                  rddat_r <= r_rd_data(15 downto 0);
                  state   <= S_IDLE;
               end if;

            -- writes
            when S_WWAIT =>
               if w_wr_free >= l_n then
                  state <= S_WCAP;
               end if;

            when S_WCAP =>
               -- addr_wc steps one word per clock; wrdat and we follow it one clock later
               wc     <= wc + 1;
               cap_on <= '1';
               if cap_on = '1' then
                  w_wr_data <= std_logic_vector(wtag) & we_i & wrdat_i;
                  w_wr_en   <= '1';
                  cnt       <= cnt + 1;
                  if cnt = l_n - 1 then
                     state <= S_WCMD;
                  end if;
               end if;

            when S_WCMD =>
               if c_wr_free /= 0 then
                  c_wr_data <= std_logic_vector(wtag) & '1' & std_logic_vector(l_start) &
                               x"FF" & std_logic_vector(l_n);
                  c_wr_en   <= '1';
                  state     <= S_IDLE;
               end if;
         end case;

         skip <= v_skip;

         if rstn_i = '0' then
            state    <= S_IDLE;
            init_cnt <= (others => '0');
            skip     <= (others => '0');
         end if;
      end if;
   end process p_ram;

   ------------------------------------------------------------------------------------------
   -- hr_clk side
   ------------------------------------------------------------------------------------------

   hr_write_o      <= h_write;
   hr_read_o       <= h_read;
   hr_address_o    <= "0000000000" & std_logic_vector(h_addr);
   hr_writedata_o  <= h_wdata;
   hr_byteenable_o <= h_be;
   hr_burstcount_o <= std_logic_vector(h_len(7 downto 0));

   -- the next burst: to the end of the wrap block, to the next burst boundary, at most the rest
   p_len : process (all)
      variable v_blk : unsigned(8 downto 0);
      variable v_bst : unsigned(8 downto 0);
      variable v_len : unsigned(8 downto 0);
   begin
      v_blk := ('0' & h_mask) - ('0' & (h_addr(7 downto 0) and h_mask)) + 1;
      v_bst := u9(C_BURST) - ('0' & resize(h_addr(G_BURST_LOG2 - 1 downto 0), 8));
      v_len := h_left;
      if v_blk < v_len then
         v_len := v_blk;
      end if;
      if v_bst < v_len then
         v_len := v_bst;
      end if;
      h_next_len <= v_len;
   end process p_len;

   -- write words of another tag (a write lost by a reset of this side) are dropped
   h_wstart <= '1' when hstate = H_WWAIT and h_prep = '0' and h_left /= 0 and w_rd_count >= h_len_r and
                        w_rd_data(19 downto 18) = h_tag else '0';
   h_wpop   <= '1' when h_wstart = '1' or
                        (hstate = H_WBURST and hr_waitrequest_i = '0' and h_beats /= 1) else '0';
   -- (only while this write still has words to come: the clock after its last burst, the head
   -- is already the next write's)
   w_rd_en  <= '1' when (hstate = H_WWAIT and h_prep = '0' and h_left /= 0 and w_rd_count /= 0 and
                         w_rd_data(19 downto 18) /= h_tag) or h_wpop = '1' else '0';

   p_hr : process (hr_clk_i)
      variable v_addr : unsigned(21 downto 0);
      variable v_got  : unsigned(8 downto 0);
   begin
      if rising_edge(hr_clk_i) then
         c_rd_en <= '0';
         r_wr_en <= '0';
         -- the next burst's length, one clock after h_addr, h_left and h_mask changed (every
         -- state that changes them sets h_prep, the wait states then skip a clock)
         h_len_r <= h_next_len;
         h_prep  <= '0';

         case hstate is
            when H_IDLE =>
               -- (not in reset: the reset below would put the state back, the command taken
               -- out of the FIFO would be lost and its read would wait for the timeout, tb/sim)
               if c_rd_count /= 0 and c_rd_en = '0' and hr_rst_i = '0' then
                  h_tag  <= c_rd_data(41 downto 40);
                  h_wr   <= c_rd_data(39);
                  h_addr <= unsigned(c_rd_data(38 downto 17));
                  h_mask <= unsigned(c_rd_data(16 downto 9));
                  h_left <= unsigned(c_rd_data(8 downto 0));
                  h_prep <= '1';
                  c_rd_en <= '1';
                  if c_rd_data(39) = '1' then
                     hstate <= H_WWAIT;
                  else
                     hstate <= H_RWAIT;
                  end if;
               end if;

            -- reads: one burst at a time, only when its words fit into the read FIFO
            when H_RWAIT =>
               if h_prep = '1' then
                  null;
               elsif h_left = 0 then
                  hstate <= H_IDLE;
               elsif r_wr_free >= h_len_r and hr_rst_i = '0' then
                  h_len   <= h_len_r;
                  h_beats <= h_len_r;
                  h_be    <= "11";
                  h_read  <= '1';
                  hstate  <= H_RREQ;
               end if;

            when H_RREQ =>
               if hr_waitrequest_i = '0' then
                  h_read <= '0';
                  hstate <= H_RDATA;
               end if;

            when H_RDATA =>
               if hr_readdatavalid_i = '1' then
                  r_wr_data <= h_tag & hr_readdata_i;
                  r_wr_en   <= '1';
                  h_beats   <= h_beats - 1;
                  if h_beats = 1 then
                     v_addr := h_addr + h_len;
                     h_addr <= h_addr(21 downto 8) &
                               ((h_addr(7 downto 0) and not h_mask) or (v_addr(7 downto 0) and h_mask));
                     h_left <= h_left - h_len;
                     h_prep <= '1';
                     hstate <= H_RWAIT;
                  end if;
               end if;

            -- writes: a burst starts when all its words are here; the data register moves on
            -- with every accepted beat
            when H_WWAIT =>
               if h_prep = '1' then
                  null;
               elsif h_left = 0 then
                  hstate <= H_IDLE;
               elsif h_wstart = '1' then
                  h_len   <= h_len_r;
                  h_beats <= h_len_r;
                  h_wdata <= w_rd_data(15 downto 0);
                  h_be    <= w_rd_data(17 downto 16);
                  h_write <= '1';
                  hstate  <= H_WBURST;
               end if;

            when H_WBURST =>
               if hr_waitrequest_i = '0' then
                  h_beats <= h_beats - 1;
                  if h_beats = 1 then
                     h_write <= '0';
                     h_addr  <= h_addr + h_len;
                     h_left  <= h_left - h_len;
                     h_prep  <= '1';
                     hstate  <= H_WWAIT;
                  else
                     h_wdata <= w_rd_data(15 downto 0);
                     h_be    <= w_rd_data(17 downto 16);
                  end if;
               end if;
         end case;

         -- hr_rst (the framework resets the HyperRAM with every core reset, i.e. every press of the
         -- reset button, clk_m2m.vhd): the controller drops the burst in flight. A read resumes
         -- after the reset with its first word not yet received: the clk_ram side waits for all
         -- its words (megax-hr13: after a reset the read was lost, x68_hrmem gave up after its
         -- timeout, cachecont's read block kept the line without its words and the 68000 waited
         -- for ever). A write is dropped: its words left in the FIFO go by their tag; the X68000 is
         -- reset at the same time.
         if hr_rst_i = '1' then
            h_write <= '0';
            h_read  <= '0';
            case hstate is
               when H_RWAIT | H_RREQ =>
                  hstate <= H_RWAIT;
               when H_RDATA =>
                  if not (hr_readdatavalid_i = '1' and h_beats = 1) then   -- (else done above)
                     v_got := h_len - h_beats;
                     if hr_readdatavalid_i = '1' then
                        v_got := v_got + 1;
                     end if;
                     v_addr := h_addr + v_got;
                     h_addr <= h_addr(21 downto 8) &
                               ((h_addr(7 downto 0) and not h_mask) or (v_addr(7 downto 0) and h_mask));
                     h_left <= h_left - v_got;
                     h_prep <= '1';
                     hstate <= H_RWAIT;
                  end if;
               when others =>
                  hstate <= H_IDLE;
            end case;
         end if;
      end if;
   end process p_hr;

   ------------------------------------------------------------------------------------------
   -- the bring-up flags
   ------------------------------------------------------------------------------------------

   p_dbg_ram : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if state = S_IDLE and rd_i = '0' and wr_i = '0' and refrsh_i = '0' then
            d_busy_cnt <= (others => '0');
         elsif d_busy_cnt(20) = '0' then
            d_busy_cnt <= d_busy_cnt + 1;
         else
            d_stuck <= '1';
         end if;
         if state = S_RDATA and idle_cnt = x"FFFF" then
            d_tmo <= '1';
         end if;
      end if;
   end process p_dbg_ram;

   p_dbg_hr : process (hr_clk_i)
   begin
      if rising_edge(hr_clk_i) then
         if (hstate = H_RREQ or hstate = H_WBURST) and hr_waitrequest_i = '1' then
            if d_wq_cnt(20) = '0' then d_wq_cnt <= d_wq_cnt + 1; else d_wq_stuck <= '1'; end if;
         else
            d_wq_cnt <= (others => '0');
         end if;
         if hstate = H_RDATA and hr_readdatavalid_i = '0' then
            if d_rd_cnt(20) = '0' then d_rd_cnt <= d_rd_cnt + 1; else d_rd_stuck <= '1'; end if;
         else
            d_rd_cnt <= (others => '0');
         end if;
         if hstate = H_IDLE and c_rd_count /= 0 then
            if d_id_cnt(20) = '0' then d_id_cnt <= d_id_cnt + 1; else d_id_stuck <= '1'; end if;
         else
            d_id_cnt <= (others => '0');
         end if;
         if (hstate = H_RDATA and hr_readdatavalid_i = '1' and h_beats = 1) or
            (hstate = H_WBURST and hr_waitrequest_i = '0' and h_beats = 1) then
            d_burst <= '1';
         end if;
      end if;
   end process p_dbg_hr;

   -- the bring-up state: counters and the live state of both sides
   p_dbgx_ram : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if state = S_IDLE and rd_i = '1' then
            x_nrd       <= x_nrd + 1;
            x_lrd_addrh <= addr_high_i;
            x_lrd_be    <= bgnaddr_i & endaddr_i;
            x_lrd_bw    <= bwidth_i;
         end if;
         if state = S_IDLE and rd_i = '0' and wr_i = '1' then
            x_nwr <= x_nwr + 1;
         end if;
         if state = S_RLAST and r_head_ok = '1' then
            x_nrdone <= x_nrdone + 1;
         end if;
         if state = S_RDATA and abort_i = '1' then
            x_nabort <= x_nabort + 1;
         end if;
         if state = S_RDATA and abort_i = '0' and r_take = '0' and idle_cnt = x"FFFF" then
            x_ntmo <= x_ntmo + 1;
         end if;
         if de_r = '1' then
            x_ndew <= x_ndew + 1;
         end if;
         x_ram(0)  <= std_logic_vector(to_unsigned(t_state'pos(state), 4)) & hrrst_s2 & rd_i & wr_i &
                      refrsh_i & abort_i & init_cnt(8) & std_logic_vector(tag) & std_logic_vector(wtag) &
                      de_r & cap_on;
         x_ram(1)  <= "0000000" & std_logic_vector(cnt);
         x_ram(2)  <= "0000000" & std_logic_vector(l_m);
         x_ram(3)  <= "0000000" & std_logic_vector(l_n);
         x_ram(4)  <= "0000" & std_logic_vector(skip);
         x_ram(5)  <= "00" & std_logic_vector(c_wr_free) & std_logic_vector(r_rd_count);
         x_ram(6)  <= "000000" & std_logic_vector(w_wr_free);
         x_ram(7)  <= std_logic_vector(idle_cnt);
         x_ram(8)  <= std_logic_vector(x_nrd);
         x_ram(9)  <= std_logic_vector(x_nrdone);
         x_ram(10) <= std_logic_vector(x_nabort);
         x_ram(11) <= std_logic_vector(x_ntmo);
         x_ram(12) <= std_logic_vector(x_nwr);
         x_ram(13) <= x_lrd_addrh;
         x_ram(14) <= x_lrd_be;
         x_ram(15) <= x_lrd_bw & std_logic_vector(x_ndew(11 downto 0));
      end if;
   end process p_dbgx_ram;

   p_dbgx_hr : process (hr_clk_i)
   begin
      if rising_edge(hr_clk_i) then
         if hstate = H_IDLE and c_rd_count /= 0 and c_rd_en = '0' and hr_rst_i = '0' then
            x_hcmd <= x_hcmd + 1;
         end if;
         if hstate = H_RDATA and hr_readdatavalid_i = '1' then
            x_hrdw <= x_hrdw + 1;
         end if;
         if hstate = H_WBURST and hr_waitrequest_i = '0' then
            x_hwrw <= x_hwrw + 1;
         end if;
         if (hstate = H_RREQ or hstate = H_WBURST) and hr_waitrequest_i = '0' then
            x_hbst <= x_hbst + 1;
         end if;
         x_hr(0)  <= std_logic_vector(to_unsigned(t_hstate'pos(hstate), 4)) & h_tag & h_wr & h_prep &
                     hr_rst_i & hr_waitrequest_i & hr_readdatavalid_i & h_read & h_write & "000";
         x_hr(1)  <= "0000000" & std_logic_vector(h_left);
         x_hr(2)  <= "0000000" & std_logic_vector(h_beats);
         x_hr(3)  <= "0000000" & std_logic_vector(h_len);
         x_hr(4)  <= std_logic_vector(h_addr(15 downto 0));
         x_hr(5)  <= std_logic_vector(h_mask) & "00" & std_logic_vector(h_addr(21 downto 16));
         x_hr(6)  <= "00000000000" & std_logic_vector(c_rd_count);
         x_hr(7)  <= "000000" & std_logic_vector(w_rd_count);
         x_hr(8)  <= "0000000" & std_logic_vector(r_wr_free);
         x_hr(9)  <= std_logic_vector(x_hcmd);
         x_hr(10) <= std_logic_vector(x_hrdw);
         x_hr(11) <= std_logic_vector(x_hwrw);
         x_hr(12) <= std_logic_vector(x_hbst);
         x_hr(13) <= c_rd_data(41 downto 26);
         x_hr(14) <= c_rd_data(25 downto 10);
         x_hr(15) <= "000000" & c_rd_data(9 downto 0);
      end if;
   end process p_dbgx_hr;

   g_dbgx : for i in 0 to 15 generate
      dbgx_o(16 * i + 15 downto 16 * i)         <= x_ram(i);
      dbgx_o(256 + 16 * i + 15 downto 256 + 16 * i) <= x_hr(i);
   end generate g_dbgx;

   dbg_o <= d_tmo & d_id_stuck & d_rd_stuck & d_wq_stuck & hr_rst_i & d_burst & d_stuck & init_cnt(8);

end architecture rtl;
