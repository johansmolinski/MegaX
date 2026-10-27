----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- Configuration data for the Shell: welcome and help screens, directories, the on-screen
-- menu (OSM). The address decoder at the end is the M2M template's plus Megamiga's
-- SEL_OPTM_ROWS (M2M-UPSTREAM menu-rows, M2M/rom/menu_rows.asm: radio groups side by side;
-- none here); SEL_OPTM_DEPS is not served.
--
-- Rules (Megamiga AGENTS.md, hard rules 7, 10, 11):
--   * OPTM_PAUSE stays false.
--   * The menu bit of a line is its line number: the C_MENU_* constants in mega65.vhd must
--     match OPTM_ITEMS below. make_rom.sh scrapes C_MENU_* and the core OPTM_G_* into
--     osm_const.asm (keep those constants single-line).
--   * Every menu growth: recheck MENU_HEAP_SIZE in m2m-rom.asm (the Shell goes fatal with
--     ERR_FATAL_HEAP1/2 at boot when it is too small).
--
-- done by Johan Smolinski in 2026, after PC10-III's config.vhd (the MiSTer2MEGA65 template,
-- sy2002 and MJoergen, 2022)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity config is
port (
   clk_i       : in std_logic;

   -- bits 27 .. 12:    select configuration data block; called "Selector" hereafter
   -- bits 11 downto 0: address the up to 4k the configuration data
   address_i   : in std_logic_vector(27 downto 0);

   -- config data
   data_o      : out std_logic_vector(15 downto 0)
);
end entity config;

architecture beh of config is

-- The version of the core: welcome/help screens and the core name derive from it
constant CORE_VERSION : string := "0.1";

----------------------------------------------------------------------------------------------------------
-- String and character constants (specific for the Anikki-16x16 font)
----------------------------------------------------------------------------------------------------------

constant CHR_LINE_1  : character := character'val(196);
constant CHR_LINE_5  : string := CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1;
constant CHR_LINE_10 : string := CHR_LINE_5 & CHR_LINE_5;

----------------------------------------------------------------------------------------------------------
-- Welcome and Help Screens
----------------------------------------------------------------------------------------------------------

constant WHS_RECORDS   : natural := 2;
constant WHS_MAX_PAGES : natural := 1;

constant SEL_WHS           : std_logic_vector(15 downto 0) := x"1000";

type WHS_INDEX_TYPE is array (0 to WHS_MAX_PAGES - 1) of natural;

type WHS_RECORD_TYPE is record
   page_count  : natural;
   page_start  : WHS_INDEX_TYPE;
   page_length : WHS_INDEX_TYPE;
end record;

type WHS_RECORD_ARRAY_TYPE is array (0 to WHS_RECORDS - 1) of WHS_RECORD_TYPE;

-- The OSM canvas is 48 x 32 characters (globals.vhd), the frame takes two of each.
constant SCR_WELCOME : string :=
   "MegaX " & CORE_VERSION & "\n\n" &
   "Sharp X68000 for MEGA65\n\n" &
   "Powered by MiSTer2MEGA65\n\n" &
   "Press Space to continue.\n";

constant HELP_1 : string :=
   " MegaX " & CORE_VERSION & " - Sharp X68000 for MEGA65\n\n" &
   " The MiSTer X68000 core (Puu-san) on the MEGA65.\n" &
   " /megax/boot.rom   MiSTer's boot.rom (1 MB)\n" &
   " FDD0, FDD1        XDF/DIM/HDM or D88 images\n\n" &
   " Keys (MiSTer layout):\n" &
   " " & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & "\n" &
   " F1 F3 .. F13      F1 .. F7\n" &
   " MEGA + 8 9 0      F8 F9 F10\n" &
   " MEGA + F1 .. F9   XF1 .. XF5\n" &
   " MEGA + 1 / 2      OPT.1 / OPT.2\n" &
   " MEGA + H          HELP\n" &
   " MEGA + Z X K      ZENKAKU HIRAGANA KANA\n" &
   " MEGA + ; T R Y    KIGOU TOUROKU ROMAJI YEN\n" &
   " ALT               XF2\n" &
   " RUN/STOP          BREAK\n" &
   " NO SCROLL         COPY\n" &
   " CLR/HOME RESTORE  HOME CLR\n" &
   " MEGA + up/down    ROLL UP / ROLL DOWN\n" &
   " MEGA + left       UNDO\n" &
   " MEGA + DEL/pound  DEL / INS\n" &
   " pound arrow-up    YEN ^\n" &
   " arrow-left        _\n" &
   " Help              this menu\n\n" &
   " Press Space to close the help screen.";

constant WHS_DATA : string := SCR_WELCOME & HELP_1;

constant SCR_WELCOME_START : natural := 0;
constant HELP_1_START      : natural := SCR_WELCOME'length;

constant WHS : WHS_RECORD_ARRAY_TYPE := (
   (page_count    => 1,
    page_start    => (0 => SCR_WELCOME_START),
    page_length   => (0 => SCR_WELCOME'length)),

   (page_count    => 1,
    page_start    => (0 => HELP_1_START),
    page_length   => (0 => HELP_1'length))
);

----------------------------------------------------------------------------------------------------------
-- Set start folder for file browser and specify config file for menu persistence
----------------------------------------------------------------------------------------------------------

constant SEL_DIR_START     : std_logic_vector(15 downto 0) := x"0100";
constant SEL_CFG_FILE      : std_logic_vector(15 downto 0) := x"0101";

constant DIR_START         : string := "/megax";
constant CFG_FILE          : string := "/megax/megaxcfg";

----------------------------------------------------------------------------------------------------------
-- General configuration settings: Reset, Pause, OSD behavior, Ascal, etc. (Selector 0x0110)
----------------------------------------------------------------------------------------------------------

constant SEL_GENERAL       : std_logic_vector(15 downto 0) := x"0110";  -- !!! DO NOT TOUCH !!!

constant RESET_COUNTER     : natural := 100;
constant OPTM_PAUSE        : boolean := false;     -- hard rule 7
constant WELCOME_ACTIVE    : boolean := false;
constant WELCOME_AT_RESET  : boolean := false;
constant KEYBOARD_AT_RESET : boolean := false;
constant JOY_1_AT_RESET    : boolean := false;
constant JOY_2_AT_RESET    : boolean := false;
constant KEYBOARD_AT_OSD   : boolean := false;
constant JOY_1_AT_OSD      : boolean := false;
constant JOY_2_AT_OSD      : boolean := false;
constant ASCAL_USAGE       : natural := 2;   -- 2 = AUSE_DIRECT: ascal mode from ASCAL_MODE below
constant ASCAL_MODE        : natural := 0;   -- nearest neighbour
constant SAVE_SETTINGS     : boolean := true;
constant VD_ANTI_THRASHING_DELAY : natural := 2000;
constant VD_ITERATION_SIZE       : natural := 100;

----------------------------------------------------------------------------------------------------------
-- Name of the core
----------------------------------------------------------------------------------------------------------

constant SEL_CORENAME      : std_logic_vector(15 downto 0) := x"0200";
constant CORENAME          : string := "MegaX " & CORE_VERSION;

----------------------------------------------------------------------------------------------------------
-- On-Screen-Menu (OSM)
----------------------------------------------------------------------------------------------------------

constant SEL_OPTM_ITEMS       : std_logic_vector(15 downto 0) := x"0300";
constant SEL_OPTM_GROUPS      : std_logic_vector(15 downto 0) := x"0301";
constant SEL_OPTM_STDSEL      : std_logic_vector(15 downto 0) := x"0302";
constant SEL_OPTM_LINES       : std_logic_vector(15 downto 0) := x"0303";
constant SEL_OPTM_START       : std_logic_vector(15 downto 0) := x"0304";
constant SEL_OPTM_ICOUNT      : std_logic_vector(15 downto 0) := x"0305";
constant SEL_OPTM_MOUNT_DRV   : std_logic_vector(15 downto 0) := x"0306";
constant SEL_OPTM_SINGLESEL   : std_logic_vector(15 downto 0) := x"0307";
constant SEL_OPTM_MOUNT_STR   : std_logic_vector(15 downto 0) := x"0308";
constant SEL_OPTM_DIMENSIONS  : std_logic_vector(15 downto 0) := x"0309";
constant SEL_OPTM_SAVING_STR  : std_logic_vector(15 downto 0) := x"030A";
constant SEL_OPTM_HELP        : std_logic_vector(15 downto 0) := x"0310";
constant SEL_OPTM_CRTROM      : std_logic_vector(15 downto 0) := x"0311";
constant SEL_OPTM_CRTROM_STR  : std_logic_vector(15 downto 0) := x"0312";
constant SEL_OPTM_ROWS        : std_logic_vector(15 downto 0) := x"0314";   -- M2M-UPSTREAM menu-rows

constant OPTM_G_TEXT       : integer := 16#00000#;         -- text that cannot be selected
constant OPTM_G_CLOSE      : integer := 16#000FF#;         -- menu items that closes menu
constant OPTM_G_STDSEL     : integer := 16#00100#;         -- item within a group that is selected by default
constant OPTM_G_LINE       : integer := 16#00200#;         -- draw a line at this position
constant OPTM_G_START      : integer := 16#00400#;         -- selector / cursor position after startup (only use once!)
constant OPTM_G_HEADLINE   : integer := 16#01000#;         -- like OPTM_G_TEXT but will be shown in a brigher color
constant OPTM_G_SINGLESEL  : integer := 16#08000#;         -- single select item
constant OPTM_G_MOUNT_DRV  : integer := 16#08800#;         -- line item means: mount drive
constant OPTM_G_HELP       : integer := 16#0A000#;         -- line item means: help screen; first occurance = WHS(1)
constant OPTM_G_SUBMENU    : integer := 16#0C000#;         -- starts/ends a section that is treated as submenu
constant OPTM_G_LOAD_ROM   : integer := 16#18000#;         -- line item means: load ROM

constant OPTM_GTC          : natural := 17;                -- Amount of significant bits in OPTM_G_* constants

constant OPTM_S_MOUNT      : string := "<Mount Drive>";
constant OPTM_S_CRTROM     : string := "<No Disk>";
constant OPTM_S_SAVING     : string := "<Saving>";

-- Size of menu and menu items. The line numbers are the bits of qnice_osm_control_i
-- (mega65.vhd C_MENU_*):
--     0  MegaX                   headline
--     1  ----
--     2  FDD0:%s                 floppy image of drive 0 (manual ROM load 0, x68_sd.vhd slot 0)
--     3  FDD1:%s                 floppy image of drive 1 (manual ROM load 1, slot 1)
--     4  ----
--     5  HDMI: %s                submenu
--     6    HDMI mode             headline
--     7    ----
--     8    720p 60 Hz 16:9       C_MENU_HDMI_720P (default)
--     9    720p 50 Hz 16:9       C_MENU_HDMI_720P50
--    10    ----
--    11    Back to main menu
--    12  68000 at 20 MHz         C_MENU_TURBO (MiSTer's "Turbo"; default off: 10 MHz)
--    13  ----
--    14  Help
--    15  Reset the X68000        C_MENU_RESET (momentary: the firmware resets and clears it)
--    16  ----
--    17  Close Menu
--
-- The settings file keeps one byte per line, so the layout is part of its format: the
-- firmware's CFG_SIGCHECK accepts only a file whose text carries this menu's signature
-- (m2m-rom.asm, CFG_SIG_VAL; change it with every layout change), any other file is reset to
-- the defaults.
constant OPTM_SIZE         : natural := 18;
constant OPTM_DX           : natural := 30;
constant OPTM_DY           : natural := 12;   -- the visible main menu (lines 0-5, 12-17)

constant OPTM_ITEMS        : string :=
   " MegaX\n"                 &
   "\n"                       &
   " FDD0:%s\n"               &
   " FDD1:%s\n"               &
   "\n"                       &
   " HDMI: %s\n"              &
   " HDMI mode\n"             &
   "\n"                       &
   " 720p 60 Hz 16:9\n"       &
   " 720p 50 Hz 16:9\n"       &
   "\n"                       &
   " Back to main menu\n"     &
   " 68000 at 20 MHz\n"       &
   "\n"                       &
   " Help\n"                  &
   " Reset the X68000\n"      &
   "\n"                       &
   " Close Menu\n";

-- Menu groups (single-line: make_rom.sh scrapes them into osm_const.asm as X68_OPTM_G_*)
constant OPTM_G_HDMI       : integer := 1;
constant OPTM_G_TURBO      : integer := 2;
constant OPTM_G_RESET      : integer := 3;
constant OPTM_G_FDD0       : integer := 4;
constant OPTM_G_FDD1       : integer := 5;

type OPTM_GTYPE is array (0 to OPTM_SIZE - 1) of integer range 0 to 2**OPTM_GTC- 1;

constant OPTM_GROUPS       : OPTM_GTYPE := ( OPTM_G_TEXT + OPTM_G_HEADLINE,            --  0 MegaX
                                             OPTM_G_LINE,                              --  1
                                             OPTM_G_FDD0 + OPTM_G_LOAD_ROM + OPTM_G_START, --  2 FDD0:%s
                                             OPTM_G_FDD1 + OPTM_G_LOAD_ROM,            --  3 FDD1:%s
                                             OPTM_G_LINE,                              --  4
                                             OPTM_G_SUBMENU,                           --  5 HDMI: %s
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --  6 HDMI mode
                                             OPTM_G_LINE,                              --  7
                                             OPTM_G_HDMI + OPTM_G_STDSEL,              --  8 720p 60 Hz
                                             OPTM_G_HDMI,                              --  9 720p 50 Hz
                                             OPTM_G_LINE,                              -- 10
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 11 Back
                                             OPTM_G_TURBO + OPTM_G_SINGLESEL,          -- 12 68000 at 20 MHz
                                             OPTM_G_LINE,                              -- 13
                                             OPTM_G_HELP,                              -- 14 Help
                                             OPTM_G_RESET + OPTM_G_SINGLESEL,          -- 15 Reset the X68000
                                             OPTM_G_LINE,                              -- 16
                                             OPTM_G_CLOSE                              -- 17 Close Menu
                                           );

-- M2M-UPSTREAM menu-rows (Megamiga, M2M/rom/menu_rows.asm): radio groups drawn as a row. None
-- here; OPTM_ROWS names a group that does not exist.
type OPTM_RTYPE is array (natural range <>) of natural;
constant OPTM_ROWS : OPTM_RTYPE := (0 => 200);

-- the layout word of every item (SEL_OPTM_ROWS): bit 0 = an option of a row (Megamiga's
-- word also carries greyed-out rules and headline separators: not used here)
type OPTM_LTYPE is array (0 to OPTM_SIZE - 1) of natural;
function optmLayout return OPTM_LTYPE is
   variable r : OPTM_LTYPE := (others => 0);
begin
   for i in 0 to OPTM_SIZE - 1 loop
      for k in OPTM_ROWS'range loop
         if OPTM_GROUPS(i) mod 256 = OPTM_ROWS(k) then
            r(i) := 1;
         end if;
      end loop;
   end loop;
   return r;
end function optmLayout;
constant OPTM_LAYOUT : OPTM_LTYPE := optmLayout;

begin

addr_decode : process(clk_i)
   -- return ASCII value of given string at the position defined by index (zero-based)
   pure function str2data(str : string; index : integer) return std_logic_vector is
   variable strpos : integer;
   begin
      strpos := index + 1;
      if strpos <= str'length then
         return std_logic_vector(to_unsigned(character'pos(str(strpos)), 16));
      else
         return X"0000"; -- zero terminated strings
      end if;
   end function str2data;

   -- return the dimensions of the Options menu
   pure function getDXDY(dx, dy, index: natural) return std_logic_vector is
   begin
      case index is
         when 0 => return std_logic_vector(to_unsigned(dx + 2, 16));
         when 1 => return std_logic_vector(to_unsigned(dy + 2, 16));
         when others => return X"0000";
      end case;
   end function getDXDY;

   -- convert bool to std_logic_vector
   pure function bool2slv(b: boolean) return std_logic_vector is
   begin
      if b then
         return x"0001";
      else
         return x"0000";
      end if;
   end function bool2slv;

   -- return the General Configuration settings
   function getGenConf(index: natural) return std_logic_vector is
   begin
      case index is
         when 1      => return std_logic_vector(to_unsigned(RESET_COUNTER, 16));
         when 2      => return bool2slv(OPTM_PAUSE);
         when 3      => return bool2slv(WELCOME_ACTIVE);
         when 4      => return bool2slv(WELCOME_AT_RESET);
         when 5      => return bool2slv(KEYBOARD_AT_RESET);
         when 6      => return bool2slv(JOY_1_AT_RESET);
         when 7      => return bool2slv(JOY_2_AT_RESET);
         when 8      => return bool2slv(KEYBOARD_AT_OSD);
         when 9      => return bool2slv(JOY_1_AT_OSD);
         when 10     => return bool2slv(JOY_2_AT_OSD);
         when 11     => return std_logic_vector(to_unsigned(ASCAL_USAGE, 16));
         when 12     => return std_logic_vector(to_unsigned(ASCAL_MODE, 16));
         when 13     => return std_logic_vector(to_unsigned(VD_ANTI_THRASHING_DELAY, 16));
         when 14     => return std_logic_vector(to_unsigned(VD_ITERATION_SIZE, 16));
         when 15     => return bool2slv(SAVE_SETTINGS);
         when others => return x"0000";
      end case;
   end function getGenConf;

   variable index           : integer;
   variable whs_page_index  : integer;
   variable whs_array_index : integer;

begin

   if falling_edge(clk_i) then

      index := to_integer(unsigned(address_i(11 downto 0)));
      whs_page_index  := to_integer(unsigned(address_i(19 downto 12)));
      whs_array_index := to_integer(unsigned(address_i(23 downto 20)));

      data_o <= x"EEEE";

      -----------------------------------------------------------------------------------
      -- Welcome & Help System: upper 4 bits of address equal SEL_WHS' upper 4 bits
      -----------------------------------------------------------------------------------

      if address_i(27 downto 24) = SEL_WHS(15 downto 12) then

         if  whs_array_index < WHS_RECORDS then
            if index = 4095 then
               data_o <= std_logic_vector(to_unsigned(WHS(whs_array_index).page_count, 16));
            else
               if index < WHS(whs_array_index).page_length(whs_page_index) then
                  data_o <= str2data(WHS_DATA, WHS(whs_array_index).page_start(whs_page_index) + index);
               else
                  data_o <= (others => '0'); -- zero-terminated strings
               end if;
            end if;
         end if;

      -----------------------------------------------------------------------------------
      -- All other selectors, which are 16-bit values
      -----------------------------------------------------------------------------------

      else

         case address_i(27 downto 12) is
            when SEL_GENERAL           => data_o <= getGenConf(index);
            when SEL_DIR_START         => data_o <= str2data(DIR_START, index);
            when SEL_CFG_FILE          => data_o <= str2data(CFG_FILE, index);
            when SEL_CORENAME          => data_o <= str2data(CORENAME, index);
            when SEL_OPTM_ITEMS        => data_o <= str2data(OPTM_ITEMS, index);
            when SEL_OPTM_MOUNT_STR    => data_o <= str2data(OPTM_S_MOUNT, index);
            when SEL_OPTM_CRTROM_STR   => data_o <= str2data(OPTM_S_CRTROM, index);
            when SEL_OPTM_SAVING_STR   => data_o <= str2data(OPTM_S_SAVING, index);
            when SEL_OPTM_GROUPS       => data_o <= std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15)) &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(14)) & "0" &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(12)) & "0000" &
                                                    std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(7 downto 0));
            when SEL_OPTM_STDSEL       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(8));
            when SEL_OPTM_LINES        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(9));
            when SEL_OPTM_START        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(10));
            when SEL_OPTM_MOUNT_DRV    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(11));
            when SEL_OPTM_HELP         => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(13));
            when SEL_OPTM_SINGLESEL    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15));
            when SEL_OPTM_CRTROM       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(16));
            when SEL_OPTM_ICOUNT       => data_o <= x"00" & std_logic_vector(to_unsigned(OPTM_SIZE, 8));
            when SEL_OPTM_DIMENSIONS   => data_o <= getDXDY(OPTM_DX, OPTM_DY, index);
            -- Rows (M2M-UPSTREAM menu-rows): the layout word of the item. Index 4095 is the
            -- feature probe (x"2D52"); without this arm the firmware draws the classic menu.
            when SEL_OPTM_ROWS         => if index = 4095 then
                                             data_o <= x"2D52";
                                          elsif index < OPTM_SIZE then
                                             data_o <= std_logic_vector(to_unsigned(OPTM_LAYOUT(index), 16));
                                          else
                                             data_o <= x"0000";
                                          end if;

            when others                => null;
         end case;
      end if;
   end if;
end process;

end architecture beh;
