#!/usr/bin/env python3
"""MegaX: x68_hrmem's state and memcont's current command (R3 bring-up, temporary; QNICE device
C_DEV_X68_DEBUG window 5, mega65.vhd), read twice through the QNICE monitor (the Shell's debug
mode; see qmon.py) and decoded. Words that changed between the two reads are marked "*" (the
machine is running there); a hang shows everything standing still.

  tools/hrstate.py [--port /dev/ttyUSB1] [--wait <s>] [--stay]
  tools/hrstate.py --raw <tb/sim log>    decode tb/sim's "window5:" line instead

Stays in the debug mode with --stay; otherwise leaves it (CR224F) afterwards.
"""
import os, re, subprocess, sys

args = sys.argv[1:]
qargs, stay, raw = [], False, None
while args:
    if args[0] in ("--port", "--wait"):
        qargs += args[:2]; args = args[2:]
    elif args[0] == "--raw":
        raw = args[1]; args = args[2:]
    elif args[0] == "--stay":
        stay = True; args = args[1:]
    else:
        sys.exit(__doc__)
here = os.path.dirname(os.path.abspath(__file__))
SEL = ["MCFFF40110", "MCFFF50005"]          # device C_DEV_X68_DEBUG, window 5


def qmon(cmds, extra=()):
    return subprocess.run([sys.executable, os.path.join(here, "qmon.py")] + list(extra) + cmds,
                          capture_output=True, text=True).stdout


def dump():
    out = qmon(SEL + ["MD80008023", "MD8040807F"], qargs)
    words = {}
    for m in re.finditer(r"^([0-9A-F]{4}): ((?:[0-9A-F]{4} ?)+)", out, re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            words[a + i] = int(w, 16)
    try:
        return [words.get(0x8000 + i, 0) if 36 <= i < 64 else words[0x8000 + i] for i in range(128)]
    except KeyError:
        sys.exit("incomplete dump\n" + out)


if raw:
    for line in open(raw):
        if line.startswith("window5:"):
            a = b = [int(x, 16) for x in line.split()[1:]]
    stay = True
else:
    a, b = dump(), dump()
if not stay:
    try:
        subprocess.run([sys.executable, os.path.join(here, "qmon.py"), "CR224F"],
                       capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        pass


def w(i):
    return b[i]


def ch(*idx):
    return " *" if any(a[i] != b[i] for i in idx) else ""


def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


S_RAM = ["S_IDLE", "S_RCMD", "S_RDATA", "S_RLAST", "S_WWAIT", "S_WCAP", "S_WCMD"]
S_HR = ["H_IDLE", "H_RWAIT", "H_RREQ", "H_RDATA", "H_WWAIT", "H_WBURST"]
CLS = ["idle", "refresh", "GVRAM line read", "CPU read fill", "CPU write-back", "GVRAM fast clear",
       "disks", "other"]

v = w(0)
print("clk_ram side%s" % ch(0, 1, 2, 3, 4, 5, 6, 7))
print("  state %s  hr_rst %d  rd %d wr %d refrsh %d abort %d  initdone %d  tag %d wtag %d  de %d cap_on %d"
      % (S_RAM[bits(v, 15, 12)] if bits(v, 15, 12) < 7 else bits(v, 15, 12), bits(v, 11, 11),
         bits(v, 10, 10), bits(v, 9, 9), bits(v, 8, 8), bits(v, 7, 7), bits(v, 6, 6), bits(v, 5, 4),
         bits(v, 3, 2), bits(v, 1, 1), bits(v, 0, 0)))
print("  cnt %d  l_m %d  l_n %d  skip %d  idle_cnt %d" % (w(1), w(2), w(3), w(4), w(7)))
print("  c_wr_free %d  r_rd_count %d  w_wr_free %d" % (bits(w(5), 13, 9), bits(w(5), 8, 0), w(6)))
print("  reads %d, ended %d, aborted %d, timed out %d; writes %d; de words (12 bits) %d%s"
      % (w(8), w(9), w(10), w(11), w(12), bits(w(15), 11, 0), ch(8, 9, 10, 11, 12, 15)))
print("  last read: addrh %04x bgn %02x end %02x bwidth %d" % (w(13), w(14) >> 8, w(14) & 0xFF,
                                                               w(15) >> 12))
v = w(16)
print("hr_clk side%s" % ch(*range(16, 25)))
print("  hstate %s  h_tag %d h_wr %d h_prep %d  hr_rst %d  waitrequest %d readdatavalid %d  read %d write %d"
      % (S_HR[bits(v, 15, 12)] if bits(v, 15, 12) < 6 else bits(v, 15, 12), bits(v, 11, 10),
         bits(v, 9, 9), bits(v, 8, 8), bits(v, 7, 7), bits(v, 6, 6), bits(v, 5, 5), bits(v, 4, 4),
         bits(v, 3, 3)))
print("  h_left %d  h_beats %d  h_len %d  h_addr %06x  h_mask %02x"
      % (w(17), w(18), w(19), w(20) | bits(w(21), 5, 0) << 16, w(21) >> 8))
print("  c_rd_count %d  w_rd_count %d  r_wr_free %d" % (w(22), w(23), w(24)))
print("  commands %d, read words %d, write words %d, bursts %d%s" % (w(25), w(26), w(27), w(28),
                                                                   ch(25, 26, 27, 28)))
c = w(29) << 32 | w(30) << 16 | w(31)
print("  command FIFO head: tag %d write %d start %06x mask %02x words %d"
      % (c >> 40, (c >> 39) & 1, (c >> 17) & 0x3FFFFF, (c >> 9) & 0xFF, c & 0x1FF))
m = w(32) | w(33) << 16 | w(34) << 32 | w(35) << 48
print("memcont%s" % ch(32, 33, 34, 35))
print("  CPU read request %d ack %d  class %s  rd %d wr %d busy %d de %d abort %d  bwidth %d  addrh %04x bgn %02x end %02x"
      % (bits(m, 51, 51), bits(m, 50, 50), CLS[bits(m, 47, 45)], bits(m, 44, 44), bits(m, 43, 43),
         bits(m, 42, 42), bits(m, 41, 41), bits(m, 40, 40), bits(m, 39, 36), bits(m, 31, 16),
         bits(m, 15, 8), bits(m, 7, 0)))

ST = ["IDLE", "BREAD", "BWRITE", "BCREAD", "G0CLR", "G1CLR", "G2CLR", "G3CLR", "GCLRDIRECT", "GCLRREAD",
      "GCLRWRITE", "G00READ", "G01READ", "G02READ", "G03READ", "T0READ", "G10READ", "G11READ", "G12READ",
      "G13READ", "T1READ", "FDEREAD", "FDEWRITE", "FECREAD", "FECWRITE", "REFRSH"]
v, u = w(64), w(65)
print("cachecont%s" % ch(*range(64, 128)))
print("  state %s  brcache_sel %d  aborted %d  cpu_urgent_used %d  sb_rd %d  braddrnone %d  brack %d  bwcache_dirty %d  bcpend %d"
      % (ST[v >> 11] if (v >> 11) < len(ST) else v >> 11, bits(v, 10, 7), bits(v, 6, 6), bits(v, 5, 5),
         bits(v, 4, 4), bits(v, 3, 3), bits(v, 2, 2), bits(v, 1, 1), bits(v, 0, 0)))
print("  sb_wr %d sb_rmw %d  cpbusy %d  vid_hazard %d  cpu_dirty_hazard %d  bwcache_busy %d  brcache_busy %d  b_rd %d b_wr %d  bcnext %d"
      % (bits(u, 15, 14), bits(u, 13, 12), bits(u, 11, 11), bits(u, 10, 10), bits(u, 9, 9), bits(u, 8, 8),
         bits(u, 7, 7), bits(u, 6, 6), bits(u, 5, 4), bits(u, 3, 0)))
print("  sb_addr %06x  b_addr %06x  bwaddr_sel %05x  refcount %d  vidcount %d"
      % (w(66) | w(67) << 16, w(68) | w(69) << 16, w(70) | w(71) << 16, w(74) >> 8, w(74) & 3))
print("  read blocks (tag = word address >> 7; mask, rdb, ext = the word at b_addr present):")
for i in range(16):
    lo, hi = w(80 + 2 * i), w(81 + 2 * i)
    tag = lo | (hi >> 3) << 16
    print("    %2d  tag %s  mask %d rdb %d ext %d" % (i, "none" if tag == 0x3FFFF else "%05x (line %06x)" % (tag, tag << 7),
                                                  bits(hi, 2, 2), bits(hi, 1, 1), bits(hi, 0, 0)))
