----------------------------------------------------------------------------------
-- MegaX - Sharp X68000 for MEGA65
--
-- x68_sd: disk images straight from the SD card, served to the core through MiSTer's hps_io
-- sector interface (x68_system's img_* / sd_*), for MiSTer's eight slots: 0, 1 the floppy
-- drives (XDF/DIM/HDM sector images or D88), 2 the SASI hard disk, 3 the SRAM image, 4..7 the
-- SxSI hard disks. After PC10-III's pc_fdd_sd.vhd (itself after Megamiga's adf_sd.vhd):
--
--   * the firmware hands over each image as Megamiga does: the extent map of the file
--     (FAT32$FILE_MAP format: word 0 = number of extents, then per extent first cluster lo/hi
--     and number of clusters lo/hi; here at most 127 extents per slot), the SD block of
--     cluster 0 (DEV_CLUSTER - (2 << SHIFT)), log2(sectors per cluster), the number of 512-byte
--     sectors, the file size and the card slot; MODE goes last. Every MODE write is a (re)mount:
--     the core gets img_mounted for the slot with img_size (0 = ejected), img_xdf and
--     img_readonly, as hps_io gives them on a MiSTer.
--   * the core asks for a block with sd_rd / sd_wr (bit n = slot n) and sd_lba; the request
--     crosses into the QNICE clock domain as a toggle with a payload that is stable while it
--     crosses (CORE.xdc bounds qnice <-> main), the answer comes back the same way.
--   * read: the LBA becomes an SD block through the extent map, the block lands in a 512-byte
--     dual-port buffer, then sd_ack rises, the 512 bytes go to the core (sd_buff_addr,
--     sd_buff_dout, a one-clock sd_buff_wr every fourth clock) and sd_ack drops.
--   * write: sd_ack rises, the core's 512 bytes are collected (sd_buff_addr, sd_buff_din two
--     clocks later), the block is written to the card, then sd_ack drops (write-through: when
--     the core sees the end, the block is on the SD card).
--   * a failed transfer is tried again G_RETRIES times, 1 ms apart; a controller that is not
--     ready (it re-initialises the card, or no card) is waited for up to G_READY_WAIT ms. A
--     transfer that ended without a block (QNICE preempted the engine port) is issued again.
--     The core has no error path in this interface (neither has hps_io): an error, a slot
--     without an image, an LBA beyond the file or a write to a write-protected image still
--     completes the handshake (a read then delivers zeros; a write is dropped) and is counted.
--
-- QNICE devices C_DEV_X68_DISK0..7 (qnice_slot_i selects which one is addressed; writes on the
-- falling edge like every M2M device, reads combinational):
--   window 0x0000  registers of the slot:
--     0x00 MODE    bit 0 = on, bit 1 = the card is in slot 1, bit 2 = XDF/DIM/HDM (img_xdf);
--                  written last: the (re)mount
--     0x01/0x02    SECTS  number of 512-byte sectors of the file (lo, hi)
--     0x03/0x04    BASE   SD block of cluster 0 (lo, hi)
--     0x05 SHIFT   log2(sectors per cluster)
--     0x06 WP      bit 0 = write protected (img_readonly at the next MODE write)
--     0x08 STATUS  (read) bit 0 = a transfer is running (any slot), bit 1 = the slot is on
--     0x09/0x0A    BYTES  the file size in bytes (lo, hi): img_size (SECTS rounds it up; a
--                  D88 image is not a whole number of sectors)
--     0x10..0x12   (read) blocks read, blocks written, failed requests (all slots, wrapping)
--   window 0x0001  the extent map of the slot (512 words: at most 127 extents)
--   window 0xFFFF  the M2M CRT/ROM load CSR (STATUS, file size; PARSEST answers "ready" as soon
--                  as STATUS is "ok": the firmware has set the slot up in PREP_LOAD_IMAGE)
--
-- done by Johan Smolinski in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.sdhost_pkg.all;

entity x68_sd is
   generic (
      G_RETRIES      : natural := 2;
      G_MS           : natural := 50_000;      -- QNICE clocks per millisecond
      G_READY_WAIT   : natural := 500          -- ms
   );
   port (
      -- QNICE clock domain
      qnice_clk_i     : in  std_logic;
      qnice_rst_i     : in  std_logic;
      qnice_slot_i    : in  std_logic_vector(2 downto 0);
      qnice_addr_i    : in  std_logic_vector(27 downto 0);
      qnice_data_i    : in  std_logic_vector(15 downto 0);
      qnice_data_o    : out std_logic_vector(15 downto 0);
      qnice_ce_i      : in  std_logic;
      qnice_we_i      : in  std_logic;

      -- SD host engine port (QNICE clock domain)
      sd_c2q_o        : out std_logic_vector(75 downto 0);
      sd_q2c_i        : in  std_logic_vector(63 downto 0);

      -- main clock domain (clk_sys): x68_system's hps_io interface
      main_clk_i      : in  std_logic;
      main_rst_i      : in  std_logic;
      img_mounted_o   : out std_logic_vector(7 downto 0);
      img_readonly_o  : out std_logic;
      img_size_o      : out std_logic_vector(63 downto 0);
      img_xdf_o       : out std_logic;
      sd_lba_i        : in  std_logic_vector(31 downto 0);
      sd_rd_i         : in  std_logic_vector(7 downto 0);
      sd_wr_i         : in  std_logic_vector(7 downto 0);
      sd_ack_o        : out std_logic_vector(7 downto 0);
      sd_buff_addr_o  : out std_logic_vector(8 downto 0);
      sd_buff_dout_o  : out std_logic_vector(7 downto 0);
      sd_buff_din_i   : in  std_logic_vector(7 downto 0);
      sd_buff_wr_o    : out std_logic;
      main_busy_o     : out std_logic;                       -- a transfer is running
      main_present_o  : out std_logic_vector(7 downto 0)     -- the slots that are on
   );
end entity x68_sd;

architecture synthesis of x68_sd is

   attribute async_reg : string;

   constant C_N : natural := 8;

   type t_u32 is array (0 to C_N - 1) of unsigned(31 downto 0);
   type t_u3  is array (0 to C_N - 1) of unsigned(2 downto 0);
   type t_csr is array (0 to C_N - 1) of std_logic_vector(3 downto 0);

   ------------------------------------------------------------------------------------------
   -- QNICE side: registers
   ------------------------------------------------------------------------------------------
   signal q_on        : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal q_slot1     : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal q_xdf       : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal q_wp        : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal q_gen       : std_logic_vector(C_N - 1 downto 0) := (others => '0');  -- toggles per MODE write
   signal q_sects     : t_u32 := (others => (others => '0'));
   signal q_bytes     : t_u32 := (others => (others => '0'));
   signal q_base      : t_u32 := (others => (others => '0'));
   signal q_shift     : t_u3  := (others => (others => '0'));
   signal q_csr       : t_csr := (others => (others => '0'));
   signal q_fs        : t_u32 := (others => (others => '0'));
   signal q_st_rd     : unsigned(15 downto 0) := (others => '0');
   signal q_st_wr     : unsigned(15 downto 0) := (others => '0');
   signal q_st_err    : unsigned(15 downto 0) := (others => '0');

   signal q_win       : std_logic_vector(15 downto 0);
   signal q_ofs       : std_logic_vector(11 downto 0);
   signal q_s         : natural range 0 to C_N - 1;
   signal q_map_we    : std_logic;
   signal q_map_q     : std_logic_vector(15 downto 0);

   ------------------------------------------------------------------------------------------
   -- QNICE side: the transfer engine
   ------------------------------------------------------------------------------------------
   type t_qstate is (Q_IDLE, Q_CHECK, Q_N0, Q_N1, Q_EA, Q_EB, Q_EC, Q_ED, Q_EE, Q_EF, Q_SD,
                     Q_RUN, Q_DELAY, Q_FINISH);
   signal qstate      : t_qstate := Q_IDLE;
   signal q_req_s     : std_logic_vector(2 downto 0) := "000";   -- sync of m_req_tgl, + last
   attribute async_reg of q_req_s : signal is "true";
   signal q_drv       : natural range 0 to C_N - 1 := 0;
   signal q_write     : std_logic := '0';
   signal q_lba       : unsigned(31 downto 0) := (others => '0');
   signal q_cluster   : unsigned(31 downto 0) := (others => '0');
   signal q_offs      : unsigned(31 downto 0) := (others => '0');
   signal q_next      : unsigned(31 downto 0) := (others => '0');  -- first file cluster after the extent
   signal q_n         : unsigned(6 downto 0) := (others => '0');   -- extents
   signal q_e         : unsigned(6 downto 0) := (others => '0');
   signal q_first     : unsigned(31 downto 0) := (others => '0');
   signal q_cnt       : unsigned(31 downto 0) := (others => '0');
   signal q_block     : unsigned(31 downto 0) := (others => '0');
   signal q_map_raddr : std_logic_vector(11 downto 0);
   signal q_map_rq    : std_logic_vector(15 downto 0);
   signal q_tries     : natural range 0 to G_RETRIES := 0;
   signal q_ms_cnt    : natural range 0 to G_MS - 1 := 0;
   signal q_ms        : natural range 0 to G_READY_WAIT := 0;
   signal q_blk_seen  : std_logic := '0';
   signal q_err       : std_logic := '0';
   signal q_done_tgl  : std_logic := '0';
   signal q_busy      : std_logic := '0';
   signal q_start     : std_logic := '0';
   signal q_err_out   : std_logic := '0';          -- read in the main domain after the toggle

   -- buffer port A (engine)
   signal q_buf_addr  : std_logic_vector(8 downto 0);
   signal q_buf_we    : std_logic;
   signal q_buf_q     : std_logic_vector(7 downto 0);

   ------------------------------------------------------------------------------------------
   -- main side
   ------------------------------------------------------------------------------------------
   type t_mstate is (M_IDLE, M_COLLECT, M_WAIT, M_STREAM, M_LOW);
   signal mstate      : t_mstate := M_IDLE;
   signal m_req_tgl   : std_logic := '0';
   signal m_slot      : natural range 0 to C_N - 1 := 0;
   signal m_write     : std_logic := '0';
   signal m_lba       : std_logic_vector(31 downto 0) := (others => '0');
   signal m_done_s    : std_logic_vector(2 downto 0) := "000";
   attribute async_reg of m_done_s : signal is "true";
   signal m_idx       : unsigned(9 downto 0) := (others => '0');
   signal m_phase     : unsigned(1 downto 0) := (others => '0');
   signal m_hold      : natural range 0 to 63 := 0;
   signal m_ack       : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal m_baddr     : std_logic_vector(8 downto 0) := (others => '0');
   signal m_bwr       : std_logic := '0';
   signal m_buf_addr  : std_logic_vector(8 downto 0);
   signal m_buf_we    : std_logic;
   signal m_buf_q     : std_logic_vector(7 downto 0);
   signal m_bdout     : std_logic_vector(7 downto 0) := (others => '0');

   -- mounts
   signal m_gen_s     : std_logic_vector(3 * C_N - 1 downto 0) := (others => '0');
   attribute async_reg of m_gen_s : signal is "true";
   signal m_mnt_pend  : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal m_mnt_wait  : natural range 0 to 31 := 0;
   signal m_mounted   : std_logic_vector(C_N - 1 downto 0) := (others => '0');
   signal m_size      : unsigned(31 downto 0) := (others => '0');
   signal m_mxdf      : std_logic := '0';
   signal m_mwp       : std_logic := '0';
   signal m_img       : std_logic_vector(C_N * 35 - 1 downto 0);    -- per slot: on, xdf, wp, bytes
   signal q_img       : std_logic_vector(C_N * 35 - 1 downto 0);

begin

   ------------------------------------------------------------------------------------------
   -- QNICE registers
   ------------------------------------------------------------------------------------------

   q_win <= qnice_addr_i(27 downto 12);
   q_ofs <= qnice_addr_i(11 downto 0);
   q_s   <= to_integer(unsigned(qnice_slot_i));

   p_qregs : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_ce_i = '1' and qnice_we_i = '1' then
            if q_win = x"0000" then
               case q_ofs is
                  when x"000" => q_on(q_s)    <= qnice_data_i(0);
                                 q_slot1(q_s) <= qnice_data_i(1);
                                 q_xdf(q_s)   <= qnice_data_i(2);
                                 q_gen(q_s)   <= not q_gen(q_s);
                  when x"001" => q_sects(q_s)(15 downto 0)  <= unsigned(qnice_data_i);
                  when x"002" => q_sects(q_s)(31 downto 16) <= unsigned(qnice_data_i);
                  when x"003" => q_base(q_s)(15 downto 0)   <= unsigned(qnice_data_i);
                  when x"004" => q_base(q_s)(31 downto 16)  <= unsigned(qnice_data_i);
                  when x"005" => q_shift(q_s) <= unsigned(qnice_data_i(2 downto 0));
                  when x"006" => q_wp(q_s)    <= qnice_data_i(0);
                  when x"009" => q_bytes(q_s)(15 downto 0)  <= unsigned(qnice_data_i);
                  when x"00A" => q_bytes(q_s)(31 downto 16) <= unsigned(qnice_data_i);
                  when others => null;
               end case;
            elsif q_win = x"FFFF" then
               case q_ofs is
                  when x"000" => q_csr(q_s) <= qnice_data_i(3 downto 0);
                  when x"001" => q_fs(q_s)(15 downto 0)  <= unsigned(qnice_data_i);
                  when x"002" => q_fs(q_s)(31 downto 16) <= unsigned(qnice_data_i);
                  when others => null;
               end case;
            end if;
         end if;
         if qnice_rst_i = '1' then
            q_csr <= (others => (others => '0'));
         end if;
      end if;
   end process p_qregs;

   p_qread : process (all)
   begin
      qnice_data_o <= x"EEEE";
      if q_win = x"0000" then
         case q_ofs is
            when x"000" => qnice_data_o <= x"000" & '0' & q_xdf(q_s) & q_slot1(q_s) & q_on(q_s);
            when x"001" => qnice_data_o <= std_logic_vector(q_sects(q_s)(15 downto 0));
            when x"002" => qnice_data_o <= std_logic_vector(q_sects(q_s)(31 downto 16));
            when x"003" => qnice_data_o <= std_logic_vector(q_base(q_s)(15 downto 0));
            when x"004" => qnice_data_o <= std_logic_vector(q_base(q_s)(31 downto 16));
            when x"005" => qnice_data_o <= x"000" & '0' & std_logic_vector(q_shift(q_s));
            when x"006" => qnice_data_o <= x"000" & "000" & q_wp(q_s);
            when x"008" => qnice_data_o <= x"000" & "00" & q_on(q_s) & q_busy;
            when x"009" => qnice_data_o <= std_logic_vector(q_bytes(q_s)(15 downto 0));
            when x"00A" => qnice_data_o <= std_logic_vector(q_bytes(q_s)(31 downto 16));
            when x"010" => qnice_data_o <= std_logic_vector(q_st_rd);
            when x"011" => qnice_data_o <= std_logic_vector(q_st_wr);
            when x"012" => qnice_data_o <= std_logic_vector(q_st_err);
            when others => qnice_data_o <= x"0000";
         end case;
      elsif q_win = x"0001" then
         qnice_data_o <= q_map_q;
      elsif q_win = x"FFFF" then
         qnice_data_o <= x"0000";
         case q_ofs is
            when x"000" => qnice_data_o <= x"000" & q_csr(q_s);
            when x"001" => qnice_data_o <= std_logic_vector(q_fs(q_s)(15 downto 0));
            when x"002" => qnice_data_o <= std_logic_vector(q_fs(q_s)(31 downto 16));
            when x"010" => if q_csr(q_s) = "0011" then         -- STATUS ok -> PARSEST ready
                              qnice_data_o <= x"0002";
                           end if;
            when others => null;
         end case;
      end if;
   end process p_qread;

   ------------------------------------------------------------------------------------------
   -- Extent maps: port A = QNICE (falling edge), port B = the engine (rising edge)
   ------------------------------------------------------------------------------------------

   q_map_we <= qnice_ce_i and qnice_we_i when q_win = x"0001" else '0';

   i_map : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 12,
         DATA_WIDTH        => 16,
         RAM_STYLE_SELECT  => "block",
         FALLING_A         => true
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => qnice_slot_i & q_ofs(8 downto 0),
         data_a            => qnice_data_i,
         wren_a            => q_map_we,
         q_a               => q_map_q,
         clock_b           => qnice_clk_i,
         address_b         => q_map_raddr,
         q_b               => q_map_rq
      ); -- i_map

   ------------------------------------------------------------------------------------------
   -- The transfer engine (QNICE clock, rising edge)
   ------------------------------------------------------------------------------------------

   -- extent map word address, combinational from the state: the word addressed in one state
   -- is at q_map_rq in the next one (Q_N0: count; Q_N1/Q_EF: first lo; Q_EA: first hi;
   -- Q_EB: clusters lo; Q_EC: clusters hi)
   p_maddr : process (all)
      variable v_w : unsigned(8 downto 0);
      variable v_b : unsigned(8 downto 0);
   begin
      v_b := resize(q_e & "00", 9);
      case qstate is
         when Q_N1 | Q_EF => v_w := v_b + 1;
         when Q_EA        => v_w := v_b + 2;
         when Q_EB        => v_w := v_b + 3;
         when Q_EC        => v_w := v_b + 4;
         when others      => v_w := (others => '0');
      end case;
      q_map_raddr <= std_logic_vector(to_unsigned(q_drv, 3)) & std_logic_vector(v_w);
   end process p_maddr;

   p_engine : process (qnice_clk_i)
      variable v_shift : natural range 0 to 7;
      variable v_end   : unsigned(31 downto 0);
   begin
      if rising_edge(qnice_clk_i) then
         q_start <= '0';
         q_req_s <= q_req_s(1 downto 0) & m_req_tgl;
         v_shift := to_integer(q_shift(q_drv));

         case qstate is
            when Q_IDLE =>
               q_busy <= '0';
               if q_req_s(2) /= q_req_s(1) then
                  q_busy  <= '1';
                  q_drv   <= m_slot;
                  q_write <= m_write;
                  q_lba   <= unsigned(m_lba);
                  q_tries <= 0;
                  q_err   <= '0';
                  q_ms    <= 0;
                  qstate  <= Q_CHECK;
               end if;

            when Q_CHECK =>
               q_cluster <= shift_right(q_lba, v_shift);
               q_offs    <= q_lba and (shift_left(to_unsigned(1, 32), v_shift) - 1);
               q_e       <= (others => '0');
               q_next    <= (others => '0');
               if q_on(q_drv) = '0' or q_lba >= q_sects(q_drv) or
                  (q_write = '1' and q_wp(q_drv) = '1') then
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               else
                  qstate <= Q_N0;
               end if;

            when Q_N0 =>                                    -- address word 0
               qstate <= Q_N1;

            when Q_N1 =>                                    -- the number of extents
               q_n <= unsigned(q_map_rq(6 downto 0));
               if unsigned(q_map_rq) = 0 or unsigned(q_map_rq) > 127 then
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               else
                  qstate <= Q_EA;
               end if;

            when Q_EA =>
               q_first(15 downto 0)  <= unsigned(q_map_rq);
               qstate <= Q_EB;

            when Q_EB =>
               q_first(31 downto 16) <= unsigned(q_map_rq);
               qstate <= Q_EC;

            when Q_EC =>
               q_cnt(15 downto 0)    <= unsigned(q_map_rq);
               qstate <= Q_ED;

            when Q_ED =>
               q_cnt(31 downto 16)   <= unsigned(q_map_rq);
               qstate <= Q_EE;

            when Q_EE =>
               v_end := q_next + q_cnt;
               if q_cluster < v_end then
                  q_block <= q_base(q_drv) + shift_left(q_first + q_cluster - q_next, v_shift) + q_offs;
                  qstate  <= Q_SD;
               elsif q_e + 1 = q_n then                     -- past the end of the map
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               else
                  q_next <= v_end;
                  q_e    <= q_e + 1;
                  qstate <= Q_EF;
               end if;

            when Q_EF =>                                    -- address the next extent
               qstate <= Q_EA;

            when Q_SD =>                                    -- wait for the controller
               q_blk_seen <= '0';
               if sd_q2c_i(Q2C_READY) = '1' and sd_q2c_i(Q2C_BUSY) = '0' then
                  q_start <= '1';
                  qstate  <= Q_RUN;
               elsif q_ms = G_READY_WAIT then
                  q_err  <= '1';
                  qstate <= Q_FINISH;
               elsif q_ms_cnt = G_MS - 1 then
                  q_ms_cnt <= 0;
                  q_ms     <= q_ms + 1;
               else
                  q_ms_cnt <= q_ms_cnt + 1;
               end if;

            when Q_RUN =>
               if sd_q2c_i(Q2C_BLK) = '1' then
                  q_blk_seen <= '1';
               end if;
               if q_start = '0' and sd_q2c_i(Q2C_DONE) = '1' then
                  if sd_q2c_i(Q2C_ERROR) = '1' then
                     if q_tries = G_RETRIES then
                        q_err  <= '1';
                        qstate <= Q_FINISH;
                     else
                        q_tries  <= q_tries + 1;
                        q_ms_cnt <= 0;
                        qstate   <= Q_DELAY;
                     end if;
                  elsif q_blk_seen = '0' and sd_q2c_i(Q2C_BLK) = '0' then
                     qstate <= Q_SD;                       -- preempted before the block
                  else
                     qstate <= Q_FINISH;
                  end if;
               end if;

            when Q_DELAY =>                                 -- 1 ms before a retry
               if q_ms_cnt = G_MS - 1 then
                  q_ms_cnt <= 0;
                  qstate   <= Q_SD;
               else
                  q_ms_cnt <= q_ms_cnt + 1;
               end if;

            when Q_FINISH =>
               if q_err = '1' then
                  q_st_err <= q_st_err + 1;
               elsif q_write = '1' then
                  q_st_wr <= q_st_wr + 1;
               else
                  q_st_rd <= q_st_rd + 1;
               end if;
               q_err_out  <= q_err;
               q_done_tgl <= not q_done_tgl;
               qstate     <= Q_IDLE;
         end case;

         if qnice_rst_i = '1' then
            qstate  <= Q_IDLE;
            q_busy  <= '0';
            q_start <= '0';
         end if;
      end if;
   end process p_engine;

   -- the engine port: request fields held for the whole transfer, START a pulse
   p_c2q : process (all)
   begin
      sd_c2q_o              <= (others => '0');
      sd_c2q_o(C2Q_START)   <= q_start;
      sd_c2q_o(C2Q_WRITE)   <= q_write;
      sd_c2q_o(C2Q_ADDR)    <= std_logic_vector(q_block);
      sd_c2q_o(C2Q_COUNT)   <= x"0001";
      sd_c2q_o(C2Q_LIMIT)   <= x"0001";
      sd_c2q_o(C2Q_WRDATA)  <= q_buf_q;
      sd_c2q_o(C2Q_SLOT)    <= q_slot1(q_drv);
   end process p_c2q;

   -- buffer port A: the controller's read strobes write it, its write address reads it (the
   -- byte is there one clock after the address, as sdhost expects)
   q_buf_addr <= sd_q2c_i(Q2C_RDIDX) when q_write = '0' else sd_q2c_i(Q2C_WRIDX);
   q_buf_we   <= sd_q2c_i(Q2C_RDWE) when q_write = '0' and qstate = Q_RUN else '0';

   i_buf : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH        => 9,
         DATA_WIDTH        => 8,
         RAM_STYLE_SELECT  => "block"
      )
      port map (
         clock_a           => qnice_clk_i,
         address_a         => q_buf_addr,
         data_a            => sd_q2c_i(Q2C_RDDATA),
         wren_a            => q_buf_we,
         q_a               => q_buf_q,
         clock_b           => main_clk_i,
         address_b         => m_buf_addr,
         data_b            => sd_buff_din_i,
         wren_b            => m_buf_we,
         q_b               => m_buf_q
      ); -- i_buf

   ------------------------------------------------------------------------------------------
   -- Mounts: the slots' set-up into the main domain (static while a toggle crosses), then one
   -- img_mounted pulse per MODE write, one slot at a time
   ------------------------------------------------------------------------------------------

   g_img : for s in 0 to C_N - 1 generate
      q_img(s * 35 + 34 downto s * 35) <= q_on(s) & q_xdf(s) & q_wp(s) & std_logic_vector(q_bytes(s));
   end generate g_img;

   i_cdc_img : entity work.cdc_stable
      generic map (
         G_DATA_SIZE    => C_N * 35,
         G_REGISTER_SRC => true
      )
      port map (
         src_clk_i   => qnice_clk_i,
         src_data_i  => q_img,
         dst_clk_i   => main_clk_i,
         dst_data_o  => m_img
      ); -- i_cdc_img

   g_present : for s in 0 to C_N - 1 generate
      main_present_o(s) <= m_img(s * 35 + 34);
   end generate g_present;

   p_mount : process (main_clk_i)
      variable v_s : natural range 0 to C_N - 1;
   begin
      if rising_edge(main_clk_i) then
         m_mounted <= (others => '0');
         for s in 0 to C_N - 1 loop
            m_gen_s(3 * s + 2 downto 3 * s) <= m_gen_s(3 * s + 1 downto 3 * s) & q_gen(s);
            if m_gen_s(3 * s + 2) /= m_gen_s(3 * s + 1) then
               m_mnt_pend(s) <= '1';
            end if;
         end loop;
         -- the set-up crosses in a few clocks (cdc_stable): wait 31 clocks after a toggle, then
         -- announce the lowest pending slot
         if m_mnt_pend = (m_mnt_pend'range => '0') then
            m_mnt_wait <= 31;
         elsif m_mnt_wait /= 0 then
            m_mnt_wait <= m_mnt_wait - 1;
         else
            v_s := 0;
            for s in C_N - 1 downto 0 loop
               if m_mnt_pend(s) = '1' then
                  v_s := s;
               end if;
            end loop;
            m_mnt_pend(v_s) <= '0';
            m_mounted(v_s)  <= '1';
            m_mxdf <= m_img(v_s * 35 + 33);
            m_mwp  <= m_img(v_s * 35 + 32);
            if m_img(v_s * 35 + 34) = '1' then
               m_size <= unsigned(m_img(v_s * 35 + 31 downto v_s * 35));
            else
               m_size <= (others => '0');
            end if;
            m_mnt_wait <= 31;
         end if;
         if main_rst_i = '1' then
            m_mnt_pend <= (others => '0');
            m_mounted  <= (others => '0');
         end if;
      end if;
   end process p_mount;

   img_mounted_o  <= m_mounted;
   img_size_o     <= std_logic_vector(resize(m_size, 64));
   img_xdf_o      <= m_mxdf;
   img_readonly_o <= m_mwp;

   ------------------------------------------------------------------------------------------
   -- Main side: the core's sector requests, one at a time (the lowest slot first)
   ------------------------------------------------------------------------------------------

   m_buf_addr <= m_baddr;
   -- write: the core's byte at sd_buff_addr is on sd_buff_din two clocks later
   m_buf_we   <= '1' when mstate = M_COLLECT and m_phase = 2 else '0';

   p_main : process (main_clk_i)
      variable v_req : std_logic_vector(C_N - 1 downto 0);
      variable v_s   : natural range 0 to C_N - 1;
   begin
      if rising_edge(main_clk_i) then
         m_done_s <= m_done_s(1 downto 0) & q_done_tgl;
         m_bwr    <= '0';

         case mstate is
            when M_IDLE =>
               m_idx   <= (others => '0');
               m_phase <= (others => '0');
               v_req   := sd_rd_i or sd_wr_i;
               if v_req /= (v_req'range => '0') then
                  v_s := 0;
                  for s in C_N - 1 downto 0 loop
                     if v_req(s) = '1' then
                        v_s := s;
                     end if;
                  end loop;
                  m_slot  <= v_s;
                  m_write <= sd_wr_i(v_s);
                  m_lba   <= sd_lba_i;
                  if sd_wr_i(v_s) = '1' then
                     m_ack(v_s) <= '1';                    -- the core's bytes first
                     m_baddr    <= (others => '0');
                     mstate     <= M_COLLECT;
                  else
                     m_req_tgl <= not m_req_tgl;
                     mstate    <= M_WAIT;
                  end if;
               end if;

            -- sd_buff_addr = m_idx at phase 0; the byte is on sd_buff_din at phase 2, written
            -- into the buffer then (m_buf_we); four clocks per byte
            when M_COLLECT =>
               m_baddr <= std_logic_vector(m_idx(8 downto 0));
               m_phase <= m_phase + 1;
               if m_phase = 3 then
                  if m_idx = 511 then
                     m_req_tgl <= not m_req_tgl;
                     mstate    <= M_WAIT;
                  end if;
                  m_idx <= m_idx + 1;
               end if;

            when M_WAIT =>
               m_idx   <= (others => '0');
               m_phase <= (others => '0');
               if m_done_s(2) /= m_done_s(1) then
                  if m_write = '1' then
                     m_ack  <= (others => '0');            -- the block is on the card
                     m_hold <= 40;
                     mstate <= M_LOW;
                  else
                     m_ack(m_slot) <= '1';
                     mstate        <= M_STREAM;
                  end if;
               end if;

            -- read, four clocks per byte: phase 0 addresses the buffer (m_baddr, also
            -- sd_buff_addr), its byte is in m_buf_q after the second clock; phase 2 puts it on
            -- sd_buff_dout with the one-clock sd_buff_wr strobe
            when M_STREAM =>
               m_phase <= m_phase + 1;
               if m_phase = 0 then
                  m_baddr <= std_logic_vector(m_idx(8 downto 0));
               elsif m_phase = 2 then
                  if q_err_out = '1' then
                     m_bdout <= (others => '0');
                  else
                     m_bdout <= m_buf_q;
                  end if;
                  m_bwr <= '1';
               elsif m_phase = 3 then
                  if m_idx = 511 then
                     m_hold <= 40;
                     mstate <= M_LOW;
                  end if;
                  m_idx <= m_idx + 1;
               end if;

            -- sd_ack drops; the core drops its request in reply
            when M_LOW =>
               m_ack <= (others => '0');
               if m_hold /= 0 then
                  m_hold <= m_hold - 1;
               else
                  mstate <= M_IDLE;
               end if;
         end case;

         if main_rst_i = '1' then
            mstate <= M_IDLE;
            m_ack  <= (others => '0');
            m_bwr  <= '0';
         end if;
      end if;
   end process p_main;

   sd_ack_o       <= m_ack;
   sd_buff_addr_o <= m_baddr;
   sd_buff_dout_o <= m_bdout;
   sd_buff_wr_o   <= m_bwr;
   main_busy_o    <= '0' when mstate = M_IDLE else '1';

end architecture synthesis;
