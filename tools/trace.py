#!/usr/bin/env python3
"""MegaX: read the 68000 bus trace (x68_trace.vhd, QNICE device 0x0110) through the QNICE
monitor and print it, oldest cycle first.

  tools/trace.py [--port /dev/ttyUSB1] [--wait <s>] [--writes] [--keep]
  tools/trace.py [...] --arm <addr>[/<mask>] [--reset]
  tools/trace.py [...] --status

The MEGA65 must be in the Shell's debug mode (QMON>; --wait waits for it). The trace is
frozen for the read-out and unfrozen afterwards (--keep: stays frozen). --writes: switch to
"writes only" (and unfreeze), so that a later read shows the last 1024 write cycles.
--arm: the trigger on a program fetch at <addr> (hex, mask default FFFFFF); the trace then
freezes itself 64 cycles after it; --reset resets the X68000 afterwards (M2M CSR bit 0, about
a millisecond), so the trigger catches the next boot. --status: control, fired, counters, and
the OPM bus wait probe (X68K_top's dbg_opm) decoded, with the opm_ce(0) pulse counter read twice.
"""
import os, re, subprocess, sys

args = sys.argv[1:]
qargs, writes, keep, arm, reset, status = [], False, False, None, False, False
while args:
    if args[0] in ("--port", "--wait"):
        qargs += args[:2]; args = args[2:]
    elif args[0] == "--arm":
        arm = args[1]; args = args[2:]
    elif args[0] == "--reset":
        reset = True; args = args[1:]
    elif args[0] == "--status":
        status = True; args = args[1:]
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
if status:
    out = qmon(["MCFFF40110", "MCFFF50000", "MD8000800B", "MD8000800B"], qargs)
    print(out)
    # the OPM bus wait probe (register 9, X68K_top's dbg_opm) and the opm_ce(0) pulse counter
    # (registers 10/11), from both dumps: the counter must move between them (4 MHz)
    dumps = []
    for b in re.split(r"MEMORY/DUMP", out)[1:]:
        w = []
        for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", b, re.M):
            w += [int(x, 16) for x in m.group(2).split()]
        dumps.append(w)
    if len(dumps) == 2 and all(len(w) >= 12 for w in dumps):
        o = dumps[1][9]
        names = ["iowait_opm", "iowait_sasi", "iowait_rcpy", "iowait", "srstn", "mpu_reset_n",
                 "cpu_rstn", "opm_csn", "b_rdn", "b_wrn0", "opm_ce0", "ASn"]
        print("dbg_opm %04X: opm_wstate=%d " % (o, o & 3) +
              " ".join("%s=%d" % (n, o >> (i + 2) & 1) for i, n in enumerate(names)))
        c0, c1 = (w[10] | w[11] << 16 for w in dumps)
        print("opm_ce(0) pulses: %d, then %d (%s)" % (c0, c1, "running" if c1 != c0 else "STOPPED"))
    sys.exit(0)
if arm:
    a, _, m = arm.partition("/")
    a, m = int(a, 16), int(m or "FFFFFF", 16)
    print(qmon(["MCFFF40110", "MCFFF50000",
                "MC8004%04X" % (a & 0xFFFF), "MC8005%04X" % (a >> 16),
                "MC8006%04X" % (m & 0xFFFF), "MC8007%04X" % (m >> 16),
                "MC80000004"], qargs))
    if reset:
        o = qmon(["MCFFE0"], [])          # shows the current value, waits for the new one
        cur = int(re.search(r"CURRENT VALUE=([0-9A-F]{4})", o).group(1), 16)
        # finish that change with the reset bit set, then clear it again
        print(o + qmon(["%04X" % (cur | 1)], []) + qmon(["MCFFE0%04X" % (cur & 0xFFFE)], []))
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
