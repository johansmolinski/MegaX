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
--    clock is clk_ram inverted on the MiSTer (altddio_out); 180 degrees here is the same edge.
--
-- i_clk_scan (VCO 1165 MHz = 100 MHz / 5 x 58.25):
--    clk_scan  = 1165 / 16.75 = 69.552239 MHz (+3.6 ppm)   CLKOUT0
--    The X68000's 31 kHz oscillator (69.552 MHz), the video scanout clock and M2M's video clock.
--    Phase 2: fixed; main.vhd tells the core that only the modes of this oscillator are
--    available (the other three, 38.864 / 50.35 / 75.249 MHz, are phase 4: inventory section 6
--    has MMCM settings for them).
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
      G_SDRAM_PHASE   : real := 180.0    -- clk_sdram behind clk_ram, degrees (multiple of 45/8)
   );
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      clk_ram_o       : out std_logic;   -- 80 MHz
      clk_sys_o       : out std_logic;   -- 40 MHz, also M2M's main clock
      clk_sdram_o     : out std_logic;   -- 80 MHz, G_SDRAM_PHASE behind clk_ram
      x68_locked_o    : out std_logic;   -- i_clk_x68 locked (asynchronous)
      sys_rst_o       : out std_logic;   -- clk_sys domain: i_clk_x68 not locked

      clk_scan_o      : out std_logic;   -- 69.552 MHz, also M2M's video clock
      scan_locked_o   : out std_logic;   -- i_clk_scan locked (asynchronous)
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

signal scan_fb_mmcm    : std_logic;
signal scan_fb         : std_logic;
signal clk_scan_mmcm   : std_logic;
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

   i_clk_scan : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 5,          -- PFD 20 MHz
         CLKFBOUT_MULT_F      => 58.250,     -- VCO 1165 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 16.750,     -- clk_scan 69.552239 MHz
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE
      )
      port map (
         CLKFBOUT            => scan_fb_mmcm,
         CLKOUT0             => clk_scan_mmcm,
         CLKFBIN             => scan_fb,
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
         LOCKED              => scan_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_scan

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

   scan_fb_bufg : BUFG
      port map (
         I => scan_fb_mmcm,
         O => scan_fb
      );

   clk_scan_bufg : BUFG
      port map (
         I => clk_scan_mmcm,
         O => clk_scan
      );

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
