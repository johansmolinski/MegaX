#!/usr/bin/env python3
# MegaX simulation: repairs a naming collision in ghdl's Verilog output (ghdl 5.0.1).
#
# ghdl names the net of an instance output "<instance>_<port>" (A). When the VHDL
# architecture also has a signal of exactly that name (B) - X68K_top: instance
# "spreg", port "ypos", signal "spreg_ypos"; KBCONV: instance "kb", port "rxed",
# signal "KB_RXED" - both are declared under one name, which Verilog merges into
# one net (B can also be a port of the module). A is used in exactly three places:
#     wire X;                                   (its declaration, the second one)
#     <inst> ( ... .<port>(X) ... );            (the instance drives it)
#     assign <inst>_n<digits> = X; // (signal)  (ghdl's alias reads it)
# Those three are renamed to X__io; every other use of X is B. An instance output
# left open (".port()") leaves only the declaration, which is renamed alone. A and B can be the
# same VHDL signal through the alias (spreg) or different signals (kb): both stay
# correct. A duplicate that does not show this shape stops the build.
#
# usage: fix_dups.py <in.v> <out.v>
import re, sys

DECL = re.compile(r'^(\s*(?:wire|reg)\b[^;]*?\b)(\w+);')
PORT = re.compile(r'^\s*(?:\(\s*)?(?:input|output|inout)\b[^,;()]*?\b(\w+)\s*[,)]')
LABEL = re.compile(r'^\s+(?:\w+\s+)?(\w+)\s*\($')

def fix_module(lines, name):
    seen, dups = {}, {}
    for i, l in enumerate(lines):
        p = PORT.match(l)
        if p and i < 400 and p.group(1) not in seen:   # module header: ports are declarations too
            seen[p.group(1)] = i
            continue
        m = DECL.match(l)
        if m:
            if m.group(2) in seen:
                dups[m.group(2)] = i
            else:
                seen[m.group(2)] = i
    for x, decl in dups.items():
        new = x + '__io'
        port_hits, labels, label = [], [], None
        for i, l in enumerate(lines):
            m = LABEL.match(l)
            if m:
                label = m.group(1)
            m = re.match(r'^\s*\.(\w+)\(%s\)[,)]' % re.escape(x), l)
            if m and label and label + '_' + m.group(1) == x:
                port_hits.append(i)
                labels.append(label)
        alias_hits = [i for i, l in enumerate(lines) if labels and
                      re.match(r'^\s*assign %s_n\d+ = %s; // \(signal\)' % (re.escape(labels[0]), re.escape(x)), l)]
        # an instance output left open (".port()"): its net is declared, never used
        unused = not port_hits and not alias_hits
        if not unused and (len(port_hits) != 1 or len(alias_hits) != 1):
            sys.exit('fix_dups.py: %s: duplicate %s: %d instance outputs, %d alias reads (expected 1 and 1)'
                     % (name, x, len(port_hits), len(alias_hits)))
        lines[decl] = DECL.sub(lambda m: m.group(1) + new + ';', lines[decl], count=1)
        for i in port_hits + alias_hits:
            lines[i] = re.sub(r'(?<![\w$])%s(?![\w$])' % re.escape(x), new, lines[i])
    return lines, len(dups)

def main(src, dst):
    out, mod, name, total = [], [], None, 0
    for line in open(src):
        if line.startswith('module '):
            name = line.split()[1]
            mod = [line]
        elif name is not None:
            mod.append(line)
            if line.startswith('endmodule'):
                fixed, n = fix_module(mod, name)
                out.extend(fixed)
                total += n
                name = None
        else:
            out.append(line)
    open(dst, 'w').writelines(out)
    print('fix_dups.py: %d instance-output nets renamed' % total)
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
