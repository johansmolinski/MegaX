-- MegaX: a small dual-clock FIFO for x68_hrmem (the R3 memory path): first word fall through,
-- distributed RAM with an asynchronous read, Gray-coded pointers through two flip-flops each
-- way. Written out instead of xpm_fifo_async so that the same code runs in the ghdl/Verilator
-- simulation of x68_system (tb/sim). No reset: the pointers start at zero with the
-- configuration and are never cleared, so the two sides can never disagree after a reset of
-- one of them; x68_hrmem tags its words and throws stale ones away instead.
--
-- Counts: wr_free is the write side's view (it may be low by the words read in the last few
-- clocks), rd_count the read side's (low by the words written in the last few clocks): both
-- err on the safe side. The other side's pointer is converted from Gray code into a register
-- (one clock more of lag, a shorter path into the counts).
--
-- Constraints (CORE.xdc): the paths into the first synchroniser stages (afifo_*_s1; Vivado may
-- merge a Gray pointer bit with the binary pointer's, so they are named by their destination)
-- and from the RAM to the read side are crossings (set_max_delay -datapath_only).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity x68_afifo is
   generic (
      G_WIDTH : natural := 16;
      G_LOG2  : natural := 4                -- depth 2**G_LOG2
   );
   port (
      wr_clk_i   : in  std_logic;
      wr_en_i    : in  std_logic;
      wr_data_i  : in  std_logic_vector(G_WIDTH - 1 downto 0);
      wr_free_o  : out unsigned(G_LOG2 downto 0);
      rd_clk_i   : in  std_logic;
      rd_en_i    : in  std_logic;           -- pops the word on rd_data_o (only when rd_count > 0)
      rd_data_o  : out std_logic_vector(G_WIDTH - 1 downto 0);
      rd_count_o : out unsigned(G_LOG2 downto 0)
   );
end entity x68_afifo;

architecture rtl of x68_afifo is
   type t_ram is array (0 to 2**G_LOG2 - 1) of std_logic_vector(G_WIDTH - 1 downto 0);
   signal ram : t_ram;
   attribute ram_style : string;
   attribute ram_style of ram : signal is "distributed";

   subtype t_ptr is unsigned(G_LOG2 downto 0);
   signal w_bin, w_gray     : t_ptr := (others => '0');
   signal r_bin, r_gray     : t_ptr := (others => '0');
   signal afifo_w2r_s1, afifo_w2r_s2 : t_ptr := (others => '0');   -- w_gray into rd_clk
   signal afifo_r2w_s1, afifo_r2w_s2 : t_ptr := (others => '0');   -- r_gray into wr_clk
   signal w2r_bin, r2w_bin  : t_ptr := (others => '0');            -- the synchronised pointers, binary
   attribute ASYNC_REG : string;
   attribute ASYNC_REG of afifo_w2r_s1, afifo_w2r_s2, afifo_r2w_s1, afifo_r2w_s2 : signal is "TRUE";

   function to_gray(b : t_ptr) return t_ptr is
   begin
      return b xor shift_right(b, 1);
   end function;

   function from_gray(g : t_ptr) return t_ptr is
      variable b : t_ptr;
   begin
      b(G_LOG2) := g(G_LOG2);
      for i in G_LOG2 - 1 downto 0 loop
         b(i) := b(i + 1) xor g(i);
      end loop;
      return b;
   end function;
begin

   p_wr : process (wr_clk_i)
      variable nb : t_ptr;
   begin
      if rising_edge(wr_clk_i) then
         afifo_r2w_s1 <= r_gray;
         afifo_r2w_s2 <= afifo_r2w_s1;
         r2w_bin      <= from_gray(afifo_r2w_s2);
         if wr_en_i = '1' then
            ram(to_integer(w_bin(G_LOG2 - 1 downto 0))) <= wr_data_i;
            nb := w_bin + 1;
            w_bin  <= nb;
            w_gray <= to_gray(nb);
         end if;
      end if;
   end process p_wr;

   wr_free_o <= to_unsigned(2**G_LOG2, G_LOG2 + 1) - (w_bin - r2w_bin);

   p_rd : process (rd_clk_i)
      variable nb : t_ptr;
   begin
      if rising_edge(rd_clk_i) then
         afifo_w2r_s1 <= w_gray;
         afifo_w2r_s2 <= afifo_w2r_s1;
         w2r_bin      <= from_gray(afifo_w2r_s2);
         if rd_en_i = '1' then
            nb := r_bin + 1;
            r_bin  <= nb;
            r_gray <= to_gray(nb);
         end if;
      end if;
   end process p_rd;

   rd_count_o <= w2r_bin - r_bin;
   rd_data_o  <= ram(to_integer(r_bin(G_LOG2 - 1 downto 0)));

end architecture rtl;
