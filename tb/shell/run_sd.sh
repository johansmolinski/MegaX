#!/usr/bin/env bash
# MegaX: tb_sd (x68_sd.vhd, disk images from the SD card through hps_io's sector interface)
# under ghdl. Prints "tb_sd PASS" or the mismatches. On the Fedora host.
set -euo pipefail
cd "$(dirname "$0")"
M=../../M2M/vhdl
W=obj/sd
rm -rf $W && mkdir -p $W
F="--std=08 -frelaxed -fsynopsys --workdir=$W"
ghdl -i $F $M/QNICE/sdhost.vhd $M/2port2clk_ram.vhd $M/tdp_ram.vhd $M/cdc_stable.vhd ../../CORE/vhdl/x68_sd.vhd tb_sd.vhd
ghdl -m $F -o $W/tb_sd tb_sd 2>&1 | grep -v "^analyze\|^elaborate" || true
$W/tb_sd --ieee-asserts=disable 2>&1 | grep -v "^\s*$"
