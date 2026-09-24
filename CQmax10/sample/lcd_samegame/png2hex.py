#!/usr/bin/env python3

from PIL import Image
import sys
import os

LOGO_WIDTH = 20
LOGO_HEIGHT = 20


def rgb888_to_rgb565(r, g, b):
    r5 = (r >> 3) & 0x1F
    g6 = (g >> 2) & 0x3F
    b5 = (b >> 3) & 0x1F

    return (r5 << 11) | (g6 << 5) | b5


def convert_png_to_hex(infile, outfile):

    img = Image.open(infile).convert("RGB")

    if img.size != (LOGO_WIDTH, LOGO_HEIGHT):
        raise ValueError(
            f"Image size must be "
            f"{LOGO_WIDTH}x{LOGO_HEIGHT}, "
            f"but got {img.size}"
        )

    with open(outfile, "w") as f:
        for y in range(LOGO_HEIGHT):
            for x in range(LOGO_WIDTH):

                r, g, b = img.getpixel((x, y))

                rgb565 = rgb888_to_rgb565(r, g, b)

                f.write(f"{rgb565:04X}\n")


def main():

    if len(sys.argv) != 3:
        print(
            "Usage:\n"
            "  python png2hex.py input.png output.hex"
        )
        sys.exit(1)

    infile = sys.argv[1]
    outfile = sys.argv[2]

    convert_png_to_hex(infile, outfile)

    print(f"Generated {outfile}")


if __name__ == "__main__":
    main()