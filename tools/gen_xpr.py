#!/usr/bin/env python3
"""Generate CORE/CORE-R6.xpr from Megamiga's CORE-R6.xpr (the framework file list).

Keeps the project settings, the run strategies, the synth_pre.tcl hook, the constraint set and
every source under M2M/ (the vendored framework), drops Megamiga's own sources (CORE/vhdl,
Minimig) and adds MegaX's: the MEGA65 shell (CORE/vhdl) and the machine's file list
CORE/sources.txt (the same list the simulation uses). Megamiga hard rule 2: SFType only VHDL2008,
SVerilog or none (.v files: none, Verilog by extension).

  git -C ~/git/pub/AExp show main:CORE/CORE-R6.xpr > /tmp/megamiga-r6.xpr
  tools/gen_xpr.py /tmp/megamiga-r6.xpr CORE/CORE-R6.xpr

After PC10-III's tools/gen_xpr.py.
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# the MEGA65 shell (CORE/vhdl), in compile order after the machine
SHELL = ["vhdl/globals.vhd", "vhdl/config.vhd", "vhdl/clk.vhd", "vhdl/keyboard.vhd",
         "vhdl/x68_boot.vhd", "vhdl/x68_sd.vhd", "vhdl/x68_dbg.vhd", "vhdl/main.vhd", "vhdl/mega65.vhd"]


def sftype(path):
    if path.endswith(".vhd"):
        return "VHDL2008"
    if path.endswith(".sv"):
        return "SVerilog"
    return None                          # .v: inferred from the extension


def machine():
    files = []
    for line in open(os.path.join(ROOT, "CORE", "sources.txt")):
        f = line.split()
        if len(f) == 2 and f[0] in ("vhdl", "sv"):
            files.append(f[1])
    return files


src, dst = sys.argv[1], sys.argv[2]
CORE_FILES = [(f, sftype(f)) for f in machine() + SHELL]

x = open(src).read()

m = re.search(r'(<FileSet Name="sources_1".*?<Filter Type="Srcs"/>\n)(.*?)(      <Config>.*?</FileSet>)', x, re.S)
head, body, tail = m.group(1), m.group(2), m.group(3)
entries = re.findall(r'      <File Path=".*?</File>\n', body, re.S)
keep = [e for e in entries if '$PPRDIR/../M2M/' in e]
for path, t in CORE_FILES:
    assert os.path.exists(os.path.join(ROOT, "CORE", path)), path
    keep.append('      <File Path="$PPRDIR/%s">\n        <FileInfo%s>\n'
                '          <Attr Name="UsedIn" Val="synthesis"/>\n'
                '          <Attr Name="UsedIn" Val="simulation"/>\n'
                '        </FileInfo>\n      </File>\n' % (path, ' SFType="%s"' % t if t else ""))
# no Verilog include dirs or defines of Megamiga's (the X68000's sources include nothing)
tail = re.sub(r'\s*<Option Name="VerilogDir"[^>]*/>', '', tail)
tail = re.sub(r'\s*<Define Name[^>]*/>', '', tail)
x = x[:m.start()] + head + "".join(keep) + tail + x[m.end():]

# the project's own path and id are rewritten by Vivado on open; give it a neutral path
x = re.sub(r'<Project Version="7" Minor="61" Path="[^"]*"',
           '<Project Version="7" Minor="61" Path="CORE-R6.xpr"', x)
for t in set(re.findall(r'SFType="([^"]*)"', x)):
    assert t in ("VHDL2008", "SVerilog"), t
open(dst, "w").write(x)
print("%s: %d framework files kept, %d core files" % (dst, len(keep) - len(CORE_FILES), len(CORE_FILES)))
