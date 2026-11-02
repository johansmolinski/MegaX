#!/usr/bin/env python3
"""Simulation copy of upstream's MOUSECONV.vhd for ghdl (tb/shell only).

valX/valY and the sign and button bits are not reset (the FPGA's power-up value 0); in VHDL
they start as 'U' and the first packet would be unknown. The copy gives them the initial 0.

  mouseconv_sim.py <MOUSECONV.vhd> <out.vhd>
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline='').read()
for old, new in [("signal\tvalX,valY\t:std_logic_vector(9 downto 0);",
                  "signal\tvalX,valY\t:std_logic_vector(9 downto 0) := (others => '0');"),
                 ("signal\tmsbX,msbY\t:std_logic;", "signal\tmsbX,msbY\t:std_logic := '0';"),
                 ("signal\tsw0,sw1\t\t:std_logic;", "signal\tsw0,sw1\t\t:std_logic := '0';")]:
    assert s.count(old) == 1, old
    s = s.replace(old, new)
open(dst, 'w', newline='').write(s)
