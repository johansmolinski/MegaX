----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- Amiga quadrature mouse (MEGA65 joystick port) -> PS/2 mouse -> the core's MOUSECONV
--
-- On the MiSTer the X68000 core takes its mouse from hps_io's PS/2 mouse device: MOUSECONV
-- (rtl/SCC/MOUSEIF/MOUSECONV.vhd) is a PS/2 host that resets the mouse (FF, waits for AA), takes
-- the next byte as its ID, sets the defaults (F6, waits for FA), enables reporting (F4, waits for
-- FA) and then reads the standard 3-byte packets (buttons and signs, X, Y up positive) into the
-- X68000 mouse's SCC packets. This entity is that PS/2 mouse:
--
-- * the quadrature lines: PC10-III's decoder (rtl/system/cbm_mouse.sv, tested there with an
--   Amiga mouse): H/HQ count right, V/VQ count down, one count per edge. The lines come raw
--   from the framework (M2M-UPSTREAM raw-joyports: a 2-FF synchronizer, no 1 ms filter) and
--   pass two more flip-flops here.
-- * packets: the counts add up between packets; at most every 10 ms (the PS/2 default rate of
--   100 samples per second), when reporting is on, the FIFO is empty and something moved or a
--   button changed, one packet goes out with the counts clamped to -256..255 (the rest stays
--   for the next packet).
-- * host commands: every byte the host sends is answered with FA, FF additionally with AA 00
--   (self-test passed, mouse ID 0), F2 with the ID 00. F4 turns reporting on, F5, F6 and FF
--   turn it off. Other arguments (F3 rate, E8 resolution) are acknowledged and ignored.
-- * the line protocol is keyboard.vhd's (hps_io.sv's ps2_device), the same code.
-- * enable_i = '0' (the port is not the mouse): no movement and no buttons; the commands are
--   still answered.
--
-- done by Johan Smolinski in 2026, after keyboard.vhd, PC10-III's cbm_mouse.sv and MiSTer's
-- hps_io.sv ps2_device (sorgelig)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mouse is
   generic (
      C_PS2DIV        : natural := 2400;       -- the PS/2 bit clock: clk_i / (2 x (C_PS2DIV + 1))
      C_PERIOD        : natural := 400_000     -- the shortest packet interval: 10 ms at 40 MHz
   );
   port (
      clk_i           : in  std_logic;         -- clk_sys, 40 MHz
      reset_i         : in  std_logic;
      enable_i        : in  std_logic;         -- the port is the mouse (the menu)

      -- the Amiga mouse (DB9: H pin 2, HQ pin 4, V pin 1, VQ pin 3; buttons '0' = pressed)
      h_i             : in  std_logic;
      hq_i            : in  std_logic;
      v_i             : in  std_logic;
      vq_i            : in  std_logic;
      btn_l_n_i       : in  std_logic;
      btn_r_n_i       : in  std_logic;

      -- PS/2 (point to point with the core, '1' = released)
      ps2_clk_o       : out std_logic;
      ps2_dat_o       : out std_logic;
      ps2_clk_i       : in  std_logic;               -- the host's clock
      ps2_dat_i       : in  std_logic                -- the host's data
   );
end entity mouse;

architecture synthesis of mouse is

   constant C_FIFO_LOG : natural := 3;
   type t_fifo is array (0 to 2**C_FIFO_LOG - 1) of std_logic_vector(7 downto 0);

   signal fifo      : t_fifo;
   signal wr_ptr    : unsigned(C_FIFO_LOG - 1 downto 0) := (others => '0');
   signal rd_ptr    : unsigned(C_FIFO_LOG - 1 downto 0) := (others => '0');

   -- PS/2 line (hps_io.sv ps2_device, as keyboard.vhd)
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

   -- the mouse
   signal sh, shq   : std_logic_vector(2 downto 0) := (others => '1');  -- 2 sync stages + the last
   signal sv, svq   : std_logic_vector(2 downto 0) := (others => '1');
   signal sl, sr    : std_logic_vector(1 downto 0) := (others => '1');
   signal cnt_x     : signed(11 downto 0) := (others => '0');           -- right positive
   signal cnt_y     : signed(11 downto 0) := (others => '0');           -- down positive
   signal btn_sent  : std_logic_vector(1 downto 0) := "00";             -- {right, left}, 1 = pressed
   signal stream_on    : std_logic := '0';
   signal period    : natural range 0 to C_PERIOD := 0;

   -- +1 / -1 from the old (o) and new (n) levels of the pulse (p) and quad (q) lines
   -- (PC10-III's cbm_mouse.sv step())
   function step(po, pn, qo, qn : std_logic) return integer is
   begin
      if (qo = '0' and qn = '1' and pn = '1') or (qo = '1' and qn = '0' and pn = '0') or
         (po = '0' and pn = '1' and qn = '0') or (po = '1' and pn = '0' and qn = '1') then
         return 1;
      elsif (qo = '0' and qn = '1' and pn = '0') or (qo = '1' and qn = '0' and pn = '1') or
            (po = '0' and pn = '1' and qn = '1') or (po = '1' and pn = '0' and qn = '0') then
         return -1;
      end if;
      return 0;
   end function step;

   function clamp(c : signed(11 downto 0)) return signed is
   begin
      if c > 255 then
         return to_signed(255, 9);
      elsif c < -256 then
         return to_signed(-256, 9);
      end if;
      return c(8 downto 0);
   end function clamp;

begin

   p_main : process (clk_i)
      variable v_wr    : unsigned(C_FIFO_LOG - 1 downto 0);
      variable v_rd    : unsigned(C_FIFO_LOG - 1 downto 0);
      variable v_free  : unsigned(C_FIFO_LOG - 1 downto 0);
      variable v_dx    : signed(8 downto 0);
      variable v_dy    : signed(8 downto 0);                          -- up positive (PS/2)
      variable v_btn   : std_logic_vector(1 downto 0);
      variable v_cx    : signed(11 downto 0);
      variable v_cy    : signed(11 downto 0);

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
         -- the mouse: quadrature counts, buttons, packets
         ------------------------------------------------------------------------------------

         sh  <= sh(1 downto 0) & h_i;
         shq <= shq(1 downto 0) & hq_i;
         sv  <= sv(1 downto 0) & v_i;
         svq <= svq(1 downto 0) & vq_i;
         sl  <= sl(0) & btn_l_n_i;
         sr  <= sr(0) & btn_r_n_i;

         v_cx := cnt_x;
         v_cy := cnt_y;
         if enable_i = '1' then
            v_cx := v_cx + step(sh(2), sh(1), shq(2), shq(1));
            v_cy := v_cy + step(sv(2), sv(1), svq(2), svq(1));
            v_btn := not (sr(1) & sl(1));
         else
            v_cx  := (others => '0');
            v_cy  := (others => '0');
            v_btn := "00";
         end if;

         if period /= 0 then
            period <= period - 1;
         end if;

         v_free := v_rd - v_wr - 1;                          -- free FIFO entries

         if rx_got = '1' then
            -- a host command: acknowledge it (at most three bytes; a full FIFO drops them)
            if v_free >= 3 then
               push(x"FA");
               if rx_data = x"FF" then
                  push(x"AA");
                  push(x"00");
               elsif rx_data = x"F2" then
                  push(x"00");
               end if;
            end if;
            if rx_data = x"F4" then
               stream_on <= '1';
            elsif rx_data = x"F5" or rx_data = x"F6" or rx_data = x"FF" then
               stream_on <= '0';
            end if;
         elsif stream_on = '1' and period = 0 and v_wr = v_rd and tx_state = 0 and
               (v_cx /= 0 or v_cy /= 0 or v_btn /= btn_sent) then
            -- a packet: buttons and signs, X, Y (up positive)
            v_dx := clamp(v_cx);
            v_dy := clamp(-v_cy);
            push("00" & v_dy(8) & v_dx(8) & '1' & '0' & v_btn(1) & v_btn(0));
            push(std_logic_vector(v_dx(7 downto 0)));
            push(std_logic_vector(v_dy(7 downto 0)));
            v_cx := v_cx - resize(v_dx, 12);
            v_cy := v_cy + resize(v_dy, 12);
            btn_sent <= v_btn;
            period   <= C_PERIOD;
         end if;

         cnt_x  <= v_cx;
         cnt_y  <= v_cy;
         wr_ptr <= v_wr;
         rd_ptr <= v_rd;

         if reset_i = '1' then
            wr_ptr   <= (others => '0');
            rd_ptr   <= (others => '0');
            rx_state <= 0;
            tx_state <= 0;
            clk_out  <= '1';
            dat_out  <= '1';
            cnt_x    <= (others => '0');
            cnt_y    <= (others => '0');
            btn_sent <= "00";
            stream_on   <= '0';
            period   <= 0;
         end if;
      end if;
   end process p_main;

   ps2_clk_o <= clk_out;
   ps2_dat_o <= dat_out;

end architecture synthesis;
