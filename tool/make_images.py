"""Black launch images and an app icon (Nabla "24" on a night sky) for the
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

# Icon: a deep night-blue square with two Nabla digits.
size = 512
icon = Image.new('RGBA', (size, size))
top, bottom = (11, 28, 64), (2, 3, 12)
for y in range(size):
    t = y / (size - 1)
    c = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
    icon.paste(c, (0, y, size, y + 1))
two = Image.open(os.path.join(glyphs, 'day_32.png')).convert('RGBA')
four = Image.open(os.path.join(glyphs, 'day_34.png')).convert('RGBA')
scale = 0.95
two = two.resize((round(two.width * scale), round(two.height * scale)), Image.LANCZOS)
four = four.resize((round(four.width * scale), round(four.height * scale)), Image.LANCZOS)
pad = round(400 * 0.3 * scale)
adv = round(208 * scale)
x0 = (size - 2 * adv) // 2 - pad
y0 = (size - round(400 * scale)) // 2 - pad
icon.alpha_composite(two, (x0, y0))
icon.alpha_composite(four, (x0 + adv, y0))
icon = icon.convert('RGB')
for px, name in [(76, 'AppIcon76x76~ipad.png'), (152, 'AppIcon76x76@2x~ipad.png'),
                 (167, 'AppIcon83.5x83.5@2x~ipad.png')]:
    icon.resize((px, px), Image.LANCZOS).save(os.path.join(app, name))
