----------------------------------------------------------------------------------
-- MegaX: keyboard.vhd against the core's own PS/2 host, KBCONV (rtl/MFP/KBIF, with PS2IF and
-- the MiSTer layout tables), as X68K_top's MFP has it: clk_sys 40 MHz, sys_ce 10 MHz,
-- CLKCYC 10000, SFTCYC 400.
--
-- A model of the framework's key scan (each MEGA65 key shown for 8 clocks) drives keyboard.vhd;
-- a reader plays the 68000: it enables the MFP's receiver (RSR bit 0) and reads every key code
-- KBCONV announces (RXED, then a DATRD cycle). KBCONV is a simulation copy (kbconv_sim.py):
-- its KBWAIT_CMD gets the FPGA's power-up value 0 instead of VHDL's 'U'. The stimulus waits for KBCONV's start-up
-- (reset FF / AA, ID F2 / FA AB 83, LEDs ED / FA / xx / FA, typematic F3 / FA / xx / FA), then
-- presses keys; the codes must be the X68000 keyboard's:
--   A                        1E, 9E
--   MEGA + 8                 6A (F8), EA      (MEGA alone sends nothing to the X68000)
--   RUN/STOP                 61 (BREAK), E1   (then the next E0 key must still work)
--   cursor up                3C, BC
--   MEGA + H                 54 (HELP), D4    (KBCONV's Win combo)
--   Q held 900 ms            11, then 4 .. 6 repeats (typematic: 500 ms, then every 92 ms; KBCONV
--                            shows each as 91 11), 91
--
-- Run: tb/shell/run_keyboard.sh (on the Fedora host)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_keyboard is
end entity tb_keyboard;

architecture sim of tb_keyboard is

   constant C_T       : time := 25 ns;               -- 40 MHz

   component KBCONV is
      generic (
         CLKCYC  : integer := 20000;
         SFTCYC  : integer := 400
      );
      port (
         DATIN    : in  std_logic_vector(7 downto 0);
         DATOUT   : out std_logic_vector(7 downto 0);
         DOE      : out std_logic;
         CONTRD   : in  std_logic;
         CONTWR   : in  std_logic;
         RXSTRD   : in  std_logic;
         RXSTWR   : in  std_logic;
         TXSTRD   : in  std_logic;
         TXSTWR   : in  std_logic;
         DATRD    : in  std_logic;
         DATWR    : in  std_logic;
         KBWAIT   : in  std_logic;
         KBen     : out std_logic;
         TXEMP    : out std_logic;
         RXED     : out std_logic;
         KBCLKIN  : in  std_logic;
         KBCLKOUT : out std_logic;
         KBDATIN  : in  std_logic;
         KBDATOUT : out std_logic;
         monout   : out std_logic_vector(7 downto 0);
         kbsel    : in  std_logic := '0';
         kbout    : out std_logic_vector(7 downto 0);
         kbrx     : out std_logic;
         LED      : out std_logic_vector(6 downto 0);
         kbdtype  : in  std_logic_vector(2 downto 0) := "000";
         clk      : in  std_logic;
         ce       : in  std_logic := '1';
         rstn     : in  std_logic
      );
   end component KBCONV;

   signal clk         : std_logic := '0';
   signal ce          : std_logic := '0';
   signal div         : unsigned(1 downto 0) := (others => '0');
   signal rstn        : std_logic := '0';
   signal reset       : std_logic := '1';
   signal done        : boolean := false;

   signal key_num     : integer range 0 to 79 := 0;
   signal key_n       : std_logic := '1';
   signal keys        : std_logic_vector(79 downto 0) := (others => '0');   -- 1 = held
   signal scan_cnt    : unsigned(2 downto 0) := (others => '0');

   signal kbd_clk     : std_logic;
   signal kbd_dat     : std_logic;
   signal host_clk    : std_logic;
   signal host_dat    : std_logic;

   signal datin       : std_logic_vector(7 downto 0) := (others => '0');
   signal datout      : std_logic_vector(7 downto 0);
   signal rxstwr      : std_logic := '0';
   signal datrd       : std_logic := '0';
   signal rxed        : std_logic;

   type t_codes is array (natural range <>) of std_logic_vector(7 downto 0);
   signal got         : t_codes(0 to 63);
   signal ngot        : natural := 0;

   -- MEGA65 key numbers
   constant K_A       : natural := 10;
   constant K_8       : natural := 27;
   constant K_H       : natural := 29;
   constant K_MEGA    : natural := 61;
   constant K_Q       : natural := 62;
   constant K_STOP    : natural := 63;
   constant K_UP      : natural := 73;

begin

   clk <= not clk after C_T / 2 when not done;

   p_ce : process (clk)
   begin
      if rising_edge(clk) then
         div <= div + 1;
         ce  <= '1' when div = 3 else '0';
      end if;
   end process p_ce;

   -- the framework's key scan: one key every 8 clocks, round robin
   p_scan : process (clk)
   begin
      if rising_edge(clk) then
         scan_cnt <= scan_cnt + 1;
         if scan_cnt = 7 then
            key_num <= (key_num + 1) mod 80;
         end if;
      end if;
   end process p_scan;
   key_n <= not keys(key_num);

   i_dut : entity work.keyboard
      port map (
         clk_i           => clk,
         reset_i         => reset,
         key_num_i       => key_num,
         key_pressed_n_i => key_n,
         ps2_clk_o       => kbd_clk,
         ps2_dat_o       => kbd_dat,
         ps2_clk_i       => host_clk,
         ps2_dat_i       => host_dat
      );

   i_kbconv : KBCONV
      generic map (CLKCYC => 10000, SFTCYC => 400)
      port map (
         DATIN    => datin,
         DATOUT   => datout,
         DOE      => open,
         CONTRD   => '0',
         CONTWR   => '0',
         RXSTRD   => '0',
         RXSTWR   => rxstwr,
         TXSTRD   => '0',
         TXSTWR   => '0',
         DATRD    => datrd,
         DATWR    => '0',
         KBWAIT   => '0',
         KBen     => open,
         TXEMP    => open,
         RXED     => rxed,
         KBCLKIN  => kbd_clk,
         KBCLKOUT => host_clk,
         KBDATIN  => kbd_dat,
         KBDATOUT => host_dat,
         monout   => open,
         kbsel    => '0',
         kbout    => open,
         kbrx     => open,
         LED      => open,
         kbdtype  => "000",
         clk      => clk,
         ce       => ce,
         rstn     => rstn
      );

   -- the 68000: enable the receiver, then read every code
   p_cpu : process
   begin
      wait for 100 * C_T;
      wait until rising_edge(clk);
      rstn  <= '1';
      reset <= '0';
      wait for 1 us;
      wait until rising_edge(clk) and ce = '1';
      datin  <= x"01";
      rxstwr <= '1';
      wait until rising_edge(clk) and ce = '1';
      rxstwr <= '0';
      loop
         wait until rising_edge(clk) and rxed = '1';
         wait until rising_edge(clk) and ce = '1';
         datrd <= '1';
         wait until rising_edge(clk) and ce = '1';
         got(ngot) <= datout;
         report "X68000 key code " & to_hstring(datout) & " at " & time'image(now);
         ngot  <= ngot + 1;
         datrd <= '0';
         wait for 1 us;
      end loop;
   end process p_cpu;

   p_stim : process
      procedure tap(k : natural; hold : time) is
      begin
         keys(k) <= '1';
         wait for hold;
         keys(k) <= '0';
         wait for 20 ms;
      end procedure tap;

      constant C_WANT : t_codes := (x"1E", x"9E", x"6A", x"EA", x"61", x"E1", x"3C", x"BC",
                                    x"54", x"D4", x"11");
      variable v_ok   : boolean := true;
      variable v_reps : natural := 0;
   begin
      wait for 250 ms;                                  -- KBCONV's start-up dialogue
      tap(K_A, 20 ms);
      keys(K_MEGA) <= '1';
      wait for 20 ms;
      tap(K_8, 20 ms);
      keys(K_MEGA) <= '0';
      wait for 20 ms;
      tap(K_STOP, 20 ms);
      tap(K_UP, 20 ms);
      keys(K_MEGA) <= '1';
      wait for 20 ms;
      tap(K_H, 20 ms);
      keys(K_MEGA) <= '0';
      wait for 20 ms;
      tap(K_Q, 900 ms);                                 -- 500 ms delay, then ~5 repeats
      wait for 10 ms;

      for i in C_WANT'range loop
         if i >= ngot or got(i) /= C_WANT(i) then
            v_ok := false;
            report "code " & integer'image(i) & ": want " & to_hstring(C_WANT(i)) severity error;
         end if;
      end loop;
      -- then Q's repeats: KBCONV gives the X68000 a repeated make code as a release and a make
      -- (91 11, KS_RDTBL / KS_REP); Q's release (91) last
      for i in 0 to (ngot - C_WANT'length - 1) / 2 - 1 loop
         if got(C_WANT'length + 2 * i) = x"91" and got(C_WANT'length + 2 * i + 1) = x"11" then
            v_reps := v_reps + 1;
         else
            v_ok := false;
            report "repeat " & integer'image(i) & ": " & to_hstring(got(C_WANT'length + 2 * i)) &
                   " " & to_hstring(got(C_WANT'length + 2 * i + 1)) & ", want 91 11" severity error;
         end if;
      end loop;
      if ngot = 0 or got(ngot - 1) /= x"91" then
         v_ok := false;
         report "the last code is not Q's release (91)" severity error;
      end if;
      if v_reps < 4 or v_reps > 6 then
         v_ok := false;
         report "Q repeated " & integer'image(v_reps) & " times, want 4 .. 6" severity error;
      end if;
      if v_ok then
         report "tb_keyboard PASS: " & integer'image(ngot) & " codes, " & integer'image(v_reps) & " repeats";
      else
         report "tb_keyboard FAIL" severity error;
      end if;
      done <= true;
      wait;
   end process p_stim;

end architecture sim;
