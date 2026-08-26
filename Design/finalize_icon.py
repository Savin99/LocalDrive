"""Подготовка сгенерированной картинки под иконку iOS.

Модель рисует скруглённый квадрат со светлыми уголками, а iOS маскирует иконку
сам — поэтому уголки надо залить фоном, иначе выйдет двойное скругление.
"""

import sys
from PIL import Image

src_path, out_path = sys.argv[1], sys.argv[2]

im = Image.open(src_path).convert("RGB")
W, H = im.size

# Растягиваем внутреннюю часть (без скруглённой рамки) на весь квадрат:
# так уголки заполняются продолжением фона, а не заливкой средним цветом.
INSET = 56
inner = im.crop((INSET, INSET, W - INSET, H - INSET)).resize((W, H), Image.LANCZOS)

# Проверяем, что светлых уголков не осталось
for x, y in [(2, 2), (W - 3, 2), (2, H - 3), (W - 3, H - 3)]:
    px = inner.getpixel((x, y))
    assert sum(px) / 3 < 220, f"угол {x},{y} всё ещё светлый: {px}"

inner.save(out_path)
print(
    f"{out_path}: {inner.size}, углы {inner.getpixel((2, 2))} / {inner.getpixel((W - 3, H - 3))}"
)
