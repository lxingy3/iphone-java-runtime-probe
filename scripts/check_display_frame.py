#!/usr/bin/env python3
"""Compare an sRGB Simulator capture with the fixture's encoded Metal pixel.

Use PNG samples directly: AppKit's device-color conversion can apply another
display transform even when simctl already wrote sRGB-encoded samples.
"""
import json
from pathlib import Path
import struct
import sys
import zlib


def center_pixel(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Not a PNG capture')
    offset, chunks = 8, {}
    while offset < len(data):
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from('>I', data, offset + 8 + size)[0]
        if zlib.crc32(kind + body) & 0xffffffff != crc:
            raise ValueError('PNG checksum mismatch')
        chunks.setdefault(kind, []).append(body)
        offset += size + 12
        if kind == b'IEND':
            break
    width, height, bits, kind, compression, filtering, interlace = struct.unpack('>IIBBBBB', chunks[b'IHDR'][0])
    if bits != 8 or kind not in (2, 6) or compression or filtering or interlace:
        raise ValueError('Expected an 8-bit noninterlaced RGB or RGBA capture')
    if b'sRGB' not in chunks or b'iCCP' in chunks:
        raise ValueError('Capture is not explicitly sRGB; color conversion is required')
    channels = 4 if kind == 6 else 3
    raw = zlib.decompress(b''.join(chunks[b'IDAT']))
    stride = width * channels
    if len(raw) != height * (stride + 1):
        raise ValueError('Incorrect PNG data length')
    end = (width // 2 + 1) * channels
    previous = bytearray(end)
    for y in range(height // 2 + 1):
        start = y * (stride + 1)
        mode = raw[start]
        row = bytearray(raw[start + 1:start + 1 + end])
        if mode not in range(5):
            raise ValueError('Unknown PNG row filter')
        if mode:
            for x in range(end):
                left = row[x - channels] if x >= channels else 0
                up = previous[x]
                corner = previous[x - channels] if x >= channels else 0
                if mode == 1:
                    predictor = left
                elif mode == 2:
                    predictor = up
                elif mode == 3:
                    predictor = (left + up) // 2
                else:
                    p = left + up - corner
                    distances = (abs(p-left), abs(p-up), abs(p-corner))
                    predictor = (left, up, corner)[distances.index(min(distances))]
                row[x] = (row[x] + predictor) & 255
        previous = row
    pixel = list(previous[-channels:])
    if channels == 4 and pixel[3] != 255:
        raise ValueError('Fixture pixel is not opaque')
    return pixel[:3], [width, height]


if __name__ == '__main__':
    try:
        rgb, size = center_pixel(sys.argv[1])
        expected = [int(sys.argv[2]), int(sys.argv[3]), 0]
        passed = all(abs(a-b) <= 4 for a, b in zip(rgb, expected))
        print(json.dumps(dict(passed=passed, rgb=rgb, expected=expected, size=size, encoding='PNG sRGB')))
        sys.exit(0 if passed else 1)
    except Exception as error:
        print(json.dumps(dict(passed=False, error=str(error))))
        sys.exit(2)
