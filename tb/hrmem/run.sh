#!/usr/bin/env bash
# MegaX: tb_hrmem (x68_hrmem against SDRAMC with its chip model, the same random commands).
# ghdl synthesises SDRAMC's simulation copy and x68_hrmem to Verilog; Verilator runs the SV
# testbench. Prints "TB_HRMEM: PASS" or the first differences. M2M=1: the Avalon side is the
# framework's arbiter and HyperRAM controller with a chip model (avl_m2m.sv). Arguments go to the
# testbench (+verilator+seed+N).
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
VL_SRC="avl_model.sv"; VL_DEF=""
if [ "${M2M:-0}" = 1 ]; then
   # the framework's arbiter and HyperRAM controller logic (m2m_hr.vhd), as on the board
   M=../../M2M/vhdl
   ghdl -a $G $M/memory/avm_arbit.vhd $M/memory/avm_arbit_general.vhd \
      $M/controllers/hyperram/hyperram_errata.vhd $M/controllers/hyperram/hyperram_config.vhd \
      $M/controllers/hyperram/hyperram_ctrl.vhd m2m_hr.vhd
   # (hyperram_ctrl's signal "config" is a Verilog keyword)
   ghdl --synth $G --out=verilog m2m_hr 2> $W/m2m_synth.log | sed -E 's/\bconfig\b/config_s/g' > $W/m2m_hr.v
   VL_SRC="avl_m2m.sv $W/m2m_hr.v"; VL_DEF="-DM2M"
fi
verilator --binary --timing -O2 -Wno-fatal -Wno-WIDTH -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
   -Wno-CASEINCOMPLETE -Wno-INITIALDLY -Wno-BLKSEQ $VL_DEF --top-module tb_hrmem --Mdir $W/vl -o tb \
   tb_hrmem.sv $VL_SRC $W/sdramc.v $W/hrmem.v ../sim/sdram_chip.sv > $W/verilator.log 2>&1 || { tail -30 $W/verilator.log; exit 1; }
$W/vl/tb "$@" | grep -v "^SDRAM" | grep -v "violation"
