----------------------------------------------------------------------------------
-- MegaX: x68_sd.vhd (disk images from the SD card through hps_io's sector interface) under
-- ghdl.
--
-- The QNICE side sets up slot 1 the way the firmware does: an extent map with two extents
-- (clusters 100..102 and 500..509), 4 sectors per cluster (SHIFT 2), BASE 1000, 52 sectors,
-- XDF, MODE last. An engine-port model plays the SD host: it is ready, and on START it reads
-- (RDWE strobes, the byte = f(block, index)) or writes (WRIDX, WRDATA one clock later) one
-- block, then DONE. A core model plays x68_system: sd_rd / sd_wr of slot 1 with sd_lba, drops
-- the request when sd_ack rises, takes the bytes on sd_buff_wr, gives its write data on
-- sd_buff_din (its buffer RAM: one clock after sd_buff_addr).
-- Checks: the mount pulse (slot 1, 52 x 512 bytes, XDF); reads of LBA 0, 5, 13 (second
-- extent) and 51 land on SD blocks 1400, 1405, 3013, 3061 with the right 512 bytes; a write
-- of LBA 9 reaches block 3001 with the core's bytes; LBA 52 (beyond the file) completes with
-- zeros and no SD transfer.
--
-- Run: tb/shell/run_sd.sh (on the Fedora host)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;

entity tb_sd is
end entity tb_sd;

architecture sim of tb_sd is

   signal done          : boolean := false;
   signal qclk          : std_logic := '0';
   signal sclk          : std_logic := '0';
   signal qrst          : std_logic := '1';
   signal srst          : std_logic := '1';

   signal q_slot        : std_logic_vector(2 downto 0) := "001";
   signal q_addr        : std_logic_vector(27 downto 0) := (others => '0');
   signal q_wdata       : std_logic_vector(15 downto 0) := (others => '0');
   signal q_rdata       : std_logic_vector(15 downto 0);
   signal q_ce          : std_logic := '0';
   signal q_we          : std_logic := '0';

   signal c2q           : std_logic_vector(75 downto 0);
   signal q2c           : std_logic_vector(63 downto 0) := (others => '0');

   signal img_mounted   : std_logic_vector(7 downto 0);
   signal img_readonly  : std_logic;
   signal img_size      : std_logic_vector(63 downto 0);
   signal img_xdf       : std_logic;
   signal sd_lba        : std_logic_vector(31 downto 0) := (others => '0');
   signal sd_rd         : std_logic_vector(7 downto 0) := (others => '0');
   signal sd_wr         : std_logic_vector(7 downto 0) := (others => '0');
   signal sd_ack        : std_logic_vector(7 downto 0);
   signal sd_buff_addr  : std_logic_vector(8 downto 0);
   signal sd_buff_dout  : std_logic_vector(7 downto 0);
   signal sd_buff_din   : std_logic_vector(7 downto 0) := (others => '0');
   signal sd_buff_wr    : std_logic;

   -- the engine model's record of the last transfer
   signal e_block       : unsigned(31 downto 0) := (others => '0');
   signal e_write       : std_logic := '0';
   signal e_count       : natural := 0;                    -- transfers
   type t_bytes is array (0 to 511) of std_logic_vector(7 downto 0);
   signal e_wbuf        : t_bytes;

   -- the core model
   signal c_rbuf        : t_bytes;
   signal c_nbytes      : natural := 0;
   signal mnt_seen      : natural := 0;
   signal mnt_ok        : boolean := false;

   function sd_byte(blk : unsigned(31 downto 0); i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((to_integer(blk(7 downto 0)) * 7 + i * 3 + i / 256) mod 256, 8));
   end function sd_byte;

   function core_byte(i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((i * 11 + 5) mod 256, 8));
   end function core_byte;

begin

   qclk <= not qclk after 10 ns when not done;       -- 50 MHz
   sclk <= not sclk after 12.5 ns when not done;     -- 40 MHz

   i_dut : entity work.x68_sd
      generic map (G_MS => 500)                       -- 10 us "milliseconds"
      port map (
         qnice_clk_i     => qclk,
         qnice_rst_i     => qrst,
         qnice_slot_i    => q_slot,
         qnice_addr_i    => q_addr,
         qnice_data_i    => q_wdata,
         qnice_data_o    => q_rdata,
         qnice_ce_i      => q_ce,
         qnice_we_i      => q_we,
         sd_c2q_o        => c2q,
         sd_q2c_i        => q2c,
         main_clk_i      => sclk,
         main_rst_i      => srst,
         img_mounted_o   => img_mounted,
         img_readonly_o  => img_readonly,
         img_size_o      => img_size,
         img_xdf_o       => img_xdf,
         sd_lba_i        => sd_lba,
         sd_rd_i         => sd_rd,
         sd_wr_i         => sd_wr,
         sd_ack_o        => sd_ack,
         sd_buff_addr_o  => sd_buff_addr,
         sd_buff_dout_o  => sd_buff_dout,
         sd_buff_din_i   => sd_buff_din,
         sd_buff_wr_o    => sd_buff_wr,
         main_busy_o     => open,
         main_present_o  => open
      );

   -- the SD host's engine port (QNICE clock)
   p_engine : process
      variable v_blk : unsigned(31 downto 0);
   begin
      q2c <= (others => '0');
      q2c(Q2C_READY) <= '1';
      loop
         wait until rising_edge(qclk) and c2q(C2Q_START) = '1';
         v_blk := unsigned(c2q(C2Q_ADDR));
         e_block <= v_blk;
         e_write <= c2q(C2Q_WRITE);
         q2c(Q2C_BUSY) <= '1';
         for i in 1 to 20 loop
            wait until rising_edge(qclk);
         end loop;
         if c2q(C2Q_WRITE) = '0' then
            for i in 0 to 511 loop
               q2c(Q2C_RDIDX)  <= std_logic_vector(to_unsigned(i, 9));
               q2c(Q2C_RDDATA) <= sd_byte(v_blk, i);
               q2c(Q2C_RDWE)   <= '1';
               wait until rising_edge(qclk);
               q2c(Q2C_RDWE)   <= '0';
               wait until rising_edge(qclk);
            end loop;
         else
            for i in 0 to 511 loop
               q2c(Q2C_WRIDX) <= std_logic_vector(to_unsigned(i, 9));
               wait until rising_edge(qclk);
               wait until rising_edge(qclk);
               e_wbuf(i) <= c2q(C2Q_WRDATA);
            end loop;
         end if;
         q2c(Q2C_BLK) <= '1';
         wait until rising_edge(qclk);
         q2c(Q2C_BLK)  <= '0';
         q2c(Q2C_BUSY) <= '0';
         q2c(Q2C_DONE) <= '1';
         wait until rising_edge(qclk);
         q2c(Q2C_DONE) <= '0';
         e_count <= e_count + 1;
      end loop;
   end process p_engine;

   -- the core's sector buffer: sd_buff_din one clock after sd_buff_addr; its writes
   p_corebuf : process (sclk)
   begin
      if rising_edge(sclk) then
         sd_buff_din <= core_byte(to_integer(unsigned(sd_buff_addr)));
         if sd_buff_wr = '1' then
            c_rbuf(to_integer(unsigned(sd_buff_addr))) <= sd_buff_dout;
            c_nbytes <= c_nbytes + 1;
         end if;
         if img_mounted /= x"00" then
            mnt_seen <= mnt_seen + 1;
            mnt_ok   <= img_mounted = x"02" and unsigned(img_size) = 52 * 512 and img_xdf = '1' and
                        img_readonly = '0';
         end if;
      end if;
   end process p_corebuf;

   p_main : process
      variable v_err : natural := 0;
      variable v_n0  : natural;

      procedure qwr(win : natural; ofs : natural; data : natural) is
      begin
         wait until rising_edge(qclk);
         q_addr  <= std_logic_vector(to_unsigned(win, 16)) & std_logic_vector(to_unsigned(ofs, 12));
         q_wdata <= std_logic_vector(to_unsigned(data, 16));
         q_ce    <= '1';
         q_we    <= '1';
         wait until rising_edge(qclk);
         q_ce    <= '0';
         q_we    <= '0';
      end procedure qwr;

      -- one request of the core; returns after sd_ack has dropped again
      procedure request(lba : natural; wr : boolean) is
      begin
         wait until rising_edge(sclk);
         sd_lba <= std_logic_vector(to_unsigned(lba, 32));
         if wr then
            sd_wr(1) <= '1';
         else
            sd_rd(1) <= '1';
         end if;
         wait until rising_edge(sclk) and sd_ack(1) = '1';
         sd_rd <= (others => '0');
         sd_wr <= (others => '0');
         wait until rising_edge(sclk) and sd_ack(1) = '0';
         for i in 1 to 100 loop
            wait until rising_edge(sclk);
         end loop;
      end procedure request;

      procedure check_read(lba : natural; blk : natural) is
         variable v_ok : boolean := true;
      begin
         v_n0 := c_nbytes;
         request(lba, false);
         if c_nbytes - v_n0 /= 512 then
            report "LBA " & integer'image(lba) & ": " & integer'image(c_nbytes - v_n0) & " bytes" severity error;
            v_err := v_err + 1;
         end if;
         if e_block /= blk or e_write /= '0' then
            report "LBA " & integer'image(lba) & ": SD block " & integer'image(to_integer(e_block)) &
                   ", want " & integer'image(blk) severity error;
            v_err := v_err + 1;
         end if;
         for i in 0 to 511 loop
            if c_rbuf(i) /= sd_byte(to_unsigned(blk, 32), i) then
               report "LBA " & integer'image(lba) & " byte " & integer'image(i) & ": " &
                      to_hstring(c_rbuf(i)) severity error;
               v_err := v_err + 1;
               exit;
            end if;
         end loop;
      end procedure check_read;

      variable v_cnt : natural;
   begin
      wait for 200 ns;
      wait until rising_edge(qclk);
      qrst <= '0';
      srst <= '0';
      wait for 1 us;

      -- slot 1: extent map (window 1), then the registers, MODE last
      qwr(1, 0, 2);                          -- two extents
      qwr(1, 1, 100); qwr(1, 2, 0); qwr(1, 3, 3);  qwr(1, 4, 0);
      qwr(1, 5, 500); qwr(1, 6, 0); qwr(1, 7, 10); qwr(1, 8, 0);
      qwr(0, 1, 52);  qwr(0, 2, 0);          -- SECTS
      qwr(0, 3, 1000); qwr(0, 4, 0);         -- BASE
      qwr(0, 5, 2);                          -- SHIFT
      qwr(0, 9, 52 * 512); qwr(0, 10, 0);    -- BYTES
      qwr(0, 0, 16#5#);                      -- MODE: on, card slot 0, XDF
      wait for 5 us;
      if mnt_seen /= 1 or not mnt_ok then
         report "mount: " & integer'image(mnt_seen) & " pulses, ok = " & boolean'image(mnt_ok) severity error;
         v_err := v_err + 1;
      end if;

      -- reads: cluster = LBA / 4; block = 1000 + 4 x (first + cluster - start of extent) + LBA mod 4
      check_read(0, 1000 + 4 * 100 + 0);     -- 1400
      check_read(5, 1000 + 4 * 101 + 1);     -- 1405
      check_read(13, 1000 + 4 * 500 + 1);    -- cluster 3 = second extent's first: 3001 + ...
      check_read(51, 1000 + 4 * 509 + 3);    -- the last sector: 3039
      -- a write
      request(9, true);
      if e_block /= 1000 + 4 * 102 + 1 or e_write /= '1' then
         report "write LBA 9: SD block " & integer'image(to_integer(e_block)) severity error;
         v_err := v_err + 1;
      end if;
      for i in 0 to 511 loop
         if e_wbuf(i) /= core_byte(i) then
            report "write byte " & integer'image(i) & ": " & to_hstring(e_wbuf(i)) &
                   ", want " & to_hstring(core_byte(i)) severity error;
            v_err := v_err + 1;
            exit;
         end if;
      end loop;
      -- beyond the file: completes, zeros, no SD transfer
      v_cnt := e_count;
      v_n0  := c_nbytes;
      request(52, false);
      if e_count /= v_cnt or c_nbytes - v_n0 /= 512 or c_rbuf(7) /= x"00" then
         report "LBA 52: SD transfers " & integer'image(e_count - v_cnt) & ", bytes " &
                integer'image(c_nbytes - v_n0) severity error;
         v_err := v_err + 1;
      end if;

      if v_err = 0 then
         report "tb_sd PASS: " & integer'image(e_count) & " SD transfers";
      else
         report "tb_sd FAIL: " & integer'image(v_err) & " errors" severity error;
      end if;
      done <= true;
      wait;
   end process p_main;

end architecture sim;
