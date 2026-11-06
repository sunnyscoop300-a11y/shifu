#!/usr/bin/env python3
# Makes pc/font.ha: the PC fonts for code page 865 (Nordic), 8x16 (VGA text,
# 480-line graphics) and 8x8 (200-line graphics, like CGA's ROM font).
# Box drawing, blocks and shades are drawn by rule so they join up exactly
# from cell to cell; the rest is rendered from DejaVu Sans Mono Bold (free
# licence). The 8x8 letters come from font8x8 by Daniel Hepper (public
# domain, tools/font8x8.txt); symbols it lacks are the 8x16 ones squeezed.
#	python3 tools/genfont.py [preview.png]
import sys
from PIL import Image, ImageDraw, ImageFont

CHARSET = (
    " ☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
    "`abcdefghijklmnopqrstuvwxyz{|}~⌂"
    "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜø£Ø₧ƒáíóúñÑªº¿⌐¬½¼¡«¤"
    "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
    "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ")
assert len(CHARSET) == 256, len(CHARSET)

FONTS = ["/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]

def render(ch, path, size=13, dy=0):
    f = ImageFont.truetype(path, size)
    img = Image.new("L", (8, 16), 0)
    ImageDraw.Draw(img).text((0, dy), ch, font=f, fill=255)
    return [[img.getpixel((x, y)) > 110 for x in range(8)] for y in range(16)]

def blank(h):
    return [[False] * 8 for _ in range(h)]

# Box drawing: each entry is a list of strokes. ("V", x, y0, y1) or
# ("H", y, x0, x1). y may be "A", "B", "C" (double-above, single, double-
# below lines) or "E" (bottom row); singles are at x=3, doubles at x=2,4.
BOX = {
    0xB3: [("V",3,0,"E")],
    0xB4: [("V",3,0,"E"), ("H","B",0,3)],
    0xB5: [("V",3,0,"E"), ("H","A",0,3), ("H","C",0,3)],
    0xB6: [("V",2,0,"E"), ("V",4,0,"E"), ("H","B",0,2)],
    0xB7: [("H","B",0,4), ("V",2,"B","E"), ("V",4,"B","E")],
    0xB8: [("H","A",0,3), ("H","C",0,3), ("V",3,"A","E")],
    0xB9: [("V",4,0,"E"), ("V",2,0,"A"), ("V",2,"C","E"), ("H","A",0,2), ("H","C",0,2)],
    0xBA: [("V",2,0,"E"), ("V",4,0,"E")],
    0xBB: [("H","A",0,4), ("V",4,"A","E"), ("H","C",0,2), ("V",2,"C","E")],
    0xBC: [("H","C",0,4), ("V",4,0,"C"), ("H","A",0,2), ("V",2,0,"A")],
    0xBD: [("H","B",0,4), ("V",2,0,"B"), ("V",4,0,"B")],
    0xBE: [("V",3,0,"C"), ("H","A",0,3), ("H","C",0,3)],
    0xBF: [("H","B",0,3), ("V",3,"B","E")],
    0xC0: [("V",3,0,"B"), ("H","B",3,7)],
    0xC1: [("H","B",0,7), ("V",3,0,"B")],
    0xC2: [("H","B",0,7), ("V",3,"B","E")],
    0xC3: [("V",3,0,"E"), ("H","B",3,7)],
    0xC4: [("H","B",0,7)],
    0xC5: [("V",3,0,"E"), ("H","B",0,7)],
    0xC6: [("V",3,0,"E"), ("H","A",3,7), ("H","C",3,7)],
    0xC7: [("V",2,0,"E"), ("V",4,0,"E"), ("H","B",4,7)],
    0xC8: [("V",2,0,"C"), ("H","C",2,7), ("V",4,0,"A"), ("H","A",4,7)],
    0xC9: [("V",2,"A","E"), ("H","A",2,7), ("V",4,"C","E"), ("H","C",4,7)],
    0xCA: [("H","C",0,7), ("V",2,0,"A"), ("H","A",0,2), ("V",4,0,"A"), ("H","A",4,7)],
    0xCB: [("H","A",0,7), ("V",2,"C","E"), ("H","C",0,2), ("V",4,"C","E"), ("H","C",4,7)],
    0xCC: [("V",2,0,"E"), ("V",4,0,"A"), ("H","A",4,7), ("V",4,"C","E"), ("H","C",4,7)],
    0xCD: [("H","A",0,7), ("H","C",0,7)],
    0xCE: [("V",2,0,"A"), ("H","A",0,2), ("V",4,0,"A"), ("H","A",4,7),
           ("V",2,"C","E"), ("H","C",0,2), ("V",4,"C","E"), ("H","C",4,7)],
    0xCF: [("H","A",0,7), ("H","C",0,7), ("V",3,0,"A")],
    0xD0: [("H","B",0,7), ("V",2,0,"B"), ("V",4,0,"B")],
    0xD1: [("H","A",0,7), ("H","C",0,7), ("V",3,"C","E")],
    0xD2: [("H","B",0,7), ("V",2,"B","E"), ("V",4,"B","E")],
    0xD3: [("V",2,0,"B"), ("V",4,0,"B"), ("H","B",2,7)],
    0xD4: [("V",3,0,"C"), ("H","A",3,7), ("H","C",3,7)],
    0xD5: [("V",3,"A","E"), ("H","A",3,7), ("H","C",3,7)],
    0xD6: [("H","B",2,7), ("V",2,"B","E"), ("V",4,"B","E")],
    0xD7: [("V",2,0,"E"), ("V",4,0,"E"), ("H","B",0,7)],
    0xD8: [("V",3,0,"E"), ("H","A",0,7), ("H","C",0,7)],
    0xD9: [("V",3,0,"B"), ("H","B",0,3)],
    0xDA: [("H","B",3,7), ("V",3,"B","E")],
}

def box(code, h):
    cy = 7 if h == 16 else 3
    ys = {"A": cy - 1, "B": cy, "C": cy + 1, "E": h - 1, 0: 0}
    g = blank(h)
    for kind, a, b, c in BOX[code]:
        if kind == "V":
            for y in range(ys.get(b, b), ys.get(c, c) + 1): g[y][a] = True
        else:
            for x in range(b, c + 1): g[ys.get(a, a)][x] = True
    return g

def fill(g, x0, y0, x1, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1): g[y][x] = True
    return g

def pattern(rows, h):
    return [[bool(rows[y % len(rows)] & (0x80 >> x)) for x in range(8)] for y in range(h)]

def drawn(code, h):
    half = h // 2
    if code in BOX: return box(code, h)
    if code == 0xB0: return pattern([0x22, 0x88], h)
    if code == 0xB1: return pattern([0x55, 0xAA], h)
    if code == 0xB2: return pattern([0xDD, 0x77], h)
    if code == 0xDB: return fill(blank(h), 0, 0, 7, h - 1)
    if code == 0xDC: return fill(blank(h), 0, half, 7, h - 1)
    if code == 0xDD: return fill(blank(h), 0, 0, 3, h - 1)
    if code == 0xDE: return fill(blank(h), 4, 0, 7, h - 1)
    if code == 0xDF: return fill(blank(h), 0, 0, 7, half - 1)
    if code == 0xFE: return fill(blank(h), 1, h // 4, 6, h * 11 // 16)   # ■
    if code == 0x16: return fill(blank(h), 0, h * 9 // 16, 7, h * 12 // 16)  # ▬
    if code in (0x08, 0x0A):                                             # ◘ ◙
        g = fill(blank(h), 0, 0, 7, h - 1)
        c = h * 6 // 16
        hole = [(3,c),(4,c),(2,c+1),(5,c+1),(2,c+2),(5,c+2),(3,c+3),(4,c+3)] if code == 0x0A \
            else [(x, y) for y in range(c, c + 4) for x in range(2, 6)
                  if not ((y in (c, c + 3)) and x in (2, 5))]
        for x, y in hole:
            if y < h: g[y][x] = False
        return g
    return None

missing = render("", FONTS[0])
def text16(code, ch):
    if code in (0, 0x20, 0xFF): return blank(16)
    dy = -2 if (ch.isupper() and not ch.isascii() and ch not in "ΓΣΦΘΩ") else 0
    for path in FONTS:
        g = render(ch, path, 13, dy)
        if g != missing: break
    return g

def squeeze(g16):
    # 8x16 -> 8x8: the glyphs use rows 2-15; OR each pair of rows.
    out = blank(8)
    for y in range(8):
        for x in range(8):
            r0 = 2 * y + 1
            out[y][x] = g16[r0][x] or (r0 + 1 < 16 and g16[r0 + 1][x])
    return out

import os
F8X8 = {}
for line in open(os.path.join(os.path.dirname(__file__), "font8x8.txt")):
    if line.startswith("U+"):
        parts = line.split()
        rows8 = [int(v, 16) for v in parts[1:]]
        F8X8[int(parts[0][2:], 16)] = [[bool(r & (1 << x)) for x in range(8)] for r in rows8]

f16, f8 = [], []
for code, ch in enumerate(CHARSET):
    g = drawn(code, 16)
    f16.append(g if g is not None else text16(code, ch))
    g = drawn(code, 8)
    if g is None and code not in (0, 0xFF): g = F8X8.get(ord(ch))
    f8.append(g if g is not None else
              (blank(8) if code in (0, 0xFF) else squeeze(text16(code, ch))))

def rows(g):
    return [sum(0x80 >> x for x in range(8) if r[x]) for r in g]

out = ["// Generated by tools/genfont.py: the PC fonts for code page 865",
       "// (Nordic). Box drawing, blocks and shades are drawn by rule; the rest",
       "// comes from DejaVu Sans Mono Bold (free licence). Bit 7 is the",
       "// leftmost pixel.", "",
       "// 8x16, for text mode and 480-line graphics (like a VGA card's).",
       "export const FONT16: [256][16]u8 = ["]
for code, g in enumerate(f16):
    name = CHARSET[code] if CHARSET[code].strip() else "space"
    out.append("\t[" + ", ".join("0x%02x" % r for r in rows(g)) + "], // %02X %s" % (code, name))
out += ["];", "", "// 8x8, for 200-line graphics (like the CGA ROM font).",
        "export const FONT8: [256][8]u8 = ["]
for code, g in enumerate(f8):
    name = CHARSET[code] if CHARSET[code].strip() else "space"
    out.append("\t[" + ", ".join("0x%02x" % r for r in rows(g)) + "], // %02X %s" % (code, name))
out.append("];")
open("pc/font.ha", "w", encoding="utf-8").write("\n".join(out) + "\n")

if len(sys.argv) > 1:
    s = 3
    img = Image.new("RGB", (16 * 9 * s * 2, 16 * 17 * s), (0, 0, 170))
    for font, ox, h in ((f16, 0, 16), (f8, 16 * 9 * s, 8)):
        for code, g in enumerate(font):
            cx, cy = ox + (code % 16) * 9 * s, (code // 16) * 17 * s
            for y in range(h):
                for x in range(8):
                    if g[y][x]:
                        img.paste((255, 255, 85), (cx + x*s, cy + y*s, cx + x*s + s, cy + y*s + s))
    img.save(sys.argv[1])
