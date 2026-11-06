#!/usr/bin/env python3
# Makes assets/shifu-icon-*.png: a blue DOS screen in a gold double frame
# with "C:\>" and a cursor, drawn with Shifu's own CP865 font.
import re
from PIL import Image, ImageDraw
src = open("pc/font.ha", encoding="utf-8").read()
font = [[int(v, 16) for v in re.findall(r"0x([0-9a-f]{2})", line)]
        for line in src.splitlines() if line.startswith("\t[")]
base = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
d = ImageDraw.Draw(base)
d.rounded_rectangle((2, 2, 61, 61), 9, fill=(0, 0, 170, 255))
gold = (255, 255, 85, 255)
for r in ((6, 6, 57, 57), (9, 9, 54, 54)):
    d.rectangle(r, outline=gold)
def glyph(ch, x, y, col):
    for gy, bits in enumerate(font[ch]):
        for gx in range(8):
            if bits & (0x80 >> gx): base.putpixel((x + gx, y + gy), col)
x = 14
for ch in b"C:\\>":
    glyph(ch, x, 22, (255, 255, 255, 255))
    x += 8
for yy in (35, 36): 
    for xx in range(x, x + 7): base.putpixel((xx, yy), gold)
for s in (16, 24, 32, 48, 64, 128, 256):
    img = base.resize((s, s), Image.NEAREST if s % 64 == 0 or s > 64 else Image.LANCZOS)
    img.save("assets/shifu-icon-%d.png" % s)
