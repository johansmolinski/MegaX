#!/usr/bin/env python3
# MegaX simulation: a 2HD XDF image (77 cylinders x 2 heads x 8 sectors x 1024 bytes
# = 1261568 bytes) with the given boot sector at the start and zeros elsewhere.
# usage: mkxdf.py <boot.bin> <out.xdf>
import sys

SIZE = 77 * 2 * 8 * 1024

def main(src, dst):
    boot = open(src, 'rb').read()
    if len(boot) > 1024:
        sys.exit('mkxdf.py: boot sector is %d bytes, at most 1024' % len(boot))
    open(dst, 'wb').write(boot + bytes(SIZE - len(boot)))
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
