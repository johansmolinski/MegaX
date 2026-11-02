----------------------------------------------------------------------------------
-- MegaX: mouse.vhd against the core's own PS/2 mouse host, MOUSECONV (rtl/SCC/MOUSEIF, with
-- PS2IF), as the SCC has it: clk_sys 40 MHz, sys_ce 10 MHz, CLKCYC 10000, SFTCYC 400.
--
-- The stimulus waits for MOUSECONV's start-up (reset FF / FA AA 00, defaults F6 / FA, reporting
-- F4 / FA), then plays an Amiga mouse: 40 quadrature edges to the right, 20 down, the left
-- button pressed. A reader plays the SCC: REQ, then the three bytes MOUSECONV announces (RXED).
-- MOUSECONV halves the counts, Y is down positive on the X68000:
--   packet 1: 01 (left button), 14 (X +20), 0A (Y +20 down)
-- then 10 edges to the left, 6 up, the button released:
--   packet 2: 00, FB (X -5), FD (Y -3)
--
-- Run: tb/shell/run_mouse.sh
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mouse is
end entity tb_mouse;

architecture sim of tb_mouse is

   constant C_T       : time := 25 ns;               -- 40 MHz

   component MOUSECONV is
      generic (
         CLKCYC  : integer := 20000;
         SFTCYC  : integer := 400;
         RXINT   : integer := 2
      );
      port (
         REQ     : in  std_logic;
         DATOUT  : out std_logic_vector(7 downto 0);
         RXED    : out std_logic;
         MCLKIN  : in  std_logic;
         MCLKOUT : out std_logic;
         MDATIN  : in  std_logic;
         MDATOUT : out std_logic;
         clk     : in  std_logic;
         ce      : in  std_logic := '1';
         rstn    : in  std_logic
      );
   end component MOUSECONV;

   signal clk         : std_logic := '0';
   signal ce          : std_logic := '0';
   signal div         : unsigned(1 downto 0) := (others => '0');
   signal rstn        : std_logic := '0';
   signal reset       : std_logic := '1';
   signal done        : boolean := false;

   signal h, hq, v, vq : std_logic := '0';
   signal btn_l_n     : std_logic := '1';

   signal dev_clk, dev_dat, host_clk, host_dat : std_logic;
   signal req         : std_logic := '0';
   signal rdat        : std_logic_vector(7 downto 0);
   signal rxed        : std_logic;

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);
   constant C_EXPECT  : t_bytes := (x"01", x"14", x"0A", x"00", x"FB", x"FD");
   signal got         : t_bytes(0 to 5) := (others => x"EE");
   signal n_got       : natural := 0;

begin

   clk <= not clk after C_T / 2 when not done;

   p_ce : process (clk)
   begin
      if rising_edge(clk) then
         div <= div + 1;
         if div = 3 then ce <= '1'; else ce <= '0'; end if;
      end if;
   end process p_ce;

   i_conv : MOUSECONV
      generic map (CLKCYC => 10000, SFTCYC => 400)
      port map (
         REQ => req, DATOUT => rdat, RXED => rxed,
         MCLKIN => dev_clk, MCLKOUT => host_clk, MDATIN => dev_dat, MDATOUT => host_dat,
         clk => clk, ce => ce, rstn => rstn
      );

   i_mouse : entity work.mouse
      generic map (C_PERIOD => 4000)                 -- 100 us between packets in the test
      port map (
         clk_i => clk, reset_i => reset, enable_i => '1',
         h_i => h, hq_i => hq, v_i => v, vq_i => vq,
         btn_l_n_i => btn_l_n, btn_r_n_i => '1',
         ps2_clk_o => dev_clk, ps2_dat_o => dev_dat,
         ps2_clk_i => host_clk, ps2_dat_i => host_dat
      );

   -- the PS/2 traffic seen from the mouse (debug)
   p_mon : process (clk)
      alias rx_got is <<signal .tb_mouse.i_mouse.rx_got : std_logic>>;
      alias rx_data is <<signal .tb_mouse.i_mouse.rx_data : std_logic_vector(7 downto 0)>>;
   begin
      if rising_edge(clk) and rx_got = '1' then
         report "host -> mouse " & to_hstring(rx_data);
      end if;
   end process p_mon;

   p_read : process (clk)
   begin
      if rising_edge(clk) then
         if ce = '1' and rxed = '1' and n_got < 6 then
            got(n_got) <= rdat;
            n_got <= n_got + 1;
            report "SCC byte " & integer'image(n_got) & ": " & to_hstring(rdat);
         end if;
      end if;
   end process p_read;

   p_stim : process
      -- one quadrature edge on (p, q): +1 runs 00 10 11 01, -1 the other way
      procedure edges(signal p, q : inout std_logic; n : integer) is
      begin
         for i in 1 to abs(n) loop
            if n > 0 then
               if p = q then p <= not p; else q <= not q; end if;
            else
               if p = q then q <= not q; else p <= not p; end if;
            end if;
            wait for 10 us;
         end loop;
      end procedure edges;

      procedure request(first : natural) is
      begin
         wait until rising_edge(clk) and ce = '1';
         req <= '1';
         wait until rising_edge(clk) and ce = '1';
         req <= '0';
         for i in 0 to 2000 loop
            wait for 10 us;
            exit when n_got >= first + 3;
         end loop;
      end procedure request;
   begin
      wait for 1 us;
      rstn  <= '1';
      reset <= '0';
      -- MOUSECONV's start-up: until it has enabled reporting (F4), then its FA travels
      wait until <<signal .tb_mouse.i_mouse.stream_on : std_logic>> = '1' for 200 ms;
      assert <<signal .tb_mouse.i_mouse.stream_on : std_logic>> = '1'
         report "MOUSECONV never enabled reporting" severity failure;
      wait for 3 ms;
      edges(h, hq, 40);
      edges(v, vq, 20);
      btn_l_n <= '0';
      wait for 20 ms;                                -- the packets travel (4 ms each)
      request(0);
      edges(h, hq, -10);
      edges(v, vq, -6);
      btn_l_n <= '1';
      wait for 20 ms;
      request(3);

      for i in 0 to 5 loop
         if got(i) /= C_EXPECT(i) then
            report "byte " & integer'image(i) & ": got " & to_hstring(got(i)) &
                   ", expected " & to_hstring(C_EXPECT(i)) severity error;
            report "tb_mouse FAIL";
            done <= true;
            wait;
         end if;
      end loop;
      report "tb_mouse PASS";
      done <= true;
      wait;
   end process p_stim;

end architecture sim;
