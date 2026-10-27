----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- Clock generator (doc/plan.md section 2.1). Two MMCMs from the board's 100 MHz:
--
-- i_clk_x68 (VCO 800 MHz = 100 MHz x 8, PFD 100 MHz):
--    clk_ram   = 800 / 10 = 80 MHz      CLKOUT0  SDRAM controller, caches, video render, TVRAM
--    clk_sys   = 800 / 20 = 40 MHz      CLKOUT1  68000 (clock enables), peripherals; also M2M's
--                                                main clock (globals.vhd CORE_CLK_SPEED)
--    clk_sdram = 800 / 10 = 80 MHz      CLKOUT2  the SDRAM chip's clock, forwarded by an ODDR in
--                                                main.vhd; G_SDRAM_PHASE degrees behind clk_ram
--    As on the MiSTer (one PLL, X68000.sv): the rising edges of clk_sys coincide with every
--    other rising edge of clk_ram, the core's 80/40 MHz paths rely on it (CORE.xdc). The SDRAM
--    clock is clk_ram inverted on the MiSTer (altddio_out, 180 degrees); the MiSTer board's
--    delays then put the chip's read data where SDRAMC samples it. The MEGA65's are shorter:
--    at 180 degrees the read hold fails by 2.57 ns at the fast corner (megax-k: the X68000
--    never got through its IPL). 288 degrees (3.75 ns later) balances read setup/hold and
--    command setup/hold at about 1 ns each (Vivado checks all four, CORE.xdc).
--
-- i_clk_scan(0..3): the X68000's video oscillators (x68k_video_clock.sv's families), one MMCM each
-- (no two of them share a VCO within 60 ppm), internal feedback:
--    family 0  69.552239 MHz = 100 / 5 x 58.25 / 16.75     (+3.4 ppm)  31 kHz modes
--    family 1  38.863636 MHz = 100 / 2 x 21.375 / 27.5     (0.0 ppm)   15 kHz modes
--    family 2  50.349650 MHz = 100 / 1 x 9.0 / 17.875      (-6.9 ppm)  HMODE 3 (VGA 640) modes
--    family 3  75.249113 MHz = 100 / 7 x 56.625 / 10.75    (+7.6 ppm)  "60 Hz" 31 kHz (boost)
--    clk_scan = the family scan_sel_i selects, through a tree of three BUFGMUX_CTRL (glitch-free:
--    all four MMCMs run all the time). It is the video scanout clock and M2M's video clock.
--    scan_sel_i is asynchronous (main.vhd's handshake holds the X68000's scanout in reset while
--    it changes, as the MiSTer core does while its PLL relocks).
--
-- done by Johan Smolinski in 2026, based on PC10-III's clk.vhd (MiSTer2MEGA65 template, sy2002
-- and MJoergen)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   generic (
      G_SDRAM_PHASE   : real := 288.0    -- clk_sdram behind clk_ram, degrees (multiple of 4.5)
   );
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      clk_ram_o       : out std_logic;   -- 80 MHz
      clk_sys_o       : out std_logic;   -- 40 MHz, also M2M's main clock
      clk_sdram_o     : out std_logic;   -- 80 MHz, G_SDRAM_PHASE behind clk_ram
      x68_locked_o    : out std_logic;   -- i_clk_x68 locked (asynchronous)
      sys_rst_o       : out std_logic;   -- clk_sys domain: i_clk_x68 not locked

      scan_sel_i      : in  std_logic_vector(1 downto 0);   -- oscillator family (asynchronous)
      clk_scan_o      : out std_logic;   -- the selected oscillator, also M2M's video clock
      scan_locked_o   : out std_logic;   -- all four i_clk_scan locked (asynchronous)
      scan_rst_o      : out std_logic    -- clk_scan domain: i_clk_scan not locked
   );
end entity clk;

architecture rtl of clk is

signal x68_fb_mmcm     : std_logic;
signal x68_fb          : std_logic;
signal clk_ram_mmcm    : std_logic;
signal clk_sys_mmcm    : std_logic;
signal clk_sdram_mmcm  : std_logic;
signal clk_sys         : std_logic;
signal x68_locked      : std_logic;

type real_array is array (0 to 3) of real;
type int_array  is array (0 to 3) of integer;
constant C_SCAN_D      : int_array  := (5, 2, 1, 7);
constant C_SCAN_M      : real_array := (58.250, 21.375, 9.000, 56.625);
constant C_SCAN_O      : real_array := (16.750, 27.500, 17.875, 10.750);

signal scan_fb         : std_logic_vector(0 to 3);
signal scan_mmcm       : std_logic_vector(0 to 3);
signal scan_lock       : std_logic_vector(0 to 3);
signal scan_mux_a      : std_logic;              -- family 0 / 1
signal scan_mux_b      : std_logic;              -- family 2 / 3
signal clk_scan        : std_logic;
signal scan_locked     : std_logic;

begin

   i_clk_x68 : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 1,          -- PFD 100 MHz
         CLKFBOUT_MULT_F      => 8.000,      -- VCO 800 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 10.000,     -- clk_ram 80 MHz
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 20,         -- clk_sys 40 MHz
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_USE_FINE_PS  => FALSE,
         CLKOUT2_DIVIDE       => 10,         -- clk_sdram 80 MHz
         CLKOUT2_PHASE        => G_SDRAM_PHASE,
         CLKOUT2_DUTY_CYCLE   => 0.500,
         CLKOUT2_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT            => x68_fb_mmcm,
         CLKOUT0             => clk_ram_mmcm,
         CLKOUT1             => clk_sys_mmcm,
         CLKOUT2             => clk_sdram_mmcm,
         CLKFBIN             => x68_fb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         CLKINSEL            => '1',
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         LOCKED              => x68_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_x68

   g_clk_scan : for i in 0 to 3 generate
      i_clk_scan : MMCME2_ADV
         generic map (
            BANDWIDTH            => "OPTIMIZED",
            CLKOUT4_CASCADE      => FALSE,
            COMPENSATION         => "INTERNAL",  -- feedback CLKFBOUT -> CLKFBIN, no BUFG
            STARTUP_WAIT         => FALSE,
            CLKIN1_PERIOD        => 10.0,        -- INPUT @ 100 MHz
            REF_JITTER1          => 0.010,
            DIVCLK_DIVIDE        => C_SCAN_D(i),
            CLKFBOUT_MULT_F      => C_SCAN_M(i),
            CLKFBOUT_PHASE       => 0.000,
            CLKFBOUT_USE_FINE_PS => FALSE,
            CLKOUT0_DIVIDE_F     => C_SCAN_O(i),
            CLKOUT0_PHASE        => 0.000,
            CLKOUT0_DUTY_CYCLE   => 0.500,
            CLKOUT0_USE_FINE_PS  => FALSE
         )
         port map (
            CLKFBOUT            => scan_fb(i),
            CLKOUT0             => scan_mmcm(i),
            CLKFBIN             => scan_fb(i),
            CLKIN1              => sys_clk_i,
            CLKIN2              => '0',
            CLKINSEL            => '1',
            DADDR               => (others => '0'),
            DCLK                => '0',
            DEN                 => '0',
            DI                  => (others => '0'),
            DO                  => open,
            DRDY                => open,
            DWE                 => '0',
            PSCLK               => '0',
            PSEN                => '0',
            PSINCDEC            => '0',
            PSDONE              => open,
            LOCKED              => scan_lock(i),
            CLKINSTOPPED        => open,
            CLKFBSTOPPED        => open,
            PWRDWN              => '0',
            RST                 => '0'
         ); -- i_clk_scan
   end generate g_clk_scan;

   x68_fb_bufg : BUFG
      port map (
         I => x68_fb_mmcm,
         O => x68_fb
      );

   clk_ram_bufg : BUFG
      port map (
         I => clk_ram_mmcm,
         O => clk_ram_o
      );

   clk_sys_bufg : BUFG
      port map (
         I => clk_sys_mmcm,
         O => clk_sys
      );

   clk_sdram_bufg : BUFG
      port map (
         I => clk_sdram_mmcm,
         O => clk_sdram_o
      );

   -- the oscillator tree: S selects I1
   i_scan_mux_a : BUFGMUX_CTRL
      port map (
         I0 => scan_mmcm(0),
         I1 => scan_mmcm(1),
         S  => scan_sel_i(0),
         O  => scan_mux_a
      );

   i_scan_mux_b : BUFGMUX_CTRL
      port map (
         I0 => scan_mmcm(2),
         I1 => scan_mmcm(3),
         S  => scan_sel_i(0),
         O  => scan_mux_b
      );

   i_scan_mux : BUFGMUX_CTRL
      port map (
         I0 => scan_mux_a,
         I1 => scan_mux_b,
         S  => scan_sel_i(1),
         O  => clk_scan
      );

   scan_locked <= scan_lock(0) and scan_lock(1) and scan_lock(2) and scan_lock(3);

   clk_sys_o     <= clk_sys;
   clk_scan_o    <= clk_scan;
   x68_locked_o  <= x68_locked;
   scan_locked_o <= scan_locked;

   i_xpm_cdc_async_rst_sys : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not x68_locked,
         dest_clk  => clk_sys,
         dest_arst => sys_rst_o
      );

   i_xpm_cdc_async_rst_scan : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not scan_locked,
         dest_clk  => clk_scan,
         dest_arst => scan_rst_o
      );

end architecture rtl;
