----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- x68_dbg: a probe for the hardware bring-up, read through the QNICE monitor (the Shell's debug
-- mode: tools/qmon.py). QNICE device C_DEV_X68_DEBUG, window 0:
--   0x00       status (asynchronous bits, read as they are): bit 0 started, 1 ldr_done,
--              2 core_rstn, 3 the X68000's reset input, 4 locked (SDRAM power-up done),
--              5 scan_ready, 6 boot_active, 7 the capture is armed/running, 8 the capture is full
--   0x01/0x02  SDRAM READ commands since the arm (lo, hi)
--   0x03/0x04  WRITE commands, 0x05/0x06 ACTIVE commands, 0x07/0x08 AUTO REFRESH commands
--   0x09       scan_req & scan_mode (bits 7..4, 3..0)
--   0x0A       the number of captured reads (0..64)
--   0x10..     the capture: per entry i four words at 0x10 + 4 i: bank & row (bits 14..13,
--              12..0), column (9..0), the word the controller sampled (DQ at the third clk_ram
--              edge after the READ, SDRAMC's rddat), the word one clock later
-- The probe arms when the X68000's reset input falls (the Shell's un-reset after the boot ROM)
-- and captures the first 64 READ commands. Commands are decoded from the SDRAM pins' signals
-- (CS_n is always 0 in SDRAMC); the row of a READ is the last ACTIVE's of its bank.
--
-- done by Johan Smolinski in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_dbg is
   port (
      clk_ram_i      : in  std_logic;
      ras_n_i        : in  std_logic;
      cas_n_i        : in  std_logic;
      we_n_i         : in  std_logic;
      ba_i           : in  std_logic_vector(1 downto 0);
      a_i            : in  std_logic_vector(12 downto 0);
      dq_i           : in  std_logic_vector(15 downto 0);
      arm_i          : in  std_logic;                       -- any clock: the X68000's reset
      status_i       : in  std_logic_vector(6 downto 0);    -- any clock
      scan_i         : in  std_logic_vector(7 downto 0);    -- any clock

      qnice_addr_i   : in  std_logic_vector(27 downto 0);
      qnice_data_o   : out std_logic_vector(15 downto 0)
   );
end entity x68_dbg;

architecture synthesis of x68_dbg is

   type t_rows is array (0 to 3) of std_logic_vector(12 downto 0);
   type t_cap  is array (0 to 255) of std_logic_vector(15 downto 0);

   signal rows      : t_rows := (others => (others => '0'));
   signal cap       : t_cap := (others => (others => '0'));
   signal n_rd      : unsigned(31 downto 0) := (others => '0');
   signal n_wr      : unsigned(31 downto 0) := (others => '0');
   signal n_act     : unsigned(31 downto 0) := (others => '0');
   signal n_ref     : unsigned(31 downto 0) := (others => '0');
   signal n_cap     : unsigned(6 downto 0) := (others => '0');
   signal armed     : std_logic := '0';
   signal arm_s     : std_logic_vector(2 downto 0) := (others => '0');
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of arm_s : signal is "TRUE";

   -- the pipeline from a READ to its data: stage k = k clocks after the command was seen
   signal p_rd      : std_logic_vector(3 downto 0) := (others => '0');
   signal dq_d      : std_logic_vector(15 downto 0) := (others => '0');

   signal win       : std_logic_vector(15 downto 0);
   signal ofs       : unsigned(11 downto 0);

begin

   p_probe : process (clk_ram_i)
      variable v_i : natural range 0 to 63;
   begin
      if rising_edge(clk_ram_i) then
         arm_s <= arm_s(1 downto 0) & arm_i;
         dq_d  <= dq_i;
         p_rd  <= p_rd(2 downto 0) & '0';
         v_i   := to_integer(n_cap(5 downto 0));

         -- the command on the pins during the last clock
         if ras_n_i = '0' and cas_n_i = '1' and we_n_i = '1' then          -- ACTIVE
            rows(to_integer(unsigned(ba_i))) <= a_i;
            if armed = '1' then
               n_act <= n_act + 1;
            end if;
         elsif ras_n_i = '1' and cas_n_i = '0' and we_n_i = '1' then       -- READ
            if armed = '1' then
               n_rd <= n_rd + 1;
               if n_cap < 64 then
                  cap(v_i * 4)     <= '0' & ba_i & rows(to_integer(unsigned(ba_i)));
                  cap(v_i * 4 + 1) <= "000000" & a_i(9 downto 0);
                  p_rd(0)          <= '1';
               end if;
            end if;
         elsif ras_n_i = '1' and cas_n_i = '0' and we_n_i = '0' then       -- WRITE
            if armed = '1' then
               n_wr <= n_wr + 1;
            end if;
         elsif ras_n_i = '0' and cas_n_i = '0' and we_n_i = '1' then       -- AUTO REFRESH
            if armed = '1' then
               n_ref <= n_ref + 1;
            end if;
         end if;

         -- the command was on the pins from edge t; this process saw it at t+1 (p_rd(0) set
         -- then), SDRAMC samples DQ at t+3: p_rd(1) at t+2 means dq_i at t+3 is the sampled word
         if p_rd(1) = '1' then
            cap(to_integer(n_cap(5 downto 0)) * 4 + 2) <= dq_i;
         end if;
         if p_rd(2) = '1' then
            cap(to_integer(n_cap(5 downto 0)) * 4 + 3) <= dq_i;
            n_cap <= n_cap + 1;
         end if;

         -- arm at the falling edge of the reset: clear everything
         if arm_s(2) = '1' and arm_s(1) = '0' then
            armed <= '1';
            n_rd  <= (others => '0');
            n_wr  <= (others => '0');
            n_act <= (others => '0');
            n_ref <= (others => '0');
            n_cap <= (others => '0');
            p_rd  <= (others => '0');
         end if;
      end if;
   end process p_probe;

   -- QNICE reads (asynchronous to clk_ram; a value that changes may read torn: read twice)
   win <= qnice_addr_i(27 downto 12);
   ofs <= unsigned(qnice_addr_i(11 downto 0));

   p_read : process (all)
   begin
      qnice_data_o <= x"0000";
      if win = x"0000" then
         if ofs >= 16#10# and ofs < 16#110# then
            qnice_data_o <= cap(to_integer(ofs - 16#10#));
         else
            case to_integer(ofs) is
               when 16#00# => qnice_data_o <= "0000000" & n_cap(6) & armed & status_i;
               when 16#01# => qnice_data_o <= std_logic_vector(n_rd(15 downto 0));
               when 16#02# => qnice_data_o <= std_logic_vector(n_rd(31 downto 16));
               when 16#03# => qnice_data_o <= std_logic_vector(n_wr(15 downto 0));
               when 16#04# => qnice_data_o <= std_logic_vector(n_wr(31 downto 16));
               when 16#05# => qnice_data_o <= std_logic_vector(n_act(15 downto 0));
               when 16#06# => qnice_data_o <= std_logic_vector(n_act(31 downto 16));
               when 16#07# => qnice_data_o <= std_logic_vector(n_ref(15 downto 0));
               when 16#08# => qnice_data_o <= std_logic_vector(n_ref(31 downto 16));
               when 16#09# => qnice_data_o <= x"00" & scan_i;
               when 16#0A# => qnice_data_o <= "000000000" & std_logic_vector(n_cap);
               when others => null;
            end case;
         end if;
      end if;
   end process p_read;

end architecture synthesis;
