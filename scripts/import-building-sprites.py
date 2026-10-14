"""把 v3 建筑素材包导入仓库。

用法：python scripts/import-building-sprites.py

素材包**不在仓库里**（在 WorkBuddy 的输出目录下），所以这个脚本只在本地跑一次，
产物 `godot/assets/building_src/<id>.png` 是提交进仓库的 —— 这样没有素材包的人
也能跑 `npm run gen:art`（和 `scripts/import-icons.py` 同一套做法）。

**用中文名对表**，不靠英文名猜：素材包的英文名和我们的 content id 对不上
（`lumber_camp` vs `lumberjack`、`stone_quarry` vs `quarry`、`jerry_shed` vs
`dried_meat_works` …），但中文名是唯一的。

对不上的会**列出来**，不静默跳过。
"""
import json
import os
import re
import shutil
import sys

SRC = r'C:\Users\wangxu\WorkBuddy\2026-10-14-07-02-44\outputs\buildings_v3'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, 'godot', 'assets', 'building_src')


def load(name):
    with open(os.path.join(ROOT, 'content', name), encoding='utf-8') as f:
        return json.load(f)


def main():
    if not os.path.isdir(SRC):
        print(f'素材目录不存在：{SRC}', file=sys.stderr)
        return 1
    os.makedirs(DST, exist_ok=True)

    # 中文名 -> content id
    name2id = {}
    for x in load('buildings.json')['buildings']:
        name2id[x['nameZh']] = x['id']
    for x in load('housing.json')['housing']:
        name2id[x['nameZh']] = x['id']

    files = []
    for f in sorted(os.listdir(SRC)):
        # 序号_英文名_中文名_宽x高.png
        # ⚠️ 英文名里**含下划线**（coarse_mill / hunter_camp），所以英文名那组要贪婪，
        # 中文名那组用 [^_]+ 锁死 —— 否则正则会从第一个下划线切开，
        # 把英文名劈成两半（第一版就是这么错的）。
        m = re.match(r'^(\d+)_(.+)_([^_]+)_(\d+)x(\d+)\.png$', f)
        if m:
            files.append((int(m.group(1)), m.group(2), m.group(3), int(m.group(4)),
                          int(m.group(5)), f))

    imported, unmatched = [], []
    for (idx, en, zh, w, h, fn) in files:
        gid = name2id.get(zh)
        matched = gid is not None
        if not matched:
            # 4 座新建筑 content 里还没有（仓库/市场/别墅/城镇中心）——仍导入备用，
            # 但**不改 content**（那是 docs/town.md 设计稿的实装工作，不属本次范围）
            gid = en
            unmatched.append((idx, en, zh, w, h))
        shutil.copyfile(os.path.join(SRC, fn), os.path.join(DST, f'{gid}.png'))
        imported.append((idx, zh, gid, w, h, matched))

    print(f'导入 {len(imported)} 个 -> {os.path.relpath(DST, ROOT)}')
    for (idx, zh, gid, w, h, matched) in imported:
        mark = '' if matched else '  ← content 里还没有（备用）'
        print(f'  {idx:2d} {zh:8s} -> {gid:22s} {w}x{h}{mark}')
    print(f'\n其中 content 已有条目 {sum(1 for r in imported if r[5])} 个，'
          f'纯备用 {len(unmatched)} 个')
    if unmatched:
        print('⚠️ 这 4 座 content 里没有（已落盘，设计稿实装时直接可用）：')
        for (idx, en, zh, w, h) in unmatched:
            print(f'  {idx:2d} {zh} ({en}) {w}x{h}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
