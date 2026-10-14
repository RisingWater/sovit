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
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'ui', 'tech')
OUT = 32

# 文件名里的科技名 -> 我们的科技 id。只有这一个对不上：
# 素材叫 hunting_camp（按建筑名走的），我们的科技 id 是 hunting。
OVERRIDE = {'hunting_camp': 'hunting'}


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


def main():
    if not os.path.isdir(SRC):
        print(f'素材目录不存在：{SRC}', file=sys.stderr)
        return 1

    techs = json.load(open(os.path.join(ROOT, 'content', 'technologies.json'), encoding='utf-8'))
    ids = [x['id'] for x in techs['technologies']]
    idset = set(ids)

    # 文件名 -> 科技 id
    file_to_id = {}
    for f in sorted(os.listdir(SRC)):
        if not f.endswith('.png') or not f[0].isdigit():
            continue
        base = f.split('_', 1)[1] if '_' in f else f
        base = base.replace('_64x64.png', '')
        file_to_id[f] = OVERRIDE.get(base, base)

    bad = {f: i for f, i in file_to_id.items() if i not in idset}
    if bad:
        print(f'这些图标对不上任何科技 id：{bad}', file=sys.stderr)
        return 2
    missing = [i for i in ids if i not in set(file_to_id.values())]
    if missing:
        print(f'这些科技没有图标：{missing}', file=sys.stderr)
        return 2

    os.makedirs(DST, exist_ok=True)
    made = []
    for f, gid in sorted(file_to_id.items(), key=lambda kv: kv[1]):
        im = Image.open(os.path.join(SRC, f)).convert('RGBA')
        n = uniform_factor(im)
        if n > 1:
            base = im.resize((im.width // n, im.height // n), Image.NEAREST)
            out = (base.resize((OUT, OUT), Image.NEAREST)
                   if OUT % base.width == 0 else im.resize((OUT, OUT), Image.NEAREST))
            how = f'{im.size} 原生{base.size}({n}x) -> {OUT}'
        else:
            # 真 64x64（实测 29 张全是这种）：最近邻降到 32。
            # 不用 LANCZOS —— 它会引入灰边，与硬边像素风格冲突。
            out = im.resize((OUT, OUT), Image.NEAREST)
            how = f'{im.size} -> {OUT}（真高分辨率，最近邻）'
        assert out.size == (OUT, OUT)
        out, removed = dematt(out)
        out.save(os.path.join(DST, gid + '.png'))
        made.append((gid, f, how, removed))

    print(f'导出 {len(made)}/{len(ids)} 个科技图标 -> {os.path.relpath(DST, ROOT)}')
    total_dematt = 0
    for gid, f, how, removed in made:
        total_dematt += removed
        print(f'   {gid:22s} <- {f:34s} {how}' + (f'，去毛边 {removed}px' if removed else ''))
    print(f'\n去毛边合计 {total_dematt}px')
    return 0


if __name__ == '__main__':
    sys.exit(main())
