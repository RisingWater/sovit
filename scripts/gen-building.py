#!/usr/bin/env python
"""生成建筑贴图（v3 建筑素材包那一套风格）。

风格基准是 `godot/assets/building_src/` 里的 v3 建筑图：**2× 密度像素、粗深棕描边、
正面略带俯视、站在基线上一动不动、透明底**。抠图 / 缩放 / 量化直接复用
`scripts/gen-icons.py` 里那套（色相抠图 + despill + 硬边 + 48 色），别在这儿重写。

用法：
    python scripts/gen-building.py --list
    python scripts/gen-building.py --only embassy --candidates 4      # 出 4 个候选 + 审阅图
    python scripts/gen-building.py --only embassy --pick 2            # 把第 2 个候选落盘
    python scripts/gen-building.py --only embassy --pick 2 --no-gen    # 只重跑后处理

产物：`godot/assets/building_src/<id>.png`（**素材副本**，入库）。
之后 `npm run gen:art` 会把它做成 `godot/assets/buildings/<id>.png` + 缩略图 ——
前提是 `content/buildings.json` 里有这座建筑（`art.arch: "sprite"`）。

⚠️ 需要 ComfyUI 在 http://127.0.0.1:8188 上跑着（模型见 manifest.style.models）。
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "scripts", "building-manifest.json")
OUT_DIR = os.path.join(ROOT, "godot", "assets", "building_src")
STAGING = os.path.join(os.environ.get("TEMP", "/tmp"), "sovit_buildings")


def load_icons_module():
    """把 gen-icons.py 当模块加载（文件名带连字符，不能直接 import）。"""
    path = os.path.join(ROOT, "scripts", "gen-icons.py")
    spec = importlib.util.spec_from_file_location("gen_icons", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def fit_building(im, out_width, max_height):
    """裁到内容 → 等比缩到 out_width（太高就按 max_height 收） → 底边贴齐、不加留白。"""
    im = im.convert("RGBA")
    bbox = im.getbbox()
    if bbox is None:
        return Image.new("RGBA", (out_width, 1), (0, 0, 0, 0))
    im = im.crop(bbox)
    w, h = im.size
    scale = min(out_width / float(w), max_height / float(h))
    tw, th = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    return im.resize((tw, th), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser(description="生成建筑贴图（v3 风格）")
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--only")
    ap.add_argument("--candidates", type=int, default=4, help="一次出几个候选（只出预览）")
    ap.add_argument("--pick", type=int, default=0, help="把第几个候选落盘（1 起）")
    ap.add_argument("--no-gen", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    man = json.load(open(args.manifest, encoding="utf-8"))
    items = man["buildings"]
    if args.only:
        want = [x.strip() for x in args.only.split(",") if x.strip()]
        by_id = {b["id"]: b for b in items}
        missing = [w for w in want if w not in by_id]
        if missing:
            sys.exit("manifest 里没有这些 id: " + ", ".join(missing))
        items = [by_id[w] for w in want]

    if args.list:
        for b in items:
            print("%-16s %dx%d → 宽 %d（最高 %d）  %s"
                  % (b["id"], b["gen_width"], b["gen_height"], b["out_width"],
                     b["max_height"], b["subject"]))
        return

    gi = load_icons_module()
    # ⚠️ `download_outputs` 用的是 gen-icons 自己的暂存目录 —— 指到这边来，
    #    否则原图下到 `%TEMP%\sovit_icons`、这里去 `sovit_buildings` 找，永远"没拿到"。
    gi.STAGING = STAGING
    style = man["style"]
    os.makedirs(STAGING, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    sheet_paths = []

    for b in items:
        bid = b["id"]
        if not args.no_gen:
            n = args.candidates
            branch_items = []
            for k in range(n):
                branch_items.append(({
                    "id": "%s_c%d" % (bid, k + 1),
                    "bg": b["bg"],
                    "subject": b["subject"],
                    "seed": 1000 * (abs(hash(bid)) % 1000) + k * 7919,
                }, None))
            items_prompts = [(ic, gi.prompt_for(ic, style, 0)) for ic, _ in branch_items]
            print("生成 %d 个候选：%s ..." % (n, bid), flush=True)
            wf = gi.build_workflow(items_prompts, style, b["gen_width"])
            # 建筑不是正方形：把每个分支的 latent 改成宽幅
            for node in wf.values():
                if node["class_type"] == "EmptySD3LatentImage":
                    node["inputs"]["width"] = b["gen_width"]
                    node["inputs"]["height"] = b["gen_height"]
            hist = gi.run_workflow(wf)
            got = gi.download_outputs(hist, "b")
            for k in range(n):
                key = "%s_c%d" % (bid, k + 1)
                if key not in got:
                    print("  !! 没拿到", key)

        for k in range(1, args.candidates + 1):
            raw = os.path.join(STAGING, "b__%s_c%d.png" % (bid, k))
            if not os.path.exists(raw):
                continue
            with Image.open(raw) as im:
                rgb = im.convert("RGB")
            bgc = gi.BG_COLORS[b["bg"]]
            score = gi.screen_score(rgb, bgc)
            if score < 25.0:
                print("  !! %s_c%d 背景不是纯幕（分 %.0f）" % (bid, k, score))
            cut = gi.key_out(rgb, bgc)
            cut = gi.despill(cut, bgc)
            out = fit_building(cut, b["out_width"], b["max_height"])
            out = gi.harden_alpha(out)
            out = gi.shrink_colors(out)
            prev = os.path.join(STAGING, "preview_%s_c%d.png" % (bid, k))
            out.save(prev, optimize=True)
            sheet_paths.append(prev)
            print("  候选 %d: %dx%d  %s" % (k, out.size[0], out.size[1], prev))

        if args.pick:
            src = os.path.join(STAGING, "preview_%s_c%d.png" % (bid, args.pick))
            if not os.path.exists(src):
                sys.exit("没有候选 %d：%s" % (args.pick, src))
            dst = os.path.join(OUT_DIR, bid + ".png")
            Image.open(src).save(dst, optimize=True)
            print("落盘 -> %s  %dx%d  %d B" % (os.path.relpath(dst, ROOT),
                  *Image.open(dst).size, os.path.getsize(dst)))

    if sheet_paths:
        sheet = os.path.join(STAGING, "sheet.png")
        gi.contact_sheet(sheet_paths, sheet, cell=160, cols=4,
                         labels=[os.path.basename(p) for p in sheet_paths])
        print("审阅图：", sheet)


if __name__ == "__main__":
    main()
