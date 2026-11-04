-- MegaX: x68_r3probe against synthetic SDRAM commands and a HyperRAM stand-in (ghdl,
-- run_r3probe.sh). Lines of 2540 clk_ram cycles; per line two 256-word GVRAM reads, a
-- 128-word CPU read fill and an 8-word CPU write-back. The stand-in accepts commands after a
-- pseudo-random wait and returns read data 20 clocks later, one word per clock (ascal's
-- traffic is not modelled). Checks: every command and word arrives in the mirror, nothing is
-- lost, the snapshot handshake works.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_r3probe is
end entity;

architecture sim of tb_r3probe is
   signal clk_ram, hr_clk, qclk : std_logic := '0';
   signal mem    : std_logic_vector(51 downto 0) := (others => '0');
   signal hr_wr, hr_rd, hr_wait, hr_valid : std_logic := '0';
   signal hr_addr : std_logic_vector(31 downto 0);
   signal hr_bc   : std_logic_vector(7 downto 0);
   signal q_addr  : std_logic_vector(27 downto 0) := (others => '0');
   signal q_din, q_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal q_ce, q_we : std_logic := '0';
   signal done : boolean := false;
   constant LINES : natural := 40;
begin
   clk_ram <= not clk_ram after 6.25 ns when not done;
   hr_clk  <= not hr_clk  after 5 ns    when not done;
   qclk    <= not qclk    after 10 ns   when not done;

   dut : entity work.x68_r3probe
      port map (
         clk_ram_i => clk_ram, mem_i => mem,
         hr_clk_i => hr_clk, hr_rst_i => '0',
         hr_write_o => hr_wr, hr_read_o => hr_rd, hr_address_o => hr_addr,
         hr_writedata_o => open, hr_byteenable_o => open, hr_burstcount_o => hr_bc,
         hr_readdata_i => x"0000", hr_readdatavalid_i => hr_valid, hr_waitrequest_i => hr_wait,
         qnice_clk_i => qclk, qnice_addr_i => q_addr, qnice_data_i => q_din,
         qnice_data_o => q_dout, qnice_ce_i => q_ce, qnice_we_i => q_we);

   -- the HyperRAM stand-in
   p_slave : process (hr_clk)
      variable lfsr    : unsigned(15 downto 0) := x"ACE1";
      variable pend    : integer := 0;     -- read words still to deliver
      variable delay   : integer := 0;
      variable wleft   : integer := 0;
   begin
      if rising_edge(hr_clk) then
         lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
         hr_valid <= '0';
         if pend > 0 then
            if delay > 0 then
               delay := delay - 1;
            else
               hr_valid <= '1';
               pend := pend - 1;
            end if;
         end if;
         -- waitrequest: busy while a read is outstanding, otherwise random
         if pend > 0 or lfsr(2 downto 0) = "000" then
            hr_wait <= '1';
         else
            hr_wait <= '0';
         end if;
         if hr_wait = '0' and hr_rd = '1' then
            assert unsigned(hr_bc) > 0 and unsigned(hr_bc) <= 128 report "read burstcount" severity failure;
            assert hr_addr(21) = '1' report "address outside the mirror area" severity failure;
            pend := to_integer(unsigned(hr_bc));
            delay := 20;
            hr_wait <= '1';
         end if;
         if hr_wait = '0' and hr_wr = '1' then
            if wleft = 0 then
               wleft := to_integer(unsigned(hr_bc));
               assert wleft > 0 and wleft <= 128 report "write burstcount" severity failure;
            end if;
            wleft := wleft - 1;
         end if;
      end if;
   end process;

   -- SDRAM commands: 51 cpu rd, 50 ack, 49 HCOMP, 48 VPSTART, 47..45 class, 44 rd, 43 wr,
   -- 42 busy, 41 de, 40 abort, 39..36 bwidth, 31..16 addr_high, 15..8 bgn, 7..0 end
   p_cmds : process
      procedure cmd(cls : natural; rd : std_logic; bw : natural; ah : natural; b, e : natural) is
      begin
         mem(47 downto 45) <= std_logic_vector(to_unsigned(cls, 3));
         mem(44) <= rd; mem(43) <= not rd;
         mem(39 downto 36) <= std_logic_vector(to_unsigned(bw, 4));
         mem(31 downto 16) <= std_logic_vector(to_unsigned(ah, 16));
         mem(15 downto 8) <= std_logic_vector(to_unsigned(b, 8));
         mem(7 downto 0) <= std_logic_vector(to_unsigned(e, 8));
         wait until rising_edge(clk_ram);
         mem(44) <= '0'; mem(43) <= '0';
      end procedure;
      procedure idle(n : natural) is
      begin
         mem(47 downto 45) <= "000";
         for i in 1 to n loop wait until rising_edge(clk_ram); end loop;
      end procedure;
   begin
      wait for 2 us;                         -- the clear and the CDC first
      for l in 1 to LINES loop
         mem(49) <= '1'; mem(48) <= '1' when l = 1 else '0';
         wait until rising_edge(clk_ram);
         mem(49) <= '0'; mem(48) <= '0';
         cmd(2, '1', 8, 16#3A00# + 2 * l, 0, 0);     idle(300);    -- GVRAM, both halves
         cmd(2, '1', 8, 16#3A01# + 2 * l, 0, 0);     idle(300);
         mem(51) <= '1';                                           -- a CPU read: a miss
         cmd(3, '1', 7, 16#0123#, 16#85#, 16#85#);   idle(150);
         mem(50) <= '1'; wait until rising_edge(clk_ram); mem(51) <= '0'; mem(50) <= '0';
         cmd(4, '0', 7, 16#0040#, 16#83#, 16#8A#);   idle(2540 - 300 - 300 - 150 - 5);
      end loop;
      idle(5000);
      wait;
   end process;

   -- QNICE: clear, wait, snapshot, read, check
   p_qnice : process
      procedure qw(a : natural; d : std_logic_vector(15 downto 0)) is
      begin
         q_addr <= x"0004" & std_logic_vector(to_unsigned(a, 12)); q_din <= d;
         q_ce <= '1'; q_we <= '1';
         wait until falling_edge(qclk);
         q_ce <= '0'; q_we <= '0';
         wait until rising_edge(qclk);
      end procedure;
      impure function qr(i : natural) return natural is
      begin
         return 0;
      end function;
      variable lo, hi : natural;
      type t_v is array (0 to 45) of natural;
      variable v : t_v;
      variable sumw, sumo : natural := 0;
   begin
      wait for 500 ns;
      qw(0, x"0001");                                          -- clear
      wait for (LINES * 2540 + 6000) * 12.5 ns;
      qw(0, x"0002");                                          -- snapshot
      wait for 1 us;
      q_addr <= x"0004000"; wait until rising_edge(qclk); wait for 1 ns;
      assert q_dout(1 downto 0) = "11" report "snapshot not acknowledged" severity failure;
      for i in 0 to 45 loop
         q_addr <= x"0004" & std_logic_vector(to_unsigned(16 + 2 * i, 12));
         wait until rising_edge(qclk); wait for 1 ns;
         lo := to_integer(unsigned(q_dout));
         q_addr <= x"0004" & std_logic_vector(to_unsigned(17 + 2 * i, 12));
         wait until rising_edge(qclk); wait for 1 ns;
         hi := to_integer(unsigned(q_dout(14 downto 0)));
         v(i) := lo + 65536 * hi;
         report "reg " & integer'image(i) & " = " & integer'image(v(i));
      end loop;
      for k in 0 to 6 loop
         sumo := sumo + v(9 + k);
         sumw := sumw + v(16 + k);
      end loop;
      assert v(1) = 1 report "frames" severity failure;
      assert v(10) = 2 * LINES report "GVRAM reads" severity failure;
      assert v(17) = 2 * LINES * 256 report "GVRAM words" severity failure;
      assert v(18) = LINES * 128 report "CPU fill words" severity failure;
      assert v(19) = LINES * 8 report "CPU write words" severity failure;
      assert v(24) = 512 report "GVRAM words per line" severity failure;
      assert v(27) = LINES report "CPU reads" severity failure;
      assert v(29) >= 150 report "CPU longest stall" severity failure;
      assert v(30) = 0 and v(44) = 0 report "lost commands" severity failure;
      assert v(32) = sumo report "mirrored commands" severity failure;
      assert v(33) = sumw report "mirrored words" severity failure;
      assert v(42) > 0 and v(42) < 2540 * 10 / 8 report "GVRAM line latency" severity failure;
      report "TB_R3PROBE: PASS";
      done <= true;
      wait;
   end process;
end architecture;
