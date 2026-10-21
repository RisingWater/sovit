"""把 docs/art/npc/ 里手抠的立绘做成游戏用的 640x896 立绘（写 godot/assets/portraits/）。

用法：
    python scripts/frame-npc-portraits.py --probe   # 只写 shots/npc_probe/framed/ + 诊断
    python scripts/frame-npc-portraits.py           # 写 godot/assets/portraits/

为什么要做“合成”而不是直接缩放：
    `docs/art/npc/*.png` 是手工抠的**成品**，但只有原图的 1/3 大小（201x332 ~ 392x530）。
    游戏里立绘要高到 ~700px（`intro.gd` 的 PORTRAIT_H=0.78 × 900），直接放大三倍会糊。
    所以这里只取它的 **alpha（也就是手工抠出来的形状）**，
    颜色回到 `docs/art/npc/origin/` 的全分辨率绿幕图上取：
        `F = (C - (1-a)·BG) / a`（未预乘）
    半透明的边就按这个式子反解，绿溢色天生不会带进来（比事后 despill 更干净）。

取景沿用现有立绘，**不能改**：
    origin 是 1024x1536，裁 `(110, 140)-(910, 1260)`（800x1120 = 5:7）再缩到 640x896。
    这个框是拿现有 8 张成品反推出来的（IoU 0.998），而且 `cast.gd::portrait_head()`
    取的是**上面 36%** 当小头像 —— 取景一变，小头像就切错地方。
    顺带一提，这个框正好把右下角水印（y 1265 起）裁掉了。

对应关系：只处理 godot/assets/portraits/ 里已有的人（8 个），按 id 配对，
不认识的 id 不新增（`cast.gd` 的名单没变）。
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPC = os.path.join(ROOT, 'docs', 'art', 'npc')
ORG = os.path.join(NPC, 'origin')
DST = os.path.join(ROOT, 'godot', 'assets', 'portraits')
PROBE = os.path.join(ROOT, 'shots', 'npc_probe', 'framed')

BG = np.array([0.0, 255.0, 0.0])
KEY_F = -40.0                     # 主体自身的绿键期望值（颜色反解用）
DECON_KEY = 20                    # key 超过它才做绿底反解（弱绿只 despill）
CROP = (110, 140, 910, 1260)      # 与现有立绘逐像素对齐的取景框（800x1120）
SIZE = (640, 896)
SPREAD = 3
EDGE_DEPTH = 3.0                  # 轮廓外沿多少 px 内的颜色改成从内部拉（0 = 关）
RAMP_LO, RAMP_HI = 0.22, 0.78     # 把上采样后的软边掐回一段紧过渡（见 tight()）
FIG_KEY = 140                     # 绿幕判主体
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
    """把轮廓外沿 depth px 内的颜色换成从内部“拉出来”的。

    `origin/` 里的绿幕图本身在轮廓上就挂着一圈偏紫的渗色（换绿底那次抠图留下的，
    不是这一步造成的）。紫边的根子是那些像素的观察色比“绿底 + 半透”能解释的更暗，
    任何反解都还原不出来 —— 只能把最外那圈颜色换成紧邻内部的颜色。
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


def register(alpha_u, fig):
    """在 origin 坐标系里找 alpha_u 的 (缩放, 位移)：使 alpha 与绿幕剪影重合最多。"""
    D = 4
    fh, fw = fig.shape
    small_fig = cv2.resize(fig.astype(np.float32), (fw // D, fh // D), interpolation=cv2.INTER_AREA)
    hu, wu = alpha_u.shape
    s0 = (fh * 0.9) / max(hu, 1)
    best = (-1.0, s0, 0, 0)
    for k in np.linspace(0.80, 1.20, 17):
        s = s0 * k
        tw, th = max(4, int(round(wu * s / D))), max(4, int(round(hu * s / D)))
        if tw >= fw // D or th >= fh // D:
            continue
        tpl = cv2.resize(alpha_u.astype(np.float32), (tw, th), interpolation=cv2.INTER_AREA)
        res = cv2.matchTemplate(small_fig, tpl, cv2.TM_CCORR_NORMED)
        _, mx, _, loc = cv2.minMaxLoc(res)
        if mx > best[0]:
            best = (mx, s, loc[0] * D, loc[1] * D)

    # 全分辨率上再细调 ±D 与缩放
    score, s, dx, dy = best
    for k in np.linspace(0.97, 1.03, 7):
        ss = s * k
        tw, th = max(4, int(round(wu * ss))), max(4, int(round(hu * ss)))
        if tw >= fw or th >= fh:
            continue
        tpl = cv2.resize(alpha_u.astype(np.float32), (tw, th), interpolation=cv2.INTER_AREA)
        x0 = max(0, dx - D)
        y0 = max(0, dy - D)
        win = fig[y0:y0 + th + 2 * D, x0:x0 + tw + 2 * D].astype(np.float32)
        if win.shape[0] < th or win.shape[1] < tw:
            continue
        res = cv2.matchTemplate(win, tpl, cv2.TM_CCORR_NORMED)
        _, mx, _, loc = cv2.minMaxLoc(res)
        if mx > score:
            score, s, dx, dy = mx, ss, x0 + loc[0], y0 + loc[1]
    return score, s, dx, dy


def tighten(a):
    """把上采样放软的边掐紧：只保留 RAMP_LO..RAMP_HI 这一段过渡。"""
    return np.clip((a - RAMP_LO) / (RAMP_HI - RAMP_LO), 0.0, 1.0)


def ramp_width(alpha):
    """边缘过渡有多宽：对 0.15<a<0.85 的像素，量它到“实心”和“全透”的距离之和，取中位。"""
    mid = (alpha > 0.15) & (alpha < 0.85)
    if not mid.any():
        return 0.0
    d_solid = ndimage.distance_transform_edt(alpha <= 0.95)
    d_clear = ndimage.distance_transform_edt(alpha >= 0.05)
    return float(np.median(d_solid[mid] + d_clear[mid]))


def build(aid, do_tighten, stats):
    npc_path = None
    for p in glob.glob(os.path.join(NPC, '*_%s.png' % aid)):
        npc_path = p
    org_path = os.path.join(ORG, os.path.basename(npc_path)) if npc_path else None
    if not npc_path or not os.path.exists(org_path):
        print('%-12s 跳过：找不到 npc 或 origin 对应文件' % aid)
        return None

    cut = np.asarray(Image.open(npc_path).convert('RGBA'), np.float32) / 255.0
    alpha_u = cut[:, :, 3]

    org = np.asarray(Image.open(org_path).convert('RGB'), np.float32)
    key = org[:, :, 1] - np.maximum(org[:, :, 0], org[:, :, 2])
    fig = (key < FIG_KEY).astype(np.float32)

    score, s, dx, dy = register(alpha_u, fig)
    h, w = fig.shape
    tw, th = max(1, int(round(alpha_u.shape[1] * s))), max(1, int(round(alpha_u.shape[0] * s)))
    up = cv2.resize(alpha_u, (tw, th), interpolation=cv2.INTER_LANCZOS4)
    a_full = np.zeros((h, w), np.float32)
    x0, y0 = max(0, dx), max(0, dy)
    x1, y1 = min(w, dx + tw), min(h, dy + th)
    a_full[y0:y1, x0:x1] = np.clip(up[y0 - dy:y1 - dy, x0 - dx:x1 - dx], 0.0, 1.0)

    stats['score'] = score
    stats['scale'] = s
    stats['ramp_raw'] = ramp_width(a_full)
    if do_tighten:
        a_full = tighten(a_full)
    stats['ramp_tight'] = ramp_width(a_full)
    stats['iou'] = float(np.logical_and(a_full > 0.5, fig > 0.5).sum()
                         / max(np.logical_or(a_full > 0.5, fig > 0.5).sum(), 1))

    # 颜色从全分辨率绿幕反解（未预乘）。
    # ⚠️ 两个坑（都踩过）：
    #   1) 拿 alpha 做除法必须用**绿键算出来的 alpha**，不能用手工蒙版的形状 alpha：
    #      形状 alpha 的过渡带会伸进实心画面，那里原图不是“艺术+绿底”的混合，
    #      硬除会在轮廓上炸出一圈紫块。
    #   2) 只在**真被绿污染**的像素（key > DECON_KEY）上反解。灰色布料 key 只有 -10 左右，
    #      反解会按 10% 绿去减，反而把整块布料算成偏品红。
    #      弱绿（0 < key <= DECON_KEY）不反解，交给后面的 despill 把 G 压回去就够了。
    a_key = np.clip((255.0 - key) / (255.0 - KEY_F), 0.0, 1.0)
    a_key[ndimage.binary_erosion(fig > 0.5, ST8, iterations=2)] = 1.0
    rgb = org.copy()
    m = (a_key > 0.25) & (a_key < 0.995) & (key > DECON_KEY)
    den = a_key[m][:, None]
    rgb[m] = np.clip((org[m] - (1.0 - a_key[m][:, None]) * BG) / den, 0.0, 255.0)
    lim = np.maximum(rgb[..., 0], rgb[..., 2])
    wgt = np.clip((key - 4.0) / 10.0, 0.0, 1.0)
    rgb[..., 1] = np.where(wgt > 0, np.minimum(rgb[..., 1], lim), rgb[..., 1])
    # 深度取“实测过渡宽 + 2”：手工蒙版向外软出去几 px，紫边正好落在这一段里，
    # 固定 3px 盖不住（试过，浅底上还能看见一圈粉紫）。
    depth = float(np.clip(stats['ramp_raw'] + 2.0, 3.0, 10.0))
    stats['edge_depth'] = depth
    rgb = edge_recolor(rgb, a_full, depth)
    rgb = spread(rgb, a_full, SPREAD)

    cx0, cy0, cx1, cy1 = CROP
    rgb = rgb[cy0:cy1, cx0:cx1]
    al = a_full[cy0:cy1, cx0:cx1]
    pm = np.dstack([rgb * al[..., None], al * 255.0])
    arr = np.asarray(Image.fromarray(np.clip(pm, 0, 255).astype(np.uint8), 'RGBA')
                     .resize(SIZE, Image.LANCZOS), np.float32)
    a8 = np.clip(arr[:, :, 3:4] / 255.0, 0, 1)
    rgb_out = np.where(a8 > 0.004, arr[:, :, :3] / np.maximum(a8, 1e-6), 0.0)
    return np.dstack([np.clip(rgb_out, 0, 255), arr[:, :, 3]]).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description='手抠立绘 -> 游戏用 640x896 立绘')
    ap.add_argument('--probe', action='store_true', help='写到 shots/npc_probe/framed/，不动成品')
    ap.add_argument('--loose', action='store_true', help='不掐边（默认会把上采样后的软边掐紧一半）')
    args = ap.parse_args()

    dst = PROBE if args.probe else DST
    os.makedirs(dst, exist_ok=True)

    ids = sorted(os.path.splitext(os.path.basename(p))[0]
                 for p in glob.glob(os.path.join(DST, '*.png')))
    if not ids:
        print('godot/assets/portraits 里没有立绘，先确认目录')
        return 1

    outs = []
    for aid in ids:
        stats = {}
        rgba = build(aid, not args.loose, stats)
        if rgba is None:
            continue
        out = os.path.join(dst, aid + '.png')
        Image.fromarray(rgba, 'RGBA').save(out, optimize=True, compress_level=9)
        outs.append(out)
        print('%-12s 配准分 %.4f  缩放 %.2fx  过渡宽 %.1f -> %.1f px  IoU(剪影) %.4f  %d KB'
              % (aid, stats['score'], stats['scale'], stats['ramp_raw'],
                 stats['ramp_tight'], stats['iou'], os.path.getsize(out) // 1024))

    print('\n写好了 %d 张 -> %s' % (len(outs), os.path.relpath(dst, ROOT)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
