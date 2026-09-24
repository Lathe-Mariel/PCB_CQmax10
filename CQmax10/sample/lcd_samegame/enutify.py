from PIL import Image
import glob

LOGO_WIDTH = 20
LOGO_HEIGHT = 20


def rgb565(r,g,b):
    return ((r>>3)<<11) | ((g>>2)<<5) | (b>>3)


with open("logo_rom.hex", "w") as fout:

    for filename in sorted(glob.glob("logo*.png")):

        img = Image.open(filename).convert("RGB")

        if img.size != (20,20):
            raise RuntimeError(
                f"{filename}: must be 20x20"
            )

        print("adding", filename)

        for y in range(20):
            for x in range(20):

                r,g,b = img.getpixel((x,y))

                fout.write(
                    f"{rgb565(r,g,b):04X}\n"
                )