"""绿幕 NPC 立绘 -> 带 alpha 的 PNG（出到 docs/art/npc/）。

⚠️ 一般**不要跑这个脚本**：`docs/art/npc/*.png` 现在是**手工抠**的成品（比自动抠的干净，
   发丝也修过）。这里跑一遍会用绿幕重抠并**就地覆盖掉那些手工蒙版**。
   留着它是当“哪天要重新自动抠”的参考实现（物理模型、水印块清理、发丝碎块的坑）。
   日常只需要 `scripts/despill-npc.py`（去污）和 `scripts/frame-npc-portraits.py`（出游戏立绘）。

用法：
    python scripts/key-npc.py             # 写 docs/art/npc/（就地替换旧的抠图）
    python scripts/key-npc.py --probe     # 只出到 shots/npc_probe/out/，不动成品
    python scripts/key-npc.py --only vera # 只跑某一张

源（素材不入库，路径写死）：
    <GEN>/portraits/green   9 位顾问
    <GEN>/rulers/green      12 位统治者
纯绿底 #00FF00，1024x1536。两边编号不是一套，文件名 -> 目标名在 MAP 里写死，
已用剪影 IoU 逐张核对过（每对 > 0.98，且每个源正好用一次）。

产物：`docs/art/npc/<NN>_<id>.png`，1024x1536，straight alpha（非预乘），
画面构图与源图逐像素一致（不裁不缩），后续要做 640x960 立绘再照
`import-portraits.py` 的 CROP 走一遍。

抠图口径（物理模型，与 scripts/import-portraits.py 同一套）：
  * `key = G - max(R, B)`：绿底 = 255，主体 =< 0。
  * alpha 按物理式估：`a = (255 - key) / (255 - keyF)`，`keyF ≈ -40`（主体自身的 key）。
    这个式子直接把绿边过渡带变成半透明，颜色再从绿底上反解，不会有硬边白/绿描边。
  * 剪影内缩 CORE_R 的“芯”强制 a=1；否则中性色（18_aislin 的白发、20_hermann 的
    钢甲）按物理式只到 0.86，整个人会显得半透。
  * 过渡带颜色 `F = (C - (1-a)·BG) / a`，再把 G 压到 max(R,B) 去绿。
  * 颜色向外扩 SPREAD 圈：透明区的 RGB 不能还是绿，否则缩放 / mipmap 会把绿渗回来。

水印（这批量产图自带，必须处理）：
  * 右下角有模板水印：一个“双箭头”小 logo（~14x22px 深灰）+ 一行小圆点，
    绿底上呈**独立小块**（y 1285..1319，x 806..898，逐图横向漂 ±40px）。
    它 key≈0、长得像主体，纯按 key 抠会当成人物留下来 —— 旧那版就带着这些碎块。
    处理：bbox 完全落在右下角水印区、面积又很小的连通块直接丢。
  * ⚠️ 别用“只留最大连通块”这种粗暴规则：`05_vera` 有一缕**飘出去的发丝**
    （727px，x136..168/y678..742）和一撮**手肘间露出的头发**（96px），都是真画，
    丢了人物会缺角。
  * 压在衣服上的那行“AI生成 / WORKBUDDY”字**去不掉**，也别试图用 inpaint 糊：
    它在**背景上**的部分已经被绿底替换盖掉了，只剩衣服上的那一截，alpha 层面无解。
    试过“白顶帽抓笔画 + 滑动窗口定位 + Telea 修补”，字能去掉七八成，但一半的图会
    留残字或糊块，比留着更难看 —— 所以脚本只做抠图。要干净只有两条路：
    重新生成不含水印的源图，或把画面裁到 y < 1255（右下角那圈不要）。
  * 源图的人物轮廓上还挂着一圈 1~3px 的深色描边（换背景前那次抠图的黑底渗进边缘），
    浅色头发上会看成黑边 —— 由 EDGE_DEPTH 那步“边缘改成从内部拉色”处理。
  * 源图那层绿底是拿**硬蒙版**换上去的，边界是一格一格的阶梯 —— 由 FEATHER_* 那步
    亚像素羽化处理（往剪影外放 1~1.5px，外面的颜色已由 spread 填成内部色）。
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'docs', 'art', 'npc')
PREVIEW = os.path.join(ROOT, 'shots', 'npc_probe', 'out')

GEN = r'C:\Users\wangxu\WorkBuddy\2026-10-12-21-28-26\generated-images'
SRC_PORTRAIT = os.path.join(GEN, 'portraits', 'green')
SRC_RULER = os.path.join(GEN, 'rulers', 'green')

# 目标文件名 -> (源目录, 源文件名)，顺序即画册顺序
MAP = [
    ('01_sebastian', SRC_PORTRAIT, '01_sebastian'),
    ('02_alvin', SRC_PORTRAIT, '02_alvin'),
    ('03_reynard', SRC_PORTRAIT, '03_reynard'),
    ('04_isabella', SRC_PORTRAIT, '04_isabella'),
    ('05_vera', SRC_PORTRAIT, '05_vera'),
    ('06_luna', SRC_PORTRAIT, '06_luna'),
    ('07_serafina', SRC_PORTRAIT, '07_serafina'),
    ('08_milla', SRC_PORTRAIT, '08_milla'),
    ('09_gareth', SRC_PORTRAIT, '09_gareth'),
    ('11_adderick', SRC_RULER, '01_adderick'),
    ('12_albert', SRC_RULER, '02_albert'),
    ('12_irena', SRC_RULER, '12_irena'),
    ('13_bernard', SRC_RULER, '03_bernard'),
    ('14_cedric', SRC_RULER, '04_cedric'),
    ('15_theodore', SRC_RULER, '05_theodore'),
    ('16_edmund', SRC_RULER, '06_edmund'),
    ('17_frederick', SRC_RULER, '07_frederick'),
    ('18_aislin', SRC_RULER, '08_aislin'),
    ('19_batur', SRC_RULER, '09_batur'),
    ('20_hermann', SRC_RULER, '10_hermann'),
    ('21_gregory', SRC_RULER, '11_gregory'),
]

BG = np.array([0.0, 255.0, 0.0])
KEY_F = -40.0          # 主体自身的 key（alpha 物理估计用）
CORE_R = 2             # 剪影内缩几 px 算“芯”
SPREAD = 3             # 颜色外扩圈数
FEATHER_SIGMA = 0.8    # 蒙版柔化半径（压掉源图硬蒙版的阶梯）
FEATHER_GAIN = 0.9     # 羽化光圈的最大 alpha
FEATHER_PX = 1.5       # 羽化最多往剪影外放几 px
EDGE_DEPTH = 3.0       # 边缘多少 px 内的颜色改成从内部拉（0 = 关；4.0 试过，没更好）
WM_X, WM_Y = 790, 1270  # 水印小块所在的右下角区域起点
WM_MAX = 400           # 水印块面积上限
NOISE_MIN = 8          # 面积小于它、且离开主体 > 2px 的游离块当噪点丢掉
BG_DARK = (26, 24, 34, 255)

ST8 = np.ones((3, 3), np.uint8)


# ---------------------------------------------------------------- 小工具

def spread(rgb, alpha, passes=SPREAD):
    """把不透明像素的颜色向外扩几圈：透明区的 RGB 不该还是绿。"""
    out = rgb.copy()
    known = alpha > 0.02
    h, w = alpha.shape
    for _ in range(passes):
        grow = ndimage.binary_dilation(known, ST8) & ~known
        if not grow.any():
            break
        acc = np.zeros_like(out)
        cnt = np.zeros((h, w), np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                ys0, ys1 = max(0, -dy), h - max(0, dy)
                xs0, xs1 = max(0, -dx), w - max(0, dx)
                src = known[ys0 + dy:ys1 + dy, xs0 + dx:xs1 + dx]
                acc[ys0:ys1, xs0:xs1] += np.where(
                    src[..., None], out[ys0 + dy:ys1 + dy, xs0 + dx:xs1 + dx], 0.0)
                cnt[ys0:ys1, xs0:xs1] += src
        fill = grow & (cnt > 0)
        out[fill] = acc[fill] / cnt[fill][:, None]
        known = known | fill
    return out


def key_of(rgb):
    return rgb[:, :, 1] - np.maximum(rgb[:, :, 0], rgb[:, :, 2])


def edge_recolor(rgb, alpha, depth=EDGE_DEPTH):
    """把边缘 depth px 内的颜色换成从内部“拉出来”的。

    绿幕源的人物轮廓本身挂着一圈 1~3px 的深色描边（换背景那一步留下的）：
    浅色头发（18_aislin）边上会看到黑边，深色衣服上看不出来。这不是 alpha 的问题，
    光调 alpha 去不掉，只能把最外那圈的颜色换成紧邻内部的颜色。
    """
    inside = alpha > 0.02
    dist = ndimage.distance_transform_edt(inside)
    known = dist >= depth
    out = rgb.copy()
    band = inside & ~known
    h, w = alpha.shape
    for _ in range(int(depth) + 3):
        if not band.any():
            break
        acc = np.zeros_like(out)
        cnt = np.zeros((h, w), np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                ys0, ys1 = max(0, -dy), h - max(0, dy)
                xs0, xs1 = max(0, -dx), w - max(0, dx)
                src = known[ys0 + dy:ys1 + dy, xs0 + dx:xs1 + dx]
                acc[ys0:ys1, xs0:xs1] += np.where(
                    src[..., None], out[ys0 + dy:ys1 + dy, xs0 + dx:xs1 + dx], 0.0)
                cnt[ys0:ys1, xs0:xs1] += src
        fill = band & (cnt > 0)
        if not fill.any():
            break
        out[fill] = acc[fill] / cnt[fill][:, None]
        known = known | fill
        band = band & ~fill
    return out


def clean_mask(solid, stats):
    """丢掉水印小块与远处噪点，保留真画（含游离的发丝）。"""
    lab, n = ndimage.label(solid, ST8)
    if not n:
        return solid
    sizes = ndimage.sum(solid, lab, range(1, n + 1))
    main = int(np.argmax(sizes)) + 1
    keep = np.zeros(n + 1, bool)
    keep[main] = True
    objs = ndimage.find_objects(lab)
    near_main = ndimage.binary_dilation(lab == main, ST8, iterations=2)

    for i in range(1, n + 1):
        if i == main:
            continue
        sl = objs[i - 1]
        y0, y1, x0, x1 = sl[0].start, sl[0].stop, sl[1].start, sl[1].stop
        size = int(sizes[i - 1])
        if x0 >= WM_X and y0 >= WM_Y and size <= WM_MAX:
            stats['wm'] += 1
            continue
        if size < NOISE_MIN and not near_main[sl][lab[sl] == i].any():
            stats['noise'] += 1
            continue
        keep[i] = True
        stats['frag'] += 1
    return keep[lab]


# ---------------------------------------------------------------- 主流程

def cutout(path, stats):
    """绿幕 PNG -> 1024x1536 straight-alpha RGBA uint8。"""
    rgb = np.asarray(Image.open(path).convert('RGB'), dtype=np.float32)
    key = key_of(rgb)

    # ROI = 任何不完全像绿底的像素；水印小块就在这里面，先在 ROI 上清干净，
    # 后面的 alpha 一律以清过的 keep 为门 —— 否则被丢掉的块会从物理式里复活。
    keep = clean_mask(key < 245, stats)

    core = ndimage.binary_erosion(keep, ST8, iterations=CORE_R)
    a_phys = np.clip((255.0 - key) / (255.0 - KEY_F), 0.0, 1.0)
    alpha = np.where(core, 1.0, np.where(keep, a_phys, 0.0))

    # 亚像素羽化：源图那层绿底是拿一张硬蒙版换上去的，边界是一格一格的阶梯。
    # 用高斯把蒙版软化，再往剪影外放 1~1.5px（外面那些像素的颜色已被 spread 填成
    # 内部色，所以放出去不会带绿），阶梯就变成一段柔和的过渡。
    if FEATHER_SIGMA > 0:
        soft = ndimage.gaussian_filter(keep.astype(np.float32), FEATHER_SIGMA)
        out_dist = ndimage.distance_transform_edt(~keep)
        aura = FEATHER_GAIN * soft
        alpha = np.where(
            core, 1.0,
            np.where(keep, np.maximum(alpha, aura),
                     np.where(out_dist <= FEATHER_PX, aura, alpha)))

    # 过渡带反解颜色（未预乘）
    out = rgb.copy()
    m = (alpha > 0.02) & (alpha < 0.995)
    den = np.maximum(alpha[m], 0.25)[:, None]
    out[m] = np.clip((rgb[m] - (1.0 - alpha[m][:, None]) * BG) / den, 0.0, 255.0)

    # 去绿：把占优的 G 压到 max(R,B)
    lim = np.maximum(out[..., 0], out[..., 2])
    w = np.clip((key - 4.0) / 10.0, 0.0, 1.0)
    out[..., 1] = out[..., 1] - w * np.maximum(out[..., 1] - lim, 0.0)

    # 边缘那圈深色描边必须在 spread 之前处理：这些像素的观察色比“绿底 + 半透”能解释的
    # 还要暗，反解时会除出紫色毛边；先换成内部色，spread 才不会把这圈紫再糊出去。
    if EDGE_DEPTH > 0:
        out = edge_recolor(out, alpha, EDGE_DEPTH)

    out = spread(out, alpha, SPREAD)

    stats['trans'] = float(np.mean(alpha < 8 / 255.0))
    stats['solid'] = float(np.mean(alpha > 0.97))
    stats['half'] = float(np.mean((alpha >= 8 / 255.0) & (alpha <= 0.97)))
    resid = out[..., 1] - np.maximum(out[..., 0], out[..., 2])
    stats['green'] = float(np.mean(resid[alpha > 0.5] > 20))
    return np.dstack([np.clip(out, 0, 255), alpha * 255.0]).astype(np.uint8)


def contact(files, tag='contact'):
    ims = [Image.open(f).convert('RGBA').resize((171, 256), Image.LANCZOS) for f in files]
    pad = 10
    cols = 7
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new('RGBA', (cols * (171 * 2 + pad) + pad, rows * (256 + pad) + pad), BG_DARK)
    for i, im in enumerate(ims):
        x = pad + (i % cols) * (171 * 2 + pad)
        y = pad + (i // cols) * (256 + pad)
        for k, bg in enumerate((BG_DARK, (255, 0, 255, 255))):
            base = Image.new('RGBA', im.size, bg)
            sheet.alpha_composite(Image.alpha_composite(base, im), (x + k * 171, y))
    path = os.path.join(PREVIEW, tag + '.png')
    sheet.convert('RGB').save(path)
    return path


def faces(files):
    """脸看一张：绿边、掉色、眼睛有没有被去绿带走，看这个最直观。"""
    tiles = []
    for f in files:
        im = Image.open(f).convert('RGBA')
        bg = Image.new('RGBA', im.size, BG_DARK)
        tiles.append(Image.alpha_composite(bg, im).convert('RGB').crop((150, 120, 470, 420)))
    cw, ch = tiles[0].size
    cols = min(7, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new('RGB', (cw * cols + 8 * (cols + 1), ch * rows + 8 * (rows + 1)), (70, 70, 70))
    for i, t in enumerate(tiles):
        sheet.paste(t, (8 + (i % cols) * (cw + 8), 8 + (i // cols) * (ch + 8)))
    path = os.path.join(PREVIEW, 'faces.png')
    sheet.save(path)
    return path


def main():
    ap = argparse.ArgumentParser(description='绿幕 NPC 立绘 -> 带 alpha 的 PNG')
    ap.add_argument('--probe', action='store_true', help='只出到 shots/npc_probe/out，不写 docs/art')
    ap.add_argument('--only', default=None, help='只处理名字里含该子串的几张')
    args = ap.parse_args()

    out_dir = PREVIEW if args.probe else DST
    os.makedirs(out_dir, exist_ok=True)
    if args.probe:
        os.makedirs(PREVIEW, exist_ok=True)

    outs = []
    for name, src_dir, src_name in MAP:
        if args.only and args.only not in name:
            continue
        p = os.path.join(src_dir, src_name + '.png')
        if not os.path.exists(p):
            print('缺源图：%s' % p)
            return 1
        stats = {'wm': 0, 'noise': 0, 'frag': 0}
        rgba = cutout(p, stats)
        dst = os.path.join(out_dir, name + '.png')
        Image.fromarray(rgba, 'RGBA').save(dst, optimize=True, compress_level=9)
        outs.append(dst)
        print('%-16s -> %-7s KB  透明 %.3f 实心 %.3f 半透 %.4f 绿残留 %.5f'
              '  水印块 %d 噪点 %d 保留碎块 %d'
              % (name, os.path.getsize(dst) // 1024,
                 stats['trans'], stats['solid'], stats['half'], stats['green'],
                 stats['wm'], stats['noise'], stats['frag']))

    if args.probe and outs:
        print('样张：', os.path.relpath(contact(outs), ROOT))
        print('脸庞：', os.path.relpath(faces(outs), ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
