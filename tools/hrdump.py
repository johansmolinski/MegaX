#!/usr/bin/env python3
"""MegaX: read the scaler's frame buffers (ascal, M2M digital_pipeline) out of the HyperRAM
through the QNICE monitor and look at the pixels.

  tools/hrdump.py [--port /dev/ttyUSB1] [--wait <s>] [--bpp 16|24] [--first L] [--lines N]
                  [--bufs 012] [--out <file>]

ascal keeps three input buffers at HyperRAM byte 0, RAMSIZE, 2 x RAMSIZE (only buffer 0 while
triple buffering is off, mega65.vhd). --bpp 16 (the default, globals.vhd ASCAL_16BPP): RAMSIZE
1 MB, a line is 1536 bytes (16bpp 565); --bpp 24 (builds up to megax-t): RAMSIZE 2 MB, a line is
2304 bytes, 24 bpp packed. The QNICE device M2M$HYPERRAM (4) is
addressed in 16-bit words: window = word >> 12. The MEGA65 must be in the Shell's debug mode
(QMON>; --wait waits for it). The video keeps running while QMON reads, so the buffers change
under the read-out: every line is a live sample.

16 bpp: per buffer and line, the number of non-zero pixels and the pixel values found (most
frequent first): text in one colour shows one value, anything else is a corrupted pixel.
24 bpp: per buffer, byte order (low byte first / high byte first) and line: the number of non-zero
bytes, and the pixels by the channels that are non-zero (R, G, B, RG, ... with the bytes of a
pixel taken as R, G, B in that order). Defaults: lines 0..6, black on the vidtest screen
(tb/sim/bootdisk/vidtest.S). On a text line in one colour (memtest: green) the right byte
order shows that colour's class only; anything else is a corrupted pixel in the buffer.
"""
import os, re, subprocess, sys

args = sys.argv[1:]
qargs, bpp, first, lines, bufs, out = [], 16, 0, 7, "0", None
while args:
    if args[0] in ("--port", "--wait"):
        qargs += args[:2]; args = args[2:]
    elif args[0] == "--bpp":
        bpp = int(args[1]); args = args[2:]
    elif args[0] == "--first":
        first = int(args[1]); args = args[2:]
    elif args[0] == "--lines":
        lines = int(args[1]); args = args[2:]
    elif args[0] == "--bufs":
        bufs = args[1]; args = args[2:]
    elif args[0] == "--out":
        out = args[1]; args = args[2:]
    else:
        sys.exit("unknown argument " + args[0])
here = os.path.dirname(os.path.abspath(__file__))

LINE = 768 * bpp // 8
BUF = (1 if bpp == 16 else 2) * 1024 * 1024

def qmon(cmds, extra=()):
    return subprocess.run([sys.executable, os.path.join(here, "qmon.py")] + list(extra) + cmds,
                          capture_output=True, text=True).stdout

# the words to read: per buffer, lines first .. first+lines-1 (LINE is even: whole words)
blist = [int(c) for c in bufs]
cmds = ["MCFFF40004"]
plan = []
for b in blist:
    w0 = (b * BUF + first * LINE) // 2
    w1 = w0 + lines * LINE // 2
    w = w0
    while w < w1:
        win, off = w >> 12, w & 0xFFF
        n = min(0x1000 - off, w1 - w)
        cmds += ["MCFFF5%04X" % win, "MD%04X%04X" % (0x8000 + off, 0x8000 + off + n - 1)]
        plan.append((b, w))
        w += n
o = qmon(cmds, qargs)
blocks = re.split(r"MEMORY/DUMP", o)[1:]
if len(blocks) < len(plan):
    print(o); sys.exit("incomplete read-out: %d of %d dumps" % (len(blocks), len(plan)))

# data[b][i]: word i of the dumped range of buffer b
data = {b: {} for b in blist}
for (b, w), blk in zip(plan, blocks):
    base = w & ~0xFFF
    w0 = (b * BUF + first * LINE) // 2
    for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", blk, re.M):
        a = int(m.group(1), 16) - 0x8000
        for i, x in enumerate(m.group(2).split()):
            data[b][base + a + i - w0] = int(x, 16)

if out:
    with open(out, "w") as f:
        for b in blist:
            for i in sorted(data[b]):
                f.write("%d %06X %04X\n" % (b, i, data[b][i]))

if bpp == 16:
    for b in blist:
        print("buffer %d" % b)
        for y in range(lines):
            px = [data[b].get(y * LINE // 2 + x, 0) for x in range(768)]
            hist = {}
            for v in px:
                if v:
                    hist[v] = hist.get(v, 0) + 1
            vals = sorted(hist.items(), key=lambda kv: -kv[1])
            print("  line %3d: %4d non-zero pixels  %s" % (first + y, sum(hist.values()),
                  "  ".join("%04X x%d" % kv for kv in vals[:6])))
    sys.exit(0)

CLS = ["-", "R", "G", "RG", "B", "RB", "GB", "RGB"]
for b in blist:
    nwords = lines * LINE // 2
    words = [data[b].get(i) for i in range(nwords)]
    missing = sum(1 for x in words if x is None)
    for order in ("lo-hi", "hi-lo"):
        by = []
        for x in words:
            x = x or 0
            by += [x & 0xFF, x >> 8] if order == "lo-hi" else [x >> 8, x & 0xFF]
        print("buffer %d (%s)%s" % (b, order, ", %d words missing" % missing if missing else ""))
        for y in range(lines):
            ln = by[y * LINE:(y + 1) * LINE]
            nz = sum(1 for v in ln if v)
            cnt = [0] * 8
            ex = {}
            for x in range(768):
                r, g, bl = ln[3 * x:3 * x + 3]
                c = (r != 0) | (g != 0) << 1 | (bl != 0) << 2
                cnt[c] += 1
                ex.setdefault(c, (x, r, g, bl))
            cls = "  ".join("%s %d" % (CLS[c], cnt[c]) for c in range(1, 8) if cnt[c])
            exs = "  ".join("%s@%d=%02X%02X%02X" % ((CLS[c],) + ex[c]) for c in range(1, 8) if c in ex)
            print("  line %3d: %4d non-zero bytes  %s   %s" % (first + y, nz, cls, exs))
