----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- R3 bring-up (temporary, X68_HRMEM): a self-test of the HyperRAM memory path before the
-- machine gets it. Sits between memcont and x68_hrmem (x68_system G_HR) on the SDRAMC-like
-- interface; after x68_hrmem's initdone it writes 24 blocks of 256 words (main RAM low and high,
-- GVRAM) in full, writes them again with byte enables (per word "10", "01", "00", "11"), reads them
-- back and compares every word; then it hands the interface over (memcont sees initdone only
-- now; before, busy is held, so a command of cachecont's waits and is answered by nothing).
-- result_o: 0 done, 1 a word differed, 2 a command was busy for 2**20 clocks (the test ends there),
-- 3 a difference in a byte the masked pass did not write (byte enables wrong); err_o the first
-- difference: block, column, read and expected word.
--
-- done by Johan Smolinski in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_hrtest is
   port (
      clk_i          : in  std_logic;                       -- clk_ram
      rstn_i         : in  std_logic;

      -- memcont's side
      m_addrh_i      : in  std_logic_vector(15 downto 0);
      m_bgn_i        : in  std_logic_vector(7 downto 0);
      m_end_i        : in  std_logic_vector(7 downto 0);
      m_bwidth_i     : in  std_logic_vector(3 downto 0);
      m_wrdat_i      : in  std_logic_vector(15 downto 0);
      m_we_i         : in  std_logic_vector(1 downto 0);
      m_rd_i         : in  std_logic;
      m_wr_i         : in  std_logic;
      m_refrsh_i     : in  std_logic;
      m_abort_i      : in  std_logic;
      m_addr_rc_o    : out std_logic_vector(7 downto 0);
      m_addr_wc_o    : out std_logic_vector(7 downto 0);
      m_rddat_o      : out std_logic_vector(15 downto 0);
      m_de_o         : out std_logic;
      m_busy_o       : out std_logic;
      m_initdone_o   : out std_logic;

      -- x68_hrmem's side
      x_addrh_o      : out std_logic_vector(15 downto 0);
      x_bgn_o        : out std_logic_vector(7 downto 0);
      x_end_o        : out std_logic_vector(7 downto 0);
      x_bwidth_o     : out std_logic_vector(3 downto 0);
      x_wrdat_o      : out std_logic_vector(15 downto 0);
      x_we_o         : out std_logic_vector(1 downto 0);
      x_rd_o         : out std_logic;
      x_wr_o         : out std_logic;
      x_refrsh_o     : out std_logic;
      x_abort_o      : out std_logic;
      x_addr_rc_i    : in  std_logic_vector(7 downto 0);
      x_addr_wc_i    : in  std_logic_vector(7 downto 0);
      x_rddat_i      : in  std_logic_vector(15 downto 0);
      x_de_i         : in  std_logic;
      x_busy_i       : in  std_logic;
      x_initdone_i   : in  std_logic;

      result_o       : out std_logic_vector(3 downto 0);
      err_o          : out std_logic_vector(44 downto 0)    -- 44..40 block, 39..32 column, 31..16 read, 15..0 expected
   );
end entity x68_hrtest;

architecture rtl of x68_hrtest is

   constant C_NBLK : natural := 24;
   type t_blk is array (0 to C_NBLK - 1) of std_logic_vector(15 downto 0);
   constant C_BLK : t_blk := (
      x"0100", x"0101", x"0102", x"0103", x"0104", x"0105", x"0106", x"0107",
      x"0108", x"0109", x"010A", x"010B", x"010C", x"010D", x"010E", x"010F",
      x"7400", x"7401", x"77FE", x"77FF",           -- GVRAM
      x"1FFC", x"1FFD", x"1FFE", x"1FFF");          -- the top of the 4 MB of main RAM

   type t_state is (T_INIT, T_CMD, T_WAIT, T_NEXT, T_DONE);
   signal state   : t_state := T_INIT;
   signal pass    : natural range 0 to 2 := 0;          -- 0 full write, 1 masked write, 2 read
   signal blk     : natural range 0 to C_NBLK - 1 := 0;
   signal tmo     : unsigned(20 downto 0) := (others => '0');
   signal t_rd, t_wr : std_logic := '0';
   signal t_wrdat : std_logic_vector(15 downto 0) := (others => '0');
   signal t_we    : std_logic_vector(1 downto 0) := "00";
   signal done    : std_logic := '0';
   signal f_err, f_tmo, f_lane : std_logic := '0';
   signal err     : std_logic_vector(44 downto 0) := (others => '0');

   function d_full(b : natural; c : unsigned(7 downto 0)) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((b * 4099 + 4660) mod 65536, 16) + (c & c(3 downto 0) & c(7 downto 4)));
   end function;

   function d_mask(b : natural; c : unsigned(7 downto 0)) return std_logic_vector is
   begin
      return std_logic_vector(c) & std_logic_vector(to_unsigned(b, 8)) xor x"A5C3";
   end function;

   function we_mask(c : unsigned(7 downto 0)) return std_logic_vector is
   begin
      case c(1 downto 0) is
         when "00"   => return "10";
         when "01"   => return "01";
         when "10"   => return "00";
         when others => return "11";
      end case;
   end function;

   function expect(b : natural; c : unsigned(7 downto 0)) return std_logic_vector is
      variable v : std_logic_vector(15 downto 0);
      variable m : std_logic_vector(15 downto 0);
      variable w : std_logic_vector(1 downto 0);
   begin
      v := d_full(b, c);
      m := d_mask(b, c);
      w := we_mask(c);
      if w(1) = '1' then v(15 downto 8) := m(15 downto 8); end if;
      if w(0) = '1' then v(7 downto 0)  := m(7 downto 0);  end if;
      return v;
   end function;

begin

   -- the interface: the test's until done, then memcont's
   x_addrh_o  <= m_addrh_i  when done = '1' else C_BLK(blk);
   x_bgn_o    <= m_bgn_i    when done = '1' else x"00";
   x_end_o    <= m_end_i    when done = '1' else
                 x"00" when pass = 2 else x"FF";                -- a read of 256 words, a write of 256
   x_bwidth_o <= m_bwidth_i when done = '1' else "1000";
   x_wrdat_o  <= m_wrdat_i  when done = '1' else t_wrdat;
   x_we_o     <= m_we_i     when done = '1' else t_we;
   x_rd_o     <= m_rd_i     when done = '1' else t_rd;
   x_wr_o     <= m_wr_i     when done = '1' else t_wr;
   x_refrsh_o <= m_refrsh_i when done = '1' else '0';
   x_abort_o  <= m_abort_i  when done = '1' else '0';

   m_addr_rc_o  <= x_addr_rc_i;
   m_addr_wc_o  <= x_addr_wc_i;
   m_rddat_o    <= x_rddat_i;
   m_de_o       <= x_de_i and done;
   m_busy_o     <= x_busy_i when done = '1' else '1';
   m_initdone_o <= x_initdone_i and done;

   result_o <= f_lane & f_tmo & f_err & done;
   err_o    <= err;

   p_test : process (clk_i)
      variable v_c   : unsigned(7 downto 0);
      variable v_exp : std_logic_vector(15 downto 0);
      variable v_d   : std_logic_vector(15 downto 0);
      variable v_w   : std_logic_vector(1 downto 0);
   begin
      if rising_edge(clk_i) then
         t_rd <= '0';
         t_wr <= '0';

         -- write data one clock after addr_wc, as cachecont's cache RAM
         v_c := unsigned(x_addr_wc_i);
         if pass = 0 then
            t_wrdat <= d_full(blk, v_c);
            t_we    <= "11";
         else
            t_wrdat <= d_mask(blk, v_c);
            t_we    <= we_mask(v_c);
         end if;

         -- read words
         if done = '0' and pass = 2 and x_de_i = '1' then
            v_c   := unsigned(x_addr_rc_i);
            v_exp := expect(blk, v_c);
            if x_rddat_i /= v_exp then
               if f_err = '0' then
                  err <= std_logic_vector(to_unsigned(blk, 5)) & std_logic_vector(v_c) & x_rddat_i & v_exp;
               end if;
               f_err <= '1';
               -- a byte the masked pass left alone
               v_d := d_full(blk, v_c);
               v_w := we_mask(v_c);
               if (v_w(1) = '0' and x_rddat_i(15 downto 8) /= v_d(15 downto 8)) or
                  (v_w(0) = '0' and x_rddat_i(7 downto 0) /= v_d(7 downto 0)) then
                  f_lane <= '1';
               end if;
            end if;
         end if;

         case state is
            when T_INIT =>
               if x_initdone_i = '1' then
                  state <= T_CMD;
               end if;

            when T_CMD =>
               if x_busy_i = '0' then
                  if pass = 2 then t_rd <= '1'; else t_wr <= '1'; end if;
                  tmo   <= (others => '0');
                  state <= T_WAIT;
               end if;

            when T_WAIT =>
               -- (busy is high from the request on; the clock after it, too)
               tmo <= tmo + 1;
               if tmo /= 0 and x_busy_i = '0' then
                  state <= T_NEXT;
               elsif tmo(20) = '1' then
                  f_tmo <= '1';
                  state <= T_DONE;
               end if;

            when T_NEXT =>
               if blk = C_NBLK - 1 then
                  blk <= 0;
                  if pass = 2 then
                     state <= T_DONE;
                  else
                     pass  <= pass + 1;
                     state <= T_CMD;
                  end if;
               else
                  blk   <= blk + 1;
                  state <= T_CMD;
               end if;

            when T_DONE =>
               done <= '1';
         end case;

         if rstn_i = '0' then
            state <= T_INIT;
            pass  <= 0;
            blk   <= 0;
            done  <= '0';
         end if;
      end if;
   end process p_test;

end architecture rtl;
