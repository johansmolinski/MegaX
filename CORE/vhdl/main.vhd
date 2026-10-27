----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- Wrapper for the machine: x68_system (the MiSTer core and its MiSTer-top glue) plus what it
-- needs from the MEGA65: the PS/2 keyboard (keyboard.vhd), the SDRAM pins, the video clock
-- handshake, video into M2M, audio. The boot ROM loader (x68_boot.vhd), the disk images
-- (x68_sd.vhd, through the hps_io ports here) and the menu live in mega65.vhd.
--
-- Clocks (clk.vhd): clk_ram 80 MHz, clk_sys 40 MHz (= M2M's main clock: the keyboard, the
-- menu bits, the audio), clk_scan 69.552 MHz (= M2M's video clock), clk_sdram 80 MHz (the
-- SDRAM chip's clock through an ODDR).
--
-- SDRAM: the core's controller (SDRAMC.vhd) drives the pins directly, CL2 at 80 MHz, as on the
-- MiSTer. It takes the first word of a READ three clk_ram clocks after the command; with the
-- chip clocked half a period after the controller (clk_sdram at 180 degrees), the chip's data
-- arrive in that window only with the pins' clock-to-out and the board's delays (the MiSTer
-- relies on its own; tb/sim models them as sdram_rd_delay). CORE.xdc constrains the pins
-- against the chip's datasheet so that Vivado checks the window. The controller's power-up
-- sequence starts as soon as `locked` rises and waits only ~15 us; the chip wants 100 us of
-- stable clock first, so `locked` follows the MMCM lock 8192 clk_sys clocks (205 us) late.
--
-- Video clock (phase 2): clk_scan is fixed at the X68000's 31 kHz oscillator. The core asks
-- for an oscillator through scan_req (its CRTC mode, x68k_video_clock.sv's request); the
-- handshake below answers like x68k_video_clock: scan_mode = the mode the clock is set up for,
-- scan_ready once it is stable. Only the 31 kHz modes (oscillator family 0) get scan_ready;
-- for the 15 kHz and VGA-dot modes the core's scanout stays in reset (no picture) until the
-- exact oscillators of phase 4.
--
-- Video into M2M: on clk_scan with the core's pixel enable, RGB 8 bit, syncs active high
-- (mister_sync.sv), blanks widened to cover the syncs (Megamiga hard rule 6). No scandoubler
-- (31 kHz), so the analog OSM's enable is the pixel enable.
--
-- done by Johan Smolinski in 2026, after PC10-III's main.vhd (MiSTer2MEGA65 template, sy2002
-- and MJoergen)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity main is
   port (
      clk_ram_i               : in    std_logic;
      clk_sys_i               : in    std_logic;
      clk_sdram_i             : in    std_logic;
      clk_scan_i              : in    std_logic;
      sys_rst_i               : in    std_logic;     -- clk_sys domain: clocks not locked
      scan_locked_i           : in    std_logic;     -- the clk_scan MMCM (asynchronous)
      reset_i                 : in    std_logic;     -- clk_sys domain: the X68000's reset
      turbo_i                 : in    std_logic;     -- 68000 at 20 MHz
      rtc_i                   : in    std_logic_vector(64 downto 0);

      -- boot ROM loader (x68_boot.vhd)
      boot_active_i           : in    std_logic;
      boot_addr_i             : in    std_logic_vector(19 downto 0);
      boot_data_i             : in    std_logic_vector(7 downto 0);
      boot_wr_i               : in    std_logic;
      boot_wait_o             : out   std_logic;

      -- Video output (clk_scan with video_ce_o)
      video_ce_o              : out   std_logic;
      video_ce_ovl_o          : out   std_logic;
      video_red_o             : out   std_logic_vector(7 downto 0);
      video_green_o           : out   std_logic_vector(7 downto 0);
      video_blue_o            : out   std_logic_vector(7 downto 0);
      video_vs_o              : out   std_logic;
      video_hs_o              : out   std_logic;
      video_hblank_o          : out   std_logic;
      video_vblank_o          : out   std_logic;

      -- a floppy motor runs (clk_sys; the drive LED, as MiSTer's user LED)
      fd_motor_o              : out   std_logic;

      -- disk images: MiSTer's hps_io sector interface (clk_sys; x68_sd.vhd)
      img_mounted_i           : in    std_logic_vector(7 downto 0);
      img_readonly_i          : in    std_logic;
      img_size_i              : in    std_logic_vector(63 downto 0);
      img_xdf_i               : in    std_logic;
      sd_lba_o                : out   std_logic_vector(31 downto 0);
      sd_rd_o                 : out   std_logic_vector(7 downto 0);
      sd_wr_o                 : out   std_logic_vector(7 downto 0);
      sd_ack_i                : in    std_logic_vector(7 downto 0);
      sd_buff_addr_i          : in    std_logic_vector(8 downto 0);
      sd_buff_dout_i          : in    std_logic_vector(7 downto 0);
      sd_buff_din_o           : out   std_logic_vector(7 downto 0);
      sd_buff_wr_i            : in    std_logic;
      fd_sync_i               : in    std_logic_vector(1 downto 0);   -- write D88 changes back
      sram_ld_i               : in    std_logic;
      sram_st_i               : in    std_logic;
      sxsi_inject_i           : in    std_logic;
      dbg_status_o            : out   std_logic_vector(5 downto 0);   -- bring-up status bits
      dbg_scan_o              : out   std_logic_vector(7 downto 0);
      dbg_bus_o               : out   std_logic_vector(47 downto 0);  -- x68_trace.vhd

      -- Audio output (clk_sys, signed PCM)
      audio_left_o            : out   signed(15 downto 0);
      audio_right_o           : out   signed(15 downto 0);

      -- M2M keyboard interface (clk_sys)
      kb_key_num_i            : in    integer range 0 to 79;
      kb_key_pressed_n_i      : in    std_logic;

      -- SDRAM pins
      sdram_clk_o             : out   std_logic;
      sdram_cke_o             : out   std_logic;
      sdram_ras_n_o           : out   std_logic;
      sdram_cas_n_o           : out   std_logic;
      sdram_we_n_o            : out   std_logic;
      sdram_cs_n_o            : out   std_logic;
      sdram_ba_o              : out   std_logic_vector(1 downto 0);
      sdram_a_o               : out   std_logic_vector(12 downto 0);
      sdram_dqml_o            : out   std_logic;
      sdram_dqmh_o            : out   std_logic;
      sdram_dq_io             : inout std_logic_vector(15 downto 0)
   );
end entity main;

architecture synthesis of main is

   -- the SDRAM's power-up wait (see above)
   signal pwr_count     : unsigned(12 downto 0) := (others => '0');
   signal sys_locked    : std_logic := '0';

   -- video clock handshake (clk_sys)
   signal scan_req      : std_logic_vector(3 downto 0);
   signal scan_mode     : std_logic_vector(3 downto 0) := (others => '0');
   signal scan_ready    : std_logic := '0';
   signal scan_applied  : std_logic_vector(3 downto 0) := (others => '0');
   signal scan_valid    : std_logic := '0';
   signal scan_cand     : std_logic_vector(3 downto 0) := (others => '0');
   signal scan_quiet    : unsigned(5 downto 0) := (others => '0');
   signal scan_settle   : unsigned(11 downto 0) := (others => '0');
   signal scan_lock_s   : std_logic_vector(1 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of scan_lock_s : signal is "TRUE";

   -- the keyboard's PS/2 lines
   signal kbd_clk       : std_logic;
   signal kbd_dat       : std_logic;
   signal host_clk      : std_logic;
   signal host_dat      : std_logic;

   -- x68_system's outputs
   signal sd_dqm        : std_logic_vector(1 downto 0);
   signal v_ce          : std_logic;
   signal v_r           : std_logic_vector(7 downto 0);
   signal v_g           : std_logic_vector(7 downto 0);
   signal v_b           : std_logic_vector(7 downto 0);
   signal v_hs          : std_logic;
   signal v_vs          : std_logic;
   signal v_hb          : std_logic;
   signal v_vb          : std_logic;
   signal snd_l         : std_logic_vector(15 downto 0);
   signal snd_r         : std_logic_vector(15 downto 0);

   -- video registers (clk_scan)
   signal o_ce          : std_logic := '0';
   signal o_r           : std_logic_vector(7 downto 0) := (others => '0');
   signal o_g           : std_logic_vector(7 downto 0) := (others => '0');
   signal o_b           : std_logic_vector(7 downto 0) := (others => '0');
   signal o_hs          : std_logic := '0';
   signal o_vs          : std_logic := '0';
   signal o_hb          : std_logic := '1';
   signal o_vb          : std_logic := '1';

   -- x68k_video_clock.sv's oscillator family of a mode (v60 = 0): 0 = 69.552 MHz (31 kHz),
   -- 1 = 38.864 MHz (15 kHz), 2 = 50.35 MHz (HMODE 3)
   function family(m : std_logic_vector(3 downto 0)) return natural is
   begin
      if m(1 downto 0) = "11" then
         return 2;
      elsif m(2) = '0' then
         return 1;
      else
         return 0;
      end if;
   end function family;

begin

   ---------------------------------------------------------------------------------------------
   -- SDRAM power-up wait
   ---------------------------------------------------------------------------------------------

   p_pwr : process (clk_sys_i)
   begin
      if rising_edge(clk_sys_i) then
         if pwr_count /= 2**pwr_count'length - 1 then
            pwr_count <= pwr_count + 1;
         else
            sys_locked <= '1';
         end if;
         if sys_rst_i = '1' then
            pwr_count  <= (others => '0');
            sys_locked <= '0';
         end if;
      end if;
   end process p_pwr;

   ---------------------------------------------------------------------------------------------
   -- Video clock handshake (x68k_video_clock.sv without the PLL reconfiguration): a new request
   -- must be stable for 64 clocks, then it is applied; ready once the clock has been locked for
   -- 4096 clocks and the applied mode is one of the fixed oscillator.
   ---------------------------------------------------------------------------------------------

   p_scan : process (clk_sys_i)
   begin
      if rising_edge(clk_sys_i) then
         scan_lock_s <= scan_lock_s(0) & scan_locked_i;

         if scan_req /= scan_cand then
            scan_cand  <= scan_req;
            scan_quiet <= (others => '0');
         elsif scan_quiet /= 63 then
            scan_quiet <= scan_quiet + 1;
         end if;

         if scan_quiet = 63 and scan_cand = scan_req and (scan_valid = '0' or scan_req /= scan_applied) then
            scan_applied <= scan_req;
            scan_mode    <= scan_req;
            scan_valid   <= '1';
            scan_settle  <= (others => '0');
         elsif scan_lock_s(1) = '0' then
            scan_settle  <= (others => '0');
         elsif scan_settle /= 4095 then
            scan_settle  <= scan_settle + 1;
         end if;

         if scan_valid = '1' and scan_req = scan_applied and scan_lock_s(1) = '1' and
            scan_settle = 4095 and family(scan_applied) = 0 then
            scan_ready <= '1';
         else
            scan_ready <= '0';
         end if;

         if sys_rst_i = '1' then
            scan_valid  <= '0';
            scan_ready  <= '0';
            scan_quiet  <= (others => '0');
            scan_settle <= (others => '0');
         end if;
      end if;
   end process p_scan;

   ---------------------------------------------------------------------------------------------
   -- The machine
   ---------------------------------------------------------------------------------------------

   i_x68_system : entity work.x68_system
      port map (
         clk_ram        => clk_ram_i,
         clk_sys        => clk_sys_i,
         clk_scan       => clk_scan_i,
         scan_ready     => scan_ready,
         scan_mode      => scan_mode,
         scan_req       => scan_req,
         locked         => sys_locked,
         reset          => reset_i,
         turbo          => turbo_i,
         rtc            => rtc_i,
         boot_active    => boot_active_i,
         boot_addr      => boot_addr_i,
         boot_data      => boot_data_i,
         boot_wr        => boot_wr_i,
         boot_wait      => boot_wait_o,
         sdram_cke      => sdram_cke_o,
         sdram_cs_n     => sdram_cs_n_o,
         sdram_ras_n    => sdram_ras_n_o,
         sdram_cas_n    => sdram_cas_n_o,
         sdram_we_n     => sdram_we_n_o,
         sdram_dqm      => sd_dqm,
         sdram_ba       => sdram_ba_o,
         sdram_a        => sdram_a_o,
         sdram_dq       => sdram_dq_io,
         video_ce       => v_ce,
         video_r        => v_r,
         video_g        => v_g,
         video_b        => v_b,
         video_hs       => v_hs,
         video_vs       => v_vs,
         video_hblank   => v_hb,
         video_vblank   => v_vb,
         video_de       => open,
         video_31k      => open,
         audio_l        => snd_l,
         audio_r        => snd_r,
         img_mounted    => img_mounted_i,
         img_readonly   => img_readonly_i,
         img_size       => img_size_i,
         img_xdf        => img_xdf_i,
         sd_lba         => sd_lba_o,
         sd_rd          => sd_rd_o,
         sd_wr          => sd_wr_o,
         sd_ack         => sd_ack_i,
         sd_buff_addr   => sd_buff_addr_i,
         sd_buff_dout   => sd_buff_dout_i,
         sd_buff_din    => sd_buff_din_o,
         sd_buff_wr     => sd_buff_wr_i,
         fd_eject       => "00",
         fd_sync        => fd_sync_i,
         sram_ld        => sram_ld_i,
         sram_st        => sram_st_i,
         sxsi_inject    => sxsi_inject_i,
         dbg_status     => dbg_status_o(4 downto 0),
         dbg_bus        => dbg_bus_o,
         fd_motor       => fd_motor_o,
         ps2_kbd_clk_i  => kbd_clk,
         ps2_kbd_dat_i  => kbd_dat,
         ps2_kbd_clk_o  => host_clk,
         ps2_kbd_dat_o  => host_dat
      ); -- i_x68_system

   dbg_status_o(5) <= scan_ready;
   dbg_scan_o      <= scan_req & scan_mode;

   sdram_dqmh_o <= sd_dqm(1);
   sdram_dqml_o <= sd_dqm(0);

   -- the SDRAM chip's clock: clk_sdram forwarded (D1 = 1, D2 = 0: the pin follows the clock)
   i_sdram_clk : ODDR
      generic map (
         DDR_CLK_EDGE => "SAME_EDGE",
         INIT         => '0',
         SRTYPE       => "SYNC"
      )
      port map (
         Q  => sdram_clk_o,
         C  => clk_sdram_i,
         CE => '1',
         D1 => '1',
         D2 => '0',
         R  => '0',
         S  => '0'
      ); -- i_sdram_clk

   i_keyboard : entity work.keyboard
      port map (
         clk_i           => clk_sys_i,
         reset_i         => sys_rst_i,
         key_num_i       => kb_key_num_i,
         key_pressed_n_i => kb_key_pressed_n_i,
         ps2_clk_o       => kbd_clk,
         ps2_dat_o       => kbd_dat,
         ps2_clk_i       => host_clk,
         ps2_dat_i       => host_dat
      ); -- i_keyboard

   audio_left_o  <= signed(snd_l);
   audio_right_o <= signed(snd_r);

   ---------------------------------------------------------------------------------------------
   -- Video into M2M (clk_scan)
   ---------------------------------------------------------------------------------------------

   p_video : process (clk_scan_i)
   begin
      if rising_edge(clk_scan_i) then
         o_ce <= v_ce;
         o_r  <= v_r;
         o_g  <= v_g;
         o_b  <= v_b;
         o_hs <= v_hs;
         o_vs <= v_vs;
         o_hb <= v_hb or v_hs;
         o_vb <= v_vb or v_vs;
      end if;
   end process p_video;

   video_ce_o     <= o_ce;
   video_ce_ovl_o <= o_ce;
   video_red_o    <= o_r;
   video_green_o  <= o_g;
   video_blue_o   <= o_b;
   video_hs_o     <= o_hs;
   video_vs_o     <= o_vs;
   video_hblank_o <= o_hb;
   video_vblank_o <= o_vb;

end architecture synthesis;
