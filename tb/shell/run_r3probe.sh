#!/usr/bin/env bash
# MegaX: tb_r3probe (x68_r3probe.vhd, the R3 study's SDRAM probe and HyperRAM mirror) under
# ghdl. Prints the snapshot registers and "TB_R3PROBE: PASS" or the failed check.
set -euo pipefail
cd "$(dirname "$0")"
CORE=../../CORE
W=obj/r3probe
rm -rf $W && mkdir -p $W/xpm $W/work
F="--std=08 -frelaxed -fsynopsys"
ghdl -a $F --work=xpm --workdir=$W/xpm xpm_stub.vhd
L="-P$W/xpm --workdir=$W/work"
ghdl -a $F $L $CORE/vhdl/x68_r3probe.vhd tb_r3probe.vhd
ghdl -e $F $L tb_r3probe
ghdl -r $F $L tb_r3probe --ieee-asserts=disable 2>&1 | grep -v "^\s*$" | sed 's/.*(report note): //'
