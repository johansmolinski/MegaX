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
-- G_HRMEM (the R3 board, doc/plan.md section 4 item 8): no SDRAM; the core's memory goes to
-- the HyperRAM through x68_hrmem.vhd and the hr_* port (the framework arbiter's core port,
-- hr_clk), the SDRAM pins idle. The machine then sees 4 MB of main RAM (vis_mem), all the
-- HyperRAM has room for next to ascal's frame buffer.
--
-- Disk images reach the core through MiSTer's hps_io sector interface (img_*,
-- sd_*), served by the platform: the testbench in simulation, the SD card
-- sector service on the MEGA65. The mount glue of X68000.sv is here.
--
-- The keyboard is MiSTer's PS/2 path (KBCONV with the "MiSTer" layout); the
-- platform plays the PS/2 keyboard (keyboard.vhd on the MEGA65).
--
-- The mouse is MiSTer's PS/2 path too (MOUSECONV in the SCC); the platform plays
-- the PS/2 mouse (mouse.vhd on the MEGA65). The joysticks are the core's 2-button
-- ports (pJoyA/pJoyB, low active: 0 up, 1 down, 2 left, 3 right, 4 trigger A,
-- 5 trigger B; X68000.sv's default mode), the strobe lines are not used.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_system is
generic (
   G_HRMEM        : boolean := false                       -- the memory in the HyperRAM (R3)
);
port (
   clk_ram        : in    std_logic;
   clk_sys        : in    std_logic;
   clk_scan       : in    std_logic;
   scan_ready     : in    std_logic;
   scan_mode      : in    std_logic_vector(3 downto 0);
   scan_req       : out   std_logic_vector(3 downto 0);
   locked         : in    std_logic;                       -- clocks stable (MMCM locked);
                                                            -- low resets the memory system,
                                                            -- disk emulators and video

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

   -- HyperRAM (hr_clk), with G_HRMEM: the framework arbiter's core port (Avalon, 16-bit words)
   hr_clk         : in    std_logic := '0';
   hr_rst         : in    std_logic := '1';
   hr_write       : out   std_logic;
   hr_read        : out   std_logic;
   hr_address     : out   std_logic_vector(31 downto 0);
   hr_writedata   : out   std_logic_vector(15 downto 0);
   hr_byteenable  : out   std_logic_vector(1 downto 0);
   hr_burstcount  : out   std_logic_vector(7 downto 0);
   hr_readdata    : in    std_logic_vector(15 downto 0) := (others => '0');
   hr_readdatavalid : in  std_logic := '0';
   hr_waitrequest : in    std_logic := '1';

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
   audio_r        : out   std_logic_vector(15 downto 0);

   -- Disk images (clk_sys), MiSTer's hps_io sector interface, 512-byte blocks.
   -- Drives: 0/1 floppy FDD0/FDD1 (D88, or XDF/DIM/HDM), 2 SASI hard disk
   -- (HDF), 3 SRAM image, 4..7 SxSI hard disks (HDS).
   img_mounted    : in    std_logic_vector(7 downto 0);    -- one clock: drive (re)mounted
   img_readonly   : in    std_logic;
   img_size       : in    std_logic_vector(63 downto 0);   -- bytes, 0 = no image
   img_xdf        : in    std_logic;                       -- floppy mount: XDF/DIM/HDM, not D88
   sd_lba         : out   std_logic_vector(31 downto 0);
   sd_rd          : out   std_logic_vector(7 downto 0);
   sd_wr          : out   std_logic_vector(7 downto 0);
   sd_ack         : in    std_logic_vector(7 downto 0);
   sd_buff_addr   : in    std_logic_vector(8 downto 0);
   sd_buff_dout   : in    std_logic_vector(7 downto 0);
   sd_buff_din    : out   std_logic_vector(7 downto 0);
   sd_buff_wr     : in    std_logic;
   fd_eject       : in    std_logic_vector(1 downto 0);    -- one clock: eject FDD0/FDD1
   fd_sync        : in    std_logic_vector(1 downto 0);    -- write FDD0/FDD1 (D88) changes back
   fd_motor       : out   std_logic;                       -- a floppy motor runs (MiSTer's user LED)
   sram_ld        : in    std_logic;                       -- MiSTer's "Load SRAM from SD Card" (level)
   sram_st        : in    std_logic;                       -- "Save SRAM to SD Card" (level)
   sxsi_inject    : in    std_logic;                       -- "Inject SXSI driver" (the core takes the edge)
   dbg_status     : out   std_logic_vector(4 downto 0);    -- bring-up: started, ldr_done,
                                                           -- core_rstn, reset, locked
   dbg_bus        : out   std_logic_vector(47 downto 0);   -- the 68000's bus (x68_trace.vhd)
   dbg_opm        : out   std_logic_vector(15 downto 0);   -- the OPM bus wait (x68_trace.vhd)
   dbg_mem        : out   std_logic_vector(51 downto 0);   -- the SDRAM traffic (clk_ram)  -- R3 study (temporary, x68_r3probe.vhd)
   dbg_hr         : out   std_logic_vector(12 downto 0);   -- R3 bring-up (sticky, the LEDs): 12..9
                                                           -- x68_hrtest's result, 8 a loader byte waited
                                                           -- 26 ms (clk_sys), 7..0 x68_hrmem's flags
   dbg_hrx        : out   std_logic_vector(511 downto 0);  -- R3 bring-up: x68_hrmem's state (dbgx_o)

   -- PS/2 keyboard, as hps_io's PS/2 device on the MiSTer (X68000.sv): point to point, the
   -- device's clock and data into the core, the core's (host) clock and data out to the device
   -- (keyboard.vhd on the MEGA65; '1' = released)
   ps2_kbd_clk_i  : in    std_logic;
   ps2_kbd_dat_i  : in    std_logic;
   ps2_kbd_clk_o  : out   std_logic;
   ps2_kbd_dat_o  : out   std_logic;

   -- PS/2 mouse (clk_sys): the device's lines in, the host's (MOUSECONV) out
   ps2_ms_clk_i   : in    std_logic;
   ps2_ms_dat_i   : in    std_logic;
   ps2_ms_clk_o   : out   std_logic;
   ps2_ms_dat_o   : out   std_logic;

   -- joysticks (clk_sys, low active): 0 up, 1 down, 2 left, 3 right, 4 A, 5 B
   joy_a_n        : in    std_logic_vector(5 downto 0);
   joy_b_n        : in    std_logic_vector(5 downto 0)
);
end entity x68_system;

architecture synthesis of x68_system is

   -- the external memory controller (G_HRMEM): memcont's SDRAMC lines
   signal vis_mem      : std_logic_vector(3 downto 0);
   signal xr_addrh     : std_logic_vector(15 downto 0);
   signal xr_bgn       : std_logic_vector(7 downto 0);
   signal xr_end       : std_logic_vector(7 downto 0);
   signal xr_bwidth    : std_logic_vector(3 downto 0);
   signal xr_wrdat     : std_logic_vector(15 downto 0);
   signal xr_we        : std_logic_vector(1 downto 0);
   signal xr_rd        : std_logic;
   signal xr_wr        : std_logic;
   signal xr_refrsh    : std_logic;
   signal xr_abort     : std_logic;
   signal xr_addr_rc   : std_logic_vector(7 downto 0);
   signal xr_addr_wc   : std_logic_vector(7 downto 0);
   signal xr_rddat     : std_logic_vector(15 downto 0);
   signal xr_de        : std_logic;
   signal xr_busy      : std_logic;
   signal xr_initdone  : std_logic;
   -- between x68_hrtest and x68_hrmem (R3 bring-up, temporary)
   signal ht_addrh     : std_logic_vector(15 downto 0);
   signal ht_bgn       : std_logic_vector(7 downto 0);
   signal ht_end       : std_logic_vector(7 downto 0);
   signal ht_bwidth    : std_logic_vector(3 downto 0);
   signal ht_wrdat     : std_logic_vector(15 downto 0);
   signal ht_we        : std_logic_vector(1 downto 0);
   signal ht_rd        : std_logic;
   signal ht_wr        : std_logic;
   signal ht_refrsh    : std_logic;
   signal ht_abort     : std_logic;
   signal ht_addr_rc   : std_logic_vector(7 downto 0);
   signal ht_addr_wc   : std_logic_vector(7 downto 0);
   signal ht_rddat     : std_logic_vector(15 downto 0);
   signal ht_de        : std_logic;
   signal ht_busy      : std_logic;
   signal ht_initdone  : std_logic;
   signal ht_result    : std_logic_vector(3 downto 0);

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
   signal ldr_wcnt      : unsigned(20 downto 0) := (others => '0');
   signal ldr_stuck     : std_logic := '0';
   signal xr_dbg        : std_logic_vector(7 downto 0);
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

   -- disk mount glue (X68000.sv)
   type cnt24_t is array(0 to 7) of unsigned(23 downto 0);
   type cnt16_t is array(0 to 1) of unsigned(15 downto 0);
   signal mount_count      : cnt24_t := (others => (others => '0'));
   signal eject_count      : cnt16_t := (others => (others => '0'));
   signal disk_present     : std_logic_vector(7 downto 0) := (others => '0');
   signal post_reset_mount : std_logic_vector(7 downto 0) := (others => '0');
   signal img_mounted_d    : std_logic_vector(7 downto 0);
   signal img_mounted_old  : std_logic_vector(7 downto 0) := (others => '0');
   signal fd_eject_d       : std_logic_vector(1 downto 0);
   signal disk_mode_r      : std_logic := '0';
   signal disk_mode        : std_logic;
   signal mist_ack         : std_logic_vector(7 downto 0);
   signal fd_ack           : std_logic;
   signal reset_delayed    : unsigned(15 downto 0) := (others => '0');
   signal core_reset       : std_logic;
   signal core_reset_d     : std_logic := '1';
   -- the drives announced again after a reset one at a time, each with its own size
   type size_t is array(0 to 7) of std_logic_vector(63 downto 0);
   signal slot_size        : size_t := (others => (others => '0'));
   signal ann_size         : std_logic_vector(63 downto 0) := (others => '0');
   signal seq_on           : std_logic := '0';
   signal seq_slot         : natural range 0 to 7 := 0;
   signal seq_wait         : natural range 0 to 255 := 0;

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
         -- R3 bring-up: a byte not taken for 26 ms
         if ldr_wr = '0' then
            ldr_wcnt <= (others => '0');
         elsif ldr_wcnt(20) = '0' then
            ldr_wcnt <= ldr_wcnt + 1;
         else
            ldr_stuck <= '1';
         end if;
      end if;
   end process p_loader;

   boot_wait <= ldr_wr;
   dbg_status <= locked & reset & core_rstn & ldr_done & started;
   dbg_hr     <= ht_result & ldr_stuck & xr_dbg;
   ldr_aen   <= boot_active and not ldr_done;

   -- X68000.sv's "reset": the external one, stretched by 65535 clocks after a
   -- SASI image is mounted (status[67]/[68] toggles of the MiSTer menu: n/a)
   core_reset <= '1' when reset = '1' or reset_delayed /= 0 else '0';
   core_rstn  <= started and not core_reset;

   -- Disk mount glue, as X68000.sv: a mount is announced to the core as a level
   -- for 0xFFFFFF clocks (0.42 s); a floppy (re)mount first looks ejected for
   -- its top 256 * 65536 clocks; after every reset the drives with an image are
   -- announced again (0xFFFF clocks, plus a one-clock post_reset_mount for the
   -- XDF emulator); an eject looks ejected for 65535 clocks.
   -- MegaX 2026-11-03: X68000.sv announces all drives again at the same clock, with the one
   -- img_size of hps_io (the image mounted last); diskemu takes every drive's capacity (and
   -- enable) from it at the rising edge of its mount bit, so after a reset all hard disks had
   -- the size of one image. And diskemu ignores mounts while it is in reset (its lmount is
   -- held at 0), so the images the firmware mounts while it holds the X68000 in reset at
   -- start-up count only through this announcement. Here every mount keeps its slot's size
   -- (slot_size); after a reset all mount bits go low, and 256 clocks later (diskemu is out of
   -- reset) the drives with an image are announced one at a time, 256 clocks apart, each
   -- with its own size on mist_imgsize (ann_size).
   p_mount : process(clk_sys)
   begin
      if rising_edge(clk_sys) then
         post_reset_mount <= (others => '0');
         core_reset_d     <= core_reset;
         img_mounted_old  <= img_mounted;

         for x in 0 to 7 loop
            if mount_count(x) /= 0 then
               mount_count(x) <= mount_count(x) - 1;
            end if;
            if img_mounted(x) = '1' then
               mount_count(x) <= x"FFFFFF";
               disk_present(x) <= '1' when img_size /= x"0000000000000000" else '0';
               slot_size(x) <= img_size;
               ann_size     <= img_size;
            end if;
         end loop;

         -- if core_reset_d = '1' and core_reset = '0' then
         --    for x in 0 to 7 loop
         --       if disk_present(x) = '1' then
         --          mount_count(x) <= x"00FFFF";
         --       end if;
         --    end loop;
         --    post_reset_mount <= disk_present;
         -- end if;
         if core_reset = '1' then
            seq_on <= '0';
         elsif core_reset_d = '1' then             -- the reset ends: all quiet first
            mount_count <= (others => (others => '0'));
            seq_on   <= '1';
            seq_slot <= 0;
            seq_wait <= 255;
         elsif seq_on = '1' then
            if seq_wait /= 0 then
               seq_wait <= seq_wait - 1;
            else
               if disk_present(seq_slot) = '1' then
                  mount_count(seq_slot)      <= x"00FFFF";
                  post_reset_mount(seq_slot) <= '1';
                  ann_size                   <= slot_size(seq_slot);
               end if;
               if seq_slot = 7 then
                  seq_on <= '0';
               else
                  seq_slot <= seq_slot + 1;
                  seq_wait <= 255;
               end if;
            end if;
         end if;

         for i in 0 to 1 loop
            if fd_eject(i) = '1' then
               eject_count(i) <= x"FFFF";
               disk_present(i) <= '0';
            end if;
            if eject_count(i) /= 0 then
               eject_count(i) <= eject_count(i) - 1;
            end if;
         end loop;

         if reset_delayed /= 0 then
            reset_delayed <= reset_delayed - 1;
         end if;
         if img_mounted_old(2) = '0' and img_mounted(2) = '1' then
            reset_delayed <= x"FFFF";
         end if;

         -- the floppy emulator: D88 (bit level) or XDF/DIM/HDM (sector level),
         -- by the format of the last floppy mounted
         if (img_mounted(0) = '1' or img_mounted(1) = '1') and img_size /= x"0000000000000000" then
            disk_mode_r <= img_xdf;
         end if;
      end if;
   end process p_mount;

   g_fd : for i in 0 to 1 generate
      fd_eject_d(i)    <= '1' when mount_count(i)(23 downto 16) /= 0 or eject_count(i) /= 0 else '0';
      img_mounted_d(i) <= '1' when fd_eject_d(i) = '0' and mount_count(i) /= 0 else '0';
   end generate;
   g_other : for x in 2 to 7 generate
      img_mounted_d(x) <= '1' when mount_count(x) /= 0 else '0';
   end generate;

   disk_mode <= disk_mode_r and (disk_present(0) or disk_present(1));
   fd_ack    <= sd_ack(1) or sd_ack(0);
   mist_ack  <= "0000" & sd_ack(3 downto 0) when disk_mode = '1' else
                sd_ack(7 downto 2) & fd_ack & fd_ack;

   i_core : entity work.X68K_top
   generic map (
      EXT_RAMC         => G_HRMEM
   )
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
      plllock          => locked,               -- X68K_top: mem_rstn, dem_rstn, vid_rstn, cpu_rstn
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
      pPs2Clkin        => ps2_kbd_clk_i,
      pPs2Clkout       => ps2_kbd_clk_o,
      pPs2Datin        => ps2_kbd_dat_i,
      pPs2Datout       => ps2_kbd_dat_o,
      pPmsClkin        => ps2_ms_clk_i,
      pPmsClkout       => ps2_ms_clk_o,
      pPmsDatin        => ps2_ms_dat_i,
      pPmsDatout       => ps2_ms_dat_o,
      pJoyA            => joy_a_n,
      pJoyB            => joy_b_n,
      pStrA            => open,
      pStrB            => open,
      pJoySelA         => open,
      pJoySelB         => open,
      pFDSYNC          => fd_sync,
      pFDEJECT         => fd_eject_d,
      pFDMOTOR         => fd_motor,
      pFDACTIVE        => open,
      pFDEJECTED       => open,
      pfdwait          => "00",
      mist_mounted     => img_mounted_d or post_reset_mount,
      mist_readonly    => "0000000" & img_readonly,   -- X68000.sv: 1 bit into 8 (bit 0 only)
      mist_imgsize     => ann_size,           -- MegaX: the size of the drive announced (p_mount)
      mist_lba         => sd_lba,
      mist_rd          => sd_rd,
      mist_wr          => sd_wr,
      mist_ack         => mist_ack,
      mist_buffaddr    => sd_buff_addr,
      mist_buffdout    => sd_buff_dout,
      mist_buffdin     => sd_buff_din,
      mist_buffwr      => sd_buff_wr,
      pDip             => "0000",
      pLed             => open,
      pPsw             => "11",                -- NMI and POWER buttons released
      pkbdtype         => "000",
      pSramld          => sram_ld,
      pSramst          => sram_st,
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
      disk_mode        => disk_mode,
      sxsi_inject      => sxsi_inject,
      vis_mem          => vis_mem,
      dbg_bus          => dbg_bus,
      dbg_opm          => dbg_opm,
      dbg_mem          => dbg_mem,
      xr_addrh_o       => xr_addrh,
      xr_bgn_o         => xr_bgn,
      xr_end_o         => xr_end,
      xr_bwidth_o      => xr_bwidth,
      xr_wrdat_o       => xr_wrdat,
      xr_we_o          => xr_we,
      xr_rd_o          => xr_rd,
      xr_wr_o          => xr_wr,
      xr_refrsh_o      => xr_refrsh,
      xr_abort_o       => xr_abort,
      xr_addr_rc_i     => xr_addr_rc,
      xr_addr_wc_i     => xr_addr_wc,
      xr_rddat_i       => xr_rddat,
      xr_de_i          => xr_de,
      xr_busy_i        => xr_busy,
      xr_initdone_i    => xr_initdone
   );

   -- the memory in the HyperRAM (R3): 4 MB of main RAM for the machine ("Visible Memory"
   -- 4 MB: X68K_top puts it into the SRAM's memory size byte)
   vis_mem <= "0100" when G_HRMEM else "0000";

   G_HR : if G_HRMEM generate
      -- R3 bring-up (temporary): the memory path tests itself before memcont gets it
      i_hrtest : entity work.x68_hrtest
      port map (
         clk_i        => clk_ram,
         rstn_i       => locked,
         m_addrh_i    => xr_addrh,
         m_bgn_i      => xr_bgn,
         m_end_i      => xr_end,
         m_bwidth_i   => xr_bwidth,
         m_wrdat_i    => xr_wrdat,
         m_we_i       => xr_we,
         m_rd_i       => xr_rd,
         m_wr_i       => xr_wr,
         m_refrsh_i   => xr_refrsh,
         m_abort_i    => xr_abort,
         m_addr_rc_o  => xr_addr_rc,
         m_addr_wc_o  => xr_addr_wc,
         m_rddat_o    => xr_rddat,
         m_de_o       => xr_de,
         m_busy_o     => xr_busy,
         m_initdone_o => xr_initdone,
         x_addrh_o    => ht_addrh,
         x_bgn_o      => ht_bgn,
         x_end_o      => ht_end,
         x_bwidth_o   => ht_bwidth,
         x_wrdat_o    => ht_wrdat,
         x_we_o       => ht_we,
         x_rd_o       => ht_rd,
         x_wr_o       => ht_wr,
         x_refrsh_o   => ht_refrsh,
         x_abort_o    => ht_abort,
         x_addr_rc_i  => ht_addr_rc,
         x_addr_wc_i  => ht_addr_wc,
         x_rddat_i    => ht_rddat,
         x_de_i       => ht_de,
         x_busy_i     => ht_busy,
         x_initdone_i => ht_initdone,
         result_o     => ht_result,
         err_o        => open
      );

      i_hrmem : entity work.x68_hrmem
      port map (
         clk_i              => clk_ram,
         rstn_i             => locked,
         addr_high_i        => ht_addrh,
         bgnaddr_i          => ht_bgn,
         endaddr_i          => ht_end,
         bwidth_i           => ht_bwidth,
         addr_rc_o          => ht_addr_rc,
         addr_wc_o          => ht_addr_wc,
         rddat_o            => ht_rddat,
         wrdat_i            => ht_wrdat,
         de_o               => ht_de,
         we_i               => ht_we,
         rd_i               => ht_rd,
         wr_i               => ht_wr,
         refrsh_i           => ht_refrsh,
         abort_i            => ht_abort,
         busy_o             => ht_busy,
         initdone_o         => ht_initdone,
         hr_clk_i           => hr_clk,
         hr_rst_i           => hr_rst,
         hr_write_o         => hr_write,
         hr_read_o          => hr_read,
         hr_address_o       => hr_address,
         hr_writedata_o     => hr_writedata,
         hr_byteenable_o    => hr_byteenable,
         hr_burstcount_o    => hr_burstcount,
         hr_readdata_i      => hr_readdata,
         hr_readdatavalid_i => hr_readdatavalid,
         hr_waitrequest_i   => hr_waitrequest,
         dbg_o              => xr_dbg,
         dbgx_o             => dbg_hrx
      );
   end generate G_HR;

   G_NOHR : if not G_HRMEM generate
      hr_write      <= '0';
      hr_read       <= '0';
      hr_address    <= (others => '0');
      hr_writedata  <= (others => '0');
      hr_byteenable <= (others => '0');
      hr_burstcount <= (others => '0');
      xr_addr_rc    <= (others => '0');
      xr_addr_wc    <= (others => '0');
      xr_rddat      <= (others => '0');
      xr_de         <= '0';
      xr_busy       <= '0';
      xr_initdone   <= '0';
      xr_dbg        <= (others => '0');
      dbg_hrx       <= (others => '0');
      ht_result     <= (others => '0');
   end generate G_NOHR;

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
