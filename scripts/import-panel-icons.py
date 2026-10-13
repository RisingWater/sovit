"""把用户给的两张面板图标（64x64）导成游戏用的 32x32。

来源是**聊天附件**，不在素材文件夹里，所以单独一个小脚本，路径写死。
产物 godot/assets/ui/panel/{finance,research}.png 提交进仓库。
"""
from PIL import Image
import os
import sys

A = r'C:\Users\wangxu\.dsh\attachments\v1\objects'
SRCS = {
    'finance': os.path.join(A, '03', '03a91ec8f9878e1505a7257f725418dd5fda52ce0925c0aa37891ab6791c4a60'),
    'research': os.path.join(A, 'ff', 'ff80948521472fb70589db65ea80938a3b016588cde3d0d0d808410ac21b6588'),
}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'ui', 'panel')
OUT = 32


def max_uniform_block(im):
    """最大的 N，使每个 NxN 块都同色（= 原生分辨率的放大倍数）。"""
    px = im.load()
    w, h = im.size
    best = 1
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
            best = n
            break
    return best


def main():
    os.makedirs(DST, exist_ok=True)
    for name, src in SRCS.items():
        if not os.path.exists(src):
            print(f'缺源文件：{src}', file=sys.stderr)
            return 1
        im = Image.open(src).convert('RGBA')
        n = max_uniform_block(im)
        native = (im.width // n, im.height // n)
        # 先回到原生分辨率（无损），再按整数倍放大到 32；32 不是整数倍时用最近邻
        base = im.resize(native, Image.NEAREST) if n > 1 else im
        if OUT % base.width == 0:
            out = base.resize((OUT, OUT), Image.NEAREST)
            how = f'{native[0]}x{native[1]} ×{OUT // base.width}'
        else:
            out = im.resize((OUT, OUT), Image.NEAREST)
            how = f'{im.width}x{im.height} 直接降到 {OUT}'
        assert out.size == (OUT, OUT)
        out.save(os.path.join(DST, f'{name}.png'))
        print(f'{name:9s} {im.size} 原生{native}（{n} 倍放大） -> {how}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
