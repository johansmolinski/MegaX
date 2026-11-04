#!/usr/bin/env python3
"""MegaX: the R3 study's probe (CORE/vhdl/x68_r3probe.vhd, temporary): clear its counters, or
take a snapshot and print the report, through the QNICE monitor (the Shell's debug mode; see
qmon.py). Leaves the debug mode afterwards (CR224F), so the X68000 runs on.

  tools/r3probe.py [--port /dev/ttyUSB1] [--wait <s>] clear
  tools/r3probe.py [--port /dev/ttyUSB1] [--wait <s>] [--stay] read [<label>]

clear: all counters to 0 (a new measurement starts). read: snapshot, print the report (and
append it with the raw registers and <label> to ~/megax-work/r3probe.log).
"""
import os, re, subprocess, sys, time

args = sys.argv[1:]
qargs, stay = [], False
while args and args[0].startswith("--"):
    if args[0] in ("--port", "--wait"):
        qargs += args[:2]; args = args[2:]
    elif args[0] == "--stay":
        stay = True; args = args[1:]
    else:
        sys.exit("unknown argument " + args[0])
if not args or args[0] not in ("clear", "read"):
    sys.exit(__doc__)
here = os.path.dirname(os.path.abspath(__file__))
SEL = ["MCFFF40110", "MCFFF50004"]          # device C_DEV_X68_DEBUG, window 4

def qmon(cmds, extra=()):
    return subprocess.run([sys.executable, os.path.join(here, "qmon.py")] + list(extra) + cmds,
                          capture_output=True, text=True).stdout

def leave():
    # on its own: in one call with other commands it did not get through (2026-11-03); the
    # Shell prints nothing when it resumes, so qmon may wait for output: a timeout
    if not stay:
        try:
            subprocess.run([sys.executable, os.path.join(here, "qmon.py"), "CR224F"],
                           capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            pass

if args[0] == "clear":
    print(qmon(SEL + ["MC80000001"], qargs))
    leave()
    print("r3probe: counters cleared")
    sys.exit(0)

label = " ".join(args[1:])
out = qmon(SEL + ["MC80000002", "MD80008000", "MD8010806B"], qargs)
leave()
words = {}
for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", out, re.M):
    a = int(m.group(1), 16)
    for i, w in enumerate(m.group(2).split()):
        words[a + i] = int(w, 16)
if words.get(0x8000, 0) & 3 != 3:
    sys.exit("snapshot not acknowledged (status %r)\n%s" % (words.get(0x8000), out))
try:
    r = [words[0x8010 + 2 * i] | words[0x8011 + 2 * i] << 16 for i in range(46)]
except KeyError:
    sys.exit("incomplete dump\n" + out)

T_RAM, T_HR = 12.5e-9, 10e-9               # clk_ram 80 MHz, hr_clk 100 MHz
CLS = ["refresh", "GVRAM line reads", "CPU read fills", "CPU write-backs", "GVRAM fast clear",
       "disks (FDE/FEC)", "other"]
cyc, frames = r[0], max(r[1], 1)
busy, ops, wrds = r[2:9], r[9:16], r[16:23]
secs = cyc * T_RAM
lines = []
p = lines.append
p("R3 probe %s  %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), label))
p("  %.1f s, %d frames (%.1f Hz)" % (secs, r[1], r[1] / secs if secs else 0))
p("  SDRAM (clk_ram 80 MHz), per class: busy %, commands/frame, words/frame:")
for k in range(7):
    p("    %-18s %5.1f %%  %8.1f  %9.1f" % (CLS[k], 100.0 * busy[k] / max(cyc, 1),
                                          ops[k] / frames, wrds[k] / frames))
tot = sum(busy[1:])
p("    %-18s %5.1f %%   (without refresh)" % ("all", 100.0 * tot / max(cyc, 1)))
p("  read words by SDRAMC's de: %d (computed read+write words %d)" % (r[23], sum(wrds)))
lp = r[26]
p("  line: %d cycles = %.2f us; most GVRAM read words in a line %d; most busy cycles in a "
  "line %d (%.0f %% of a line)" % (lp, lp * T_RAM * 1e6, r[24], r[25],
                                   100.0 * r[25] / lp if lp else 0))
p("  CPU: %d SDRAM reads (%.0f/frame), stalled %.1f %% of the time, %.1f cycles per read, "
  "longest %d cycles = %.2f us" % (r[27], r[27] / frames, 100.0 * r[28] / max(cyc, 1),
                                   r[28] / max(r[27], 1), r[29], r[29] * T_RAM * 1e6))
p("  commands lost at the CDC FIFO: %d" % r[30])
hcyc = max(r[31], 1)
p("  HyperRAM mirror (hr_clk 100 MHz): %d commands, %d words, busy %.1f %% of the time" % (
  r[32], r[33], 100.0 * r[34] / hcyc))
for k in range(7):
    if r[35 + k]:
        p("    longest latency %-18s %8.2f us" % (CLS[k], r[35 + k] * T_HR * 1e6))
gops = max(ops[1], 1)
p("    GVRAM line reads: average latency %.2f us; latest end after their HCOMP %.2f us "
  "(the line: %.2f us)" % (r[45] / gops * T_HR * 1e6, r[42] * T_HR * 1e6, lp * T_RAM * 1e6))
p("    longest backlog %d commands, lost %d" % (r[43], r[44]))
rep = "\n".join(lines)
print(rep)
log = os.path.expanduser("~/megax-work/r3probe.log")
with open(log, "a") as f:
    f.write(rep + "\n  raw: " + " ".join(str(x) for x in r) + "\n\n")
