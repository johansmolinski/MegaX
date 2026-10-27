#!/usr/bin/env python3
"""MegaX: read the 68000 bus trace (x68_trace.vhd, QNICE device 0x0110) through the QNICE
monitor and print it, oldest cycle first.

  tools/trace.py [--port /dev/ttyUSB1] [--wait <s>] [--writes] [--keep]

The MEGA65 must be in the Shell's debug mode (QMON>; --wait waits for it). The trace is
frozen for the read-out and unfrozen afterwards (--keep: stays frozen). --writes: switch to
"writes only" (and unfreeze), so that a later read shows the last 1024 write cycles.
"""
import os, re, subprocess, sys

args = sys.argv[1:]
qargs, writes, keep = [], False, False
while args:
    if args[0] in ("--port", "--wait"):
        qargs += args[:2]; args = args[2:]
    elif args[0] == "--writes":
        writes = True; args = args[1:]
    elif args[0] == "--keep":
        keep = True; args = args[1:]
    else:
        sys.exit("unknown argument " + args[0])
here = os.path.dirname(os.path.abspath(__file__))

def qmon(cmds, extra=()):
    return subprocess.run([sys.executable, os.path.join(here, "qmon.py")] + list(extra) + cmds,
                          capture_output=True, text=True).stdout

if writes:
    print(qmon(["MCFFF40110", "MCFFF50000", "MC80000002"], qargs))
    sys.exit(0)

out = qmon(["MCFFF40110", "MCFFF50000", "MC80000001", "MD80008003",
            "MCFFF50001", "MD800083FF", "MCFFF50002", "MD800083FF", "MCFFF50003", "MD800083FF"] +
           ([] if keep else ["MCFFF50000", "MC80000000"]), qargs)
# split the dumps by window: each "MEMORY/DUMP" block follows a window change
blocks = re.split(r"MEMORY/DUMP", out)[1:]
def parse(b):
    d = {}
    for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", b, re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            d[a + i - 0x8000] = int(w, 16)
    return d
if len(blocks) < 4:
    print(out); sys.exit("incomplete read-out")
ctrl, data, alo, ahi = (parse(b) for b in blocks[:4])
wptr, count = ctrl.get(1, 0), ctrl.get(2, 0) | ctrl.get(3, 0) << 16
print("bus cycles recorded: %d, next index %d" % (count, wptr))
fcn = {1: "UD", 2: "UP", 5: "SD", 6: "SP", 7: "IA"}
n = min(count, 1024)
for k in range(n):
    i = (wptr - n + k) % 1024
    h = ahi.get(i, 0)
    a = (h & 0xFF) << 16 | alo.get(i, 0)
    fc, rw, uds, lds = h >> 13, h >> 12 & 1, h >> 11 & 1, h >> 10 & 1
    strobes = ("U" if not uds else "-") + ("L" if not lds else "-")
    print("%4d  %s %s %s %06X  %04X" % (k - n, fcn.get(fc, "F%d" % fc), "R" if rw else "W",
                                       strobes, a, data.get(i, 0)))
