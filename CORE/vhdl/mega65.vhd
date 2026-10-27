----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- MEGA65 main file that contains the whole machine
--
-- * clk.vhd: clk_ram 80 MHz, clk_sys 40 MHz (= main_clk), the SDRAM's clock, clk_scan
--   69.552 MHz (= the video clock)
-- * main.vhd: x68_system (the MiSTer core) + the PS/2 keyboard + SDRAM pins + video and audio
-- * x68_boot.vhd: /megax/boot.rom from the Shell's ROM auto-loader to the core's loader port
--   (QNICE device C_DEV_X68_BOOT); the X68000 starts with the first byte and runs once the
--   firmware has checked the size and ended the load (PREP_START)
-- * x68_sd.vhd: the disk images straight from the SD card (QNICE devices C_DEV_X68_FDD0 ..
--   C_DEV_X68_SXSI2, one per hps_io slot, the SD host's engine port), served to the core
--   through MiSTer's hps_io sector interface: FDD0, FDD1, SASI, SxSI 1 and 2, the SRAM image
-- * the OSM settings (config.vhd): the images, D88 write-back, SRAM load/save, the SxSI
--   driver, HDMI mode, 68000 at 20 MHz, reset
--
-- Resets: the Shell holds the core in reset (main_reset_core_i) while it loads the boot ROM,
-- but the X68000 must run then: its memory controller writes the ROM into the SDRAM. So the
-- M2M resets reach the X68000 only after the load has ended. Before the first byte the core
-- is held anyway (x68_system: it starts with boot_active).
--
-- The entity is the Megamiga fork's MEGA65_Core (M2M-UPSTREAM exceptions: floppy, SDRAM,
-- PMOD, Ethernet pins and the SD engine port are routed into the core); everything the
-- X68000 does not use (yet) is tied off here with the values of the original board tops.
--
-- done by Johan Smolinski in 2026, after PC10-III's mega65.vhd (the MiSTer2MEGA65 template,
-- sy2002 and MJoergen, 2022, and Megamiga's mega65.vhd)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;
   video_fl_o              : out std_logic;  -- interlace field flag for ascal weave deinterlacing

   -- M2M-UPSTREAM rtg-framebuffer (Megamiga 2026-10-09): the RTG graphics card - ascal shows
   -- the framebuffer in HyperRAM instead of the Amiga picture while fb_ena_o = '1' (HDMI only:
   -- the analog output keeps the Amiga picture). Core clock domain, slowly changing.
   fb_ena_o                : out std_logic;
   fb_hsize_o              : out std_logic_vector(11 downto 0);
   fb_vsize_o              : out std_logic_vector(11 downto 0);
   fb_format_o             : out std_logic_vector( 5 downto 0);
   fb_base_o               : out std_logic_vector(31 downto 0);  -- HyperRAM byte address
   fb_stride_o             : out std_logic_vector(13 downto 0);
   fb_pal_clk_o            : out std_logic;
   fb_pal_a_o              : out std_logic_vector( 7 downto 0);
   fb_pal_dw_o             : out std_logic_vector(23 downto 0);
   fb_pal_wr_o             : out std_logic;
   fb_pal_dr_i             : in  std_logic_vector(23 downto 0) := (others => '0');

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- the X68000's clk_sys, 40 MHz
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_kb_key_raw_n_i     : in  std_logic;              -- the same, also while the OSM is open (M2M osm-hotkey)
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- OSM-open key selection (issue #8): the core decodes the "OSM: %s" radio and
   -- tells the framework's m2m_keyb which key(s) drive the menu-open bit
   -- (qnice_keys bit 7). Threaded core->framework->m2m_keyb, exactly like video_fl_o.
   osm_key_a_o             : out integer range 0 to 79;
   osm_key_b_o             : out integer range 0 to 79;
   osm_combo_o             : out std_logic;
   -- Megamiga (M2M-UPSTREAM osm-hotkey): '1' = the menu key must not open the menu now
   -- (CTRL+MEGA are held: CTRL+MEGA+HELP is the cartridge's freeze button)
   osm_block_o             : out std_logic;

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- MEGA65 internal floppy drive (Hardware Floppy feature): the 34-pin
   -- connector, threaded as plain wires from the board tops (M2M-UPSTREAM
   -- floppy-pins; the C64MEGA65 issue-#90 pattern). All active low. Drive B
   -- (f_motorb/f_selectb) stays tied '1' at the top level; the WRITE pins
   -- f_wdata/f_wgate are driven by physical_fdd_writer since WIP-V2-A9.
   f_wdata_o               : out std_logic;
   f_wgate_o               : out std_logic;
   f_motora_o              : out std_logic;
   f_selecta_o             : out std_logic;
   f_side1_o               : out std_logic;
   f_stepdir_o             : out std_logic;
   f_step_o                : out std_logic;
   f_density_o             : out std_logic;
   f_index_i               : in  std_logic;
   f_track0_i              : in  std_logic;
   f_writeprotect_i        : in  std_logic;
   f_rdata_i               : in  std_logic;
   f_diskchanged_i         : in  std_logic;

   -- SDRAM (R4/R5/R6 only: IS42S16320F, 32M x 16): the X68000's main RAM, boot ROM and half of
   -- the graphics VRAM, threaded as plain wires from the board tops (M2M-UPSTREAM sdram-pins,
   -- the floppy-pins pattern).
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
   sdram_dq_io             : inout std_logic_vector(15 downto 0);

   -- PMOD headers (R4/R5/R6 only), threaded as plain wires from the board tops (M2M-UPSTREAM
   -- pmod-pins, the floppy-pins pattern); unused, high-Z and unpowered.
   p1lo_io                 : inout std_logic_vector(3 downto 0);
   p1hi_io                 : inout std_logic_vector(3 downto 0);
   p2lo_io                 : inout std_logic_vector(3 downto 0);
   p2hi_io                 : inout std_logic_vector(3 downto 0);
   pmod1_en_o              : out   std_logic;
   pmod2_en_o              : out   std_logic;

   -- Ethernet PHY KSZ8081 (R4/R5/R6 only), threaded as plain wires from the board tops
   -- (M2M-UPSTREAM eth-pins, the floppy-pins pattern); unused.
   eth_clock_o             : out   std_logic;
   eth_led2_o              : out   std_logic;
   eth_mdc_o               : out   std_logic;
   eth_mdio_io             : inout std_logic;
   eth_reset_o             : out   std_logic;
   eth_rxd_i               : in    std_logic_vector(1 downto 0) := "00";
   eth_rxdv_i              : in    std_logic := '0';
   eth_rxer_i              : in    std_logic := '0';
   eth_txd_o               : out   std_logic_vector(1 downto 0);
   eth_txen_o              : out   std_logic;

   -- The engine port of the SD host controller (M2M-UPSTREAM sd-host, sdhost_pkg; QNICE
   -- clock domain): the disk images' sector service (phase 3)
   sd_eng_i                : in    std_logic_vector(63 downto 0) := (others => '0');
   sd_eng_o                : out   std_logic_vector(75 downto 0);

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- OSM menu bits (= line numbers of OPTM_ITEMS in config.vhd; keep single-line, make_rom.sh
-- scrapes them into osm_const.asm as X68_OSM_*)
---------------------------------------------------------------------------------------------

constant C_MENU_FDD0_LN       : natural := 2;   -- " FDD0:%s" (the firmware's SPACE eject)
constant C_MENU_FDD1_LN       : natural := 3;   -- " FDD1:%s"
constant C_MENU_SASI_LN       : natural := 4;   -- " SASI:%s"
constant C_MENU_SXSI1_LN      : natural := 5;   -- " SxSI 1:%s"
constant C_MENU_SXSI2_LN      : natural := 6;   -- " SxSI 2:%s"
constant C_MENU_SRAM_LN       : natural := 7;   -- " SRAM:%s"
constant C_MENU_SYNC0         : natural := 12;  -- momentary (the firmware clears them)
constant C_MENU_SYNC1         : natural := 13;
constant C_MENU_SRAM_LD       : natural := 14;
constant C_MENU_SRAM_ST       : natural := 15;
constant C_MENU_SXSI_INJ      : natural := 16;
constant C_MENU_SXSI_BOOT     : natural := 17;
constant C_MENU_HDMI_720P     : natural := 23;
constant C_MENU_HDMI_720P50   : natural := 24;
constant C_MENU_TURBO         : natural := 27;
constant C_MENU_RESET         : natural := 30;

---------------------------------------------------------------------------------------------
-- Clocks and resets
---------------------------------------------------------------------------------------------

signal clk_ram                : std_logic;
signal main_clk               : std_logic;             -- clk_sys
signal clk_sdram              : std_logic;
signal video_clk              : std_logic;             -- clk_scan
signal main_rst               : std_logic;
signal video_rst              : std_logic;
signal scan_locked            : std_logic;
signal scan_sel               : std_logic_vector(1 downto 0);
signal main_x68_reset         : std_logic := '1';
signal main_fd_motor          : std_logic;
signal main_boot_ended_d      : std_logic := '0';
signal main_dbg_status        : std_logic_vector(5 downto 0);
signal main_dbg_scan          : std_logic_vector(7 downto 0);
signal main_dbg_bus           : std_logic_vector(47 downto 0);
signal qnice_dbg_data         : std_logic_vector(15 downto 0);
signal qnice_dbg_ce           : std_logic;
signal qnice_dbg_we           : std_logic;
signal main_sxsi_inject       : std_logic := '0';

---------------------------------------------------------------------------------------------
-- boot ROM loader
---------------------------------------------------------------------------------------------

signal main_boot_active       : std_logic;
signal main_boot_addr         : std_logic_vector(19 downto 0);
signal main_boot_data         : std_logic_vector(7 downto 0);
signal main_boot_wr           : std_logic;
signal main_boot_wait         : std_logic;
signal main_boot_ended        : std_logic;

signal qnice_boot_data        : std_logic_vector(15 downto 0);
signal qnice_boot_ce          : std_logic;
signal qnice_boot_we          : std_logic;
signal qnice_boot_wait        : std_logic;

---------------------------------------------------------------------------------------------
-- disk images (x68_sd.vhd): QNICE side and the core's hps_io sector interface (main clock)
---------------------------------------------------------------------------------------------

signal qnice_sd_data          : std_logic_vector(15 downto 0);
signal qnice_sd_ce            : std_logic;
signal qnice_sd_we            : std_logic;
signal qnice_sd_slot          : std_logic_vector(2 downto 0);

signal main_img_mounted       : std_logic_vector(7 downto 0);
signal main_img_readonly      : std_logic;
signal main_img_size          : std_logic_vector(63 downto 0);
signal main_img_xdf           : std_logic;
signal main_sd_lba            : std_logic_vector(31 downto 0);
signal main_sd_rd             : std_logic_vector(7 downto 0);
signal main_sd_wr             : std_logic_vector(7 downto 0);
signal main_sd_ack            : std_logic_vector(7 downto 0);
signal main_sd_buff_addr      : std_logic_vector(8 downto 0);
signal main_sd_buff_dout      : std_logic_vector(7 downto 0);
signal main_sd_buff_din       : std_logic_vector(7 downto 0);
signal main_sd_buff_wr        : std_logic;

begin

   ---------------------------------------------------------------------------------------------
   -- Tie-offs: everything the X68000 does not use (values of the original M2M board tops)
   ---------------------------------------------------------------------------------------------

   hr_core_write_o      <= '0';
   hr_core_read_o       <= '0';
   hr_core_address_o    <= (others => '0');
   hr_core_writedata_o  <= (others => '0');
   hr_core_byteenable_o <= (others => '0');
   hr_core_burstcount_o <= (others => '0');

   -- M2M-UPSTREAM rtg-framebuffer: off (ascal shows the core's picture)
   fb_ena_o             <= '0';
   fb_hsize_o           <= (others => '0');
   fb_vsize_o           <= (others => '0');
   fb_format_o          <= (others => '0');
   fb_base_o            <= (others => '0');
   fb_stride_o          <= (others => '0');
   fb_pal_clk_o         <= '0';
   fb_pal_a_o           <= (others => '0');
   fb_pal_dw_o          <= (others => '0');
   fb_pal_wr_o          <= '0';

   -- M2M-UPSTREAM interlace: progressive (the X68000's interlaced modes: later)
   video_fl_o           <= '0';

   -- M2M-UPSTREAM osm-hotkey: the Help key opens the menu
   osm_key_a_o          <= 67;
   osm_key_b_o          <= 67;
   osm_combo_o          <= '0';
   osm_block_o          <= '0';

   -- IEC port: idle
   iec_reset_n_o        <= '1';
   iec_atn_n_o          <= '1';
   iec_clk_en_o         <= '0';
   iec_clk_n_o          <= '1';
   iec_data_en_o        <= '0';
   iec_data_n_o         <= '1';
   iec_srq_en_o         <= '0';
   iec_srq_n_o          <= '1';

   -- M2M-UPSTREAM floppy-pins: the internal drive idle
   f_motora_o           <= '1';
   f_selecta_o          <= '1';
   f_stepdir_o          <= '1';
   f_step_o             <= '1';
   f_side1_o            <= '1';
   f_wdata_o            <= '1';
   f_wgate_o            <= '1';
   f_density_o          <= '1';

   -- M2M-UPSTREAM pmod-pins: unused, unpowered
   p1lo_io              <= (others => 'Z');
   p1hi_io              <= (others => 'Z');
   p2lo_io              <= (others => 'Z');
   p2hi_io              <= (others => 'Z');
   pmod1_en_o           <= '0';
   pmod2_en_o           <= '0';

   -- M2M-UPSTREAM eth-pins: PHY held idle
   eth_clock_o          <= '0';
   eth_led2_o           <= '0';
   eth_mdc_o            <= '0';
   eth_mdio_io          <= 'Z';
   eth_reset_o          <= '1';
   eth_txd_o            <= (others => '0');
   eth_txen_o           <= '0';

   -- M2M-UPSTREAM sd-host: the engine port is x68_sd's (below)

   -- Expansion port: tristate everything; enabled because of the R5/R6 joystick port 2 bug
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';
   cart_en_o            <= '1';
   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';

   ---------------------------------------------------------------------------------------------
   -- Clocks
   ---------------------------------------------------------------------------------------------

   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         clk_ram_o         => clk_ram,         -- 80 MHz
         clk_sys_o         => main_clk,        -- 40 MHz
         clk_sdram_o       => clk_sdram,       -- 80 MHz, 288 degrees
         x68_locked_o      => open,
         sys_rst_o         => main_rst,
         scan_sel_i        => scan_sel,        -- the oscillator family (main.vhd)
         clk_scan_o        => video_clk,       -- 69.552 / 38.864 / 50.35 / 75.249 MHz
         scan_locked_o     => scan_locked,
         scan_rst_o        => video_rst
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= video_clk;
   video_rst_o <= video_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk
   ---------------------------------------------------------------------------------------------

   -- Power LED: green; blue while the reset button is held long. Drive LED: yellow while a
   -- floppy motor runs (MiSTer's user LED, X68000.sv's fdd_active).
   main_power_led_o     <= '1';
   main_power_led_col_o <= x"0000FF" when main_reset_m2m_i else x"00FF00";
   main_drive_led_o     <= main_fd_motor;
   main_drive_led_col_o <= x"FFFF00";

   -- The X68000's reset: the M2M resets (reset button, the Shell's CSR reset, i.e. the OSM's
   -- "Reset the X68000"), only once the boot ROM is in (see the header)
   p_reset : process (main_clk)
   begin
      if rising_edge(main_clk) then
         main_x68_reset <= (main_reset_core_i or main_reset_m2m_i) and main_boot_ended;
      end if;
   end process p_reset;

   -- "Inject SxSI driver" (momentary) or "SxSI driver at power-on": the latter as MiSTer's
   -- sxsi_boot_pulse, once the boot ROM is in (the core takes the rising edge)
   p_sxsi : process (main_clk)
   begin
      if rising_edge(main_clk) then
         main_boot_ended_d <= main_boot_ended;
         main_sxsi_inject  <= main_osm_control_i(C_MENU_SXSI_INJ) or
                              (main_osm_control_i(C_MENU_SXSI_BOOT) and main_boot_ended and
                               not main_boot_ended_d);
      end if;
   end process p_sxsi;

   i_main : entity work.main
      port map (
         clk_ram_i            => clk_ram,
         clk_sys_i            => main_clk,
         clk_sdram_i          => clk_sdram,
         clk_scan_i           => video_clk,
         sys_rst_i            => main_rst,
         scan_locked_i        => scan_locked,
         scan_sel_o           => scan_sel,
         reset_i              => main_x68_reset,
         turbo_i              => main_osm_control_i(C_MENU_TURBO),
         rtc_i                => main_rtc_i,

         boot_active_i        => main_boot_active,
         boot_addr_i          => main_boot_addr,
         boot_data_i          => main_boot_data,
         boot_wr_i            => main_boot_wr,
         boot_wait_o          => main_boot_wait,

         video_ce_o           => video_ce_o,
         video_ce_ovl_o       => video_ce_ovl_o,
         video_red_o          => video_red_o,
         video_green_o        => video_green_o,
         video_blue_o         => video_blue_o,
         video_vs_o           => video_vs_o,
         video_hs_o           => video_hs_o,
         video_hblank_o       => video_hblank_o,
         video_vblank_o       => video_vblank_o,

         fd_motor_o           => main_fd_motor,
         fd_sync_i            => main_osm_control_i(C_MENU_SYNC1) & main_osm_control_i(C_MENU_SYNC0),
         sram_ld_i            => main_osm_control_i(C_MENU_SRAM_LD),
         sram_st_i            => main_osm_control_i(C_MENU_SRAM_ST),
         sxsi_inject_i        => main_sxsi_inject,
         dbg_status_o         => main_dbg_status,
         dbg_scan_o           => main_dbg_scan,
         dbg_bus_o            => main_dbg_bus,

         img_mounted_i        => main_img_mounted,
         img_readonly_i       => main_img_readonly,
         img_size_i           => main_img_size,
         img_xdf_i            => main_img_xdf,
         sd_lba_o             => main_sd_lba,
         sd_rd_o              => main_sd_rd,
         sd_wr_o              => main_sd_wr,
         sd_ack_i             => main_sd_ack,
         sd_buff_addr_i       => main_sd_buff_addr,
         sd_buff_dout_i       => main_sd_buff_dout,
         sd_buff_din_o        => main_sd_buff_din,
         sd_buff_wr_i         => main_sd_buff_wr,

         audio_left_o         => main_audio_left_o,
         audio_right_o        => main_audio_right_o,

         kb_key_num_i         => main_kb_key_num_i,
         kb_key_pressed_n_i   => main_kb_key_pressed_n_i,

         sdram_clk_o          => sdram_clk_o,
         sdram_cke_o          => sdram_cke_o,
         sdram_ras_n_o        => sdram_ras_n_o,
         sdram_cas_n_o        => sdram_cas_n_o,
         sdram_we_n_o         => sdram_we_n_o,
         sdram_cs_n_o         => sdram_cs_n_o,
         sdram_ba_o           => sdram_ba_o,
         sdram_a_o            => sdram_a_o,
         sdram_dqml_o         => sdram_dqml_o,
         sdram_dqmh_o         => sdram_dqmh_o,
         sdram_dq_io          => sdram_dq_io
      ); -- i_main

   ---------------------------------------------------------------------------------------------
   -- Audio and video settings (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   -- The X68000's 31 kHz modes are 55.5 Hz: 720p at 60 Hz (default) or 50 Hz, through ascal
   qnice_video_mode_o <= C_VIDEO_HDMI_16_9_50 when qnice_osm_control_i(C_MENU_HDMI_720P50) = '1' else
                         C_VIDEO_HDMI_16_9_60;

   qnice_dvi_o                <= '0';                                         -- HDMI with sound
   -- Analog: the 31 kHz picture as it is (no scandoubler)
   qnice_scandoubler_o        <= '0';
   qnice_retro15kHz_o         <= '0';
   qnice_csync_o              <= '0';
   qnice_audio_mute_o         <= '0';
   qnice_audio_filter_o       <= '0';
   qnice_zoom_crop_o          <= '0';
   qnice_osm_cfg_scaling_o    <= (others => '1');
   qnice_ascal_mode_o         <= "00";
   qnice_ascal_polyphase_o    <= '0';
   qnice_ascal_triplebuf_o    <= '0';
   qnice_flip_joyports_o      <= '0';

   ---------------------------------------------------------------------------------------------
   -- Core specific device handling (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   core_specific_devices : process (all)
   begin
      qnice_dev_data_o <= x"EEEE";
      qnice_dev_wait_o <= '0';
      qnice_boot_ce    <= '0';
      qnice_boot_we    <= '0';
      qnice_sd_ce      <= '0';
      qnice_sd_we      <= '0';
      qnice_sd_slot    <= "000";
      qnice_dbg_ce     <= '0';
      qnice_dbg_we     <= '0';

      case qnice_dev_id_i is
         when C_DEV_X68_BOOT =>
            qnice_boot_ce    <= qnice_dev_ce_i;
            qnice_boot_we    <= qnice_dev_we_i;
            qnice_dev_data_o <= qnice_boot_data;
            qnice_dev_wait_o <= qnice_boot_wait;

         when C_DEV_X68_DEBUG =>
            qnice_dbg_ce     <= qnice_dev_ce_i;
            qnice_dbg_we     <= qnice_dev_we_i;
            qnice_dev_data_o <= qnice_dbg_data;

         -- the disk images: device 0x0101 + slot
         when C_DEV_X68_FDD0 | C_DEV_X68_FDD1 | C_DEV_X68_SASI | C_DEV_X68_SRAM |
              C_DEV_X68_SXSI1 | C_DEV_X68_SXSI2 =>
            qnice_sd_ce      <= qnice_dev_ce_i;
            qnice_sd_we      <= qnice_dev_we_i;
            qnice_sd_slot    <= std_logic_vector(unsigned(qnice_dev_id_i(2 downto 0)) - 1);
            qnice_dev_data_o <= qnice_sd_data;

         when others => null;
      end case;
   end process core_specific_devices;

   i_x68_boot : entity work.x68_boot
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_boot_data,
         qnice_ce_i           => qnice_boot_ce,
         qnice_we_i           => qnice_boot_we,
         qnice_wait_o         => qnice_boot_wait,

         clk_sys_i            => main_clk,
         rst_sys_i            => main_rst,
         boot_active_o        => main_boot_active,
         boot_addr_o          => main_boot_addr,
         boot_data_o          => main_boot_data,
         boot_wr_o            => main_boot_wr,
         boot_wait_i          => main_boot_wait,
         boot_ended_o         => main_boot_ended
      ); -- i_x68_boot

   -- the 68000 bus trace for the bring-up (x68_trace.vhd, QNICE device C_DEV_X68_DEBUG)
   i_x68_trace : entity work.x68_trace
      port map (
         clk_sys_i            => main_clk,
         bus_i                => main_dbg_bus,
         qnice_clk_i          => qnice_clk_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_dbg_data,
         qnice_ce_i           => qnice_dbg_ce,
         qnice_we_i           => qnice_dbg_we
      ); -- i_x68_trace

   i_x68_sd : entity work.x68_sd
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_slot_i         => qnice_sd_slot,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_data_o         => qnice_sd_data,
         qnice_ce_i           => qnice_sd_ce,
         qnice_we_i           => qnice_sd_we,
         sd_c2q_o             => sd_eng_o,
         sd_q2c_i             => sd_eng_i,
         main_clk_i           => main_clk,
         main_rst_i           => main_rst,
         img_mounted_o        => main_img_mounted,
         img_readonly_o       => main_img_readonly,
         img_size_o           => main_img_size,
         img_xdf_o            => main_img_xdf,
         sd_lba_i             => main_sd_lba,
         sd_rd_i              => main_sd_rd,
         sd_wr_i              => main_sd_wr,
         sd_ack_o             => main_sd_ack,
         sd_buff_addr_o       => main_sd_buff_addr,
         sd_buff_dout_o       => main_sd_buff_dout,
         sd_buff_din_i        => main_sd_buff_din,
         sd_buff_wr_o         => main_sd_buff_wr,
         main_busy_o          => open,
         main_present_o       => open
      ); -- i_x68_sd

end architecture synthesis;
