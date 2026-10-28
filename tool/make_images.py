"""Black launch images and an app icon (the clock's "24" on a night sky) for the
iPad build, made from the rendered glyphs. Needs Pillow. Usage:
  python3 make_images.py <glyphs dir> <app bundle dir>
"""

import os
import sys

from PIL import Image

glyphs, app = sys.argv[1], sys.argv[2]

# Launch images: plain black, both ways up (iPad retina, 768×1024 points).
Image.new('RGB', (1536, 2048), 'black').save(os.path.join(app, 'Launch-Portrait@2x~ipad.png'))
Image.new('RGB', (2048, 1536), 'black').save(os.path.join(app, 'Launch-Landscape@2x~ipad.png'))
Image.new('RGB', (768, 1024), 'black').save(os.path.join(app, 'Launch-Portrait~ipad.png'))
Image.new('RGB', (1024, 768), 'black').save(os.path.join(app, 'Launch-Landscape~ipad.png'))

# Icon: a deep night-blue square with two of the clock's digits.
size = 512
icon = Image.new('RGBA', (size, size))
top, bottom = (11, 28, 64), (2, 3, 12)
for y in range(size):
    t = y / (size - 1)
    c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    icon.paste(c, (0, y, size, y + 1))
digits = Image.open(os.path.join(glyphs, 'digits_24.png')).convert('RGBA')
digits = digits.crop(digits.getbbox())  # just the ink
h = round(size * 0.43)
digits = digits.resize((round(digits.width * h / digits.height), h), Image.LANCZOS)
icon.alpha_composite(digits, ((size - digits.width) // 2, (size - h) // 2))
icon = icon.convert('RGB')
for px, name in [(76, 'AppIcon76x76~ipad.png'), (152, 'AppIcon76x76@2x~ipad.png'),
                 (167, 'AppIcon83.5x83.5@2x~ipad.png')]:
    icon.resize((px, px), Image.LANCZOS).save(os.path.join(app, name))
