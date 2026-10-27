----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- Boot ROM loader: /megax/boot.rom (MiSTer's boot.rom: CGROM 768 KB, 128 KB of zeros, IPL
-- 128 KB, the image of F00000-FFFFFF; Sharp's, loaded from the SD card, AGENTS.md rule 4) from
-- the Shell's ROM auto-loader to the X68000's loader port (x68_system boot_*), which writes it
-- into the SDRAM. The MiSTer's ioctl download, byte for byte: the core starts its power-on
-- sequence with the first byte (boot_active rises) and holds the 68000 until the load has ended
-- (boot_active falls).
--
-- QNICE device C_DEV_X68_BOOT (globals.vhd), qnice_clk domain:
--   windows 0x0000..0x00FF  the image, byte i of the file at window i/4096, offset i mod 4096
--                           (the Shell writes the file from offset 0, one byte per address);
--                           each byte crosses to clk_sys through a FIFO, qnice_wait_o holds the
--                           Shell while the FIFO is full
--   window  0x1000          control registers:
--     offset 0 (R)   size bits 15..0: one more than the highest image byte written
--     offset 1 (R)   size bits 20..16 (a complete image has size 0x10_0000)
--     offset 2 (W)   bit 0 = 1: end the load (the firmware's PREP_START, after checking the
--                    size): once the FIFO is empty the device drops boot_active, the core
--                    sets ldr_done and lets the 68000 run
--             (R)    bit 0: end requested, bit 1: the load has ended (clk_sys side)
--     offset 3 (R)   bit 0: a write went to a window 0x0100..0x0FFF (the file is > 1 MB)
-- Writes to window 0xFFFF (the Shell's CRT/ROM load CSR) are ignored; reads of the image
-- windows return 0.
--
-- clk_sys side: boot_active rises with the first byte in the FIFO, the first strobe follows
-- 1024 clocks later (on the MiSTer the download starts before its first write, too). Then one
-- byte at a time: boot_wr is a one-clock strobe; x68_system answers with
-- boot_wait (its ldr_wr) from the next clock until the core has taken the byte, and boot_addr /
-- boot_data stay put until the next strobe. After a strobe the next one waits two clocks, so
-- that boot_wait has risen.
--
-- done by Johan Smolinski in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity x68_boot is
   port (
      -- QNICE clock domain
      qnice_clk_i     : in  std_logic;
      qnice_rst_i     : in  std_logic;
      qnice_addr_i    : in  std_logic_vector(27 downto 0);
      qnice_data_i    : in  std_logic_vector(15 downto 0);
      qnice_data_o    : out std_logic_vector(15 downto 0);
      qnice_ce_i      : in  std_logic;
      qnice_we_i      : in  std_logic;
      qnice_wait_o    : out std_logic;

      -- clk_sys domain (x68_system's loader port)
      clk_sys_i       : in  std_logic;
      rst_sys_i       : in  std_logic;     -- clocks not ready (clk.vhd)
      boot_active_o   : out std_logic;
      boot_addr_o     : out std_logic_vector(19 downto 0);
      boot_data_o     : out std_logic_vector(7 downto 0);
      boot_wr_o       : out std_logic;
      boot_wait_i     : in  std_logic;
      boot_ended_o    : out std_logic      -- the load has ended (the core has the whole ROM)
   );
end entity x68_boot;

architecture synthesis of x68_boot is

   constant C_WIN_CTRL    : std_logic_vector(15 downto 0) := x"1000";

   signal qnice_win       : std_logic_vector(15 downto 0);
   signal qnice_img       : std_logic;
   signal qnice_ctrl      : std_logic;

   signal qnice_size      : unsigned(20 downto 0) := (others => '0');
   signal qnice_end       : std_logic := '0';
   signal qnice_ovfl      : std_logic := '0';
   signal qnice_ended     : std_logic;

   -- FIFO: {address 19..0, data 7..0}
   signal q_wr_en         : std_logic := '0';
   signal q_din           : std_logic_vector(27 downto 0);
   signal q_full          : std_logic;
   signal q_wr_rst_busy   : std_logic;

   signal s_rd_en         : std_logic;
   signal s_dout          : std_logic_vector(27 downto 0);
   signal s_empty         : std_logic;
   signal s_rd_rst_busy   : std_logic;

   signal s_end           : std_logic;
   signal s_active        : std_logic := '0';
   signal s_ended         : std_logic := '0';
   signal s_addr          : std_logic_vector(19 downto 0) := (others => '0');
   signal s_data          : std_logic_vector(7 downto 0) := (others => '0');
   signal s_wr            : std_logic := '0';
   signal s_holdoff       : natural range 0 to 1023 := 0;

begin

   ---------------------------------------------------------------------------------------------
   -- QNICE side. QNICE writes device registers on the falling clock edge (M2M convention); the
   -- FIFO takes q_wr_en on the following rising edge.
   ---------------------------------------------------------------------------------------------

   qnice_win    <= qnice_addr_i(27 downto 12);
   qnice_img    <= '1' when qnice_win(15 downto 8) = x"00" else '0';
   qnice_ctrl   <= '1' when qnice_win = C_WIN_CTRL else '0';
   qnice_wait_o <= qnice_ce_i and qnice_we_i and qnice_img and (q_full or q_wr_rst_busy);

   p_regs : process (qnice_clk_i)
      variable v_end : unsigned(20 downto 0);
   begin
      if falling_edge(qnice_clk_i) then
         q_wr_en <= '0';
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if qnice_img = '1' then
               if q_full = '0' and q_wr_rst_busy = '0' then
                  q_din   <= qnice_win(7 downto 0) & qnice_addr_i(11 downto 0) & qnice_data_i(7 downto 0);
                  q_wr_en <= '1';
                  v_end   := unsigned(qnice_win(8 downto 0) & qnice_addr_i(11 downto 0)) + 1;
                  if v_end > qnice_size then
                     qnice_size <= v_end;
                  end if;
               end if;
            elsif qnice_ctrl = '1' then
               if qnice_addr_i(11 downto 0) = x"002" then
                  qnice_end <= qnice_data_i(0);
               end if;
            elsif qnice_win /= x"FFFF" then
               qnice_ovfl <= '1';
            end if;
         end if;
         if qnice_rst_i = '1' then
            qnice_size <= (others => '0');
            qnice_end  <= '0';
            qnice_ovfl <= '0';
         end if;
      end if;
   end process p_regs;

   p_read : process (all)
   begin
      qnice_data_o <= x"0000";
      if qnice_ctrl = '1' then
         case qnice_addr_i(11 downto 0) is
            when x"000" => qnice_data_o <= std_logic_vector(qnice_size(15 downto 0));
            when x"001" => qnice_data_o <= "00000000000" & std_logic_vector(qnice_size(20 downto 16));
            when x"002" => qnice_data_o <= "00000000000000" & qnice_ended & qnice_end;
            when x"003" => qnice_data_o <= "000000000000000" & qnice_ovfl;
            when others => null;
         end case;
      end if;
   end process p_read;

   i_fifo : xpm_fifo_async
      generic map (
         FIFO_MEMORY_TYPE    => "distributed",
         FIFO_WRITE_DEPTH    => 16,
         WRITE_DATA_WIDTH    => 28,
         READ_DATA_WIDTH     => 28,
         READ_MODE           => "fwft",
         FIFO_READ_LATENCY   => 0,
         CDC_SYNC_STAGES     => 2,
         RELATED_CLOCKS      => 0,
         USE_ADV_FEATURES    => "0000",
         WAKEUP_TIME         => 0
      )
      port map (
         sleep         => '0',
         rst           => qnice_rst_i,
         wr_clk        => qnice_clk_i,
         wr_en         => q_wr_en,
         din           => q_din,
         full          => q_full,
         wr_rst_busy   => q_wr_rst_busy,
         rd_clk        => clk_sys_i,
         rd_en         => s_rd_en,
         dout          => s_dout,
         empty         => s_empty,
         rd_rst_busy   => s_rd_rst_busy,
         injectsbiterr => '0',
         injectdbiterr => '0'
      ); -- i_fifo

   i_cdc_end : xpm_cdc_single
      generic map (
         DEST_SYNC_FF   => 3,
         SRC_INPUT_REG  => 0
      )
      port map (
         src_clk  => '0',
         src_in   => qnice_end,
         dest_clk => clk_sys_i,
         dest_out => s_end
      ); -- i_cdc_end

   i_cdc_ended : xpm_cdc_single
      generic map (
         DEST_SYNC_FF   => 3,
         SRC_INPUT_REG  => 0
      )
      port map (
         src_clk  => '0',
         src_in   => s_ended,
         dest_clk => qnice_clk_i,
         dest_out => qnice_ended
      ); -- i_cdc_ended

   ---------------------------------------------------------------------------------------------
   -- clk_sys side
   ---------------------------------------------------------------------------------------------

   s_rd_en <= '1' when s_empty = '0' and s_rd_rst_busy = '0' and s_holdoff = 0 and
                       boot_wait_i = '0' and s_active = '1' and s_ended = '0' else '0';

   p_sys : process (clk_sys_i)
   begin
      if rising_edge(clk_sys_i) then
         s_wr <= '0';
         if s_holdoff /= 0 then
            s_holdoff <= s_holdoff - 1;
         end if;
         if s_active = '0' and s_ended = '0' and s_empty = '0' and s_rd_rst_busy = '0' then
            s_active  <= '1';
            s_holdoff <= 1023;
         end if;
         if s_rd_en = '1' then
            s_addr    <= s_dout(27 downto 8);
            s_data    <= s_dout(7 downto 0);
            s_wr      <= '1';
            s_holdoff <= 2;
         end if;
         -- the end: requested, every byte taken (FIFO empty, the last one acknowledged)
         if s_active = '1' and s_end = '1' and s_empty = '1' and s_holdoff = 0 and
            s_wr = '0' and boot_wait_i = '0' then
            s_active <= '0';
            s_ended  <= '1';
         end if;
         if rst_sys_i = '1' then
            s_active  <= '0';
            s_ended   <= '0';
            s_wr      <= '0';
            s_holdoff <= 0;
         end if;
      end if;
   end process p_sys;

   boot_active_o <= s_active;
   boot_addr_o   <= s_addr;
   boot_data_o   <= s_data;
   boot_wr_o     <= s_wr;
   boot_ended_o  <= s_ended;

end architecture synthesis;
