-- MegaX: behavioural stand-ins for the XPM macros of the MEGA65 shell (ghdl). Analyse into
-- library xpm. Only the generics and ports CORE/vhdl uses; xpm_fifo_async is a first-word-
-- fall-through FIFO without the reset-busy timing (wr/rd_rst_busy follow rst).

library ieee;
use ieee.std_logic_1164.all;

package vcomponents is

   component xpm_cdc_single is
      generic (
         DEST_SYNC_FF   : integer := 4;
         INIT_SYNC_FF   : integer := 0;
         SIM_ASSERT_CHK : integer := 0;
         SRC_INPUT_REG  : integer := 1
      );
      port (
         src_clk  : in  std_logic;
         src_in   : in  std_logic;
         dest_clk : in  std_logic;
         dest_out : out std_logic
      );
   end component;

   component xpm_cdc_async_rst is
      generic (
         DEST_SYNC_FF    : integer := 4;
         INIT_SYNC_FF    : integer := 0;
         RST_ACTIVE_HIGH : integer := 0
      );
      port (
         src_arst  : in  std_logic;
         dest_clk  : in  std_logic;
         dest_arst : out std_logic
      );
   end component;

   component xpm_fifo_async is
      generic (
         FIFO_MEMORY_TYPE  : string := "auto";
         FIFO_WRITE_DEPTH  : integer := 2048;
         WRITE_DATA_WIDTH  : integer := 32;
         READ_DATA_WIDTH   : integer := 32;
         READ_MODE         : string := "std";
         FIFO_READ_LATENCY : integer := 1;
         CDC_SYNC_STAGES   : integer := 2;
         RELATED_CLOCKS    : integer := 0;
         USE_ADV_FEATURES  : string := "0707";
         WAKEUP_TIME       : integer := 0
      );
      port (
         sleep         : in  std_logic;
         rst           : in  std_logic;
         wr_clk        : in  std_logic;
         wr_en         : in  std_logic;
         din           : in  std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
         full          : out std_logic;
         wr_rst_busy   : out std_logic;
         rd_clk        : in  std_logic;
         rd_en         : in  std_logic;
         dout          : out std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
         empty         : out std_logic;
         rd_rst_busy   : out std_logic;
         injectsbiterr : in  std_logic;
         injectdbiterr : in  std_logic
      );
   end component;

end package vcomponents;

library ieee;
use ieee.std_logic_1164.all;

entity xpm_cdc_single is
   generic (
      DEST_SYNC_FF   : integer := 4;
      INIT_SYNC_FF   : integer := 0;
      SIM_ASSERT_CHK : integer := 0;
      SRC_INPUT_REG  : integer := 1
   );
   port (
      src_clk  : in  std_logic;
      src_in   : in  std_logic;
      dest_clk : in  std_logic;
      dest_out : out std_logic
   );
end entity;

architecture sim of xpm_cdc_single is
   signal sr : std_logic_vector(DEST_SYNC_FF - 1 downto 0) := (others => '0');
begin
   sr <= sr(DEST_SYNC_FF - 2 downto 0) & src_in when rising_edge(dest_clk);
   dest_out <= sr(DEST_SYNC_FF - 1);
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity xpm_cdc_async_rst is
   generic (
      DEST_SYNC_FF    : integer := 4;
      INIT_SYNC_FF    : integer := 0;
      RST_ACTIVE_HIGH : integer := 0
   );
   port (
      src_arst  : in  std_logic;
      dest_clk  : in  std_logic;
      dest_arst : out std_logic
   );
end entity;

architecture sim of xpm_cdc_async_rst is
   signal sr : std_logic_vector(DEST_SYNC_FF - 1 downto 0) := (others => '1');
begin
   process (dest_clk, src_arst)
   begin
      if src_arst = '1' then
         sr <= (others => '1');
      elsif rising_edge(dest_clk) then
         sr <= sr(DEST_SYNC_FF - 2 downto 0) & '0';
      end if;
   end process;
   dest_arst <= sr(DEST_SYNC_FF - 1);
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity xpm_fifo_async is
   generic (
      FIFO_MEMORY_TYPE  : string := "auto";
      FIFO_WRITE_DEPTH  : integer := 2048;
      WRITE_DATA_WIDTH  : integer := 32;
      READ_DATA_WIDTH   : integer := 32;
      READ_MODE         : string := "std";
      FIFO_READ_LATENCY : integer := 1;
      CDC_SYNC_STAGES   : integer := 2;
      RELATED_CLOCKS    : integer := 0;
      USE_ADV_FEATURES  : string := "0707";
      WAKEUP_TIME       : integer := 0
   );
   port (
      sleep         : in  std_logic;
      rst           : in  std_logic;
      wr_clk        : in  std_logic;
      wr_en         : in  std_logic;
      din           : in  std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
      full          : out std_logic;
      wr_rst_busy   : out std_logic;
      rd_clk        : in  std_logic;
      rd_en         : in  std_logic;
      dout          : out std_logic_vector(READ_DATA_WIDTH - 1 downto 0);
      empty         : out std_logic;
      rd_rst_busy   : out std_logic;
      injectsbiterr : in  std_logic;
      injectdbiterr : in  std_logic
   );
end entity;

architecture sim of xpm_fifo_async is
   type t_mem is array (0 to FIFO_WRITE_DEPTH - 1) of std_logic_vector(WRITE_DATA_WIDTH - 1 downto 0);
   signal mem   : t_mem;
   signal wptr  : natural range 0 to FIFO_WRITE_DEPTH - 1 := 0;
   signal rptr  : natural range 0 to FIFO_WRITE_DEPTH - 1 := 0;
   signal count : integer := 0;      -- shared bookkeeping (behavioural: no real CDC)
   signal wcnt  : integer := 0;
   signal rcnt  : integer := 0;
begin
   count <= wcnt - rcnt;

   process (wr_clk)
   begin
      if rising_edge(wr_clk) then
         if rst = '1' then
            wptr <= 0;
            wcnt <= rcnt;
         elsif wr_en = '1' and count < FIFO_WRITE_DEPTH then
            mem(wptr) <= din;
            wptr <= (wptr + 1) mod FIFO_WRITE_DEPTH;
            wcnt <= wcnt + 1;
         end if;
      end if;
   end process;

   process (rd_clk)
   begin
      if rising_edge(rd_clk) then
         if rst = '1' then
            rptr <= wptr;
         elsif rd_en = '1' and count > 0 then
            rptr <= (rptr + 1) mod FIFO_WRITE_DEPTH;
            rcnt <= rcnt + 1;
         end if;
      end if;
   end process;

   full        <= '1' when count >= FIFO_WRITE_DEPTH else '0';
   empty       <= '1' when count <= 0 else '0';
   dout        <= mem(rptr);
   wr_rst_busy <= rst;
   rd_rst_busy <= rst;
end architecture;
