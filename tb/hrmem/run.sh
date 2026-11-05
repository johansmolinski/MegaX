#!/usr/bin/env bash
# MegaX: tb_hrmem (x68_hrmem against SDRAMC with its chip model, the same random commands).
# ghdl synthesises SDRAMC's simulation copy and x68_hrmem to Verilog; Verilator runs the SV
# testbench. Prints "TB_HRMEM: PASS" or the first differences.
set -euo pipefail
cd "$(dirname "$0")"
CORE=../../CORE
W=obj
rm -rf $W && mkdir -p $W/ghdl
G="--std=08 -frelaxed -fsynopsys --workdir=$W/ghdl"
python3 ../sim/sdramc_sim.py $CORE/X68000_MiSTerMEGA65/rtl/memory/SDRAMC.vhd $W/SDRAMC_sim.vhd
ghdl -a $G $W/SDRAMC_sim.vhd $CORE/vhdl/x68_afifo.vhd $CORE/vhdl/x68_hrmem.vhd
ghdl --synth $G --out=verilog -gAWIDTH=24 -gCAWIDTH=9 SDRAMC > $W/sdramc.v
ghdl --synth $G --out=verilog x68_hrmem > $W/hrmem.v
verilator --binary --timing -O2 -Wno-fatal -Wno-WIDTH -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
   -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-BLKSEQ --top-module tb_hrmem --Mdir $W/vl -o tb \
   tb_hrmem.sv avl_model.sv $W/sdramc.v $W/hrmem.v ../sim/sdram_chip.sv > $W/verilator.log 2>&1 || { tail -30 $W/verilator.log; exit 1; }
$W/vl/tb | grep -v "^SDRAM" | grep -v "violation"
