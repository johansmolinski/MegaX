----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- The text VRAM (512 KB) in block RAM, behind the core's unchanged
-- tvram_ddr.sv: this module answers that controller's MiSTer DDRAM_* requests
-- (Avalon-MM, 64-bit data, qword addresses) the way the DE10-Nano's DDR3 did.
--
-- One qword holds the same 16-pixel word of all four planes (plane p = lane p),
-- so the 64K x 64 RAM is exactly 512 KB: 128 RAMB36, byte write enables.
-- tvram_ddr.sv uses the window DDR_BASE (0x06000000) + 0x0000..0xFFFF; only the
-- low 16 address bits are decoded.
--
-- Protocol as tvram_ddr.sv drives it (the MiSTer DDR3 bridge's contract):
-- * a read is DDRAM_RD for one clock with DDRAM_BURSTCNT = 1, 32 or 64; it is
--   answered by BURSTCNT DDRAM_DOUT_READY pulses with consecutive qwords;
-- * a write is DDRAM_WE for one clock, BURSTCNT = 1, with byte enables;
-- * DDRAM_BUSY (waitrequest) is high while a read burst is being answered, so a
--   new command waits for it (tvram_ddr.sv never issues one meanwhile).
-- Latency: the first qword comes two clocks after DDRAM_RD, then one per clock
-- (the DDR3 needed tens of clocks; the controller waits on DOUT_READY only).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tvram_bram is
port (
   clk            : in  std_logic;
   ddram_burstcnt : in  std_logic_vector(7 downto 0);
   ddram_addr     : in  std_logic_vector(28 downto 0);
   ddram_din      : in  std_logic_vector(63 downto 0);
   ddram_be       : in  std_logic_vector(7 downto 0);
   ddram_rd       : in  std_logic;
   ddram_we       : in  std_logic;
   ddram_dout     : out std_logic_vector(63 downto 0);
   ddram_dout_rdy : out std_logic;
   ddram_busy     : out std_logic
);
end entity tvram_bram;

architecture synthesis of tvram_bram is

   type ram_t is array(0 to 65535) of std_logic_vector(63 downto 0);
   signal ram : ram_t;

   signal raddr    : unsigned(15 downto 0);
   signal remain   : unsigned(7 downto 0) := (others => '0');
   signal rd_issue : std_logic;
   signal rd_valid : std_logic := '0';

begin

   ddram_busy <= '1' when remain /= 0 else '0';
   rd_issue   <= '1' when remain /= 0 else '0';

   -- Command side: latch a read burst, step the read address once per clock.
   p_cmd : process(clk)
   begin
      if rising_edge(clk) then
         if remain /= 0 then
            raddr  <= raddr + 1;
            remain <= remain - 1;
         elsif ddram_rd = '1' then
            raddr  <= unsigned(ddram_addr(15 downto 0));
            remain <= unsigned(ddram_burstcnt);
         end if;
      end if;
   end process p_cmd;

   -- The RAM: one port, byte write enables, registered read.
   p_ram : process(clk)
   begin
      if rising_edge(clk) then
         if ddram_we = '1' and remain = 0 then
            for i in 0 to 7 loop
               if ddram_be(i) = '1' then
                  ram(to_integer(unsigned(ddram_addr(15 downto 0))))(i*8+7 downto i*8) <= ddram_din(i*8+7 downto i*8);
               end if;
            end loop;
         end if;
         ddram_dout <= ram(to_integer(raddr));
         rd_valid   <= rd_issue;
      end if;
   end process p_ram;

   ddram_dout_rdy <= rd_valid;

end architecture synthesis;
