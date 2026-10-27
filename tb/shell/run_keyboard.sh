#!/usr/bin/env bash
# MegaX: tb_keyboard (keyboard.vhd against the core's KBCONV) under ghdl. Prints the X68000 key
# codes and "tb_keyboard PASS" or the mismatches. On the Fedora host:
#   tools/remote/rsim.sh start <name> -C ../shell -f /dev/null    (or ssh and run it there)
set -euo pipefail
cd "$(dirname "$0")"
CORE=../../CORE
R=$CORE/X68000_MiSTerMEGA65/rtl
W=obj/kbd
rm -rf $W && mkdir -p $W/run/sim
# the init files are read from ../../X68000_MiSTerMEGA65/... (the Vivado run directory's view)
ln -sfn ../../$CORE/X68000_MiSTerMEGA65 $W/X68000_MiSTerMEGA65
python3 ps2if_sim.py $R/PS2IF.vhd $W/PS2IF_sim.vhd
python3 kbconv_sim.py $R/MFP/KBIF/KBCONV.vhd $W/KBCONV_sim.vhd
F="--std=08 -frelaxed -fsynopsys --workdir=$PWD/$W"
ghdl -i $F $R/mega65/x68k_rams.vhd $R/LIB/sftclk.vhd $R/LIB/PARGEN.vhd $W/PS2IF_sim.vhd $W/KBCONV_sim.vhd \
    $CORE/vhdl/keyboard.vhd tb_keyboard.vhd
ghdl -m $F -o $PWD/$W/tb_keyboard tb_keyboard 2>&1 | grep -v "^analyze\|^elaborate\|warning\|^ *[0-9]* |\|^ *|" || true
cd $W/run/sim
../../tb_keyboard --ieee-asserts=disable 2>&1 | grep -v "^\s*$"
