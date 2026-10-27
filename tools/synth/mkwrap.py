#!/usr/bin/env python3
"""MegaX: write a pass-through VHDL wrapper <entity>_wrap around an entity (no generics passed:
their defaults apply), for out-of-context synthesis of that entity as a sub-module
(tools/synth/ooc.tcl). Debugging aid.

  mkwrap.py <file.vhd> <entity> <out.vhd>
"""
import re
import sys

src, name, dst = sys.argv[1:4]
s = open(src).read()
s = re.sub(r'--[^\n]*', '', s)
m = re.search(r'entity\s+%s\s+is(.*?)end\s*(entity)?\s*%s?\s*;' % (name, name), s, re.S | re.I)
ent = m.group(1)
pm = re.search(r'\bport\s*\((.*)\)\s*;\s*$', ent, re.S | re.I)
body = pm.group(1)
gm = re.search(r'\bgeneric\s*\((.*?)\)\s*;\s*port', ent, re.S | re.I)
decls = [d.strip() for d in body.split(';') if d.strip()]
ports = []
for d in decls:
    names, rest = d.split(':', 1)
    for n in names.split(','):
        ports.append((n.strip(), rest.strip()))
lines = ['library ieee;', 'use ieee.std_logic_1164.all;', 'use ieee.numeric_std.all;',
         'use ieee.std_logic_unsigned.all;',
         'entity %s_wrap is' % name]
if gm:
    lines.append('generic(%s);' % gm.group(1))
lines.append('port(')
lines.append(';\n'.join('   w_%s : %s' % (n, re.sub(r':=.*$', '', r, flags=re.S)) for n, r in ports))
lines.append(');')
lines.append('end entity;')
lines.append('architecture a of %s_wrap is' % name)
lines.append('begin')
lines.append('   i : entity work.%s port map (' % name)
lines.append(',\n'.join('      %s => w_%s' % (n, n) for n, r in ports))
lines.append('   );')
lines.append('end architecture;')
open(dst, 'w').write('\n'.join(lines) + '\n')
print(len(ports), "ports")
