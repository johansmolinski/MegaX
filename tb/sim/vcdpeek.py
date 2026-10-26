#!/usr/bin/env python3
# MegaX simulation: prints selected signals from a VCD (sim --trace), one line per
# time at which any of them changes.
#
# usage: vcdpeek.py <file.vcd> <regex>... [--from <ms>] [--to <ms>] [--list]
#   regexes match the full dotted name (x68_system.i_core.ram.cachec.ram_state);
#   --list prints the matching names only. Values in hex, x for unknown bits.
import re, sys

def main(argv):
    path, pats, t_from, t_to, list_only = argv[0], [], 0.0, 1e18, False
    i = 1
    while i < len(argv):
        if argv[i] == '--from':
            t_from = float(argv[i + 1]) * 1e9; i += 2       # ms -> ps
        elif argv[i] == '--to':
            t_to = float(argv[i + 1]) * 1e9; i += 2
        elif argv[i] == '--list':
            list_only = True; i += 1
        else:
            pats.append(re.compile(argv[i])); i += 1
    f = open(path)
    scope, ids, names, width = [], {}, [], {}
    for line in f:
        tok = line.split()
        if not tok:
            continue
        if tok[0] == '$scope':
            scope.append(tok[2])
        elif tok[0] == '$upscope':
            scope.pop()
        elif tok[0] == '$var':
            w, code, name = int(tok[2]), tok[3], tok[4]
            full = '.'.join(scope + [name])
            if any(p.search(full) for p in pats) and full not in names:
                ids.setdefault(code, []).append(full)
                names.append(full)
                width[full] = w
        elif tok[0] == '$enddefinitions':
            break
    if list_only:
        for n in names:
            print(n, width[n])
        return 0
    if not names:
        sys.exit('vcdpeek.py: no signal matches')
    short = [n.split('.')[-1] if sum(m.split('.')[-1] == n.split('.')[-1] for m in names) == 1
             else '.'.join(n.split('.')[-2:]) for n in names]
    print('#', ' '.join('%d=%s' % (k, s) for k, s in enumerate(short)))
    val = {n: 'x' for n in names}
    t, changed = 0, False

    def emit():
        if t_from <= t <= t_to:
            print('%12.6f' % (t / 1e9), ' '.join(val[n] for n in names))

    def hexval(bits, w):
        bits = bits.rjust(w, bits[0] if bits[0] in 'xz' else '0')
        if any(c in 'xz' for c in bits):
            return 'x' * ((w + 3) // 4)
        return '%0*x' % ((w + 3) // 4, int(bits, 2))

    for line in f:
        if not line:
            continue
        c = line[0]
        if c == '#':
            if changed:
                emit()
            t = int(line[1:])
            changed = False
            if t > t_to:
                break
        elif c in '01xz':
            code = line[1:].strip()
            for n in ids.get(code, ()):
                val[n] = hexval(c, width[n]); changed = True
        elif c == 'b':
            bits, code = line[1:].split()
            for n in ids.get(code, ()):
                val[n] = hexval(bits, width[n]); changed = True
    if changed:
        emit()
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
