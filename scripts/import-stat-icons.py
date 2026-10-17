"""导入顶栏 / 侧边圆钮用的"状态"图标。

用法：python scripts/import-stat-icons.py

源：本地素材包 `D:\\wangxu\\game\\图标素材`（作者 workbuddy，MIT）。
素材包**不入库**，只提交导出的 PNG —— 与商品图标的处理方式一致。

命名：中文文件名 -> 英文 id（population / money / build …）。
中文名在跨平台工具链里最容易出编码问题，落盘一律用英文。

产物：godot/assets/ui/panel/<id>.png（32x32）
"""
from PIL import Image
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from icon_util import dematt  # noqa: E402

SRC = r'D:\wangxu\game\图标素材'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'ui', 'panel')
OUT = 32

# 素材中文名 -> 游戏里的英文 id
WANT = {
    '人口': 'population',
    '就业': 'employed',
    '金币': 'money',
    '建造力': 'build',
    '研究力': 'research',
    '移民': 'migration',
    '资源工业': 'resource',
    '满意度': 'satisfaction',
    '04_finance_64x64': 'finance',
    '05_research_64x64': 'research_panel',
    # 2026-10 后加的两张（同一套、workbuddy 自绘）：
    #   任务追踪条标题 / 任务面板标题 / 左侧圆钮第 5 个 = 剪贴板 + 星
    #   AI 辅助三处（顶栏按钮 / ESC 菜单那一行 / 面板标题）= 金色问号
    # 两张都是 32x32 透明底、没有外圈毛边，所以 dematt 对它们是空操作。
    '09_task_panel_32x32': 'quest_panel',
    '08_question_mark_gold_32x32': 'ai_assist',
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


def main():
    if not os.path.isdir(SRC):
        print(f'素材目录不存在：{SRC}', file=sys.stderr)
        return 1
    os.makedirs(DST, exist_ok=True)
    made, missing = [], []
    for zh, gid in WANT.items():
        p = os.path.join(SRC, zh + '.png')
        if not os.path.exists(p):
            # 源文件不在素材文件夹里（04_finance / 05_research 是从聊天附件来的），
            # 但已导出的图还在。dematt 是**幂等**的，所以就地再处理一遍即可，
            # 不用回头找原图。
            out_p = os.path.join(DST, gid + '.png')
            if os.path.exists(out_p):
                fixed, n = dematt(Image.open(out_p))
                fixed.save(out_p)
                made.append((zh, gid, f'源缺失，就地去毛边 {n}px'))
            else:
                missing.append((zh, gid))
            continue
        im = Image.open(p).convert('RGBA')
        n = uniform_factor(im)
        if n > 1:
            # 整数倍放大：先无损回到原生，再按整数倍放到 32
            base = im.resize((im.width // n, im.height // n), Image.NEAREST)
            out = (base.resize((OUT, OUT), Image.NEAREST)
                   if OUT % base.width == 0 else im.resize((OUT, OUT), Image.NEAREST))
            how = f'{im.size} 原生{base.size}({n}x) -> {OUT}'
        else:
            out = im.resize((OUT, OUT), Image.NEAREST)
            how = f'{im.size} -> {OUT}（真高分辨率，最近邻）'
        assert out.size == (OUT, OUT)
        # 去掉外圈那 1px 浅色毛边（在深色顶栏上看着就是白边）
        out, n_removed = dematt(out)
        out.save(os.path.join(DST, gid + '.png'))
        made.append((zh, gid, how + (f'，去毛边 {n_removed}px' if n_removed else '')))

    print(f'导出 {len(made)} 个状态图标 -> {os.path.relpath(DST, ROOT)}')
    for zh, gid, how in made:
        print(f'   {zh:12s} -> {gid:14s} {how}')
    if missing:
        print(f'\n素材包里没有（{len(missing)} 个）：')
        for zh, gid in missing:
            print(f'   {zh} -> {gid}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
