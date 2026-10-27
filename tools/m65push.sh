#!/bin/bash
# MegaX: m65push.sh <bitstream.bit> [file ...]
#   Copies the files into /megax on the MEGA65's SD card over the USB serial link (it loads
#   the MEGA65 core's bitstream over JTAG for that, M65BIT), then loads the bitstream over
#   JTAG. Without files it only loads the bitstream. Every step has a timeout and the
#   script stops at the first failure. After Megamiga's ~/aexp-work/m65push.sh.
#   M65PORT: the serial port (default /dev/ttyUSB1; after a re-attach it can change, see
#   /dev/serial/by-id/*Digilent*-if01-port0). Tools: ~/git/pub/mega65-tools/bin.
M=~/git/pub/mega65-tools/bin; P=${M65PORT:-/dev/ttyUSB1}
M65BIT=${M65BIT:-$HOME/mega65r6-release-0.97.2-03b24c6/mega65r6-20250919.07-r-0.97.2-03b24c6.bit}
BIT=$1; shift
stty -F $P clocal 2>/dev/null || true   # an open() without clocal blocks waiting for carrier
if [ $# -gt 0 ]; then
    timeout 60 $M/m65 -l $P -q "$M65BIT" || { echo "m65push: loading the MEGA65 core failed" >&2; exit 1; }
    sleep 15
    args=(-c "mkdir megax" -c "cd megax")
    for f in "$@"; do args+=(-c "put $f $(basename $f)"); done
    timeout 7200 $M/mega65_ftp -F -l $P "${args[@]}" -c "dir" -c "quit" 2>&1 | tr '\r' '\n' | grep -v "^Uploaded [0-9]* bytes\.$"
    [ ${PIPESTATUS[0]} -eq 0 ] || { echo "m65push: mega65_ftp failed" >&2; exit 1; }
fi
timeout 60 $M/m65 -l $P -q "$BIT" || { echo "m65push: loading the bitstream failed" >&2; exit 1; }
