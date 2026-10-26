#!/usr/bin/env python3
# MegaX simulation: writes the simulation copy of the core's SDRAM controller.
#
# ghdl's synthesis (VHDL -> Verilog for Verilator) cannot carry an inout port through
# the hierarchy: the SDRAM data bus SDRAMC -> memcont -> X68K_top comes out
# unconnected. The copy is upstream's SDRAMC.vhd with three mechanical edits:
#   1. the SDRAM chip model (sdram_chip.sv, a black box for ghdl) is instantiated
#      inside the controller, on its command outputs and its write data MDATA;
#   2. the read data register takes the model's output instead of the pin:
#      "rddat <= PMEMDAT when rising_edge(clk);" -> "... chip_q ...";
#   3. MDATA's default (others=>'Z') becomes (others=>'0'): ghdl's synthesis turns
#      the registered tristate into logic that loses later assignments (seen: the
#      second word of a write burst repeated the first). The model only uses MDATA
#      in write cycles; Vivado maps the original to a tristate I/O register.
# Everything else - the controller's logic and timing - is upstream's.
#
# usage: sdramc_sim.py <SDRAMC.vhd> <out.vhd>
import sys

def edit(text, old, new):
    if text.count(old) != 1:
        sys.exit('sdramc_sim.py: expected exactly one "%s" in SDRAMC.vhd' % old.strip())
    return text.replace(old, new)

def main(src, dst):
    text = open(src, encoding='latin-1').read().replace('\r\n', '\n')
    text = edit(text, 'architecture rtl of SDRAMC is\n', '''architecture rtl of SDRAMC is
-- MegaX simulation (tb/sim/sdramc_sim.py): the SDRAM chip model
component sdram_chip
port(
	clk   : in  std_logic;
	ras_n : in  std_logic;
	cas_n : in  std_logic;
	we_n  : in  std_logic;
	ba    : in  std_logic_vector(1 downto 0);
	a     : in  std_logic_vector(12 downto 0);
	dqm   : in  std_logic_vector(1 downto 0);
	dq_w  : in  std_logic_vector(15 downto 0);
	dq_r  : out std_logic_vector(15 downto 0)
);
end component;
signal chip_q : std_logic_vector(15 downto 0);
''')
    text = edit(text, '\tPMEMCKE   <= \'1\';\n', '''\t-- MegaX simulation: the chip on the controller's outputs (CS_N low, CKE high)
\tchip : sdram_chip port map(
\t\tclk   => clk,
\t\tras_n => COMMAND(2),
\t\tcas_n => COMMAND(1),
\t\twe_n  => COMMAND(0),
\t\tba    => BA,
\t\ta     => MADDR,
\t\tdqm   => MADDR(12 downto 11),
\t\tdq_w  => MDATA,
\t\tdq_r  => chip_q
\t);
\tPMEMCKE   <= '1';
''')
    text = edit(text, 'rddat     <= PMEMDAT when rising_edge(clk);',
                'rddat     <= chip_q when rising_edge(clk);   -- MegaX simulation: was PMEMDAT')
    text = edit(text, "\t\t\tMDATA <=(others=>'Z');\n",
                "\t\t\tMDATA <=(others=>'0');   -- MegaX simulation: was (others=>'Z')\n")
    open(dst, 'w').write(text)
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
