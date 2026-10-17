"""抠绿幕 -> 七人顾问团的立绘。

用法：
    python scripts/import-portraits.py            # 出图到 godot/assets/portraits/
    python scripts/import-portraits.py --probe    # 只出样张到 shots/portrait_out/（不覆盖成品）

源：七张 **纯绿底（#00FF00）** 的立绘，文件名 `<两位序号>_<id>.png`，例如 `01_sebastian.png`。
素材包**不入库** —— 与图标 / 建筑整图一致，只提交抠好的 PNG。
源图放哪儿由 `--src` 指定，默认 `shots/portrait_src/`（`shots/` 在 .gitignore 里）。

产物：`godot/assets/portraits/<id>.png`，**640x960**，2:3，带 alpha。
七张源图的构图本来就对齐（人物都在 x 118..904 / y 150..1329 之内），
所以**同一套裁切框**裁过去，人物大小与站位天然一致 —— 以后补表情也照这个框。

抠图口径（踩过的坑都在这儿）：
  * `key = G - max(R, B)`：绿底 = 255，主体 =< 0，过渡带 0..255。
  * 判主体用 `key < 140`。**140..215 那一段必须丢掉** —— 它不是人影，是绿底上的
    暗边 / 投影（阿尔文腰侧那块红区就是它）。放宽了人物轮廓外会多一圈绿影。
  * 过渡带按物理式估 alpha：`a = (255 - key) / (255 - keyF)`，`keyF ≈ -40`
    （主体自身的绿占优量）；剪影内缩 3px 的“芯”强制 a=1，否则深色衣服会整体变半透。
  * 过渡带的颜色要从底上反解：`F = (C - (1-a)·B) / a`（**未预乘**）。
  * 剩下的绿再按 `G -> max(R,B)` 压掉。这套图里没有“天生是绿”的部位
    （七个角色的眼睛实测都不算绿占优），所以可以无脑压。
  * **不要填洞**：头发之间那几道是真实的缝，填了就把底上的绿留下来了。
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'portraits')
PREVIEW = os.path.join(ROOT, 'shots', 'portrait_out')

BG = np.array([0.0, 255.0, 0.0])
SOLID_T = 140      # key < T 判为主体
KEY_F = -40.0      # 主体自身的绿占优量（alpha 物理估计用）
CORE_R = 3         # 剪影内缩几 px 算“芯”
ISLAND_RATIO = 0.01
CROP = (110, 140, 910, 1340)   # 1024x1536 源图里的统一裁切框（2:3）
SIZE = (640, 960)
BG_DARK = (26, 24, 34, 255)    # 样张用的深底（贴近面板底色）


# ---------------------------------------------------------------- 形态学小工具

def dilate(mask, r):
    h, w = mask.shape
    ys, xs = np.nonzero(mask)
    if not len(ys):
        return mask.copy()
    out = np.zeros_like(mask)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out[np.clip(ys + dy, 0, h - 1), np.clip(xs + dx, 0, w - 1)] = True
    return out


def erode(mask, r):
    return ~dilate(~mask, r)


def ccl(mask):
    """行程编码 + 并查集的连通块标记。labels 里 0 = 背景。"""
    h, w = mask.shape
    parent = []

    def find(x):
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:
            parent[x], x = root, parent[x]
        return root

    prev, meta = [], []
    for y in range(h):
        d = np.diff(np.concatenate(([0], mask[y].astype(np.int8), [0])))
        starts = np.flatnonzero(d == 1)
        ends = np.flatnonzero(d == -1) - 1
        cur = []
        for s, e in zip(starts, ends):
            rid = len(parent)
            parent.append(rid)
            meta.append((y, int(s), int(e), rid))
            cur.append((int(s), int(e), rid))
        for s, e, rid in cur:
            for ps, pe, prid in prev:
                if ps <= e and s <= pe:
                    a, b = find(rid), find(prid)
                    if a != b:
                        parent[b] = a
        prev = cur
    labels = np.zeros((h, w), np.int32)
    seen = {}
    for y, s, e, rid in meta:
        labels[y, s:e + 1] = seen.setdefault(find(rid), len(seen) + 1)
    return labels, np.bincount(labels.ravel())


def despill(rgb, strength):
    out = rgb.copy()
    lim = np.maximum(out[..., 0], out[..., 2])
    g = out[..., 1]
    out[..., 1] = g - strength * np.maximum(g - lim, 0.0)
    return out


def spread(rgb, alpha, passes=3):
    """把不透明像素的颜色向外扩几圈：透明区的 RGB 不该还是绿色（缩放会渗出来）。"""
    out = rgb.copy()
    known = alpha > 0.02
    h, w = alpha.shape
    for _ in range(passes):
        grow = dilate(known, 1) & ~known
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


# ---------------------------------------------------------------- 主流程

def cutout(path, verbose=True):
    """绿幕 PNG -> 640x960 的 RGBA uint8 数组。"""
    rgb = np.asarray(Image.open(path).convert('RGB'), dtype=np.float32)
    key = rgb[:, :, 1] - np.maximum(rgb[:, :, 0], rgb[:, :, 2])
    solid = key < SOLID_T

    # 岛：丢掉远小于主体的碎块
    labels, sizes = ccl(solid)
    biggest = int(sizes[1:].max()) if len(sizes) > 1 else 0
    keep = sizes >= biggest * ISLAND_RATIO
    keep[0] = False
    solid &= ~(solid & ~keep[labels])

    core = erode(solid, CORE_R)

    a_phys = np.clip((255.0 - key) / (255.0 - KEY_F), 0.0, 1.0)
    alpha = np.where(core, 1.0, np.where(solid, a_phys, 0.0))

    out = rgb.copy()
    m = (alpha > 0.02) & (alpha < 0.995)
    den = np.maximum(alpha[m], 0.35)[:, None]
    out[m] = np.clip((rgb[m] - (1.0 - alpha[m][:, None]) * BG) / den, 0.0, 255.0)

    out = despill(out, np.clip((key - 4.0) / 10.0, 0.0, 1.0))
    out = spread(out, alpha, 3)

    if verbose:
        print('   alpha 透明 %.3f 实心 %.3f 半透 %.3f' % (
            float(np.mean(alpha < 8 / 255.)),
            float(np.mean(alpha > 0.97)),
            float(np.mean((alpha >= 8 / 255.) & (alpha <= 0.97)))))

    x0, y0, x1, y1 = CROP
    out, alpha = out[y0:y1, x0:x1], alpha[y0:y1, x0:x1]
    pm = np.clip(np.dstack([out * alpha[..., None], alpha * 255.0]), 0, 255).astype(np.uint8)
    arr = np.asarray(Image.fromarray(pm, 'RGBA').resize(SIZE, Image.LANCZOS), dtype=np.float32)
    a8 = np.clip(arr[:, :, 3:4] / 255.0, 0, 1)
    rgb_out = np.where(a8 > 0.004, arr[:, :, :3] / np.maximum(a8, 1e-6), 0.0)
    return np.dstack([np.clip(rgb_out, 0, 255), arr[:, :, 3]]).astype(np.uint8)


def contact(files, tag='contact'):
    ims = [Image.open(f).convert('RGBA') for f in files]
    pad = 12
    cw = sum(i.width for i in ims) + pad * (len(ims) + 1)
    ch = max(i.height for i in ims) + pad * 2
    sheet = Image.new('RGBA', (cw, ch), BG_DARK)
    x = pad
    for i in ims:
        sheet.alpha_composite(i, (x, pad + (ch - pad * 2 - i.height) // 2))
        x += i.width + pad
    sheet = sheet.resize((cw // 2, ch // 2), Image.LANCZOS)
    path = os.path.join(PREVIEW, tag + '.png')
    sheet.convert('RGB').save(path)
    return path


def faces(files):
    """脸看一张：绿边、掉色、眼睛有没有被去绿带走，看这个最直观。"""
    tiles = []
    for f in files:
        im = Image.open(f).convert('RGBA')
        bg = Image.new('RGBA', im.size, BG_DARK)
        tiles.append(Image.alpha_composite(bg, im).convert('RGB').crop((150, 10, 490, 300)))
    cw, ch = tiles[0].size
    cols = min(4, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new('RGB', (cw * cols + 10 * (cols + 1), ch * rows + 10 * (rows + 1)), (70, 70, 70))
    for i, t in enumerate(tiles):
        sheet.paste(t, (10 + (i % cols) * (cw + 10), 10 + (i // cols) * (ch + 10)))
    path = os.path.join(PREVIEW, 'faces.png')
    sheet.save(path)
    return path


def main():
    ap = argparse.ArgumentParser(description='绿幕立绘 -> 带 alpha 的 PNG')
    ap.add_argument('--src', default=os.path.join(ROOT, 'shots', 'portrait_src'),
                    help='绿幕源图目录（默认 shots/portrait_src）')
    ap.add_argument('--probe', action='store_true', help='只出样张到 shots/portrait_out，不写 godot/assets')
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.src, '*.png')))
    if not files:
        print('没有源图：%s' % args.src)
        print('把 `01_sebastian.png` 这样命名的七张绿幕图放进去再跑。')
        return 1

    out_dir = PREVIEW if args.probe else DST
    os.makedirs(out_dir, exist_ok=True)
    outs = []
    for p in files:
        stem = os.path.splitext(os.path.basename(p))[0]
        # 01_sebastian -> sebastian
        pid = stem.split('_', 1)[1] if stem[:2].isdigit() and '_' in stem else stem
        print(stem)
        rgba = cutout(p)
        dst = os.path.join(out_dir, pid + '.png')
        Image.fromarray(rgba, 'RGBA').save(dst, optimize=True, compress_level=9)
        print('   -> %s  %d KB' % (os.path.relpath(dst, ROOT), os.path.getsize(dst) // 1024))
        outs.append(dst)

    if args.probe:
        print('样张：', os.path.relpath(contact(outs), ROOT))
        print('脸庞：', os.path.relpath(faces(outs), ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
