----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- MEGA65 keyboard -> PS/2 keyboard (scan code set 2) -> the core's KBCONV (MiSTer layout)
--
-- On the MiSTer the X68000 core takes its keys from hps_io's PS/2 keyboard device: KBCONV
-- (rtl/MFP/KBIF/KBCONV.vhd) is a PS/2 host that resets the keyboard (FF, waits for AA), reads
-- its ID (F2), sets its LEDs (ED xx) and its typematic rate (F3 xx), and turns set-2 codes into
-- X68000 key codes through the "MiSTer" layout table. This entity is that PS/2 keyboard:
--
-- * key events: the framework scans the 80 MEGA65 keys round-robin (key_num_i, 1000 full scans
--   per second, key_pressed_n_i debounced and low active). Every change of a key becomes its
--   make code ([E0] code) or break code ([E0] F0 code) in a 32-byte FIFO (BREAK: the Pause
--   key's E1 14 77 / E1 F0 14 F0 77). A change is only taken while the FIFO has room for five
--   bytes; otherwise it is seen again on the next scan and nothing is lost.
-- * typematic repeat, as a PS/2 keyboard does it (KBCONV turns a repeated make code into the
--   X68000 keyboard's repeat, KS_REP): the last key pressed repeats its make code while it is
--   held, after the delay and at the rate the host set with F3 (default 2B: 500 ms, 10.9 per
--   second); its release, or another key's press, ends it. BREAK (E1) does not repeat.
-- * host commands: every byte the host sends is answered with FA (acknowledge), FF additionally
--   with AA (self-test passed), F2 with the MF2 keyboard ID AB 83. The answers go into the same
--   FIFO as the keys (KBCONV skips stray key bytes while it waits for an answer).
-- * the line protocol is hps_io.sv's ps2_device (MiSTer framework): a free-running PS/2 bit
--   clock (clk_i / (2 x (C_PS2DIV + 1)), 8.3 kHz at 40 MHz as on the MiSTer with PS2DIV 2400),
--   gated onto ps2_clk_o while a byte is sent or received; the host's request to send is its
--   clock rising while its data is low.
--
-- Key mapping (the MEGA key is the PS/2 Windows key, which KBCONV's MiSTer layout uses as a
-- modifier: MEGA + H = HELP, + 1 / 2 = OPT.1 / OPT.2, + F1 F3 F5 F7 F9 = XF1 .. XF5, + Z / X / K /
-- ; / T / R / Y = ZENKAKU / HIRAGANA / KANA / KIGOU / TOUROKU / ROMAJI / YEN):
--
--   MEGA65            X68000                    MEGA65            X68000
--   ESC               ESC                       RETURN            RETURN
--   1 .. 0, -         1 .. 0, -                 INST/DEL          BS (MEGA: DEL)
--   +                 keypad +                  TAB, CTRL         TAB, CTRL
--   pound             YEN (MEGA: INS)           SHIFT (both)      SHIFT
--   @ * (P row)       @ [                       ALT               XF2
--   : ; =             : ; ]                     SPACE             SPACE
--   arrow up          ^                         CAPS LOCK         CAPS
--   arrow left        _                         CLR/HOME          HOME
--   , . /             , . /                     RESTORE           CLR
--   letters           letters                   NO SCROLL         COPY
--   F1 F3 .. F13      F1 .. F7                  RUN/STOP          BREAK
--   MEGA + 8 9 0      F8 F9 F10                 cursor keys       cursor keys
--   MEGA + up / down  ROLL UP / ROLL DOWN       MEGA + left       UNDO
--   MEGA + -          keypad -
--   (the MEGA layer: the code sent at the make is remembered for the break)
--
-- Not mapped: HELP (opens the OSM).
--
-- done by Johan Smolinski in 2026, after PC10-III's keyboard.vhd and MiSTer's hps_io.sv
-- ps2_device (sorgelig)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard is
   generic (
      C_CLK_HZ        : natural := 40_000_000; -- clk_i
      C_PS2DIV        : natural := 2400        -- the PS/2 bit clock: clk_i / (2 x (C_PS2DIV + 1))
   );
   port (
      clk_i           : in  std_logic;         -- clk_sys, 40 MHz
      reset_i         : in  std_logic;

      -- Interface to the MEGA65 keyboard
      key_num_i       : in  integer range 0 to 79;   -- cycles through all MEGA65 keys
      key_pressed_n_i : in  std_logic;               -- low active, debounced

      -- PS/2 (point to point with the core, '1' = released)
      ps2_clk_o       : out std_logic;
      ps2_dat_o       : out std_logic;
      ps2_clk_i       : in  std_logic;               -- the host's clock
      ps2_dat_i       : in  std_logic                -- the host's data
   );
end entity keyboard;

architecture synthesis of keyboard is

   -- MEGA65 key numbers (M2M template keyboard.vhd)
   constant m65_mega      : integer := 61;

   -- a key's code: prefix (00 none, 01 E0, 10 E1) & set-2 code; "00" & x"00" = not mapped
   subtype t_code is std_logic_vector(9 downto 0);
   type t_map is array (0 to 79) of t_code;

   constant C_MAP : t_map := (
       0 => "00" & x"66",   -- INST/DEL     -> BS
       1 => "00" & x"5A",   -- RETURN       -> RETURN
       2 => "01" & x"74",   -- CRSR right   -> right
       3 => "00" & x"0C",   -- F7           -> F4
       4 => "00" & x"05",   -- F1           -> F1
       5 => "00" & x"06",   -- F3           -> F2
       6 => "00" & x"04",   -- F5           -> F3
       7 => "01" & x"72",   -- CRSR down    -> down
       8 => "00" & x"26",   -- 3
       9 => "00" & x"1D",   -- W
      10 => "00" & x"1C",   -- A
      11 => "00" & x"25",   -- 4
      12 => "00" & x"1A",   -- Z
      13 => "00" & x"1B",   -- S
      14 => "00" & x"24",   -- E
      15 => "00" & x"12",   -- left SHIFT
      16 => "00" & x"2E",   -- 5
      17 => "00" & x"2D",   -- R
      18 => "00" & x"23",   -- D
      19 => "00" & x"36",   -- 6
      20 => "00" & x"21",   -- C
      21 => "00" & x"2B",   -- F
      22 => "00" & x"2C",   -- T
      23 => "00" & x"22",   -- X
      24 => "00" & x"3D",   -- 7
      25 => "00" & x"35",   -- Y
      26 => "00" & x"34",   -- G
      27 => "00" & x"3E",   -- 8
      28 => "00" & x"32",   -- B
      29 => "00" & x"33",   -- H
      30 => "00" & x"3C",   -- U
      31 => "00" & x"2A",   -- V
      32 => "00" & x"46",   -- 9
      33 => "00" & x"43",   -- I
      34 => "00" & x"3B",   -- J
      35 => "00" & x"45",   -- 0
      36 => "00" & x"3A",   -- M
      37 => "00" & x"42",   -- K
      38 => "00" & x"44",   -- O
      39 => "00" & x"31",   -- N
      40 => "00" & x"79",   -- +            -> keypad +
      41 => "00" & x"4D",   -- P
      42 => "00" & x"4B",   -- L
      43 => "00" & x"4E",   -- -
      44 => "00" & x"49",   -- .
      45 => "00" & x"52",   -- :            -> :  (PS/2 ')
      46 => "00" & x"54",   -- @            -> @  (PS/2 [)
      47 => "00" & x"41",   -- ,
      48 => "00" & x"6A",   -- pound        -> YEN
      49 => "00" & x"5B",   -- *            -> [  (PS/2 ])
      50 => "00" & x"4C",   -- ;
      51 => "01" & x"6C",   -- CLR/HOME     -> HOME
      52 => "00" & x"59",   -- right SHIFT
      53 => "00" & x"5D",   -- =            -> ]  (PS/2 \)
      54 => "00" & x"55",   -- arrow up     -> ^  (PS/2 =)
      55 => "00" & x"4A",   -- /
      56 => "00" & x"16",   -- 1
      57 => "00" & x"51",   -- arrow left   -> _  (the JIS key left of right shift)
      58 => "00" & x"14",   -- CTRL
      59 => "00" & x"1E",   -- 2
      60 => "00" & x"29",   -- SPACE
      61 => "01" & x"1F",   -- MEGA         -> left Windows (KBCONV's combo modifier)
      62 => "00" & x"15",   -- Q
      63 => "10" & x"14",   -- RUN/STOP     -> BREAK (Pause: E1 14 77, KBCONV's E1 table)
      64 => "01" & x"7C",   -- NO SCROLL    -> COPY (PrtSc)
      65 => "00" & x"0D",   -- TAB
      66 => "00" & x"11",   -- ALT          -> XF2 (left Alt)
      67 => "00" & x"00",   -- HELP         (OSM key)
      68 => "00" & x"03",   -- F9           -> F5
      69 => "00" & x"0B",   -- F11          -> F6
      70 => "00" & x"83",   -- F13          -> F7
      71 => "00" & x"76",   -- ESC
      72 => "00" & x"58",   -- CAPS LOCK    -> CAPS
      73 => "01" & x"75",   -- CRSR up      -> up
      74 => "01" & x"6B",   -- CRSR left    -> left
      75 => "00" & x"77",   -- RESTORE      -> CLR (Num Lock)
      others => "00" & x"00"
   );

   -- The MEGA layer, by the key's own code; "00" & x"00" = none (the key as it is)
   function mega_code(c : t_code) return t_code is
   begin
      case c is
         when "00" & x"3E" => return "00" & x"0A";   -- 8           -> F8
         when "00" & x"46" => return "00" & x"01";   -- 9           -> F9
         when "00" & x"45" => return "00" & x"09";   -- 0           -> F10
         when "00" & x"66" => return "01" & x"71";   -- INST/DEL    -> DEL
         when "00" & x"6A" => return "01" & x"70";   -- pound       -> INS
         when "01" & x"75" => return "01" & x"7D";   -- cursor up   -> ROLL UP (PgUp)
         when "01" & x"72" => return "01" & x"7A";   -- cursor down -> ROLL DOWN (PgDn)
         when "01" & x"6B" => return "01" & x"69";   -- cursor left -> UNDO (End)
         when "00" & x"4E" => return "00" & x"7B";   -- -           -> keypad -
         when others       => return "00" & x"00";
      end case;
   end function mega_code;

   constant C_FIFO_LOG : natural := 5;

   -- typematic delay and period (PS/2): delay = (1 + bits 6..5) x 250 ms, period =
   -- (8 + bits 2..0) x 2 ^ bits 4..3 x 4.17 ms; in clk_i clocks
   constant C_CLK_MS   : natural := C_CLK_HZ / 1000;
   function tm_delay(a : std_logic_vector(7 downto 0)) return natural is
   begin
      return (1 + to_integer(unsigned(a(6 downto 5)))) * 250 * C_CLK_MS;
   end function tm_delay;
   function tm_period(a : std_logic_vector(7 downto 0)) return natural is
   begin
      return (8 + to_integer(unsigned(a(2 downto 0)))) * 2 ** to_integer(unsigned(a(4 downto 3))) *
             (C_CLK_HZ / 240);        -- 4.17 ms
   end function tm_period;

   type t_fifo is array (0 to 2**C_FIFO_LOG - 1) of std_logic_vector(7 downto 0);

   signal key_state : std_logic_vector(79 downto 0) := (others => '0');   -- 1 = pressed
   signal key_mega  : std_logic_vector(79 downto 0) := (others => '0');   -- make was a MEGA code
   signal fifo      : t_fifo;
   signal wr_ptr    : unsigned(C_FIFO_LOG - 1 downto 0) := (others => '0');
   signal rd_ptr    : unsigned(C_FIFO_LOG - 1 downto 0) := (others => '0');

   -- pipeline: A registers the scan, B looks the key up, C decides. The framework shows each key
   -- for many clocks, so after a change C ignores the next two clocks (B may still hold the key's
   -- state from before the change).
   signal a_num     : integer range 0 to 79 := 0;
   signal a_pressed : std_logic := '0';
   signal b_num     : integer range 0 to 79 := 0;
   signal b_pressed : std_logic := '0';
   signal b_state   : std_logic := '0';
   signal b_mega    : std_logic := '0';
   signal b_mkey    : std_logic := '0';
   signal b_map     : t_code := (others => '0');
   signal c_lock    : natural range 0 to 2 := 0;

   -- PS/2 line (hps_io.sv ps2_device)
   signal div       : natural range 0 to C_PS2DIV := 0;
   signal bitclk    : std_logic := '0';
   signal old_clk   : std_logic := '0';
   signal c1, c2    : std_logic := '1';
   signal d1        : std_logic := '1';
   signal rx_state  : natural range 0 to 4 := 0;
   signal rx_cnt    : natural range 0 to 15 := 0;
   signal rx_data   : std_logic_vector(7 downto 0) := (others => '0');
   signal rx_got    : std_logic := '0';
   signal tx_state  : natural range 0 to 11 := 0;
   signal tx_byte   : std_logic_vector(7 downto 0) := (others => '0');
   signal parity    : std_logic := '1';
   signal timeout   : unsigned(1 downto 0) := (others => '0');
   signal clk_out   : std_logic := '1';
   signal dat_out   : std_logic := '1';

   -- typematic repeat
   signal tm_arg    : std_logic_vector(7 downto 0) := x"2B";
   signal tm_next   : std_logic := '0';                      -- the next host byte is F3's argument
   signal rep_on    : std_logic := '0';
   signal rep_num   : integer range 0 to 79 := 0;
   signal rep_code  : t_code := (others => '0');
   signal rep_timer : natural range 0 to 2**27 - 1 := 0;

begin

   p_main : process (clk_i)
      variable v_code  : t_code;
      variable v_mega  : std_logic;
      variable v_wr    : unsigned(C_FIFO_LOG - 1 downto 0);
      variable v_rd    : unsigned(C_FIFO_LOG - 1 downto 0);
      variable v_free  : unsigned(C_FIFO_LOG - 1 downto 0);

      procedure push(b : std_logic_vector(7 downto 0)) is
      begin
         fifo(to_integer(v_wr)) <= b;
         v_wr := v_wr + 1;
      end procedure push;
   begin
      if rising_edge(clk_i) then
         v_wr := wr_ptr;
         v_rd := rd_ptr;

         ------------------------------------------------------------------------------------
         -- PS/2 line: the free-running bit clock, the host's lines, the receiver, the sender
         ------------------------------------------------------------------------------------

         if div = C_PS2DIV then
            div    <= 0;
            bitclk <= not bitclk;
         else
            div    <= div + 1;
         end if;

         c1      <= ps2_clk_i;
         c2      <= c1;
         d1      <= ps2_dat_i;
         rx_got  <= '0';
         old_clk <= bitclk;

         -- the host's request to send: its clock released while its data is low
         if rx_state = 0 and tx_state = 0 and c2 = '0' and c1 = '1' and d1 = '0' then
            rx_state <= 1;
            dat_out  <= '1';
         end if;

         if old_clk = '0' and bitclk = '1' then
            if rx_state /= 0 then
               case rx_state is
                  when 1 =>
                     rx_state <= 2;
                     rx_cnt   <= 0;
                  when 2 =>
                     if rx_cnt <= 7 then
                        rx_data <= d1 & rx_data(7 downto 1);
                     else
                        rx_state <= 3;                       -- (the parity bit is not checked)
                     end if;
                     rx_cnt <= rx_cnt + 1;
                  when 3 =>
                     if d1 = '1' then                        -- the stop bit: acknowledge
                        rx_state <= 4;
                        dat_out  <= '0';
                     end if;
                  when 4 =>
                     dat_out  <= '1';
                     rx_got   <= '1';
                     rx_state <= 0;
                  when others =>
                     rx_state <= 0;
               end case;
            elsif tx_state = 0 then
               -- a byte to send, the host does not inhibit: send it after a short pause
               if c2 = '1' and c1 = '1' and d1 = '1' and v_wr /= v_rd then
                  timeout <= timeout - 1;
                  if timeout = 0 then
                     tx_byte  <= fifo(to_integer(v_rd));
                     v_rd     := v_rd + 1;
                     parity   <= '1';
                     tx_state <= 1;
                     dat_out  <= '0';                        -- the start bit
                  end if;
               end if;
            else
               if tx_state >= 1 and tx_state < 9 then
                  dat_out <= tx_byte(0);                     -- data bits, LSB first
                  tx_byte <= '0' & tx_byte(7 downto 1);
                  if tx_byte(0) = '1' then
                     parity <= not parity;
                  end if;
               end if;
               if tx_state = 9 then
                  dat_out <= parity;                         -- odd parity
               end if;
               if tx_state = 10 then
                  dat_out <= '1';                            -- the stop bit
               end if;
               if tx_state < 11 then
                  tx_state <= tx_state + 1;
               else
                  tx_state <= 0;
               end if;
            end if;
         end if;

         -- the clock pulses only while a byte travels
         if old_clk = '0' and bitclk = '1' then
            clk_out <= '1';
         end if;
         if old_clk = '1' and bitclk = '0' then
            if tx_state = 0 and rx_state < 2 then
               clk_out <= '1';
            else
               clk_out <= '0';
            end if;
         end if;

         ------------------------------------------------------------------------------------
         -- the keys: A, B, C
         ------------------------------------------------------------------------------------

         a_num     <= key_num_i;
         a_pressed <= not key_pressed_n_i;
         b_num     <= a_num;
         b_pressed <= a_pressed;
         b_state   <= key_state(a_num);
         b_mkey    <= key_mega(a_num);
         b_mega    <= key_state(m65_mega);
         b_map     <= C_MAP(a_num);

         v_free := v_rd - v_wr - 1;                          -- free FIFO entries

         if rep_timer /= 0 then
            rep_timer <= rep_timer - 1;
         end if;

         if rx_got = '1' then
            -- a host command: acknowledge it (at most three bytes; a full FIFO drops them)
            if v_free >= 3 then
               push(x"FA");
               if tm_next = '0' and rx_data = x"FF" then
                  push(x"AA");
               elsif tm_next = '0' and rx_data = x"F2" then
                  push(x"AB");
                  push(x"83");
               end if;
            end if;
            if tm_next = '1' then
               tm_arg  <= rx_data;
               tm_next <= '0';
            elsif rx_data = x"F3" then
               tm_next <= '1';
            end if;
         elsif rep_on = '1' and rep_timer = 0 and v_free >= 3 then
            -- typematic repeat of the last key pressed
            if rep_code(9 downto 8) = "01" then
               push(x"E0");
            end if;
            push(rep_code(7 downto 0));
            rep_timer <= tm_period(tm_arg);
         elsif c_lock /= 0 then
            c_lock <= c_lock - 1;
         elsif b_pressed /= b_state and v_free >= 5 then
            c_lock <= 2;
            key_state(b_num) <= b_pressed;
            if b_pressed = '1' then
               v_mega := '0';
               if b_mega = '1' and mega_code(b_map) /= "00" & x"00" then
                  v_mega := '1';
               end if;
               key_mega(b_num) <= v_mega;
            else
               v_mega := b_mkey;
            end if;
            if v_mega = '1' then
               v_code := mega_code(b_map);
            else
               v_code := b_map;
            end if;
            if v_code(9 downto 8) = "10" then
               -- BREAK: the Pause key's bytes, E1 14 77 / E1 F0 14 F0 77. KBCONV keeps its E1
               -- flag after the E1 code (KS_WINT does not clear it); the trailing 77 (E1 table:
               -- 7F, no key) clears it, else the next E0 key would be looked up in the E1 half
               push(x"E1");
               if b_pressed = '0' then
                  push(x"F0");
               end if;
               push(v_code(7 downto 0));
               if b_pressed = '0' then
                  push(x"F0");
               end if;
               push(x"77");
            elsif v_code /= "00" & x"00" then
               if v_code(9 downto 8) = "01" then
                  push(x"E0");
               end if;
               if b_pressed = '0' then
                  push(x"F0");
               end if;
               push(v_code(7 downto 0));
            end if;
            -- typematic: a press starts it for this key, the key's release ends it
            if b_pressed = '1' then
               rep_on    <= '0';
               if v_code /= "00" & x"00" and v_code(9 downto 8) /= "10" then
                  rep_on    <= '1';
                  rep_num   <= b_num;
                  rep_code  <= v_code;
                  rep_timer <= tm_delay(tm_arg);
               end if;
            elsif b_num = rep_num then
               rep_on <= '0';
            end if;
         end if;

         wr_ptr <= v_wr;
         rd_ptr <= v_rd;

         if reset_i = '1' then
            key_state <= (others => '0');
            key_mega  <= (others => '0');
            wr_ptr    <= (others => '0');
            rd_ptr    <= (others => '0');
            c_lock    <= 2;
            rep_on    <= '0';
            tm_arg    <= x"2B";
            tm_next   <= '0';
            rx_state  <= 0;
            tx_state  <= 0;
            clk_out   <= '1';
            dat_out   <= '1';
         end if;
      end if;
   end process p_main;

   ps2_clk_o <= clk_out;
   ps2_dat_o <= dat_out;

end architecture synthesis;
