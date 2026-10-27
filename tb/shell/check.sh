#!/usr/bin/env bash
# MegaX: analyse the MEGA65 shell (CORE/vhdl) with ghdl against stand-ins for UNISIM and XPM
# (unisim_stub.vhd, xpm_stub.vhd), the M2M packages it uses and the machine (CORE/sources.txt).
# A syntax and type check in seconds before a Vivado run; heavy work goes to the Fedora host:
#   tools/remote/rsim.sh start <name> shell-check   (tb/sim's make target runs this script)
set -euo pipefail
cd "$(dirname "$0")"
CORE=../../CORE
W=obj
rm -rf $W && mkdir -p $W/unisim $W/xpm $W/work
F="--std=08 -frelaxed -fsynopsys"
ghdl -a $F --work=unisim --workdir=$W/unisim unisim_stub.vhd
ghdl -a $F --work=xpm --workdir=$W/xpm xpm_stub.vhd
L="-P$W/unisim -P$W/xpm --workdir=$W/work"
# import everything (any order), then make MEGA65_Core: ghdl analyses in dependency order and
# elaborates; the (System)Verilog modules of the machine stay unbound components (warnings)
ghdl -i $F $L ../../M2M/QNICE/vhdl/tools.vhd ../../M2M/vhdl/av_pipeline/video_modes_pkg.vhd \
    ../../M2M/vhdl/controllers/HDMI/types_pkg.vhd ../../M2M/vhdl/QNICE/sdhost.vhd \
    ../../M2M/vhdl/2port2clk_ram.vhd ../../M2M/vhdl/tdp_ram.vhd ../../M2M/vhdl/cdc_stable.vhd \
    $(awk '$1=="vhdl"{print "'$CORE'/"$2}' $CORE/sources.txt) \
    $(for f in globals config clk keyboard x68_boot x68_sd x68_trace main mega65; do echo $CORE/vhdl/$f.vhd; done)
ghdl -m $F $L mega65_core 2>&1 | grep -v "warning\|^ *[0-9]* |\|^ *|" || true
ghdl -m $F $L mega65_core > /dev/null 2>&1 && echo "shell analysis OK" || { echo "shell analysis FAILED"; exit 1; }
