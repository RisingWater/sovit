"""从 docs/art/npc/origin/ 的绿幕原图重抠立绘：全分辨率、裁空白、去水印、去污。

用法：
    python scripts/recut-npc.py --probe    # 只出到 shots/npc_probe/recut/（不动成品）
    python scripts/recut-npc.py            # 写 docs/art/npc/，并重出游戏用的 640x896

为什么要有这一步：
    之前那批 `docs/art/npc/*.png` 是拿第三方工具抠的，**输出被缩到原图的 1/3**
    （201x332 这种），而且工具把内凹的地方（叉腰的手等）当背景吃掉了。
    这里回到 `origin/` 的全分辨率绿幕图自己抠，尺寸和轮廓都由我们决定。

管线（每张）：
    1. 绿键抠图：`key = G - max(R,B)`，`a = (255-key)/(255-keyF)`，keyF≈-40；
       剪影内缩 2px 的“芯”强制 a=1（否则白发 / 钢甲会整体半透）。
    2. 连通块清理：丢右下角水印小块和远处噪点，**保留真碎片**（`05_vera` 那缕
       飘出去的发丝不能丢）。
    3. 颜色反解 + 去绿 + 边缘由内取色（origin 轮廓上自带一圈紫边）。
    4. 裁掉底部水印带：水印（“AI生成 / WORKBUDDY” + 双箭头 logo + 圆点）在
       y≈1284..1325，底边裁到 1280 就干净了 —— 这条线是量过的（1180..1280
       那条带里 21 张都没有字）。
    5. 裁掉四周空白：按 alpha 的外接框收边，留 PAD px 余量。
    6. 另外给 `godot/assets/portraits/` 里已有的那 8 位出一份 640x896：
       取景固定 (110,140)-(910,1260)，和旧成品逐像素对齐（`cast.gd::portrait_head()`
       取上面 36% 当小头像，取景不能改）。

产物：
    docs/art/npc/<NN>_<id>.png      全分辨率、紧贴人物、不带水印、straight alpha
    godot/assets/portraits/<id>.png  640x896（只处理那里已有的人）
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPC = os.path.join(ROOT, 'docs', 'art', 'npc')
ORG = os.path.join(NPC, 'origin')
GAME = os.path.join(ROOT, 'godot', 'assets', 'portraits')
PROBE = os.path.join(ROOT, 'shots', 'npc_probe', 'recut')

BG = np.array([0.0, 255.0, 0.0])
KEY_F = -40.0        # 主体自身的绿键期望值
CORE_R = 2           # 剪影内缩几 px 算“芯”
SPREAD = 3           # 颜色外扩圈数
EDGE_DEPTH = 3.0     # 边缘多少 px 内的颜色改成从内部拉
FEATHER_SIGMA = 0.8  # 蒙版柔化半径（压掉源图硬蒙版的阶梯）
FEATHER_GAIN = 0.9
FEATHER_PX = 1.5
CROP_BOTTOM = 1280   # 水印在这条线以下（量过：1284 起），底边裁到这里
PAD = 2              # 紧裁后留几 px 余量
WM_X, WM_Y = 790, 1270
WM_MAX = 400
NOISE_MIN = 8
GAME_CROP = (110, 140, 910, 1260)   # 与旧 640x896 成品对齐的取景框
GAME_SIZE = (640, 896)
ST8 = np.ones((3, 3), bool)


def spread(rgb, alpha, passes=SPREAD):
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


def edge_recolor(rgb, alpha, depth=EDGE_DEPTH):
    """把轮廓外沿 depth px 内的颜色换成从内部“拉出来”的（origin 自带一圈紫边）。"""
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


def clean_mask(mask, stats):
    """丢水印小块与远处噪点，保留真碎片（发丝）。"""
    lab, n = ndimage.label(mask, ST8)
    if not n:
        return mask
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    main = int(np.argmax(sizes)) + 1
    keep = np.zeros(n + 1, bool)
    keep[main] = True
    objs = ndimage.find_objects(lab)
    near_main = ndimage.binary_dilation(lab == main, ST8, iterations=2)
    for i in range(1, n + 1):
        if i == main:
            continue
        sl = objs[i - 1]
        y0, x0 = sl[0].start, sl[1].start
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


def cutout(path, stats):
    """绿幕原图 -> 全分辨率 straight-alpha RGBA（未裁）。"""
    rgb = np.asarray(Image.open(path).convert('RGB'), dtype=np.float32)
    key = rgb[:, :, 1] - np.maximum(rgb[:, :, 0], rgb[:, :, 2])

    keep = clean_mask(key < 245, stats)
    core = ndimage.binary_erosion(keep, ST8, iterations=CORE_R)
    a_phys = np.clip((255.0 - key) / (255.0 - KEY_F), 0.0, 1.0)
    alpha = np.where(core, 1.0, np.where(keep, a_phys, 0.0))

    if FEATHER_SIGMA > 0:
        soft = ndimage.gaussian_filter(keep.astype(np.float32), FEATHER_SIGMA)
        out_dist = ndimage.distance_transform_edt(~keep)
        aura = FEATHER_GAIN * soft
        alpha = np.where(core, 1.0,
                         np.where(keep, np.maximum(alpha, aura),
                                  np.where(out_dist <= FEATHER_PX, aura, alpha)))

    out = rgb.copy()
    m = (alpha > 0.02) & (alpha < 0.995)
    den = np.maximum(alpha[m], 0.25)[:, None]
    out[m] = np.clip((rgb[m] - (1.0 - alpha[m][:, None]) * BG) / den, 0.0, 255.0)

    lim = np.maximum(out[..., 0], out[..., 2])
    wgt = np.clip((key - 4.0) / 10.0, 0.0, 1.0)
    out[..., 1] = np.where(wgt > 0, np.minimum(out[..., 1], lim), out[..., 1])

    out = edge_recolor(out, alpha, EDGE_DEPTH)
    out = spread(out, alpha, SPREAD)

    resid = out[..., 1] - np.maximum(out[..., 0], out[..., 2])
    stats['green'] = float(np.mean(resid[alpha > 0.5] > 20))
    stats['half'] = float(np.mean((alpha > 0.05) & (alpha < 0.95)))
    return np.dstack([np.clip(out, 0, 255), alpha * 255.0]).astype(np.uint8)


def tight_crop(rgba, stats):
    """裁掉底部水印带 + 四周空白（按 alpha 外接框，留 PAD）。"""
    rgba = rgba[:CROP_BOTTOM]
    a = rgba[:, :, 3]
    ys, xs = np.nonzero(a > 8)
    if not len(ys):
        return None
    h, w = a.shape
    y0 = max(0, int(ys.min()) - PAD)
    y1 = min(h, int(ys.max()) + 1 + PAD)
    x0 = max(0, int(xs.min()) - PAD)
    x1 = min(w, int(xs.max()) + 1 + PAD)
    stats['size'] = (x1 - x0, y1 - y0)
    return rgba[y0:y1, x0:x1]


def game_frame(rgba):
    """全分辨率 RGBA -> 640x896（取景与旧成品一致）。"""
    x0, y0, x1, y1 = GAME_CROP
    sub = rgba[y0:y1, x0:x1].astype(np.float32)
    al = sub[:, :, 3:4] / 255.0
    pm = np.dstack([sub[:, :, :3] * al, sub[:, :, 3:4]])
    arr = np.asarray(Image.fromarray(np.clip(pm, 0, 255).astype(np.uint8), 'RGBA')
                     .resize(GAME_SIZE, Image.LANCZOS), np.float32)
    a8 = np.clip(arr[:, :, 3:4] / 255.0, 0, 1)
    rgb = np.where(a8 > 0.004, arr[:, :, :3] / np.maximum(a8, 1e-6), 0.0)
    return np.dstack([np.clip(rgb, 0, 255), arr[:, :, 3]]).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description='绿幕原图 -> 全分辨率立绘')
    ap.add_argument('--probe', action='store_true', help='写到 shots/npc_probe/recut/')
    ap.add_argument('--no-game', action='store_true', help='不重出 godot 的 640x896')
    args = ap.parse_args()

    dst = PROBE if args.probe else NPC
    os.makedirs(dst, exist_ok=True)

    files = sorted(glob.glob(os.path.join(ORG, '*.png')))
    if not files:
        print('origin 里没有图：%s' % ORG)
        return 1

    game_ids = {os.path.splitext(os.path.basename(p))[0]
                for p in glob.glob(os.path.join(GAME, '*.png'))}
    did_game = []
    for p in files:
        name = os.path.splitext(os.path.basename(p))[0]
        stats = {'wm': 0, 'noise': 0, 'frag': 0}
        rgba = cutout(p, stats)
        cropped = tight_crop(rgba, stats)
        if cropped is None:
            print('%-16s 空图，跳过' % name)
            continue
        out = os.path.join(dst, name + '.png')
        Image.fromarray(cropped, 'RGBA').save(out, optimize=True, compress_level=9)

        note = ''
        if not args.no_game and not args.probe:
            aid = name.split('_', 1)[1]
            if aid in game_ids:
                gp = os.path.join(GAME, aid + '.png')
                Image.fromarray(game_frame(rgba), 'RGBA').save(gp, optimize=True, compress_level=9)
                did_game.append(aid)
                note = ' +game'
        print('%-16s %-9s 透明 %.3f 半透 %.4f 绿残留 %.5f 水印块 %d 碎片 %d%s'
              % (name, '%dx%d' % stats['size'], float(np.mean(cropped[:, :, 3] < 8)),
                 stats['half'], stats['green'], stats['wm'], stats['frag'], note))

    print('\n写好了 %d 张 -> %s' % (len(files), os.path.relpath(dst, ROOT)))
    if did_game:
        print('游戏立绘 %d 张 -> %s：%s' % (len(did_game), os.path.relpath(GAME, ROOT),
                                            ' '.join(sorted(did_game))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
