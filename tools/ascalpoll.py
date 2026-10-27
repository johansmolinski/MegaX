#!/usr/bin/env python3
"""MegaX: sample what M2M's scaler (ascal) measures on the core's video, through the QNICE
monitor, and print one line per sample with the time - to correlate with what HDMI shows.

  tools/ascalpoll.py [--port /dev/ttyUSB1] [--secs 30]

Device M2M$SYS_INFO (0x00FF), window M2M$SYS_CORE (0x0030) (M2M qnice_wrapper.vhd): 0 CORE_X (ascal's i_hdmax),
1 CORE_Y (i_vdmax), 2 H_PIXELS, 3 V_PIXELS, 4 H_PULSE, 5 H_BP, 6 H_FP, 7 V_PULSE, 8 V_BP,
9 V_FP, A H_FREQ, B flags (bit 0: ascal saw interlaced input). The MEGA65 must already be
in the Shell's debug mode (QMON>).
"""
import os, re, subprocess, sys, time

args = sys.argv[1:]
port, secs = [], 30.0
while args:
    if args[0] == "--port":
        port = args[:2]; args = args[2:]
    elif args[0] == "--secs":
        secs = float(args[1]); args = args[2:]
    else:
        sys.exit("unknown argument " + args[0])
here = os.path.dirname(os.path.abspath(__file__))

def qmon(cmds):
    return subprocess.run([sys.executable, os.path.join(here, "qmon.py")] + port + cmds,
                          capture_output=True, text=True).stdout

qmon(["MCFFF400FF", "MCFFF50030"])
names = "X Y HPIX VPIX HPUL HBP HFP VPUL VBP VFP HFRQ FL".split()
print("    t  " + " ".join("%5s" % n for n in names))
t0 = time.time()
last = None
while time.time() - t0 < secs:
    o = qmon(["MD8000800B"])
    v = []
    for m in re.finditer(r"^800[08]: ((?:[0-9A-F]{4} ?)+)", o, re.M):
        v += [int(x, 16) for x in m.group(1).split()]
    if len(v) < 12:
        print("%5.1f  incomplete: %r" % (time.time() - t0, o[-120:])); continue
    mark = "" if last is None or v == last else "   <- changed"
    print("%5.1f  " % (time.time() - t0) + " ".join("%5d" % x for x in v) + mark)
    last = v
