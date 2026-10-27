----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- Global constants
--
-- Based on the MiSTer2MEGA65 template (sy2002 and MJoergen, 2022) in the Megamiga fork and
-- PC10-III's globals.vhd
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.qnice_tools.all;
use work.video_modes_pkg.all;

package globals is

----------------------------------------------------------------------------------------------------------
-- QNICE Firmware
----------------------------------------------------------------------------------------------------------

constant QNICE_FIRMWARE_MONITOR   : string  := "../../../M2M/QNICE/monitor/monitor.rom";    -- debug/development
constant QNICE_FIRMWARE_M2M       : string  := "../../../CORE/m2m-rom/m2m-rom.rom";         -- release

-- Select firmware here
constant QNICE_FIRMWARE           : string  := QNICE_FIRMWARE_M2M;

-- Megamiga fork (M2M-UPSTREAM code-banks): the code bank ROM behind the window 0x9000-0x9FFF.
-- "" = no code banks: the MegaX firmware fits into the 32K-word ROM.
constant QNICE_CODE_BANKS         : string  := "";

----------------------------------------------------------------------------------------------------------
-- Clock Speed(s)
----------------------------------------------------------------------------------------------------------

-- main_clk is the X68000's clk_sys, 40 MHz (clk.vhd; the 68000, all peripherals and the menu
-- bits run on it). The framework derives the MEGA65 keyboard link (312.5 kHz, m2m_keyb) and its
-- scan timing from this value: a stale value runs the link at the wrong speed and the keyboard
-- drops it (PC10-III build pc10-real-i).
constant CORE_CLK_SPEED       : natural := 40_000_000;

-- System clock speed (crystal that is driving the FPGA) and QNICE clock speed
-- !!! Do not touch !!!
constant BOARD_CLK_SPEED      : natural := 100_000_000;
constant QNICE_CLK_SPEED      : natural := 50_000_000;   -- a change here has dependencies in qnice_globals.vhd

----------------------------------------------------------------------------------------------------------
-- Video Mode
----------------------------------------------------------------------------------------------------------

-- The On-Screen-Menu canvas: CHARS_DX x CHARS_DY = 768/16 x 512/16 = 48 x 32 characters. 768 x 512
-- is the X68000's main 31 kHz picture (the IPL, Human68k: CRTC mode 6, 34.776 MHz dots). It also
-- sizes ascal's input buffer in HyperRAM (digital_pipeline.vhd: 2**ceil(log2(768 x 512 x 3)) = 2 MB).
-- On HDMI the overlay is right-shifted by H_PIXELS - VGA_DX (1280 - 768 for 720p; the 720-pixel
-- 480p/576p modes are therefore not offered).
constant VGA_DX               : natural := 768;
constant VGA_DY               : natural := 512;

-- The X68000's 31 kHz modes need no scandoubler; the analog output takes the picture as it is
-- (mega65.vhd: qnice_scandoubler_o = '0'). The plain line doubler stays selected for later 15 kHz
-- modes (phase 4).
constant VGA_LINEDOUBLER      : boolean := true;

--    FONT_*  size of one OSM character (the 8x8 strike, rendered as 16x16 cells)
constant FONT_FILE            : string  := "../font/Anikki-8x8-m2m.rom";
constant FONT_DX              : natural := 16;
constant FONT_DY              : natural := 16;

-- Constants for the OSM screen memory
constant CHARS_DX             : natural := VGA_DX / FONT_DX;
constant CHARS_DY             : natural := VGA_DY / FONT_DY;
constant CHAR_MEM_SIZE        : natural := CHARS_DX * CHARS_DY;
constant VRAM_ADDR_WIDTH      : natural := f_log2(CHAR_MEM_SIZE);

----------------------------------------------------------------------------------------------------------
-- HyperRAM memory map (in units of 4kW)
----------------------------------------------------------------------------------------------------------

constant C_HMAP_M2M           : std_logic_vector(15 downto 0) := x"0000";     -- Reserved for the M2M framework

----------------------------------------------------------------------------------------------------------
-- QNICE devices of the core (ids >= 0x0100)
----------------------------------------------------------------------------------------------------------

-- The boot ROM loader (x68_boot.vhd): windows 0x0000..0x00FF = the 1 MB of /megax/boot.rom, byte i of
-- the file at window i/4096, offset i mod 4096 (the Shell's ROM auto-loader streams the file from
-- offset 0); every byte goes straight on to the X68000's loader port (the core writes it into the
-- SDRAM). Window 0x0100 = its control registers (see x68_boot.vhd).
constant C_DEV_X68_BOOT       : std_logic_vector(15 downto 0) := x"0100";
-- The disk images (x68_sd.vhd): MiSTer's slots 0 and 1, the floppy drives FDD0 and FDD1. Window 0
-- registers, window 1 the extent map, window 0xFFFF the CRT/ROM load CSR. Manual "ROM" loads in
-- the menu (nothing is streamed: the firmware hands the file's extent map over).
constant C_DEV_X68_FDD0       : std_logic_vector(15 downto 0) := x"0101";
constant C_DEV_X68_FDD1       : std_logic_vector(15 downto 0) := x"0102";

----------------------------------------------------------------------------------------------------------
-- Virtual Drive Management System: not used (yet)
----------------------------------------------------------------------------------------------------------

type vd_buf_array is array(natural range <>) of std_logic_vector;
constant C_VDNUM              : natural := 0;
constant C_VD_DEVICE          : std_logic_vector(15 downto 0) := x"EEEE";
constant C_VD_BUFFER          : vd_buf_array := (x"EEEE", x"EEEE");

----------------------------------------------------------------------------------------------------------
-- System for handling simulated cartridges and ROM loaders
----------------------------------------------------------------------------------------------------------

type crtrom_buf_array is array(natural range<>) of std_logic_vector;
constant ENDSTR : character := character'val(0);

-- Cartridges and ROMs can be stored into QNICE devices, HyperRAM and SDRAM
constant C_CRTROMTYPE_DEVICE     : std_logic_vector(15 downto 0) := x"0000";
constant C_CRTROMTYPE_HYPERRAM   : std_logic_vector(15 downto 0) := x"0001";
constant C_CRTROMTYPE_SDRAM      : std_logic_vector(15 downto 0) := x"0002";

-- Types of automatically loaded ROMs:
-- If a mandatory file is missing, then the core outputs the missing file and goes fatal
constant C_CRTROMTYPE_MANDATORY  : std_logic_vector(15 downto 0) := x"0003";
constant C_CRTROMTYPE_OPTIONAL   : std_logic_vector(15 downto 0) := x"0004";

-- Manually loadable ROMs: the floppy images of FDD0 and FDD1 (menu lines " FDD0:%s", " FDD1:%s").
-- The firmware's PREP_LOAD_IMAGE hands the file to x68_sd.vhd (extent map) and leaves the file
-- pointer at the end, so the Shell streams nothing and only does the CSR handshake.
constant C_CRTROMS_MAN_NUM       : natural := 2;
constant C_CRTROMS_MAN           : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_X68_FDD0,
                                                         C_CRTROMTYPE_DEVICE, C_DEV_X68_FDD1,
                                                         x"EEEE");

-- Automatically loaded ROMs: MiSTer's boot.rom (the X68000's CGROM and IPL, Sharp's: never in the
-- repository or the bitstream, AGENTS.md rule 4), mandatory. The Shell streams it into
-- C_DEV_X68_BOOT while the X68000 waits (the core starts its power-on sequence with the first byte
-- and holds the 68000 until the loader is done) and goes fatal if the file is missing; PREP_START
-- (m2m-rom.asm) then checks that exactly 1 MB arrived and ends the load.
constant BOOT_ROM_NAME           : string := "/megax/boot.rom" & ENDSTR;
constant BOOT_ROM_NAME_START     : std_logic_vector(15 downto 0) := x"0000";

constant C_CRTROMS_AUTO_NUM      : natural := 1;
constant C_CRTROMS_AUTO_NAMES    : string  := BOOT_ROM_NAME;
constant C_CRTROMS_AUTO          : crtrom_buf_array := ( C_CRTROMTYPE_DEVICE, C_DEV_X68_BOOT,
                                                         C_CRTROMTYPE_MANDATORY, BOOT_ROM_NAME_START,
                                                         x"EEEE");

----------------------------------------------------------------------------------------------------------
-- Audio filters (the framework's optional low-pass; values of the C64 template, unused while
-- qnice_audio_filter_o = '0')
----------------------------------------------------------------------------------------------------------

constant audio_flt_rate : std_logic_vector(31 downto 0) := std_logic_vector(to_signed(7056000, 32));
constant audio_cx       : std_logic_vector(39 downto 0) := std_logic_vector(to_signed(4258969, 40));
constant audio_cx0      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(3, 8));
constant audio_cx1      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(2, 8));
constant audio_cx2      : std_logic_vector( 7 downto 0) := std_logic_vector(to_signed(1, 8));
constant audio_cy0      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-6216759, 24));
constant audio_cy1      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed( 6143386, 24));
constant audio_cy2      : std_logic_vector(23 downto 0) := std_logic_vector(to_signed(-2023767, 24));
constant audio_att      : std_logic_vector( 4 downto 0) := "00000";
constant audio_mix      : std_logic_vector( 1 downto 0) := "00"; -- 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

end package globals;
