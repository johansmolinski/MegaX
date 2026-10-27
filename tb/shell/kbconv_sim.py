#!/usr/bin/env python3
"""Simulation copy of upstream's KBCONV.vhd for ghdl (tb/shell only).

KBWAIT_CMD has neither a reset nor an initial value: 0 in the FPGA (Vivado's flip-flop
INIT), 'U' in VHDL simulation, where it keeps the receiver enable (RXEN) unknown and every
make code is dropped until the 68000 sends a keyboard command 01001xxx. The copy gives it
the FPGA's power-up value.

  kbconv_sim.py <KBCONV.vhd> <out.vhd>
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "signal	KBWAIT_CMD	:std_logic;"
assert s.count(old) == 1, "KBCONV.vhd changed upstream: check KBWAIT_CMD"
open(dst, "w").write(s.replace(old, "signal	KBWAIT_CMD	:std_logic := '0';"))
