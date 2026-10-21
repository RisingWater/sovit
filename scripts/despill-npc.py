"""把绿幕立绘上残留的绿压掉（就地改 docs/art/npc/*.png，只动颜色，不动 alpha 形状）。

用法：
    python scripts/despill-npc.py --probe   # 只出到 shots/npc_probe/despilled/，不动成品
    python scripts/despill-npc.py           # 就地写回（可重入，第二次没变化）

为什么需要：
    这批图是从绿幕源（`docs/art/npc/origin/`）抠的，绿幕溢色只留在两处 ——
    * **轮廓外沿**一圈亮绿毛边：`02_alvin` / `03_reynard` / `06_luna` 浅底上一眼能看见；
    * **发缝里**的绿线（`06_luna`）：换背景时头发之间的缝没抠干净，留着绿底。

⚠️ 别用“凡是有绿占优就压”的粗暴规则。这批图里**本来就有绿衣服**：
    `18_aislin` 的绿裙子（一块 2.8 万 px）、`09_gareth` 的绿斗篷、`15_theodore` 的青外套
    （1.2 万 px）、`17_frederick` / `22_irena` 也有绿料子。一刀切会把它们洗成灰的。
    这些”设计上的绿”有个共同点：**在人物内部，不贴着剪影**。

口径（`gd = G - max(R, B)`，绿占优才 > 0）：
    1. **外沿**（离剪影 ≤ RIM_PX）：拿“内部 3px 处的绿占优量”当参考值（把内部的 gd 往外
       扩散填进这一圈），只有比参考值明显更绿的部分才压 —— 于是绿裙子的边缘毫发无损
       （它的参考值本来就高），而绿底溢出的亮边（参考值≈0）会被压干净。
    2. **内部小块**：高饱和绿（gd > BLOB_GD）且连通块小于 BLOB_MAX，当没抠干净的绿底残渣，
       整块压掉。大片绿（> BLOB_MAX）当设计色，不动。
    3. 半透明的纯绿像素（a < THIN_A 且 gd > THIN_GD）是绿底留了半透的边，除了压绿再把
       alpha 打薄，否则成品边缘会有一圈半透明的绿影。
    压过之后 gd 落到参考值附近，所以脚本**可重入**，跑第二遍不会再有改动。
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
SRC = os.path.join(ROOT, 'docs', 'art', 'npc')
PROBE = os.path.join(ROOT, 'shots', 'npc_probe', 'despilled')

RIM_PX = 2.5         # 剪影外沿多少 px 内算“边缘带”
RIM_SLACK = 8        # 比内部参考值还绿出这么多才压（留一点余量，免得伤设计色）
BLOB_GD = 25         # 内部高饱和绿的判据
BLOB_MAX = 800       # 连通块小于它才当残渣（更大的当设计色）
BLOB_RING = 6        # 看“周围”的环宽
BLOB_RING_GD = 8     # 环绕块的绿占优均值超过它 = 周围也绿 = 设计色
THIN_A = 200         # 比这更半透明、且 gd 很高的，认定是绿底没抠干净
THIN_GD = 60
THIN_KEEP = 0.35     # 上述像素的 alpha 保留比例
ST8 = np.ones((3, 3), bool)


def _spread_into(values, known, band, passes):
    """把 known 处的值一层层扩散填进 band（归一化卷积）。"""
    out = values.copy()
    known = known.copy()
    cnt_src = np.zeros(values.shape, np.float32)
    h, w = values.shape
    for _ in range(passes):
        grow = ndimage.binary_dilation(known, ST8) & ~known & band
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
                acc[ys0:ys1, xs0:xs1] += np.where(src, out[ys0 + dy:ys1 + dy, xs0 + dx:xs1 + dx], 0.0)
                cnt[ys0:ys1, xs0:xs1] += src
        fill = grow & (cnt > 0)
        if not fill.any():
            break
        out[fill] = acc[fill] / cnt[fill]
        known |= fill
    del cnt_src
    return out, known


def despill(arr):
    """RGBA uint8 -> (RGBA uint8, 统计 dict)。"""
    out = arr.astype(np.float32)
    rgb, a = out[:, :, :3], out[:, :, 3]
    gd = rgb[:, :, 1] - np.maximum(rgb[:, :, 0], rgb[:, :, 2])

    inside = a > 0.02
    dist = ndimage.distance_transform_edt(inside)
    band = inside & (dist <= RIM_PX)

    # 1) 外沿：参考值 = 内部 3px 处的 gd，扩散进边缘带
    ref, _ = _spread_into(gd, inside & (dist > RIM_PX + 0.5), band, int(RIM_PX) + 3)
    excess_rim = np.clip(gd - ref - RIM_SLACK, 0.0, None) * band

    # 2) 内部高饱和绿块：靠“周围是不是也绿”区分设计色和残渣
    #    —— 绿裙子被打碎成的小块，其周围同样是绿的；发缝里的绿残渣，周围是头发（不绿）。
    blob_src = (gd > BLOB_GD) & inside & ~band
    lab, n = ndimage.label(blob_src, ST8)
    blob = np.zeros(gd.shape, bool)
    if n:
        sizes = ndimage.sum(blob_src, lab, range(1, n + 1))
        objs = ndimage.find_objects(lab)
        pad = BLOB_RING + 2
        for i in range(1, n + 1):
            if sizes[i - 1] < 6:
                continue
            sl = objs[i - 1]
            y0, y1 = max(0, sl[0].start - pad), min(gd.shape[0], sl[0].stop + pad)
            x0, x1 = max(0, sl[1].start - pad), min(gd.shape[1], sl[1].stop + pad)
            sub = lab[y0:y1, x0:x1] == i
            # 环只看**不透明**像素：透明区的 RGB 往往还是绿底，算进去会把残渣误判成设计色
            opaque = a[y0:y1, x0:x1] > 0.5
            ring = ndimage.binary_dilation(sub, ST8, iterations=BLOB_RING) & ~sub & opaque
            ring_gd = gd[y0:y1, x0:x1][ring]
            if ring_gd.size == 0 or float(np.mean(ring_gd)) > BLOB_RING_GD:
                continue          # 周围也绿 -> 设计色
            if sizes[i - 1] >= BLOB_MAX:
                continue          # 太大 -> 设计色
            blob[y0:y1, x0:x1] |= sub
    excess_blob = np.where(blob, np.clip(gd, 0.0, None), 0.0)

    cut = np.maximum(excess_rim, excess_blob)
    hot = cut > 0
    thin = hot & (a < THIN_A) & (gd > THIN_GD)
    n_green = int(((gd > RIM_SLACK) & inside).sum())

    # 压绿：G 减掉“超出参考值”的那部分（不会把设计色压到 max(R,B) 以下）
    rgb[..., 1] = np.where(hot, rgb[..., 1] - cut, rgb[..., 1])
    # 半透明纯绿再把 alpha 打薄
    out[:, :, 3] = np.where(thin, a * THIN_KEEP, a)

    return np.clip(out, 0, 255).astype(np.uint8), {
        'green': n_green, 'rim': int((excess_rim > 0).sum()),
        'blob': int((excess_blob > 0).sum()), 'thin': int(thin.sum())}


def main():
    ap = argparse.ArgumentParser(description='压掉绿幕立绘上的残留绿')
    ap.add_argument('--probe', action='store_true', help='写到 shots/npc_probe/despilled/，不动成品')
    args = ap.parse_args()

    dst = PROBE if args.probe else SRC
    if args.probe:
        os.makedirs(PROBE, exist_ok=True)

    files = sorted(glob.glob(os.path.join(SRC, '*.png')))
    if not files:
        print('没有图：%s' % SRC)
        return 1

    tot_rim = tot_blob = 0
    for p in files:
        arr = np.asarray(Image.open(p).convert('RGBA'), np.uint8)
        res, s = despill(arr)
        tot_rim += s['rim']
        tot_blob += s['blob']
        if s['rim'] or s['blob'] or args.probe:
            Image.fromarray(res, 'RGBA').save(
                os.path.join(dst, os.path.basename(p)), optimize=True, compress_level=9)
        if s['rim'] or s['blob']:
            print('%-18s 绿占优 %-6d 压外沿 %-5d 压内部块 %-4d 打薄 %-4d'
                  % (os.path.basename(p), s['green'], s['rim'], s['blob'], s['thin']))
        elif args.probe:
            print('%-18s 干净' % os.path.basename(p))

    print('\n合计：外沿 %d 像素、内部块 %d 像素' % (tot_rim, tot_blob))
    if args.probe:
        print('样张目录：', os.path.relpath(PROBE, ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
