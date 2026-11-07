-- MegaX tb/hrmem (M2M=1): the framework's HyperRAM path as the board has it, for ghdl --synth:
-- avm_arbit_general (three slaves, the scaler first: framework.vhd) in front of the controller's
-- logic (hyperram.vhd without the PHY: hyperram_errata, hyperram_config, hyperram_ctrl). The PHY
-- and the chip are modelled at the controller's hb_* lines (avl_m2m.sv).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity m2m_hr is
   port (
      clk_i           : in  std_logic;
      rst_i           : in  std_logic;
      -- slave 0: QNICE, slave 1: the core, slave 2: the scaler (framework.vhd's order)
      s_write_i       : in  std_logic_vector(2 downto 0);
      s_read_i        : in  std_logic_vector(2 downto 0);
      s_address_i     : in  std_logic_vector(3*32-1 downto 0);
      s_writedata_i   : in  std_logic_vector(3*16-1 downto 0);
      s_byteenable_i  : in  std_logic_vector(3*2-1 downto 0);
      s_burstcount_i  : in  std_logic_vector(3*8-1 downto 0);
      s_readdata_o    : out std_logic_vector(3*16-1 downto 0);
      s_readdatavalid_o : out std_logic_vector(2 downto 0);
      s_waitrequest_o : out std_logic_vector(2 downto 0);
      hb_rstn_o       : out std_logic;
      hb_csn_o        : out std_logic;
      hb_ck_ddr_o     : out std_logic_vector(1 downto 0);
      hb_dq_ddr_in_i  : in  std_logic_vector(15 downto 0);
      hb_dq_ddr_out_o : out std_logic_vector(15 downto 0);
      hb_dq_oe_o      : out std_logic;
      hb_dq_ie_i      : in  std_logic;
      hb_rwds_ddr_out_o : out std_logic_vector(1 downto 0);
      hb_rwds_oe_o    : out std_logic;
      hb_rwds_in_i    : in  std_logic;
      hb_read_o       : out std_logic;
      chk_o           : out std_logic_vector(127 downto 0)   -- p_hr_chk: first & counts
   );
end entity m2m_hr;

architecture sim of m2m_hr is
   constant C_LATENCY : integer := 4;     -- hyperram.vhd
   signal a_write, a_read, a_rdv, a_wait : std_logic;
   signal a_addr : std_logic_vector(31 downto 0);
   signal a_wd, a_rd : std_logic_vector(15 downto 0);
   signal a_be : std_logic_vector(1 downto 0);
   signal a_bc : std_logic_vector(7 downto 0);
   signal e_write, e_read, e_rdv, e_wait : std_logic;
   signal e_addr : std_logic_vector(31 downto 0);
   signal e_wd, e_rd : std_logic_vector(15 downto 0);
   signal e_be : std_logic_vector(1 downto 0);
   signal e_bc : std_logic_vector(7 downto 0);
   signal c_write, c_read, c_rdv, c_wait : std_logic;
   signal c_addr : std_logic_vector(31 downto 0);
   signal c_wd, c_rd : std_logic_vector(15 downto 0);
   signal c_be : std_logic_vector(1 downto 0);
   signal c_bc : std_logic_vector(7 downto 0);
   -- framework.vhd's p_hr_chk (M2M-UPSTREAM hr-avm-check, temporary), the same code on this
   -- wrapper's names; avl_m2m.sv prints the counts at the end
   type t_chk_u8  is array (0 to 2) of unsigned(7 downto 0);
   type t_chk_u10 is array (0 to 2) of unsigned(9 downto 0);
   type t_chk_cnt is array (1 to 5) of unsigned(15 downto 0);
   signal chk_wleft              : t_chk_u8  := (others => (others => '0'));
   signal chk_rleft              : t_chk_u10 := (others => (others => '0'));
   signal chk_out_wleft          : unsigned(7 downto 0) := (others => '0');
   signal chk_cnt                : t_chk_cnt := (others => (others => '0'));
   signal chk_got                : std_logic := '0';
   signal chk_first              : std_logic_vector(47 downto 0) := (others => '0');
   signal chk_core_w             : unsigned(15 downto 0) := (others => '0');
   signal chk_flat : std_logic_vector(79 downto 0);

begin

   i_arbit : entity work.avm_arbit_general
      generic map (
         G_NUM_SLAVES    => 3,
         G_PRIORITY_HIGH => true,
         G_FREQ_HZ       => 100_000_000,
         G_ADDRESS_SIZE  => 32,
         G_DATA_SIZE     => 16
      )
      port map (
         clk_i                 => clk_i,
         rst_i                 => rst_i,
         s_avm_write_i         => s_write_i,
         s_avm_read_i          => s_read_i,
         s_avm_address_i       => s_address_i,
         s_avm_writedata_i     => s_writedata_i,
         s_avm_byteenable_i    => s_byteenable_i,
         s_avm_burstcount_i    => s_burstcount_i,
         s_avm_readdata_o      => s_readdata_o,
         s_avm_readdatavalid_o => s_readdatavalid_o,
         s_avm_waitrequest_o   => s_waitrequest_o,
         m_avm_write_o         => a_write,
         m_avm_read_o          => a_read,
         m_avm_address_o       => a_addr,
         m_avm_writedata_o     => a_wd,
         m_avm_byteenable_o    => a_be,
         m_avm_burstcount_o    => a_bc,
         m_avm_readdata_i      => a_rd,
         m_avm_readdatavalid_i => a_rdv,
         m_avm_waitrequest_i   => a_wait
      );

   i_errata : entity work.hyperram_errata
      port map (
         clk_i                 => clk_i,
         rst_i                 => rst_i,
         s_avm_waitrequest_o   => a_wait,
         s_avm_write_i         => a_write,
         s_avm_read_i          => a_read,
         s_avm_address_i       => a_addr,
         s_avm_writedata_i     => a_wd,
         s_avm_byteenable_i    => a_be,
         s_avm_burstcount_i    => a_bc,
         s_avm_readdata_o      => a_rd,
         s_avm_readdatavalid_o => a_rdv,
         m_avm_waitrequest_i   => e_wait,
         m_avm_write_o         => e_write,
         m_avm_read_o          => e_read,
         m_avm_address_o       => e_addr,
         m_avm_writedata_o     => e_wd,
         m_avm_byteenable_o    => e_be,
         m_avm_burstcount_o    => e_bc,
         m_avm_readdata_i      => e_rd,
         m_avm_readdatavalid_i => e_rdv
      );

   i_config : entity work.hyperram_config
      generic map (
         G_LATENCY => C_LATENCY
      )
      port map (
         clk_i                 => clk_i,
         rst_i                 => rst_i,
         s_avm_write_i         => e_write,
         s_avm_read_i          => e_read,
         s_avm_address_i       => e_addr,
         s_avm_writedata_i     => e_wd,
         s_avm_byteenable_i    => e_be,
         s_avm_burstcount_i    => e_bc,
         s_avm_readdata_o      => e_rd,
         s_avm_readdatavalid_o => e_rdv,
         s_avm_waitrequest_o   => e_wait,
         m_avm_write_o         => c_write,
         m_avm_read_o          => c_read,
         m_avm_address_o       => c_addr,
         m_avm_writedata_o     => c_wd,
         m_avm_byteenable_o    => c_be,
         m_avm_burstcount_o    => c_bc,
         m_avm_readdata_i      => c_rd,
         m_avm_readdatavalid_i => c_rdv,
         m_avm_waitrequest_i   => c_wait
      );

   i_ctrl : entity work.hyperram_ctrl
      generic map (
         G_LATENCY => C_LATENCY
      )
      port map (
         clk_i               => clk_i,
         rst_i               => rst_i,
         avm_write_i         => c_write,
         avm_read_i          => c_read,
         avm_address_i       => c_addr,
         avm_writedata_i     => c_wd,
         avm_byteenable_i    => c_be,
         avm_burstcount_i    => c_bc,
         avm_readdata_o      => c_rd,
         avm_readdatavalid_o => c_rdv,
         avm_waitrequest_o   => c_wait,
         count_long_o        => open,
         count_short_o       => open,
         hb_rstn_o           => hb_rstn_o,
         hb_csn_o            => hb_csn_o,
         hb_ck_ddr_o         => hb_ck_ddr_o,
         hb_dq_ddr_in_i      => hb_dq_ddr_in_i,
         hb_dq_ddr_out_o     => hb_dq_ddr_out_o,
         hb_dq_oe_o          => hb_dq_oe_o,
         hb_dq_ie_i          => hb_dq_ie_i,
         hb_rwds_ddr_out_o   => hb_rwds_ddr_out_o,
         hb_rwds_oe_o        => hb_rwds_oe_o,
         hb_rwds_in_i        => hb_rwds_in_i,
         hb_read_o           => hb_read_o
      );

   p_hr_chk : process (clk_i)
      variable v_w, v_r, v_wt, v_rdv : std_logic_vector(2 downto 0);
      variable v_a   : std_logic_vector(3*32-1 downto 0);
      variable v_b   : std_logic_vector(3*8-1 downto 0);
      variable v_cnt : t_chk_cnt;
      variable v_got : std_logic;
      variable v_rl  : unsigned(9 downto 0);

      procedure viol(k : natural; i : natural; j : natural) is
      begin
         if v_cnt(k) /= x"FFFF" then
            v_cnt(k) := v_cnt(k) + 1;
         end if;
         if v_got = '0' then
            v_got     := '1';
            if i < 3 then
               chk_first(47 downto 16) <= v_b(8*i+7 downto 8*i) & v_a(32*i+23 downto 32*i);
            else                                        -- 3: the arbiter's output
               chk_first(47 downto 16) <= a_bc & a_addr(23 downto 0);
            end if;
            chk_first(15 downto 0) <= std_logic_vector(to_unsigned(k, 8)) &
                                      std_logic_vector(to_unsigned(i, 4)) &
                                      std_logic_vector(to_unsigned(j, 4));
         end if;
      end procedure viol;
   begin
      if rising_edge(clk_i) then
         v_w   := s_write_i;
         v_r   := s_read_i;
         v_wt  := s_waitrequest_o;
         v_rdv := s_readdatavalid_o;
         v_a   := s_address_i;
         v_b   := s_burstcount_i;
         v_cnt := chk_cnt;
         v_got := chk_got;

         for i in 0 to 2 loop
            if v_w(i) = '1' and v_wt(i) = '0' then
               for j in 0 to 2 loop
                  if j /= i and chk_wleft(j) /= 0 then
                     viol(1, i, j);
                  end if;
                  if j /= i and chk_rleft(j) /= 0 then
                     viol(4, i, j);
                  end if;
               end loop;
               if chk_wleft(i) = 0 then
                  chk_wleft(i) <= unsigned(v_b(8*i+7 downto 8*i)) - 1;
                  if i = 1 then
                     chk_core_w <= chk_core_w + 1;
                  end if;
               else
                  chk_wleft(i) <= chk_wleft(i) - 1;
               end if;
            end if;

            v_rl := chk_rleft(i);
            if v_rdv(i) = '1' then
               if v_rl = 0 then
                  viol(2, i, i);
               else
                  v_rl := v_rl - 1;
               end if;
            end if;
            if v_r(i) = '1' and v_wt(i) = '0' then
               for j in 0 to 2 loop
                  if j /= i and chk_wleft(j) /= 0 then
                     viol(3, i, j);
                  end if;
               end loop;
               v_rl := v_rl + unsigned(v_b(8*i+7 downto 8*i));
            end if;
            chk_rleft(i) <= v_rl;
         end loop;

         if a_write = '1' and a_wait = '0' then
            if chk_out_wleft = 0 then
               chk_out_wleft <= unsigned(a_bc) - 1;
            else
               chk_out_wleft <= chk_out_wleft - 1;
            end if;
         end if;
         if a_read = '1' and a_wait = '0' and chk_out_wleft /= 0 then
            viol(5, 3, 3);
         end if;

         -- the controller drops a burst in flight at rst_i
         if rst_i = '1' then
            chk_wleft     <= (others => (others => '0'));
            chk_rleft     <= (others => (others => '0'));
            chk_out_wleft <= (others => '0');
         end if;

         chk_cnt <= v_cnt;
         chk_got <= v_got;
      end if;
   end process p_hr_chk;

   chk_flat <= std_logic_vector(chk_cnt(5)) & std_logic_vector(chk_cnt(4)) & std_logic_vector(chk_cnt(3)) &
               std_logic_vector(chk_cnt(2)) & std_logic_vector(chk_cnt(1));
   chk_o    <= chk_first & chk_flat;

end architecture sim;
