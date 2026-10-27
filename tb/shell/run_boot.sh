#!/usr/bin/env bash
# MegaX: tb_boot (x68_boot.vhd, the boot ROM loader device) under ghdl with xpm_stub.vhd.
# Prints "tb_boot PASS" or the mismatches. On the Fedora host.
set -euo pipefail
cd "$(dirname "$0")"
W=obj/boot
rm -rf $W && mkdir -p $W/xpm $W/work
F="--std=08 -frelaxed -fsynopsys"
ghdl -a $F --work=xpm --workdir=$W/xpm xpm_stub.vhd
L="-P$W/xpm --workdir=$W/work"
ghdl -i $F $L ../../CORE/vhdl/x68_boot.vhd tb_boot.vhd
ghdl -m $F $L -o $W/tb_boot tb_boot 2>&1 | grep -v "^analyze\|^elaborate" || true
$W/tb_boot --ieee-asserts=disable 2>&1 | grep -v "^\s*$"
