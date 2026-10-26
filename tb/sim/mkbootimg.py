#!/usr/bin/env python3
# MegaX simulation: MiSTer's boot.rom as a $readmemh image of the SDRAM model.
#
# boot.rom is the 1 MB image of F00000-FFFFFF (CGROM, a zero hole, IPL ROM). The
# core's loader writes it big-endian into RAM word address 0x780000 + n
# (X68mmapCV.vhd: rom_base; ldr_addr(0) = 0 -> upper byte). SDRAMC maps a word
# address W to bank W[23:22], row W[21:9], column W[8:0] (CAWIDTH 9, column bit 9
# = 0); the model (sdram_chip.sv) indexes {bank, row, column[9:0]}.
#
# usage: mkbootimg.py <boot.rom> <out.hex>
import sys

ROM_BASE = 0x780000            # word address of F00000

def model_index(w):
    return ((w >> 22) & 3) << 23 | ((w >> 9) & 0x1FFF) << 10 | (w & 0x1FF)

def main(src, dst):
    rom = open(src, 'rb').read()
    if len(rom) != 1 << 20:
        sys.exit('mkbootimg.py: %s is %d bytes, expected 1 MB' % (src, len(rom)))
    with open(dst, 'w') as f:
        last = None
        for n in range(len(rom) // 2):
            idx = model_index(ROM_BASE + n)
            if idx != last:
                f.write('@%x\n' % idx)
            f.write('%02x%02x\n' % (rom[2 * n], rom[2 * n + 1]))
            last = idx + 1
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
