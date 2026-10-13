"""图标导入的共用处理。

`dematt()`：去掉图案外圈那 1px **浅色毛边（matte）**。

素材包里的图标是从某个工具里抠出来的，抠完之后轮廓上留了一圈**浅灰褐色**的
不透明像素 —— 在深色底（顶栏）上看着就是一圈白边。特征很明显：

    population 的 (121,105,93)：53 个像素里 51 个都贴着透明区
    money      的 (128,109,94)：54 个里 53 个
    resource   的 (233,232,232)：19 个里 19 个

判据（同时满足才删）：
  1. 是**边缘像素**（四邻里有透明的）—— 这一条把图案内部的浅色（黄脸、白眼睛、
     金色高光）排除掉，它们不在轮廓上
  2. **低饱和**（max-min <= 40）—— 排除蓝色衣服那种彩色描边
  3. **够亮**（亮度 >= 90）—— 排除深棕色那种**真正的**美术描边（如 (69,40,16)）

迭代若干轮，2px 厚的毛边也能清干净。删掉后露出的是美术自带的深色描边，
所以轮廓看起来是对的，只是不再发白。
"""
from PIL import Image

# 阈值：见模块开头的说明
MAX_CHROMA = 40
MIN_LUMA = 90
MAX_PASSES = 4


def _is_matte(rgb):
    r, g, b = rgb
    chrona = max(r, g, b) - min(r, g, b)
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    return chrona <= MAX_CHROMA and luma >= MIN_LUMA


def dematt(im):
    """返回去掉外圈浅色毛边后的新图（不改原图）。全透明像素的 RGB 也清成 0。"""
    im = im.convert('RGBA')
    w, h = im.size
    px = im.load()

    # 透明像素的 RGB 归零：素材里是 (255,255,255,0)，白底残留。
    # 项目现在用 Nearest 过滤所以看不出来，但换个缩放模式就会渗白边。
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                px[x, y] = (0, 0, 0, 0)

    removed = 0
    for _ in range(MAX_PASSES):
        doomed = []
        for y in range(h):
            for x in range(w):
                r, g, b, a = px[x, y]
                if a == 0 or not _is_matte((r, g, b)):
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                        doomed.append((x, y))
                        break
        if not doomed:
            break
        for x, y in doomed:
            px[x, y] = (0, 0, 0, 0)
            removed += 1
    return im, removed
