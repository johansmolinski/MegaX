#!/usr/bin/env bash
# MegaX: tb_mouse (mouse.vhd against the core's MOUSECONV) under ghdl. Prints the SCC bytes and
# "tb_mouse PASS" or the mismatches.
set -euo pipefail
cd "$(dirname "$0")"
CORE=../../CORE
R=$CORE/X68000_MiSTerMEGA65/rtl
W=obj/mouse
rm -rf $W && mkdir -p $W
python3 ps2if_sim.py $R/PS2IF.vhd $W/PS2IF_sim.vhd
python3 mouseconv_sim.py $R/SCC/MOUSEIF/MOUSECONV.vhd $W/MOUSECONV_sim.vhd
F="--std=08 -frelaxed -fsynopsys --workdir=$PWD/$W"
ghdl -i $F $R/LIB/sftclk.vhd $R/LIB/PARGEN.vhd $W/PS2IF_sim.vhd $W/MOUSECONV_sim.vhd \
    $CORE/vhdl/mouse.vhd tb_mouse.vhd
ghdl -m $F tb_mouse 2>&1 | grep -v "^analyze\|^elaborate\|warning\|^ *[0-9]* |\|^ *|" || true
ghdl -r $F tb_mouse --ieee-asserts=disable 2>&1 | grep -v "^\s*$"
