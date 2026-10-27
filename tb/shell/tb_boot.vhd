----------------------------------------------------------------------------------
-- MegaX: x68_boot.vhd (the boot ROM loader device) under ghdl, with xpm_stub.vhd's FIFO.
--
-- The QNICE side writes N bytes the way the Shell's ROM auto-loader does (one byte per address,
-- 4K windows, signals set on the rising edge, the device taking them on the falling edge, held
-- while qnice_wait_o is high), reads the size, then ends the load (control offset 2) and polls
-- for "ended". The X68000 side is x68_system's loader glue (p_loader, copied) with a core that
-- acknowledges each byte after a pseudo-random 3..40 clk_sys clocks (ldr_ack rising) and stores
-- it. Checks: every byte at its address, in order, boot_active high from before the first
-- strobe to after the last acknowledge, ldr_done at the end, size = N, ended read back.
--
-- Run: tb/shell/run_boot.sh (on the Fedora host)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_boot is
end entity tb_boot;

architecture sim of tb_boot is

   constant C_N         : natural := 9000;           -- bytes (crosses two 4K windows)

   signal done          : boolean := false;
   signal qclk          : std_logic := '0';
   signal sclk          : std_logic := '0';
   signal qrst          : std_logic := '1';
   signal srst          : std_logic := '1';

   signal q_addr        : std_logic_vector(27 downto 0) := (others => '0');
   signal q_wdata       : std_logic_vector(15 downto 0) := (others => '0');
   signal q_rdata       : std_logic_vector(15 downto 0);
   signal q_ce          : std_logic := '0';
   signal q_we          : std_logic := '0';
   signal q_wait        : std_logic;

   signal boot_active   : std_logic;
   signal boot_addr     : std_logic_vector(19 downto 0);
   signal boot_data     : std_logic_vector(7 downto 0);
   signal boot_wr       : std_logic;
   signal boot_wait     : std_logic;
   signal boot_ended    : std_logic;

   -- x68_system's loader glue
   signal boot_active_d : std_logic := '0';
   signal started       : std_logic := '0';
   signal ldr_wr        : std_logic := '0';
   signal ldr_ack       : std_logic := '0';
   signal ldr_ack_d     : std_logic := '0';
   signal ldr_done      : std_logic := '0';

   type t_mem is array (0 to C_N - 1) of std_logic_vector(7 downto 0);
   signal mem           : t_mem := (others => (others => 'U'));
   signal nwr           : natural := 0;
   signal cerr          : natural := 0;          -- the core model's errors

   function pattern(i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((i * 7 + 3 + i / 256) mod 256, 8));
   end function pattern;

begin

   qclk <= not qclk after 10 ns when not done;       -- 50 MHz
   sclk <= not sclk after 12.5 ns when not done;     -- 40 MHz

   i_dut : entity work.x68_boot
      port map (
         qnice_clk_i     => qclk,
         qnice_rst_i     => qrst,
         qnice_addr_i    => q_addr,
         qnice_data_i    => q_wdata,
         qnice_data_o    => q_rdata,
         qnice_ce_i      => q_ce,
         qnice_we_i      => q_we,
         qnice_wait_o    => q_wait,
         clk_sys_i       => sclk,
         rst_sys_i       => srst,
         boot_active_o   => boot_active,
         boot_addr_o     => boot_addr,
         boot_data_o     => boot_data,
         boot_wr_o       => boot_wr,
         boot_wait_i     => boot_wait,
         boot_ended_o    => boot_ended
      );

   -- x68_system.vhd p_loader
   p_loader : process (sclk)
   begin
      if rising_edge(sclk) then
         boot_active_d <= boot_active;
         ldr_ack_d     <= ldr_ack;
         if boot_active_d = '0' and boot_active = '1' then
            started <= '1';
         end if;
         if ldr_ack_d = '0' and ldr_ack = '1' and ldr_wr = '1' then
            ldr_wr <= '0';
         end if;
         if boot_wr = '1' and ldr_done = '0' then
            ldr_wr <= '1';
         end if;
         if boot_active_d = '1' and boot_active = '0' then
            ldr_done <= '1';
         end if;
      end if;
   end process p_loader;
   boot_wait <= ldr_wr;

   -- the core: takes the byte (ldr_addr / ldr_wdat) after a pseudo-random delay
   p_core : process (sclk)
      variable v_lfsr : unsigned(15 downto 0) := x"ACE1";
      variable v_cnt  : integer := -1;
   begin
      if rising_edge(sclk) then
         ldr_ack <= '0';
         if ldr_wr = '1' and v_cnt < 0 and ldr_ack = '0' and ldr_ack_d = '0' then
            v_lfsr := v_lfsr(14 downto 0) & (v_lfsr(15) xor v_lfsr(13) xor v_lfsr(12) xor v_lfsr(10));
            v_cnt  := 3 + to_integer(v_lfsr(5 downto 0)) mod 38;
         elsif v_cnt > 0 then
            v_cnt := v_cnt - 1;
         elsif v_cnt = 0 then
            v_cnt := -1;
            ldr_ack <= '1';
            if started = '0' or boot_active = '0' then
               report "byte acknowledged without boot_active / started" severity error;
               cerr <= cerr + 1;
            end if;
            if to_integer(unsigned(boot_addr)) /= nwr then
               report "byte " & integer'image(nwr) & " at address " &
                      integer'image(to_integer(unsigned(boot_addr))) severity error;
               cerr <= cerr + 1;
            end if;
            if to_integer(unsigned(boot_addr)) < C_N then
               mem(to_integer(unsigned(boot_addr))) <= boot_data;
            end if;
            nwr <= nwr + 1;
         end if;
      end if;
   end process p_core;

   p_qnice : process
      procedure qaccess(addr : natural; data : std_logic_vector(15 downto 0); we : std_logic) is
      begin
         wait until rising_edge(qclk);
         q_addr  <= std_logic_vector(to_unsigned(addr, 28));
         q_wdata <= data;
         q_ce    <= '1';
         q_we    <= we;
         loop
            wait until falling_edge(qclk);
            exit when q_wait = '0';
         end loop;
         wait until rising_edge(qclk);
         q_ce <= '0';
         q_we <= '0';
      end procedure qaccess;

      variable v_size : natural;
      variable v_err  : natural := 0;
      variable v_poll : natural;
   begin
      wait for 200 ns;
      wait until rising_edge(qclk);
      qrst <= '0';
      srst <= '0';
      wait for 1 us;

      for i in 0 to C_N - 1 loop
         qaccess(i, x"00" & pattern(i), '1');      -- window i / 4096, offset i mod 4096
      end loop;

      -- the size: control window 0x1000, offsets 0 and 1
      wait until rising_edge(qclk);
      q_addr <= x"1000" & x"000";
      q_ce   <= '1';
      wait until falling_edge(qclk);
      v_size := to_integer(unsigned(q_rdata));
      q_addr <= x"1000" & x"001";
      wait until falling_edge(qclk);
      v_size := v_size + 65536 * to_integer(unsigned(q_rdata));
      wait until rising_edge(qclk);
      q_ce <= '0';
      if v_size /= C_N then
         report "size " & integer'image(v_size) & ", want " & integer'image(C_N) severity error;
         v_err := v_err + 1;
      end if;

      -- end the load, then poll offset 2 bit 1
      qaccess(16#1000# * 4096 + 2, x"0001", '1');
      v_poll := 0;
      loop
         wait until rising_edge(qclk);
         q_addr <= x"1000" & x"002";
         q_ce   <= '1';
         wait until falling_edge(qclk);
         exit when q_rdata(1) = '1';
         v_poll := v_poll + 1;
         assert v_poll < 100000 report "the load never ended" severity failure;
      end loop;
      wait until rising_edge(qclk);
      q_ce <= '0';
      wait for 2 us;

      if nwr /= C_N then
         report integer'image(nwr) & " bytes taken, want " & integer'image(C_N) severity error;
         v_err := v_err + 1;
      end if;
      for i in 0 to C_N - 1 loop
         if mem(i) /= pattern(i) then
            report "byte " & integer'image(i) & " = " & to_hstring(mem(i)) & ", want " & to_hstring(pattern(i)) severity error;
            v_err := v_err + 1;
            exit;
         end if;
      end loop;
      if ldr_done /= '1' or boot_active /= '0' or boot_ended /= '1' then
         report "the end: ldr_done / boot_active / boot_ended not 1 / 0 / 1" severity error;
         v_err := v_err + 1;
      end if;
      wait for 10 ns;
      v_err := v_err + cerr;
      if v_err = 0 then
         report "tb_boot PASS: " & integer'image(nwr) & " bytes, ended after " & integer'image(v_poll) & " polls";
      else
         report "tb_boot FAIL: " & integer'image(v_err) & " errors" severity error;
      end if;
      done <= true;
      wait;
   end process p_qnice;

end architecture sim;
