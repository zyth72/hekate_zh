#!/usr/bin/env python3
"""Append glyphs to an LVGL v6 sparse font file (as used by Nyx).

Nyx fonts are stored in the LVGL v6 "sparse" layout:

    static const uint8_t  glyph_bitmap[]   // cells of w_px * h_px bytes, 8bpp, row major
    static const lv_font_glyph_dsc_t glyph_dsc[]   // {w_px, glyph_index}
    static const uint32_t unicode_list[]   // sorted codepoints + 0 terminator

Glyph cells are always full height (h_px) with the ink baked in at its
baseline position, and the cell width is the advance width, so both the
vertical position and the advance come from the rendered font.

Glyph bitmaps are produced by lv_font_conv in its "dump" format (one
grayscale PNG per glyph plus font_info.json with FreeType metrics):

    lv_font_conv --bpp 8 --size 23 --font NotoSansSC-Regular.otf \
        --symbols "、。！？" --format dump --no-compress -o dumpdir

This script then places every rendered bitmap into a full height cell, so
it can be appended to an existing font without re-generating the font.

Examples:
  # 30px font: render at 23px, baseline on row 23
  tools/gen_lvgl6_glyphs.py --font-c bdk/libs/lvgl/lv_fonts/harmony_os_sans_30.c \
      --dump /tmp/dump23 --baseline 23 --chars "、。，！？：；（）"

  # mono font: cells are snapped to a multiple of the 10px mono cell
  tools/gen_lvgl6_glyphs.py --font-c bdk/libs/lvgl/lv_fonts/ubuntu_mono.c \
      --dump /tmp/dump15 --baseline 15 --mono-base 10 --chars "、。，！？"
"""

import argparse
import json
import os
import re
import struct
import sys
import zlib

# ---------------------------------------------------------------- PNG reader
def read_png_gray(path):
    """Decode an 8 bit PNG (grayscale, RGB or RGBA, no interlacing).

    Returns rows of raw gray values. lv_font_conv "dump" renders glyphs as
    dark ink on a light background, so callers invert them (255 - v)."""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('%s: not a PNG' % path)

    pos = 8
    width = height = None
    idat = b''
    while pos < len(data):
        length, ctype = struct.unpack('>I4s', data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b'IHDR':
            width, height, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', chunk)
            if depth != 8 or color not in (0, 2, 4, 6) or interlace != 0:
                raise ValueError('%s: unsupported PNG (depth %d, color %d, interlace %d)'
                                 % (path, depth, color, interlace))
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'IEND':
            break

    raw = zlib.decompress(idat)
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[color]     # bytes per pixel
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        ftype = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ftype == 1:      # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:    # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:    # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ftype != 0:
            raise ValueError('%s: unknown PNG filter %d' % (path, ftype))
        rows.append(bytes(line[0::bpp]) if bpp != 1 else bytes(line))
        prev = line
    return width, height, rows


# ------------------------------------------------------------- font file I/O
class FontC:
    """Parse and rewrite the three arrays of a Nyx LVGL v6 font file."""

    def __init__(self, path):
        self.path = path
        self.src = open(path, encoding='utf-8', newline='').read()
        self.eol = '\r\n' if '\r\n' in self.src else '\n'

        m = re.search(r'static const uint8_t (\w+)\[\]\s*=\s*\{(.*?)\n\};', self.src, re.S)
        if not m:
            raise ValueError('%s: glyph_bitmap array not found' % path)
        self.bmp_name, self.bmp_body = m.group(1), m.group(2)
        self.bmp_start, self.bmp_end = m.start(2), m.end(2)

        m = re.search(r'static const lv_font_glyph_dsc_t (\w+)\[\]\s*=\s*\{(.*?)\n\};', self.src, re.S)
        if not m:
            raise ValueError('%s: glyph_dsc array not found' % path)
        self.dsc_body = m.group(2)
        self.dsc_start, self.dsc_end = m.start(2), m.end(2)

        m = re.search(r'static const uint32_t (\w+)\[\]\s*=\s*\{(.*?)\n\};', self.src, re.S)
        if not m:
            raise ValueError('%s: unicode_list array not found' % path)
        self.uni_body = m.group(2)
        self.uni_start, self.uni_end = m.start(2), m.end(2)

        self.bitmap = bytes(int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{2})', self.bmp_body))
        self.dsc = [(int(w), int(i)) for w, i in
                    re.findall(r'\{\.w_px = (\d+),\s*\.glyph_index = (\d+)\}', self.dsc_body)]
        self.uni = [int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]+)', self.uni_body)]

        m = re.search(r'\.h_px\s*=\s*(\d+)', self.src)
        self.h_px = int(m.group(1)) if m else None
        m = re.search(r'\.unicode_last\s*=\s*(\d+)', self.src)
        self.unicode_last = int(m.group(1)) if m else None
        self.added = []

    def verify(self):
        if self.uni[-1] != 0:
            raise ValueError('unicode_list has no 0 terminator')
        if len(self.dsc) != len(self.uni) - 1:
            raise ValueError('glyph_dsc (%d) and unicode_list (%d) mismatch'
                             % (len(self.dsc), len(self.uni) - 1))
        expect = 0
        for w, idx in self.dsc:
            if idx != expect:
                raise ValueError('glyph_index gap: expected %d, got %d' % (expect, idx))
            expect += w * self.h_px
        if expect != len(self.bitmap):
            raise ValueError('bitmap size mismatch: %d vs %d' % (expect, len(self.bitmap)))

    def coverage(self):
        return set(c for c in self.uni if c)

    def add_glyph(self, code, w_px, cell):
        if code in self.coverage():
            return False
        offset = len(self.bitmap)
        self.bitmap += cell
        self.dsc.append((w_px, offset))
        self.uni.insert(len(self.uni) - 1, code)
        self.added.append((code, w_px, offset, cell))
        return True

    def write(self, out_path=None):
        """Append the new glyphs to the file, leaving the existing text as is."""
        out_path = out_path or self.path

        bmp_lines = ['', '/* Glyphs added by tools/gen_lvgl6_glyphs.py */']
        dsc_lines = ['']
        uni_lines = []
        for code, w_px, offset, cell in self.added:
            bmp_lines.append('/* %s */' % chr(code))
            for r in range(self.h_px):
                row = cell[r * w_px:(r + 1) * w_px]
                bmp_lines.append(','.join('0x%02x' % b for b in row) + ',  //' + '.' * len(row))
            dsc_lines.append('    {.w_px = %d,\t.glyph_index = %d},/*(%s)*/'
                             % (w_px, offset, chr(code)))
            uni_lines.append('    0x%04x,\t/*(%s)*/' % (code, chr(code)))

        src = self.src
        # Bitmap and dsc entries go right before their closing brace.
        src = src[:self.bmp_end] + self.eol.join(bmp_lines) + self.eol + src[self.bmp_end:]
        delta = len(src) - len(self.src)
        src = src[:self.dsc_end + delta] + self.eol.join(dsc_lines) + self.eol + src[self.dsc_end + delta:]
        delta = len(src) - len(self.src)
        # Codepoints go before the 0 terminator.
        terminator = src.rindex('0x0000,', self.uni_start + delta, self.uni_end + delta)
        src = src[:terminator] + self.eol.join(uni_lines) + self.eol + src[terminator:]

        if self.unicode_last is not None:
            want_last = max(code for code in self.uni if code)
            if want_last > self.unicode_last:
                src = re.sub(r'(\.unicode_last\s*=\s*)\d+',
                             lambda m: m.group(1) + str(want_last), src, count=1)

        open(out_path, 'w', encoding='utf-8', newline='').write(src)


# ----------------------------------------------------------------- rendering
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--font-c', required=True, help='font .c file to append to')
    ap.add_argument('--dump', required=True, help='lv_font_conv dump directory')
    ap.add_argument('--baseline', type=int, required=True, help='baseline row inside the cell')
    ap.add_argument('--chars', required=True, help='characters to add')
    ap.add_argument('--mono-base', type=int, default=0,
                    help='snap cell widths to a multiple of this (monospace fonts)')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    info = json.load(open(os.path.join(args.dump, 'font_info.json'), encoding='utf-8'))
    metrics = {g['code']: g for g in info['glyphs']}

    font = FontC(args.font_c)
    font.verify()
    old_cov = font.coverage()
    old_size = len(font.bitmap)
    print('%s: h_px=%d, glyphs=%d, bitmap=%d bytes, unicode_last=%s'
          % (os.path.basename(args.font_c), font.h_px, len(font.dsc), len(font.bitmap),
             font.unicode_last))

    added = []
    rendered = []       # (code, coverage rows, metrics)
    for ch in args.chars:
        code = ord(ch)
        if code in old_cov:
            print('  skip U+%04X (%s): already present' % (code, ch))
            continue
        if code not in metrics:
            print('  skip U+%04X (%s): not rendered' % (code, ch))
            continue

        m = metrics[code]['freetype']['metrics']
        png = os.path.join(args.dump, '%x.png' % code)
        if not os.path.exists(png):
            png = os.path.join(args.dump, '%04x.png' % code)
        _w, _h, gray = read_png_gray(png)
        cov = [[255 - v for v in row] for row in gray]
        rendered.append((code, cov, m))

    if not rendered:
        print('nothing to add')
        return

    # The dump renders each glyph inside the line box; the row the baseline sits
    # on is found from the ink top and the ink height above the baseline.
    baselines = []
    for code, cov, m in rendered:
        ink = [r for r in range(len(cov)) if any(v > 8 for v in cov[r])]
        if ink:
            baselines.append(ink[0] + m['horiBearingY'] - 1)
    png_baseline = max(set(baselines), key=baselines.count) if baselines else 0
    print('dump baseline row: %d (cell baseline: %d)' % (png_baseline, args.baseline))
    shift = args.baseline - png_baseline

    for code, cov, m in rendered:
        adv, bsx = m['horiAdvance'], m['horiBearingX']
        w_ink, h_ink = m['width'], m['height']

        cell_w = max(w_ink + bsx, int(round(adv)))
        if args.mono_base:
            cell_w = max(1, int(round(adv / args.mono_base))) * args.mono_base
            cell_w = max(cell_w, bsx + w_ink)

        top = shift
        if top < 0 or top + len(cov) > font.h_px:
            raise ValueError('U+%04X: ink rows %d..%d outside 0..%d'
                             % (code, top, top + len(cov) - 1, font.h_px - 1))

        cell = bytearray(cell_w * font.h_px)
        for r, row in enumerate(cov):
            base = (top + r) * cell_w + bsx
            cell[base:base + len(row)] = bytes(row)

        font.add_glyph(code, cell_w, bytes(cell))
        added.append((code, cell_w))

    if not added:
        print('nothing to add')
        return

    font.verify()
    new_cov = font.coverage()
    print('added %d glyphs, bitmap now %d bytes (+%d), unicode_last -> %d'
          % (len(added), len(font.bitmap), len(font.bitmap) - old_size, max(new_cov)))

    for code, w in added:
        print('  + U+%04X %s w_px=%d' % (code, chr(code), w))

    if args.dry_run:
        print('dry run: not writing')
        return
    font.write()
    print('wrote %s' % args.font_c)


if __name__ == '__main__':
    sys.exit(main())
