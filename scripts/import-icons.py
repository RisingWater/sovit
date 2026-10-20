"""把手绘商品图标导成游戏用的 PNG。

用法：
    python scripts/import-icons.py

素材包**不在仓库里**，所以这个脚本只在本地跑，产物 godot/assets/icons/*.png 提交进仓库。
没有素材包的人照样能构建：图标已经是仓库里的文件了。

两代素材包，脚本先认新的：

  ① **v7（2026-10 起，当前用这个）** `V7_64_DIR`
     已经是**按商品 id 命名、64×64 的成品**（`coarse_bread.png` / `wheat.png` …），
     所以这一代只做"逐字节拷贝"，不缩放、不改尺寸 —— 64 是原生尺寸，
     各面板显示 32 / 16 时用 `STRETCH_KEEP_ASPECT_CENTERED` 按比例缩（整除，不糊）。
  ② **v0（早期那套）** `SRC`
     中文文件名、有图集要按行列裁格、原生 16 放大到 32 输出。
     下面那些 `EXPLICIT` / `ALT` / `to_32()` 都是给这一代写的，留着以防要回退。

为什么输出到 assets/icons/ 而不是 assets/goods/：
    goods/ 是 `npm run gen:art` 程序化生成的 16x16 图标，每次生成都会**整体重写**。
    手绘图标放同一个目录会被无声覆盖（速度图标就栽在这上面），
    所以分开放：icons/ = 手绘，goods/ = 程序化兜底。

⚠️ 两代**不能混着用同一套尺寸假设**：老的一批是 32×32，新的一批是 64×64，
   目录里现在两种尺寸共存（还有三张 32×32 的住房图标）。
   所以 UI 那边一律 `KEEP_ASPECT_CENTERED`，不能写 `KEEP_CENTERED`。
"""
from PIL import Image, ImageDraw
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from icon_util import dematt  # noqa: E402

# ① 当前的 v7 素材包：按商品 id 命名、64×64 成品
V7_64_DIR = r'C:\Users\wangxu\WorkBuddy\2026-10-19-23-45-31\harvest_of_heirs\icons\v7_64'
# ② 早期的素材包（中文名 + 图集）
SRC = r'D:\wangxu\game\图标素材'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'icons')
THUMBS = os.path.join(ROOT, 'godot', 'assets', 'thumbs')
OUT_SIZE = 32

# 直接指定来源（这些文件名对不上商品名，或者需要从图集里裁格）
# 文件名里的「第N行第M列」是 16px 格的坐标，**从 1 开始数**。
EXPLICIT = {
    'flax':             ('sheet', '小麦（第5行第6列） - 副本.png', (5, 6)),
    'wheat':            ('sheet', '小麦（第7行第6列）.png', (7, 6)),
    'vegetable':        ('sheet', '蔬菜（第4行第1列）.png', (4, 1)),
    'cotton':           ('sheet', '棉花（第6行第1列）.png', (6, 1)),
    # 这两张是 **3x3 的 16px 图集**（同一张海鲜表），不是单图。
    # 整张 48x48 当图标用会糊成一团（实测截图里就是这样）。
    # 按文件名给的行列号裁：鱼=第1行第1列(蓝鱼)，熏鱼=第3行第2列(棕鳟)。
    'fish':             ('sheet', '鱼（第一行第一列）.png', (1, 1)),
    'smoked_fish':      ('sheet', '熏鱼（第3行第2列） - 副本.png', (3, 2)),
    'domestic_service': ('file', '家政.png', None),
    'entertainment':    ('file', '娱乐.png', None),
    'hut':              ('thumb', 'hut.png', None),
    'wooden_house':     ('thumb', 'wooden_house.png', None),
    'brick_house':      ('thumb', 'brick_house.png', None),
}
# 商品名 -> 素材文件名（不带扩展名）。素材名比商品名短：「肉」对「肉类」这类。
ALT = {'肉类': '肉', '鱼类': '鱼', '石制工具': '工具'}


def base_name(fn):
    n = os.path.splitext(fn)[0]
    n = re.sub(r'（第[^）]*）', '', n)
    n = re.sub(r'\s*-\s*副本$', '', n)
    n = re.sub(r'（[^）]*）$', '', n)
    return n.strip()


def to_32(im):
    """等比落到 32x32，只用整数比，保持像素硬边。"""
    im = im.convert('RGBA')
    w, h = im.size
    # 先回到原生最小格（源尺寸是 16px 原画的 N 倍放大时，N 就是最大公约式的倍数）
    for n in (4, 3, 2):
        if w == 16 * n and h == 16 * n and is_upscale(im, n):
            im = im.resize((16, 16), Image.NEAREST)
            w, h = 16, 16
            break
    if (w, h) == (OUT_SIZE, OUT_SIZE):
        return im
    if w == h and OUT_SIZE % w == 0:
        return im.resize((OUT_SIZE, OUT_SIZE), Image.NEAREST)   # 16->32 整数倍
    # 非整数比（48x48、100x72 这类）：最近邻，宁可硬边也不要模糊
    return im.resize((OUT_SIZE, OUT_SIZE), Image.NEAREST)


def is_upscale(im, n):
    """im 是不是每个 n x n 块都同色（= 原生 16px 的 n 倍放大）。"""
    px = im.load()
    w, h = im.size
    for by in range(0, h, n):
        for bx in range(0, w, n):
            c0 = px[bx, by]
            for y in range(by, by + n):
                for x in range(bx, bx + n):
                    if px[x, y] != c0:
                        return False
    return True


def fit_32(im):
    """把非方图（100x72 的建筑缩略图）等比放进 32x32 居中，不拉伸。"""
    im = im.convert('RGBA')
    im.thumbnail((OUT_SIZE, OUT_SIZE), Image.NEAREST)
    out = Image.new('RGBA', (OUT_SIZE, OUT_SIZE), (0, 0, 0, 0))
    out.alpha_composite(im, ((OUT_SIZE - im.width) // 2, (OUT_SIZE - im.height) // 2))
    return out


def draw_smiley():
    """娱乐：画一个 16x16 像素笑脸，再整数放大到 32x32。"""
    im = Image.new('RGBA', (16, 16), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    FACE = (250, 206, 74, 255)
    INK = (92, 54, 20, 255)
    d.ellipse([1, 1, 14, 14], fill=FACE, outline=INK)
    d.rectangle([5, 5, 5, 6], fill=INK)      # 左眼
    d.rectangle([10, 5, 10, 6], fill=INK)    # 右眼
    for x in range(5, 11):                   # 嘴
        d.rectangle([x, 9, x, 9], fill=INK)
    d.rectangle([4, 8, 4, 8], fill=INK)
    d.rectangle([11, 8, 11, 8], fill=INK)
    return im.resize((OUT_SIZE, OUT_SIZE), Image.NEAREST)


def load_goods():
    """商品清单：直接读内容源，**不要**依赖任何中间生成的文件。"""
    goods = []
    with open(os.path.join(ROOT, 'content', 'goods.json'), encoding='utf-8') as f:
        for it in json.load(f)['goods']:
            goods.append((it['id'], it['nameZh']))
    return goods


def import_v7(goods):
    """v7 素材包：已经是按商品 id 命名的 64×64 成品 → 逐字节拷贝，不重采样。

    为什么**不**缩到 32：64 是这批图的**原生尺寸**（用户照 64 画的），
    缩放交给运行时（显示 32 / 16 都是整除），仓库里只留一份原图，
    以后想把某个面板的图标放大也不用重新导。
    """
    os.makedirs(DST, exist_ok=True)
    made, missing = [], []
    for gid, name_zh in goods:
        src = os.path.join(V7_64_DIR, f'{gid}.png')
        if not os.path.isfile(src):
            missing.append((gid, name_zh))
            continue
        dst = os.path.join(DST, f'{gid}.png')
        shutil.copyfile(src, dst)
        with Image.open(dst) as im:
            w, h = im.size
        made.append((gid, name_zh, f'{os.path.basename(V7_64_DIR)}/{os.path.basename(src)}', w, h))

    print(f'[v7] 导出 {len(made)}/{len(goods)} 个图标 -> {os.path.relpath(DST, ROOT)}（保持原生尺寸）')
    for gid, zh, src, w, h in made:
        print(f'   {zh:8s} {gid:18s} {w}x{h}  <- {src}')
    if missing:
        print(f'\n仍然缺 {len(missing)} 个（v7 里没有，会被程序化兜底图标接住）：')
        for gid, zh in missing:
            print(f'   {zh} {gid}')
    leftover = [f for f in os.listdir(V7_64_DIR) if f.lower().endswith('.png')
                and os.path.splitext(f)[0] not in {g for g, _ in goods}]
    if leftover:
        print(f'\nv7 里没用上的 {len(leftover)} 个：')
        for f in leftover:
            print(f'   {f}')
    return 0 if not missing else 2


def main():
    goods = load_goods()
    # ① 先认 v7（当前用的那批）
    if os.path.isdir(V7_64_DIR):
        return import_v7(goods)
    # ② 回退到早期素材包那套（中文名 + 图集裁格 + 输出 32×32）
    if not os.path.isdir(SRC):
        print(f'两代素材目录都不存在：\n  {V7_64_DIR}\n  {SRC}', file=sys.stderr)
        return 1
    os.makedirs(DST, exist_ok=True)

    files = [f for f in os.listdir(SRC) if f.lower().endswith('.png')]
    by_name = {}
    for f in files:
        by_name.setdefault(base_name(f), []).append(f)

    made, missing = [], []
    claimed = set()
    for gid, name_zh in goods:
        spec = EXPLICIT.get(gid)
        expected = None
        if spec is not None:
            kind, fn, arg = spec
            if kind == 'draw':
                img = draw_smiley()
            elif kind == 'thumb':
                img = fit_32(Image.open(os.path.join(THUMBS, fn)))
            elif kind == 'sheet':
                row, col = arg
                sheet = Image.open(os.path.join(SRC, fn)).convert('RGBA')
                img = to_32(sheet.crop(((col - 1) * 16, (row - 1) * 16, col * 16, row * 16)))
                claimed.add(fn)
            else:
                img = to_32(Image.open(os.path.join(SRC, fn)))
                claimed.add(fn)
        else:
            cands = by_name.get(name_zh) or by_name.get(ALT.get(name_zh, '\u0000'))
            if not cands:
                missing.append((gid, name_zh))
                continue
            fn = sorted(cands)[0]
            img = to_32(Image.open(os.path.join(SRC, fn)))
            claimed.add(fn)
            expected = fn

        assert img.size == (OUT_SIZE, OUT_SIZE), f'{gid} 尺寸不对: {img.size}'
        # 去掉外圈那 1px 浅色毛边（在深色顶栏上看着就是白边）
        img, _ = dematt(img)
        img.save(os.path.join(DST, f'{gid}.png'))
        made.append((gid, name_zh, expected or spec[1] or 'drawn/thumbs'))

    print(f'导出 {len(made)}/{len(goods)} 个图标 -> {os.path.relpath(DST, ROOT)}')
    for gid, zh, src in made:
        print(f'   {zh:8s} {gid:18s} <- {src}')
    if missing:
        print(f'\n仍然缺 {len(missing)} 个：')
        for gid, zh in missing:
            print(f'   {zh} {gid}')
    unused = sorted(set(files) - claimed)
    print(f'\n素材包里没用上的 {len(unused)} 个：')
    for f in unused:
        print(f'   {f}')
    return 0 if not missing else 2


if __name__ == '__main__':
    sys.exit(main())
