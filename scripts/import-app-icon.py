"""导入应用图标（窗口图标 + exe 图标）。

用法：python scripts/import-app-icon.py

源：`C:\\Users\\wangxu\\WorkBuddy\\2026-10-12-21-28-26\\generated-images\\TheVillage_icon_A_transparent.png`
（作者 workbuddy；992×992 RGBA，硬边像素画，四角透明）。素材包**不入库**，
只提交导出的 `godot/assets/ui/icon.png` 与 `icon.ico` —— 与商品/科技图标的处理一致。

处理：
1. **补掉右下角的 WorkBuddy 水印**（浅灰 "AI生 WORKBUDDY"，压在木框与角钉上）。
   外框四角是对称的，所以把**左下角的同位置像素水平镜像**过来补 —— 比涂抹/羽化都干净。
2. `icon.png` 256×256：窗口/任务栏图标（`project.godot` 的 `application/config/icon`）。
3. `icon.ico` 多尺寸 16/24/32/48/64/128/256：exe 文件图标
   （`export_presets.cfg` 的 `application/icon`）。

改了脚本要连 PNG/ICO 一起提交，并重跑 `--headless --path godot --import`。
"""
import os
import sys

from PIL import Image

SRC = (r'C:\Users\wangxu\WorkBuddy\2026-10-12-21-28-26\generated-images'
       r'\TheVillage_icon_A_transparent.png')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'ui')
PNG_OUT = os.path.join(DST, 'icon.png')
ICO_OUT = os.path.join(DST, 'icon.ico')

PNG_SIZE = 256
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]

# 水印检测：右下角这块里"低饱和 + 够亮"的像素（木框本身是暖棕，色差大，不会误判）
WM_REGION = (0.55, 0.75)      # 起点（宽、高的比例）
WM_MAX_CHROMA = 40
WM_MIN_LUMA = 150
WM_MARGIN = 6                 # 外扩，免得留下半截笔画


def find_watermark(im):
    """返回水印包围盒（含外扩），没找到返回 None。"""
    w, h = im.size
    px = im.load()
    x0, y0 = int(w * WM_REGION[0]), int(h * WM_REGION[1])
    box = None
    for y in range(y0, h):
        for x in range(x0, w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            if max(r, g, b) - min(r, g, b) <= WM_MAX_CHROMA and \
                    0.299 * r + 0.587 * g + 0.114 * b >= WM_MIN_LUMA:
                box = (x, y, x, y) if box is None else (
                    min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y))
    if box is None:
        return None
    return (max(0, box[0] - WM_MARGIN), max(0, box[1] - WM_MARGIN),
            min(w - 1, box[2] + WM_MARGIN), min(h - 1, box[3] + WM_MARGIN))


def patch_watermark(im):
    """把水印区域用**水平镜像**的像素盖掉（外框四角对称，镜像过来就是原样）。"""
    box = find_watermark(im)
    if box is None:
        print('（没找到水印，跳过修补）')
        return im, None
    w, h = im.size
    px = im.load()
    x0, y0, x1, y1 = box
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            mx = w - 1 - x
            if 0 <= mx < w:
                px[x, y] = px[mx, y]
    return im, box


def main():
    if not os.path.isfile(SRC):
        print(f'素材不存在：{SRC}', file=sys.stderr)
        return 1
    os.makedirs(DST, exist_ok=True)

    im = Image.open(SRC).convert('RGBA')
    print(f'源图 {im.size} {im.mode}')
    im, box = patch_watermark(im)
    print(f'水印包围盒（含 {WM_MARGIN}px 外扩）：{box}')

    # 窗口图标：256×256。992 不是 256 的整数倍，用 LANCZOS（与建筑 AI 素材同一套处理）
    big = im.resize((PNG_SIZE, PNG_SIZE), Image.LANCZOS)
    big.save(PNG_OUT)
    print(f'写出 {os.path.relpath(PNG_OUT, ROOT)}（{PNG_SIZE}×{PNG_SIZE}）')

    # exe 图标：多尺寸 ICO。逐尺寸自己算，免得依赖 Pillow ICO 插件内部的缩放方式。
    frames = [im.resize(s, Image.LANCZOS) for s in ICO_SIZES if s != (PNG_SIZE, PNG_SIZE)]
    big.save(ICO_OUT, format='ICO',
             sizes=[(f.width, f.height) for f in frames] + [(PNG_SIZE, PNG_SIZE)],
             append_images=frames)
    print(f'写出 {os.path.relpath(ICO_OUT, ROOT)}'
          f'（{"、".join(str(s[0]) for s in ICO_SIZES)}）')

    # 自检：ICO 能被读回、尺寸齐全
    back = Image.open(ICO_OUT)
    got = sorted(back.info.get('sizes', []))
    print(f'  读回 ICO：{got}')
    assert got == sorted(set(ICO_SIZES)), f'ICO 尺寸不对：{got}'
    print('OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
