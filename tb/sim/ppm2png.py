#!/usr/bin/env python3
# MegaX simulation: converts the frame dumps (binary PPM) to PNG, standard library only.
# usage: ppm2png.py <frame.ppm>... (writes <frame>.png next to each)
import struct, sys, zlib

def read_ppm(path):
    data = open(path, 'rb').read()
    parts, pos = [], 0
    while len(parts) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        parts.append(data[pos:end])
        pos = end
    if parts[0] != b'P6':
        raise ValueError(path + ': not a binary PPM')
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[pos + 1:pos + 1 + w * h * 3]

def write_png(path, w, h, rgb):
    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body))
    raw = b''.join(b'\0' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)

def main(paths):
    for p in paths:
        w, h, rgb = read_ppm(p)
        out = p[:-4] + '.png' if p.endswith('.ppm') else p + '.png'
        write_png(out, w, h, rgb)
        print(out)
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
