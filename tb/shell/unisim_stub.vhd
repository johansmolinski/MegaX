-- MegaX: behavioural stand-ins for the few UNISIM primitives of the MEGA65 shell, so that ghdl
-- can analyse (and simulate) CORE/vhdl without Vivado's libraries. Analyse into library unisim.
-- MMCME2_ADV only has the ports; its clock outputs are driven by the testbench (sim) or stay
-- '0' (analysis).

library ieee;
use ieee.std_logic_1164.all;

package vcomponents is

   component BUFG is
      port (O : out std_logic; I : in std_logic);
   end component;

   component ODDR is
      generic (
         DDR_CLK_EDGE : string := "OPPOSITE_EDGE";
         INIT         : bit := '0';
         SRTYPE       : string := "SYNC"
      );
      port (
         Q  : out std_logic;
         C  : in  std_logic;
         CE : in  std_logic;
         D1 : in  std_logic;
         D2 : in  std_logic;
         R  : in  std_logic := '0';
         S  : in  std_logic := '0'
      );
   end component;

   component MMCME2_ADV is
      generic (
         BANDWIDTH            : string := "OPTIMIZED";
         CLKOUT4_CASCADE      : boolean := FALSE;
         COMPENSATION         : string := "ZHOLD";
         STARTUP_WAIT         : boolean := FALSE;
         CLKIN1_PERIOD        : real := 0.0;
         REF_JITTER1          : real := 0.0;
         DIVCLK_DIVIDE        : integer := 1;
         CLKFBOUT_MULT_F      : real := 5.0;
         CLKFBOUT_PHASE       : real := 0.0;
         CLKFBOUT_USE_FINE_PS : boolean := FALSE;
         CLKOUT0_DIVIDE_F     : real := 1.0;
         CLKOUT0_PHASE        : real := 0.0;
         CLKOUT0_DUTY_CYCLE   : real := 0.5;
         CLKOUT0_USE_FINE_PS  : boolean := FALSE;
         CLKOUT1_DIVIDE       : integer := 1;
         CLKOUT1_PHASE        : real := 0.0;
         CLKOUT1_DUTY_CYCLE   : real := 0.5;
         CLKOUT1_USE_FINE_PS  : boolean := FALSE;
         CLKOUT2_DIVIDE       : integer := 1;
         CLKOUT2_PHASE        : real := 0.0;
         CLKOUT2_DUTY_CYCLE   : real := 0.5;
         CLKOUT2_USE_FINE_PS  : boolean := FALSE
      );
      port (
         CLKFBOUT     : out std_logic;
         CLKFBOUTB    : out std_logic;
         CLKOUT0      : out std_logic;
         CLKOUT0B     : out std_logic;
         CLKOUT1      : out std_logic;
         CLKOUT1B     : out std_logic;
         CLKOUT2      : out std_logic;
         CLKOUT2B     : out std_logic;
         CLKOUT3      : out std_logic;
         CLKOUT3B     : out std_logic;
         CLKOUT4      : out std_logic;
         CLKOUT5      : out std_logic;
         CLKOUT6      : out std_logic;
         CLKFBIN      : in  std_logic;
         CLKIN1       : in  std_logic;
         CLKIN2       : in  std_logic;
         CLKINSEL     : in  std_logic;
         DADDR        : in  std_logic_vector(6 downto 0);
         DCLK         : in  std_logic;
         DEN          : in  std_logic;
         DI           : in  std_logic_vector(15 downto 0);
         DO           : out std_logic_vector(15 downto 0);
         DRDY         : out std_logic;
         DWE          : in  std_logic;
         PSCLK        : in  std_logic;
         PSEN         : in  std_logic;
         PSINCDEC     : in  std_logic;
         PSDONE       : out std_logic;
         LOCKED       : out std_logic;
         CLKINSTOPPED : out std_logic;
         CLKFBSTOPPED : out std_logic;
         PWRDWN       : in  std_logic;
         RST          : in  std_logic
      );
   end component;

end package vcomponents;

library ieee;
use ieee.std_logic_1164.all;

entity BUFG is
   port (O : out std_logic; I : in std_logic);
end entity;

architecture sim of BUFG is
begin
   O <= I;
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity ODDR is
   generic (
      DDR_CLK_EDGE : string := "OPPOSITE_EDGE";
      INIT         : bit := '0';
      SRTYPE       : string := "SYNC"
   );
   port (
      Q  : out std_logic;
      C  : in  std_logic;
      CE : in  std_logic;
      D1 : in  std_logic;
      D2 : in  std_logic;
      R  : in  std_logic := '0';
      S  : in  std_logic := '0'
   );
end entity;

architecture sim of ODDR is
begin
   process (C)
   begin
      if rising_edge(C) then
         Q <= D1;
      elsif falling_edge(C) then
         Q <= D2;
      end if;
   end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;

entity MMCME2_ADV is
   generic (
      BANDWIDTH            : string := "OPTIMIZED";
      CLKOUT4_CASCADE      : boolean := FALSE;
      COMPENSATION         : string := "ZHOLD";
      STARTUP_WAIT         : boolean := FALSE;
      CLKIN1_PERIOD        : real := 0.0;
      REF_JITTER1          : real := 0.0;
      DIVCLK_DIVIDE        : integer := 1;
      CLKFBOUT_MULT_F      : real := 5.0;
      CLKFBOUT_PHASE       : real := 0.0;
      CLKFBOUT_USE_FINE_PS : boolean := FALSE;
      CLKOUT0_DIVIDE_F     : real := 1.0;
      CLKOUT0_PHASE        : real := 0.0;
      CLKOUT0_DUTY_CYCLE   : real := 0.5;
      CLKOUT0_USE_FINE_PS  : boolean := FALSE;
      CLKOUT1_DIVIDE       : integer := 1;
      CLKOUT1_PHASE        : real := 0.0;
      CLKOUT1_DUTY_CYCLE   : real := 0.5;
      CLKOUT1_USE_FINE_PS  : boolean := FALSE;
      CLKOUT2_DIVIDE       : integer := 1;
      CLKOUT2_PHASE        : real := 0.0;
      CLKOUT2_DUTY_CYCLE   : real := 0.5;
      CLKOUT2_USE_FINE_PS  : boolean := FALSE
   );
   port (
      CLKFBOUT     : out std_logic := '0';
      CLKFBOUTB    : out std_logic := '0';
      CLKOUT0      : out std_logic := '0';
      CLKOUT0B     : out std_logic := '0';
      CLKOUT1      : out std_logic := '0';
      CLKOUT1B     : out std_logic := '0';
      CLKOUT2      : out std_logic := '0';
      CLKOUT2B     : out std_logic := '0';
      CLKOUT3      : out std_logic := '0';
      CLKOUT3B     : out std_logic := '0';
      CLKOUT4      : out std_logic := '0';
      CLKOUT5      : out std_logic := '0';
      CLKOUT6      : out std_logic := '0';
      CLKFBIN      : in  std_logic;
      CLKIN1       : in  std_logic;
      CLKIN2       : in  std_logic;
      CLKINSEL     : in  std_logic;
      DADDR        : in  std_logic_vector(6 downto 0);
      DCLK         : in  std_logic;
      DEN          : in  std_logic;
      DI           : in  std_logic_vector(15 downto 0);
      DO           : out std_logic_vector(15 downto 0) := (others => '0');
      DRDY         : out std_logic := '0';
      DWE          : in  std_logic;
      PSCLK        : in  std_logic;
      PSEN         : in  std_logic;
      PSINCDEC     : in  std_logic;
      PSDONE       : out std_logic := '0';
      LOCKED       : out std_logic := '1';
      CLKINSTOPPED : out std_logic := '0';
      CLKFBSTOPPED : out std_logic := '0';
      PWRDWN       : in  std_logic;
      RST          : in  std_logic
   );
end entity;

architecture sim of MMCME2_ADV is
begin
end architecture;
