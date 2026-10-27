----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- x68_trace: a 68000 bus trace for the hardware bring-up, read through the QNICE monitor (the
-- Shell's debug mode; tools/trace.py). The last 1024 bus cycles in block RAM: at the end of
-- every cycle (the clock before AS rises) its function code, R/W, the strobes, the address and
-- the data (the CPU's on a write, the bus's on a read) - X68K_top's dbg_bus.
--
-- QNICE device C_DEV_X68_DEBUG (globals.vhd):
--   window 0  0x00 (R/W) control: bit 0 = 1 frozen (nothing is recorded), bit 1 = 1 writes
--                        only (a read cycle is not recorded), bit 2 = 1 trigger armed
--             0x01 (R)   the next entry's index (the oldest entry when the ring is full)
--             0x02/0x03  (R) bus cycles recorded since the power-up (lo, hi)
--             0x04/0x05  (R/W) trigger address bits 15..0, 23..16
--             0x06/0x07  (R/W) trigger mask (1 = compare this bit) bits 15..0, 23..16
--             0x08 (R)   bit 0: the trigger has fired (the trace froze itself)
--   Trigger: while armed, a program fetch (FC 2 or 6) whose address matches under the mask
--   fires; 64 more cycles are recorded, then the trace freezes (control bit 0 stays as it was:
--   write the control again to re-arm). So the ring holds the ~960 cycles before the match.
--   window 1  entry i (offset i, 0..1023): the data
--   window 2  entry i: the address bits 15..0
--   window 3  entry i: bits 15..13 FC, 12 RWn, 11 UDSn, 10 LDSn, 7..0 the address bits 23..16
-- Freeze before reading (the entries and the index change otherwise).
--
-- done by Johan Smolinski in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_trace is
   port (
      clk_sys_i      : in  std_logic;
      bus_i          : in  std_logic_vector(47 downto 0);   -- X68K_top's dbg_bus

      qnice_clk_i    : in  std_logic;
      qnice_addr_i   : in  std_logic_vector(27 downto 0);
      qnice_data_i   : in  std_logic_vector(15 downto 0);
      qnice_data_o   : out std_logic_vector(15 downto 0);
      qnice_ce_i     : in  std_logic;
      qnice_we_i     : in  std_logic
   );
end entity x68_trace;

architecture synthesis of x68_trace is

   signal q_ctrl     : std_logic_vector(2 downto 0) := "000";
   signal q_gen      : std_logic := '0';                       -- toggles per control write
   signal q_taddr    : std_logic_vector(23 downto 0) := (others => '0');
   signal q_tmask    : std_logic_vector(23 downto 0) := (others => '0');
   signal s_ctrl     : std_logic_vector(3 downto 0);
   signal s_ctrl_1   : std_logic_vector(3 downto 0) := "0000";
   signal s_gen_d    : std_logic := '0';
   signal s_fired    : std_logic := '0';
   signal s_post     : natural range 0 to 64 := 0;
   signal s_stop     : std_logic := '0';
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of s_ctrl_1 : signal is "TRUE";

   signal prev       : std_logic_vector(47 downto 0) := (others => '1');
   signal wptr       : unsigned(9 downto 0) := (others => '0');
   signal count      : unsigned(31 downto 0) := (others => '0');
   signal we         : std_logic := '0';
   signal wdata      : std_logic_vector(47 downto 0) := (others => '0');
   signal waddr      : std_logic_vector(9 downto 0) := (others => '0');

   signal q_win      : std_logic_vector(15 downto 0);
   signal q_rdata    : std_logic_vector(47 downto 0);

begin

   -- the end of a cycle: AS was low (prev) and is high now; record prev
   p_rec : process (clk_sys_i)
   begin
      if rising_edge(clk_sys_i) then
         s_ctrl_1 <= q_gen & q_ctrl;
         s_ctrl   <= s_ctrl_1;
         s_gen_d  <= s_ctrl(3);
         prev     <= bus_i;
         we       <= '0';
         -- a control write (re)starts: no stop, the trigger not fired
         if s_ctrl(3) /= s_gen_d then
            s_fired <= '0';
            s_stop  <= '0';
            s_post  <= 0;
         end if;
         if prev(47) = '0' and bus_i(47) = '1' and s_ctrl(0) = '0' and s_stop = '0' and
            (s_ctrl(1) = '0' or prev(46) = '0') then
            -- the trigger: a program fetch at the address (q_taddr/q_tmask are static while
            -- armed: written before the control word)
            if s_ctrl(2) = '1' and s_fired = '0' and prev(44) = '1' and prev(43) = '0' and
               ((prev(40 downto 17) xor q_taddr) and q_tmask) = x"000000" then
               s_fired <= '1';
               s_post  <= 64;
            elsif s_fired = '1' then
               if s_post = 1 then
                  s_stop <= '1';
               end if;
               if s_post /= 0 then
                  s_post <= s_post - 1;
               end if;
            end if;
            -- FC, RWn, UDSn, LDSn, address, data
            wdata <= prev(45 downto 43) & prev(46) & prev(42 downto 41) & "00" & prev(40 downto 17) & prev(15 downto 0);
            waddr <= std_logic_vector(wptr);
            we    <= '1';
            wptr  <= wptr + 1;
            count <= count + 1;
         end if;
      end if;
   end process p_rec;

   i_ram : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 10,
         DATA_WIDTH        => 48,
         RAM_STYLE_SELECT  => "block",
         FALLING_A         => true
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => qnice_addr_i(9 downto 0),
         data_a            => (others => '0'),
         wren_a            => '0',
         q_a               => q_rdata,
         clock_b           => clk_sys_i,
         address_b         => waddr,
         data_b            => wdata,
         wren_b            => we,
         q_b               => open
      ); -- i_ram

   q_win <= qnice_addr_i(27 downto 12);

   p_qctrl : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' and q_win = x"0000" then
            case qnice_addr_i(11 downto 0) is
               when x"000" => q_ctrl <= qnice_data_i(2 downto 0);
                              q_gen  <= not q_gen;
               when x"004" => q_taddr(15 downto 0)  <= qnice_data_i;
               when x"005" => q_taddr(23 downto 16) <= qnice_data_i(7 downto 0);
               when x"006" => q_tmask(15 downto 0)  <= qnice_data_i;
               when x"007" => q_tmask(23 downto 16) <= qnice_data_i(7 downto 0);
               when others => null;
            end case;
         end if;
      end if;
   end process p_qctrl;

   -- the index and the counter are read as they are (freeze first)
   p_qread : process (all)
   begin
      qnice_data_o <= x"0000";
      case q_win is
         when x"0000" =>
            case qnice_addr_i(11 downto 0) is
               when x"000" => qnice_data_o <= "0000000000000" & q_ctrl;
               when x"001" => qnice_data_o <= "000000" & std_logic_vector(wptr);
               when x"002" => qnice_data_o <= std_logic_vector(count(15 downto 0));
               when x"003" => qnice_data_o <= std_logic_vector(count(31 downto 16));
               when x"004" => qnice_data_o <= q_taddr(15 downto 0);
               when x"005" => qnice_data_o <= x"00" & q_taddr(23 downto 16);
               when x"006" => qnice_data_o <= q_tmask(15 downto 0);
               when x"007" => qnice_data_o <= x"00" & q_tmask(23 downto 16);
               when x"008" => qnice_data_o <= "000000000000000" & s_fired;
               when others => null;
            end case;
         when x"0001" => qnice_data_o <= q_rdata(15 downto 0);
         when x"0002" => qnice_data_o <= q_rdata(31 downto 16);
         when x"0003" => qnice_data_o <= q_rdata(47 downto 32);
         when others  => null;
      end case;
   end process p_qread;

end architecture synthesis;
