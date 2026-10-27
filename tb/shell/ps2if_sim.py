#!/usr/bin/env python3
"""Simulation copy of upstream's PS2IF.vhd for ghdl (tb/shell only).

In ST_WRSTART1 the controller decrements TIMECNT before it tests it for 0, so the counter
(integer range 0 to BITCNT) goes to -1 once; synthesis wraps the bits and leaves the state
(the value is not used again), ghdl stops with a bound check failure. The copy only
decrements while the counter is not 0: the same state sequence and timing.

  ps2if_sim.py <PS2IF.vhd> <out.vhd>
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = """				elsif(STATE=ST_WRSTART1)then
					if(SFT='1')then
						TIMECNT<=TIMECNT-1;"""
new = """				elsif(STATE=ST_WRSTART1)then
					if(SFT='1')then
						if(TIMECNT/=0)then TIMECNT<=TIMECNT-1; end if;"""
assert s.count(old) == 1, "PS2IF.vhd changed upstream: check ST_WRSTART1"
open(dst, "w").write(s.replace(old, new))
