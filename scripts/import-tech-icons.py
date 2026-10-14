"""导入科技树卡片图标。

用法：python scripts/import-tech-icons.py

源：`D:\\wangxu\\game\\图标素材\\tech_icons\\`（作者 workbuddy，MIT）。
素材包**不入库**，只提交导出的 PNG —— 与商品 / 面板图标的处理方式一致。

文件名规则：`NN_<techId>_64x64.png`，去掉 `NN_` 前缀与 `_64x64` 后缀即科技 id。
唯一的例外见 OVERRIDE。

产物：godot/assets/ui/tech/<techId>.png（32x32）
"""
from PIL import Image
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from icon_util import dematt  # noqa: E402

SRC = r'D:\wangxu\game\图标素材\tech_icons'
# 第二批（用户 2026-10 用 WorkBuddy 生成的**效率科技**图标，15 张，64x64）。
# 文件名是 `NN_<英文名>_<中文名>.png` —— 比第一批多一段中文名，
# 且英文名有 4 个跟我们的科技 id 对不上，见 OVERRIDE。
#
# ⚠️ **这一批不做去毛边（`dematt`）**：用户的素材本身就是抠干净的（白底已去、
# 轮廓自带深色描边），再跑 dematt 会**把图案里的白色/亮色一起抠掉** ——
# `standardization` 的白色石牌、`sawmill_machinery` 的亮色锯片都中过招
# （用户反馈："你把白色扣掉了"）。判据见 SOURCES 里的 dematt 开关。
SRC_V2 = r'C:\Users\wangxu\WorkBuddy\2026-10-14-07-02-44\outputs\tech_icons_v2'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'ui', 'tech')
OUT = 32

# 文件名里的科技名 -> 我们的科技 id。对不上的都在这里：
OVERRIDE = {
    # 第一批：素材按建筑名走，我们的科技 id 是 hunting
    'hunting_camp': 'hunting',
    # 第二批：素材英文名与我们的 id 不一致
    'improved_kiln': 'kiln_upgrade',
    'woodworking_machinery': 'sawmill_machinery',
    'brick_machine': 'brick_press',
    'lifting_frame': 'crane',
}


def uniform_factor(im):
    """最大 N，使每个 NxN 块同色（= 原生分辨率的放大倍数）；1 = 真高分辨率。"""
    px = im.load()
    w, h = im.size
    for n in (4, 3, 2):
        if w % n or h % n:
            continue
        ok = True
        for by in range(0, h, n):
            for bx in range(0, w, n):
                c0 = px[bx, by]
                for y in range(by, by + n):
                    for x in range(bx, bx + n):
                        if px[x, y] != c0:
                            ok = False
                            break
                    if not ok:
                        break
                if not ok:
                    break
            if not ok:
                break
        if ok:
            return n
    return 1


def parse_name(f: str):
    """文件名 -> 科技 id；不是图标文件就返回 None。

    两批的命名：
      v1 `NN_<techId>_64x64.png`
      v2 `NN_<英文名>_<中文名>.png`   ← 多一段中文名，先削掉再查 OVERRIDE
    """
    if not f.endswith('.png') or not f[0].isdigit():
        return None
    base = f.split('_', 1)[1] if '_' in f else f
    base = base.replace('_64x64.png', '')
    if '_' in base:
        tail = base.rsplit('_', 1)[1]
        # 末段是非 ASCII（中文名）就削掉；纯英文的 id（crop_rotation）保留
        if tail and not tail.isascii():
            base = base.rsplit('_', 1)[0]
    return OVERRIDE.get(base, base)


def main():
    ids = [x['id'] for x in json.load(
        open(os.path.join(ROOT, 'content', 'technologies.json'), encoding='utf-8'))['technologies']]
    idset = set(ids)

    # 两个源合并：同一 id 后出现的覆盖先出现的。
    # 第二个元素 = 这一批要不要跑 dematt（见 SRC_V2 上面的说明）。
    picked = {}
    for src, do_dematt in ((SRC, True), (SRC_V2, False)):
        if not os.path.isdir(src):
            print(f'（跳过不存在的素材目录）{src}')
            continue
        for f in sorted(os.listdir(src)):
            gid = parse_name(f)
            if gid is not None:
                picked[gid] = (os.path.join(src, f), do_dematt)
    if not picked:
        print('两个素材目录都不存在，没什么可导的', file=sys.stderr)
        return 1

    # 素材里可能有**已退役科技**的图标（例：research_institute 那条科技已删）。
    # 对不上 id 的只警告 + 跳过 —— 致命的是"某项科技没有图标"，那是 UI 会空一块。
    stale = sorted(i for i in picked if i not in idset)
    if stale:
        print(f'（跳过退役科技的图标，不影响产物）{stale}')
        for i in stale:
            picked.pop(i)
    missing = [i for i in ids if i not in picked]
    if missing:
        print(f'这些科技没有图标：{missing}', file=sys.stderr)
        return 2

    os.makedirs(DST, exist_ok=True)
    made = []
    for gid in sorted(picked):
        f, do_dematt = picked[gid]
        im = Image.open(f).convert('RGBA')
        n = uniform_factor(im)
        if n > 1:
            base = im.resize((im.width // n, im.height // n), Image.NEAREST)
            out = (base.resize((OUT, OUT), Image.NEAREST)
                   if OUT % base.width == 0 else im.resize((OUT, OUT), Image.NEAREST))
            how = f'{im.size} 原生{base.size}({n}x) -> {OUT}'
        else:
            # 真 64x64（两批都是这种）：最近邻降到 32。
            # 不用 LANCZOS —— 它会引入灰边，与硬边像素风格冲突。
            out = im.resize((OUT, OUT), Image.NEAREST)
            how = f'{im.size} -> {OUT}（真高分辨率，最近邻）'
        assert out.size == (OUT, OUT)
        if do_dematt:
            out, removed = dematt(out)
        else:
            # 只把全透明像素的 RGB 清零（白底残留），**不动任何不透明像素**
            out = out.convert('RGBA')
            px = out.load()
            for y in range(OUT):
                for x in range(OUT):
                    if px[x, y][3] == 0:
                        px[x, y] = (0, 0, 0, 0)
            removed = 0
        out.save(os.path.join(DST, gid + '.png'))
        made.append((gid, os.path.basename(f), how, removed, do_dematt))

    print(f'导出 {len(made)}/{len(ids)} 个科技图标 -> {os.path.relpath(DST, ROOT)}')
    total_dematt = 0
    n_skipped = 0
    for gid, f, how, removed, do_dematt in made:
        total_dematt += removed
        if not do_dematt:
            n_skipped += 1
        print(f'   {gid:22s} <- {f:34s} {how}'
              + (f'，去毛边 {removed}px' if removed else '')
              + ('' if do_dematt else '（原图已抠干净，不做去毛边）'))
    print(f'\n去毛边合计 {total_dematt}px；{n_skipped} 张按"原图已抠干净"原样保留')
    return 0


if __name__ == '__main__':
    sys.exit(main())
