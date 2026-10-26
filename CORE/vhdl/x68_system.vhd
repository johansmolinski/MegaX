----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- The machine: the MiSTer core's X68K_top, the text VRAM in block RAM
-- (tvram_bram.vhd) and the glue of the MiSTer top X68000.sv that is not tied to
-- the MiSTer (clock enables, reset, boot ROM loader handshake). Used by the
-- MEGA65 shell (main.vhd) and by the simulation (tb/sim) alike.
--
-- Clocks (as on the MiSTer):
--   clk_ram  80 MHz: SDRAM controller, caches, video render, text VRAM
--   clk_sys  40 MHz: 68000 (10 MHz, 20 MHz turbo, via clock enables) and all
--            peripherals; phase-aligned with clk_ram (same PLL, rising edges of
--            clk_sys coincide with every other rising edge of clk_ram)
--   clk_scan video scanout at the X68000 oscillator the core asks for
--            (scan_req): 69.552 / 38.864 / 50.35 MHz or 75.249 MHz for
--            "60 fps"; the platform reports the oscillator it delivers
--            (scan_mode) and that it is stable (scan_ready)
-- The SDRAM clock is clk_ram inverted (the MiSTer's altddio_out with D1=0,
-- D2=1); the platform generates it.
--
-- Status 2026-10-26 (phase 1): no disks, keyboard, mouse or joysticks yet
-- (tied to their idle levels, as on a MiSTer with nothing mounted or pressed).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_system is
port (
   clk_ram        : in    std_logic;
   clk_sys        : in    std_logic;
   clk_scan       : in    std_logic;
   scan_ready     : in    std_logic;
   scan_mode      : in    std_logic_vector(3 downto 0);
   scan_req       : out   std_logic_vector(3 downto 0);

   -- clk_sys domain
   reset          : in    std_logic;                       -- high: machine in reset
   turbo          : in    std_logic;                       -- 68000 at 20 MHz
   rtc            : in    std_logic_vector(64 downto 0);   -- MiSTer RTC format

   -- Boot ROM (MiSTer's boot.rom: 1 MB, the image of F00000-FFFFFF) - clk_sys.
   -- boot_active high while the image is sent (rising edge: the machine leaves
   -- its power-on reset; falling edge: loading is complete, the 68000 starts);
   -- boot_wr one clock per byte, only while boot_wait is low.
   boot_active    : in    std_logic;
   boot_addr      : in    std_logic_vector(19 downto 0);
   boot_data      : in    std_logic_vector(7 downto 0);
   boot_wr        : in    std_logic;
   boot_wait      : out   std_logic;

   -- SDRAM (clk_ram)
   sdram_cke      : out   std_logic;
   sdram_cs_n     : out   std_logic;
   sdram_ras_n    : out   std_logic;
   sdram_cas_n    : out   std_logic;
   sdram_we_n     : out   std_logic;
   sdram_dqm      : out   std_logic_vector(1 downto 0);
   sdram_ba       : out   std_logic_vector(1 downto 0);
   sdram_a        : out   std_logic_vector(12 downto 0);
   sdram_dq       : inout std_logic_vector(15 downto 0);

   -- Video (clk_scan): RGB, active-high syncs, ce_pix one clock per pixel
   video_ce       : out   std_logic;
   video_r        : out   std_logic_vector(7 downto 0);
   video_g        : out   std_logic_vector(7 downto 0);
   video_b        : out   std_logic_vector(7 downto 0);
   video_hs       : out   std_logic;
   video_vs       : out   std_logic;
   video_hblank   : out   std_logic;
   video_vblank   : out   std_logic;
   video_de       : out   std_logic;
   video_31k      : out   std_logic;

   -- Audio (clk_sys), signed
   audio_l        : out   std_logic_vector(15 downto 0);
   audio_r        : out   std_logic_vector(15 downto 0)
);
end entity x68_system;

architecture synthesis of x68_system is

   -- clock enables (X68000.sv)
   signal div_sys      : unsigned(1 downto 0) := (others => '0');
   signal div_snd      : unsigned(3 downto 0) := (others => '0');
   signal div_snd2     : unsigned(3 downto 0) := (others => '0');
   signal div_opm      : unsigned(4 downto 0) := (others => '0');
   signal turbo_l      : std_logic := '0';
   signal sys_ce       : std_logic := '0';
   signal mpu_cep      : std_logic := '0';
   signal mpu_cen      : std_logic := '0';
   signal snd_ce       : std_logic := '0';
   signal opm_ce       : std_logic_vector(1 downto 0) := (others => '0');
   signal snd_clkmode  : std_logic;

   -- reset and loader (X68000.sv)
   signal boot_active_d : std_logic := '0';
   signal started       : std_logic := '0';
   signal ldr_wr        : std_logic := '0';
   signal ldr_ack       : std_logic;
   signal ldr_ack_d     : std_logic := '0';
   signal ldr_done      : std_logic := '0';
   signal ldr_aen       : std_logic;
   signal core_rstn     : std_logic;

   -- text VRAM
   signal ddram_burstcnt : std_logic_vector(7 downto 0);
   signal ddram_addr     : std_logic_vector(28 downto 0);
   signal ddram_din      : std_logic_vector(63 downto 0);
   signal ddram_be       : std_logic_vector(7 downto 0);
   signal ddram_rd       : std_logic;
   signal ddram_we       : std_logic;
   signal ddram_dout     : std_logic_vector(63 downto 0);
   signal ddram_dout_rdy : std_logic;
   signal ddram_busy     : std_logic;

   signal snd_l, snd_r : std_logic_vector(15 downto 0);

begin

   -- Clock enables, as X68000.sv generates them on clk_sys:
   -- sys_ce 10 MHz; the 68000's phi1/phi2 enables at 10 MHz (20 MHz turbo,
   -- latched once per sys_ce period); OPM 4 MHz (opm_ce(0)) and 2 MHz
   -- (opm_ce(1)); ADPCM 8 or 4 MHz by the OPM's CT2 output (cm_out).
   p_ce : process(clk_sys)
   begin
      if rising_edge(clk_sys) then
         div_sys  <= div_sys + 1;
         div_snd  <= div_snd + 1;
         div_snd2 <= div_snd2 + 1;
         div_opm  <= div_opm + 1;
         if div_snd2 = 9 then div_snd2 <= (others => '0'); end if;
         if div_snd  = 4 then div_snd  <= (others => '0'); end if;
         if div_opm = 19 then div_opm  <= (others => '0'); end if;

         opm_ce(0) <= '1' when div_snd2 = 9 else '0';
         opm_ce(1) <= '1' when div_opm = 19 else '0';

         sys_ce <= div_sys(1) and div_sys(0);

         if div_sys = 3 then
            turbo_l <= turbo;
         end if;
         if turbo_l = '1' then
            mpu_cep <= div_sys(0);
            mpu_cen <= not div_sys(0);
         else
            mpu_cep <= div_sys(1) and div_sys(0);
            mpu_cen <= not div_sys(1) and div_sys(0);
         end if;

         if snd_clkmode = '1' then
            snd_ce <= '1' when div_snd2 = 9 else '0';
         else
            snd_ce <= '1' when div_snd = 4 else '0';
         end if;
      end if;
   end process p_ce;

   -- Reset and loader, as X68000.sv: the machine leaves its power-on reset when
   -- the boot ROM starts to arrive; the core holds the 68000 itself until
   -- ldr_done. A byte is written with ldr_wr, which stays set (boot_wait) until
   -- the core acknowledges it with a rising ldr_ack.
   p_loader : process(clk_sys)
   begin
      if rising_edge(clk_sys) then
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
   ldr_aen   <= boot_active and not ldr_done;
   core_rstn <= started and not reset;

   i_core : entity work.X68K_top
   port map (
      ramclk           => clk_ram,
      sysclk           => clk_sys,
      vidclk           => clk_ram,
      scanclk          => clk_scan,
      scan_ready       => scan_ready,
      scan_mode        => scan_mode,
      scan_reset_out   => open,
      fdcclk           => clk_sys,
      sndclk           => clk_sys,
      ram_ce           => '1',
      sys_ce           => sys_ce,
      mpu_cep          => mpu_cep,
      mpu_cen          => mpu_cen,
      fd_ce            => '1',
      snd_ce           => snd_ce,
      opm_ce           => opm_ce,
      cm_out           => snd_clkmode,
      vid_hz           => '0',
      plllock          => '1',
      CPUS             => '0',
      sysrtc           => rtc,
      pMemCke          => sdram_cke,
      pMemCs_n         => sdram_cs_n,
      pMemRas_n        => sdram_ras_n,
      pMemCas_n        => sdram_cas_n,
      pMemWe_n         => sdram_we_n,
      pMemUdq          => sdram_dqm(1),
      pMemLdq          => sdram_dqm(0),
      pMemBa1          => sdram_ba(1),
      pMemBa0          => sdram_ba(0),
      pMemAdr          => sdram_a,
      pMemDat          => sdram_dq,
      DDRAM_CLK        => open,
      DDRAM_BURSTCNT   => ddram_burstcnt,
      DDRAM_ADDR       => ddram_addr,
      DDRAM_DIN        => ddram_din,
      DDRAM_BE         => ddram_be,
      DDRAM_RD         => ddram_rd,
      DDRAM_WE         => ddram_we,
      DDRAM_DOUT       => ddram_dout,
      DDRAM_DOUT_READY => ddram_dout_rdy,
      DDRAM_BUSY       => ddram_busy,
      ldr_addr         => boot_addr,
      ldr_aen          => ldr_aen,
      ldr_wdat         => boot_data,
      ldr_wr           => ldr_wr,
      ldr_ack          => ldr_ack,
      ldr_done         => ldr_done,
      pPs2Clkin        => '1',
      pPs2Clkout       => open,
      pPs2Datin        => '1',
      pPs2Datout       => open,
      pPmsClkin        => '1',
      pPmsClkout       => open,
      pPmsDatin        => '1',
      pPmsDatout       => open,
      pJoyA            => (others => '1'),
      pJoyB            => (others => '1'),
      pStrA            => open,
      pStrB            => open,
      pJoySelA         => open,
      pJoySelB         => open,
      pFDSYNC          => "00",
      pFDEJECT         => "00",
      pFDMOTOR         => open,
      pFDACTIVE        => open,
      pFDEJECTED       => open,
      pfdwait          => "00",
      mist_mounted     => (others => '0'),
      mist_readonly    => (others => '0'),
      mist_imgsize     => (others => '0'),
      mist_lba         => open,
      mist_rd          => open,
      mist_wr          => open,
      mist_ack         => (others => '0'),
      mist_buffaddr    => (others => '0'),
      mist_buffdout    => (others => '0'),
      mist_buffdin     => open,
      mist_buffwr      => '0',
      pDip             => "0000",
      pLed             => open,
      pPsw             => "11",                -- NMI and POWER buttons released
      pkbdtype         => "000",
      pSramld          => '0',
      pSramst          => '0',
      pMidi_in         => '1',
      pMidi_out        => open,
      pMidi_en         => '0',                 -- MIDI board off (the MiSTer default)
      pVideoClk        => video_ce,
      pVideoR          => video_r,
      pVideoG          => video_g,
      pVideoB          => video_b,
      pVideoHB         => video_hblank,
      pVideoVB         => video_vblank,
      pVideoEN         => video_de,
      pVideoHS         => video_hs,
      pVideoVS         => video_vs,
      pVideoF1         => open,
      pVideo31k        => video_31k,
      pPixCe           => '0',
      pPixExt          => '0',
      pVideoMode       => scan_req,
      pVideoDyn        => open,
      pSndL            => snd_l,
      pSndR            => snd_r,
      pSndYML          => open,
      pSndYMR          => open,
      pSndPCML         => open,
      pSndPCMR         => open,
      rstn             => core_rstn,
      vid_mode         => "00",
      dHMode           => "00",
      dVMode           => '0',
      opm_sel          => '0',
      mix_fix          => '1',
      disk_mode        => '0',
      sxsi_inject      => '0',
      vis_mem          => "0000"
   );

   -- X68000.sv swaps the channels on purpose (pSndL => aud_r).
   audio_l <= snd_r;
   audio_r <= snd_l;

   i_tvram : entity work.tvram_bram
   port map (
      clk            => clk_ram,
      ddram_burstcnt => ddram_burstcnt,
      ddram_addr     => ddram_addr,
      ddram_din      => ddram_din,
      ddram_be       => ddram_be,
      ddram_rd       => ddram_rd,
      ddram_we       => ddram_we,
      ddram_dout     => ddram_dout,
      ddram_dout_rdy => ddram_dout_rdy,
      ddram_busy     => ddram_busy
   );

end architecture synthesis;
