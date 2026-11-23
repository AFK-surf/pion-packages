"""Write the JPEG fixtures used by the red-team run (PIL): 16x8 gray, RGB, Adobe CMYK, progressive RGB."""
import sys
from PIL import Image

out = sys.argv[1]
w, h = 16, 8
rgb = Image.new("RGB", (w, h))
for y in range(h):
    for x in range(w):
        rgb.putpixel((x, y), (x * 16, y * 32, 200))
rgb.convert("L").save(f"{out}/gray.jpg", quality=90)
rgb.save(f"{out}/rgb.jpg", quality=90)
# Pure cyan in CMYK: PIL (like Photoshop) writes an Adobe APP14 marker and *inverted* CMYK samples.
Image.new("CMYK", (w, h), (255, 0, 0, 0)).save(f"{out}/cmyk.jpg", quality=95)
rgb.save(f"{out}/prog.jpg", quality=90, progressive=True)
print("jpegs written to", out)
