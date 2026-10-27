#!/usr/bin/env python3
"""MegaX: read the bring-up probe (x68_dbg.vhd, QNICE device 0x0110) through the QNICE monitor
and check the captured SDRAM reads against boot.rom.

  tools/dbgread.py [--port /dev/ttyUSB1] [--wait <s>] <boot.rom>

The MEGA65 must be in the Shell's debug mode (QMON> on the serial link; --wait waits for it).
SDRAMC's word address: bank = bits 23..22, row = 21..9, column = 8..0 (CAWIDTH 9, A9 = 0);
boot.rom (F00000-FFFFFF) is at word address 0x780000, big-endian (the core's loader).
"""
import os, re, subprocess, sys

args = sys.argv[1:]
qargs = []
while args and args[0] in ("--port", "--wait"):
    qargs += args[:2]
    args = args[2:]
rom = open(args[0], "rb").read()

here = os.path.dirname(os.path.abspath(__file__))
out = subprocess.run([sys.executable, os.path.join(here, "qmon.py")] + qargs +
                     ["MCFFF40110", "MCFFF50000", "MD8000810F"],
                     capture_output=True, text=True).stdout
words = {}
for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", out, re.M):
    a = int(m.group(1), 16)
    for i, w in enumerate(m.group(2).split()):
        words[a + i] = int(w, 16)
if 0x8000 not in words:
    print(out)
    sys.exit("no dump")

def w(o):
    return words.get(0x8000 + o, 0)

st = w(0)
names = ["started", "ldr_done", "core_rstn", "reset", "locked", "scan_ready", "boot_active",
         "armed", "full"]
print("status %04X: %s" % (st, " ".join(n for i, n in enumerate(names) if st >> i & 1)))
for name, o in (("READ", 1), ("WRITE", 3), ("ACTIVE", 5), ("REFRESH", 7)):
    print("%-8s %d" % (name, w(o) | w(o + 1) << 16))
sc = w(9)
print("scan_req %X scan_mode %X" % (sc >> 4 & 15, sc & 15))
n = w(10)
print("captured reads: %d" % n)
for i in range(min(n, 64)):
    br, col, d0, d1 = (w(0x10 + 4 * i + k) for k in range(4))
    bank, row = br >> 13 & 3, br & 0x1FFF
    wa = bank << 22 | row << 9 | (col & 0x1FF)
    line = "%2d bank %d row %04X col %03X  word %06X  data %04X %04X" % (i, bank, row, col, wa, d0, d1)
    if 0x780000 <= wa < 0x800000:
        o = (wa - 0x780000) * 2
        e0 = rom[o] << 8 | rom[o + 1]
        e1 = rom[o + 2] << 8 | rom[o + 3]
        ep = rom[o - 2] << 8 | rom[o - 1] if o >= 2 else -1
        verdict = "OK" if d0 == e0 else ("NEXT WORD" if d0 == e1 else ("PREVIOUS WORD" if d0 == ep else "WRONG"))
        line += "  rom %04X %04X  %s" % (e0, e1, verdict)
    print(line)
