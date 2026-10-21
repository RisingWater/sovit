#!/usr/bin/env python
"""批量生成 / 后处理 UI 图标（科技树 · 左侧圆钮 · 顶栏）。

风格与分组规则见 `docs/icons.md`；"每个图标画什么"写在 `scripts/icon-manifest.json`。

它做三件事，可以任选其一：

  1) **生成**：把一批图标塞进同一个 ComfyUI prompt —— 一个分支一个图标，各有各的
     提示词和 seed —— 1024×1024 出图，下载到暂存目录（`%TEMP%\\sovit_icons`）；
  2) **后处理**：按分组把背景抠成透明（不带绿的图标用亮绿幕，带绿的用亮品红幕），
     裁到内容、摆成正方形、缩到目标尺寸，写进 `godot/assets/ui/{tech,panel}/<id>.png`；
  3) **审阅**：把一批图标拼成一张 contact sheet（浅灰格子底），一眼看整齐不整齐。

用法：
    python scripts/gen-icons.py --list
    python scripts/gen-icons.py --only stonework,trade --variants 3      # 试 3 种风格（只出预览）
    python scripts/gen-icons.py --only stonework --variant 2             # 用第 2 种风格落盘
    python scripts/gen-icons.py --kind tech --batch 8                    # 正式生成一批
    python scripts/gen-icons.py --all --batch 8                          # 全部（自动分批跑完）
    python scripts/gen-icons.py --all --no-gen                           # 只重跑后处理（不生成）
    python scripts/gen-icons.py --all --no-gen --sheet                   # 重跑后处理 + 拼审阅图

⚠️ 需要 ComfyUI 在 http://127.0.0.1:8188 上跑着，模型见 manifest 的 style.models。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "scripts", "icon-manifest.json")
STAGING = os.path.join(tempfile.gettempdir(), "sovit_icons")
API = os.environ.get("COMFYUI_API", "http://127.0.0.1:8188")

OUT_DIRS = {
    "tech": os.path.join(ROOT, "godot", "assets", "ui", "tech"),
    "panel": os.path.join(ROOT, "godot", "assets", "ui", "panel"),
    "nav": os.path.join(ROOT, "godot", "assets", "ui", "nav"),
    # B4 邦交：势力徽记 / 关系牌 / 动作按钮——三样都放同一个目录（UI 按 id 取图）
    "faction": os.path.join(ROOT, "godot", "assets", "ui", "faction"),
    "relation": os.path.join(ROOT, "godot", "assets", "ui", "faction"),
    "action": os.path.join(ROOT, "godot", "assets", "ui", "faction"),
    # 势力徽章的**设计稿**（256px 单色墨稿）先落在 docs/art/crests/，定稿再缩 48 进游戏
    "crest": os.path.join(ROOT, "docs", "art", "crests"),
}
## 每类的原生尺寸（`--size` 可整体覆盖）：科技 64 → 显示 32；面板 32 → 显示 16/24；
## 徽记 64（设计稿另存 256，见 "crest"）；关系牌 / 动作按钮 32（显示 16~24）
SIZE_BY_KIND = {"tech": 64, "panel": 32, "faction": 48, "relation": 32, "action": 32,
                "crest": 256}
# 用户 2026-10 定的分组规则：**不带绿的图标 → 亮绿幕；带绿的图标 → 亮品红幕**
# 单色墨稿（crest）不要幕布色：直接白底，靠亮度抠（见 ink_knockout）
BG_COLORS = {"green": (0, 255, 0), "magenta": (255, 0, 255), "white": (255, 255, 255)}
BG_NAMES = {"green": "bright green", "magenta": "bright magenta", "white": "white"}


# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------
def load_manifest(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pick_icons(man, args):
    icons = man["icons"]
    if args.only:
        want = [x.strip() for x in args.only.split(",") if x.strip()]
        by_id = {i["id"]: i for i in icons}
        missing = [w for w in want if w not in by_id]
        if missing:
            sys.exit("manifest 里没有这些 id: " + ", ".join(missing))
        return [by_id[w] for w in want]
    if args.kind:
        kinds = {k.strip() for k in args.kind.split(",")}
        return [i for i in icons if i["kind"] in kinds]
    return icons


# ---------------------------------------------------------------------------
# ComfyUI
# ---------------------------------------------------------------------------
def api_get(path):
    with urllib.request.urlopen(API + path, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def api_post(path, payload):
    req = urllib.request.Request(
        API + path, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def api_bytes(path):
    with urllib.request.urlopen(API + path, timeout=180) as r:
        return r.read()


def prompt_for(icon, style, variant):
    v = style["variants"][variant]
    # 变体可以自带 suffix（例如纹章那套要允许"盾形边框"，而物品图标不许有框）
    suffix = v.get("suffix") or style["suffix"]
    return "%s Subject: %s. %s" % (v["prefix"], icon["subject"],
                                   suffix.replace("{BG}", BG_NAMES[icon["bg"]]))


def variant_of(icon, args):
    """这个图标该用第几套提示词：图标自己写了 `variant`（1 起）就用它，否则听 `--variant`。"""
    return int(icon.get("variant", args.variant)) - 1


def build_workflow(items, style, size):
    """items = [(icon, prompt)] —— 一个图标一个分支，共用 UNET / CLIP / VAE。"""
    m = style["models"]
    wf = {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": m["unet"], "weight_dtype": "default"}},
        "2": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["1", 0], "shift": 3}},
        "3": {"class_type": "CLIPLoader", "inputs": {"clip_name": m["clip"], "type": "lumina2", "device": "default"}},
        "4": {"class_type": "VAELoader", "inputs": {"vae_name": m["vae"]}},
    }
    for n, (icon, text) in enumerate(items):
        b = 100 + n * 10
        seed = int(icon.get("seed") or (abs(hash(icon["id"])) % 1_000_000))
        wf[str(b)] = {"class_type": "CLIPTextEncode", "inputs": {"clip": ["3", 0], "text": text}}
        wf[str(b + 1)] = {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": [str(b), 0]}}
        wf[str(b + 2)] = {"class_type": "EmptySD3LatentImage",
                          "inputs": {"width": size, "height": size, "batch_size": 1}}
        wf[str(b + 3)] = {"class_type": "KSampler", "inputs": {
            "model": ["2", 0], "positive": [str(b), 0], "negative": [str(b + 1), 0],
            "latent_image": [str(b + 2), 0], "seed": seed, "steps": 8, "cfg": 1,
            "sampler_name": "res_multistep", "scheduler": "simple", "denoise": 1}}
        wf[str(b + 4)] = {"class_type": "VAEDecode", "inputs": {"samples": [str(b + 3), 0], "vae": ["4", 0]}}
        wf[str(b + 5)] = {"class_type": "SaveImage", "inputs": {
            "images": [str(b + 4), 0], "filename_prefix": "icon_" + icon["id"]}}
    return wf


def run_workflow(wf, timeout=1800):
    pid = api_post("/prompt", {"prompt": wf, "client_id": "gen-icons-" + uuid.uuid4().hex[:8]})["prompt_id"]
    t0 = time.time()
    while True:
        hist = api_get("/history/" + pid)
        if pid in hist:
            return hist[pid]
        if time.time() - t0 > timeout:
            sys.exit("ComfyUI 超时：%s（换小一点的 --batch 重试）" % pid)
        time.sleep(2)


def download_outputs(history, tag):
    """把这次的结果存进暂存目录，返回 {icon_id: 本地路径}。"""
    os.makedirs(STAGING, exist_ok=True)
    out = {}
    for _nid, node_out in (history.get("outputs") or {}).items():
        for img in node_out.get("images", []):
            q = urllib.parse.urlencode({"filename": img["filename"],
                                        "subfolder": img.get("subfolder", ""),
                                        "type": img.get("type", "output")})
            name = img["filename"]
            icon_id = name.split("icon_", 1)[-1].rsplit("_", 2)[0] if "icon_" in name else name
            path = os.path.join(STAGING, "%s__%s.png" % (tag, icon_id))
            with open(path, "wb") as f:
                f.write(api_bytes("/view?" + q))
            out[icon_id] = path
    return out


# ---------------------------------------------------------------------------
# 抠图 / 缩放
# ---------------------------------------------------------------------------
def estimate_bg(im, patch=24):
    """四角小块里最常见的颜色 —— 背景色（渐变幕也能估准）。"""
    a = np.asarray(im.convert("RGB"))
    h, w = a.shape[:2]
    corners = np.concatenate([
        a[:patch, :patch].reshape(-1, 3), a[:patch, w - patch:].reshape(-1, 3),
        a[h - patch:, :patch].reshape(-1, 3), a[h - patch:, w - patch:].reshape(-1, 3)])
    q = (corners // 4) * 4
    uniq, counts = np.unique(q, axis=0, return_counts=True)
    return tuple(int(v) for v in uniq[counts.argmax()])


def color_score(a, bg):
    """"有多像幕布色" —— 用**色相偏向**而不是 RGB 距离。

    RGB 距离在"幕布被画成灰绿、主体也是灰的"时会失效（实测：石头 → 灰绿幕，距离只有 33，
    整块石头被抠掉）。改成看谁压过谁：

      · 绿幕：(G − max(R,B))，越大越绿
      · 品红幕：(min(R,B) − G)，越大越品红

    主体的中性色/暖色/冷色这个值都在 0 附近，所以分得干净；叶子那种真绿只出现在
    **品红幕**那一组，不会被误伤（这正是分组规则存在的意义）。
    """
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    if bg[1] >= max(bg[0], bg[2]):
        return g - np.maximum(r, b)
    return np.minimum(r, b) - g


def key_out(im, bg, lo=10.0, hi=34.0):
    """背景 → 透明：色相分高的地方透明，低的地方不透明，中间给一段软边。

    ⚠️ 不做泛洪：分组规则保证"绿幕的图标里没有绿、品红幕的图标里没有品红"。
    """
    a = np.asarray(im.convert("RGB"), dtype=np.float32)
    score = color_score(a, bg)
    # score 高 = 幕布；lo 以下全不透明，hi 以上全透明，中间线性过渡（当抗锯齿用）
    alpha = np.clip((hi - score) / max(1.0, hi - lo), 0.0, 1.0)
    am = Image.fromarray((alpha * 255.0).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(1.0))
    out = im.convert("RGBA")
    out.putalpha(am)
    return out


def despill(im, bg, edge_alpha=248):
    """压掉半透明边缘上残留的幕布色（绿幕压绿、品红幕压红和蓝）。

    ⚠️ 只动**半透明**像素（alpha < edge_alpha）。以前写成 `al < 260`，结果整张图都在
    "去绿"，把不透明的主体也一起改了色 —— 图标会发灰。
    """
    a = np.asarray(im.convert("RGBA"), dtype=np.int16)
    r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    edge = al < edge_alpha
    if bg[1] >= max(bg[0], bg[2]):          # 绿幕
        a[..., 1] = np.where(edge, np.minimum(g, np.maximum(r, b)), g)
    else:                                    # 品红幕
        a[..., 0] = np.where(edge, np.minimum(r, g), r)
        a[..., 2] = np.where(edge, np.minimum(b, g), b)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def fit_square(im, size, margin=0.05):
    """裁到内容 → 摆成正方形（四周留 margin） → 缩到 size。"""
    im = im.convert("RGBA")
    bbox = im.getbbox()
    if bbox is None:
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))
    im = im.crop(bbox)
    w, h = im.size
    side = int(round(max(w, h) * (1.0 + margin * 2.0)))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(im, ((side - w) // 2, (side - h) // 2), im)
    return canvas.resize((size, size), Image.LANCZOS)


def harden_alpha(im, lo=110):
    """像素风要硬边：半透明阈值化（防"毛边糊一圈"）。"""
    im = im.convert("RGBA")
    a = np.asarray(im.getchannel("A"))
    im.putalpha(Image.fromarray(np.where(a >= lo, 255, 0).astype(np.uint8), "L"))
    return im


def shrink_colors(im, colors=48):
    """压体积：RGB 量化到 N 色（不抖动，保住像素块），alpha 原样保留。"""
    im = im.convert("RGBA")
    rgb = im.convert("RGB").quantize(colors=colors, method=Image.MEDIANCUT, dither=Image.NONE)
    out = rgb.convert("RGBA")
    out.putalpha(im.getchannel("A"))
    return out


def screen_score(im, bg, patch=24):
    """四角小块的幕布分（用来判断模型到底有没有听"用纯幕布色当背景"）。"""
    a = np.asarray(im.convert("RGB"), dtype=np.float32)
    h, w = a.shape[:2]
    corners = np.concatenate([
        a[:patch, :patch].reshape(-1, 3), a[:patch, w - patch:].reshape(-1, 3),
        a[h - patch:, :patch].reshape(-1, 3), a[h - patch:, w - patch:].reshape(-1, 3)])
    return float(np.median(color_score(corners, bg)))


def enhance(im, color=1.0, contrast=1.0):
    """饱和 / 对比度微调（只动 RGB，alpha 原样）。"""
    if color == 1.0 and contrast == 1.0:
        return im
    im = im.convert("RGBA")
    r, g, b, a = im.split()
    rgb = Image.merge("RGB", (r, g, b))
    if color != 1.0:
        rgb = ImageEnhance.Color(rgb).enhance(color)
    if contrast != 1.0:
        rgb = ImageEnhance.Contrast(rgb).enhance(contrast)
    out = rgb.convert("RGBA")
    out.putalpha(a)
    return out


def add_rim(im, color=(38, 26, 18), th=128):
    """给剪影外面加 1px 深色描边 —— 圆钮的木底是棕黄色，带金的图标不加描边会糊在一起。"""
    im = im.convert("RGBA")
    a = im.getchannel("A")
    hard = a.point(lambda v: 255 if v >= 110 else 0)
    dil = hard.filter(ImageFilter.MaxFilter(3))
    rim = ImageChops.subtract(dil, hard)
    out = im.copy()
    d = ImageDraw.Draw(out)
    w, h = out.size
    rp = rim.load()
    for y in range(h):
        for x in range(w):
            if rp[x, y] > 128:
                d.point((x, y), fill=color + (255,))
    return out


def posterize(im, colors=6):
    """压到 N 个色（不抖动）—— 给"纯色平涂"的纹章用：模型总会偷偷加明暗，这一步把渐变拍平。"""
    im = im.convert("RGBA")
    rgb = im.convert("RGB").quantize(colors=colors, method=Image.MEDIANCUT, dither=Image.NONE)
    out = rgb.convert("RGBA")
    out.putalpha(im.getchannel("A"))
    return out


def ink_knockout(im, ink=(58, 44, 32), lo=110.0, hi=190.0):
    """单色纹章：**亮的变透明、暗的变墨色**，得到"实心剪影 + 镂空花纹"。

    参考图那种家族纹章是一整块深色墨（盾面 + 王冠 + 月桂 + 绶带），里面的鹰/塔是**留白**。
    所以不要"抠幕布色"，而是按亮度取反：
      · 亮度高（纸/留白）→ alpha 0
      · 亮度低（墨）    → alpha 255，RGB 统一成深棕墨色（跨 13 张颜色完全一致）
      · 中间给一段软边（原图是矢量边，缩到小尺寸才不锯齿）
    `lo/hi` 是按实测调的两条线：比 lo 暗算墨，比 hi 亮算纸。
    """
    im = im.convert("RGB")
    g = ImageOps.autocontrast(im.convert("L"))
    a = np.asarray(g, dtype=np.float32)
    alpha = np.clip((hi - a) / max(1.0, hi - lo), 0.0, 1.0)
    out = Image.new("RGBA", im.size, tuple(ink) + (255,))
    out.putalpha(Image.fromarray((alpha * 255.0).astype(np.uint8), "L"))
    return out


def process(raw_path, icon, size, post=None):
    post = post or {}
    with Image.open(raw_path) as im:
        rgb = im.convert("RGB")
    if post.get("mono"):
        cut = ink_knockout(rgb, tuple(post.get("ink", (58, 44, 32))),
                           float(post.get("ink_lo", 110)), float(post.get("ink_hi", 190)))
        cut = fit_square(cut, size, margin=post.get("margin", 0.04))
        cut = harden_alpha(cut, lo=110)
        return cut
    bgc = BG_COLORS[icon["bg"]]
    score = screen_score(rgb, bgc)
    if score < 25.0:
        print("  !! 背景不是%s幕（四角幕布分 %.0f）——这张图抠不干净，建议换 seed 重生成" % (
            "绿" if icon["bg"] == "green" else "品红", score))
    cut = key_out(rgb, bgc)
    cut = despill(cut, bgc)
    cut = enhance(cut, post.get("color", 1.0), post.get("contrast", 1.0))
    if post.get("posterize"):
        cut = posterize(cut, int(post["posterize"]))
    cut = fit_square(cut, size, margin=post.get("margin", 0.05))
    cut = harden_alpha(cut)
    if post.get("rim", 0):
        cut = add_rim(cut)
    return shrink_colors(cut)


def make_plate(cfg):
    """左侧圆钮的**圆盘**（外圈深木 → 中圈木色 → 米色盘面），4 倍超采样后缩下来，边缘是抗锯齿的。

    用户 2026-10："圆框全是马赛克……直接用这个带圆形背景的图标吧" —— 圆盘从
    16×16 的按钮贴图（3 倍 Nearest，锯齿块）改成**烤进图标**的 48×48 抗锯齿圆。
    """
    size = int(cfg.get("size", 48))
    ss = 4
    S = size * ss
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = S / 2.0

    def disc(rr, color):
        d.ellipse([c - rr, c - rr, c + rr, c + rr], fill=tuple(color) + (255,))

    r = S / 2.0 - 0.5 * ss
    ring = float(cfg.get("ring_px", 2)) * ss
    frame = float(cfg.get("frame_px", 2)) * ss
    disc(r, cfg.get("ring", [104, 74, 46]))
    disc(r - ring, cfg.get("frame", [196, 156, 108]))
    disc(r - ring - frame, cfg.get("fill", [216, 188, 142]))
    return im.resize((size, size), Image.LANCZOS)


def compose_nav(icon_im, cfg):
    """圆盘 + 图标（图标保持自己的像素尺寸，不缩放，128 倍 …不，1:1 贴上）。"""
    plate = make_plate(cfg)
    n = int(cfg.get("icon_px", 32))
    icon = icon_im.convert("RGBA")
    if icon.size != (n, n):
        icon = icon.resize((n, n), Image.LANCZOS)
    out = plate.copy()
    out.alpha_composite(icon, ((plate.size[0] - n) // 2, (plate.size[1] - n) // 2))
    return out


def contact_sheet(paths, out, cell=64, cols=8, labels=None):
    rows = (len(paths) + cols - 1) // cols
    pad, top = 8, 12
    W = cols * (cell + pad) + pad
    H = rows * (cell + pad + top) + pad
    sheet = Image.new("RGB", (W, H), (236, 232, 222))
    d = ImageDraw.Draw(sheet)
    for i, p in enumerate(paths):
        cx = pad + (i % cols) * (cell + pad)
        cy = pad + (i // cols) * (cell + pad + top)
        d.rectangle([cx - 1, cy - 1, cx + cell, cy + cell], outline=(208, 202, 190))
        with Image.open(p) as im:
            im = im.convert("RGBA")
            sheet.paste(im, (cx, cy), im)
        if labels:
            d.text((cx, cy + cell + 1), labels[i][:10], fill=(90, 80, 70))
    os.makedirs(STAGING, exist_ok=True)
    sheet.save(out)
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="批量生成 / 后处理 UI 图标")
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--only")
    ap.add_argument("--kind")
    ap.add_argument("--all", action="store_true", default=True)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--variant", type=int, default=1, help="用第几种提示词（1 起）")
    ap.add_argument("--variants", type=int, default=0, help="同时试 N 种：只出预览，不落盘")
    ap.add_argument("--preview", action="store_true", help="只出预览（存到暂存目录 + 拼审阅图），不动仓库")
    ap.add_argument("--size", type=int, default=0, help="0 = tech 64 / panel 32")
    ap.add_argument("--gen-size", type=int, default=1024)
    ap.add_argument("--no-gen", action="store_true")
    ap.add_argument("--sheet", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    man = load_manifest(args.manifest)
    style = man["style"]
    icons = pick_icons(man, args)

    if args.list:
        for i in icons:
            print("%-6s %-18s %-8s %s" % (i["kind"], i["id"], i["bg"], i["subject"]))
        print("共 %d 个" % len(icons))
        return

    if args.dry_run:
        for i in icons:
            print("=" * 78)
            print("%s / %s / [%s] / v%d" % (i["kind"], i["id"], i["bg"],
                                            variant_of(i, args) + 1))
            print(prompt_for(i, style, variant_of(i, args)))
        return

    preview = args.variants > 1 or args.preview
    if args.variants > 1:
        first, count = 0, args.variants
    else:
        first, count = args.variant - 1, 1
    if preview:
        # 清掉上一轮的预览，免得审阅图里混进旧图
        for f in os.listdir(STAGING) if os.path.isdir(STAGING) else []:
            if f.startswith("preview_"):
                os.remove(os.path.join(STAGING, f))
    made, labels = [], []

    for start in range(0, len(icons), args.batch):
        chunk = icons[start:start + args.batch]
        # 一个批次里可能混着不同变体（纹章用 v4、其余用 v2）：按**实际变体**分组生成
        if args.variants > 1:
            # 试风格模式：整批都按 CLI 给的区间各来一遍，忽略图标自带的 variant
            groups = {v: list(chunk) for v in range(first, first + count)}
        else:
            groups = {}
            for ic in chunk:
                groups.setdefault(variant_of(ic, args), []).append(ic)
        if not args.no_gen:
            for v, group in sorted(groups.items()):
                tag = "v%d" % (v + 1)
                items = [(ic, prompt_for(ic, style, v)) for ic in group]
                print("生成 %d 个图标 [%s] ..." % (len(group), tag), flush=True)
                hist = run_workflow(build_workflow(items, style, args.gen_size))
                got = download_outputs(hist, tag)
                for ic in group:
                    if ic["id"] not in got:
                        print("  !! 没拿到", ic["id"])

        for v, group in sorted(groups.items()):
            tag = "v%d" % (v + 1)
            post_all = man.get("post", {})
            for ic in group:
                post = post_all.get(ic["kind"], {})
                if preview:
                    raw = os.path.join(STAGING, "%s__%s.png" % (tag, ic["id"]))
                    if not os.path.exists(raw):
                        continue
                    size = args.size or SIZE_BY_KIND[ic["kind"]]
                    im = process(raw, ic, size, post)
                    out = os.path.join(STAGING, "preview_%s_%s.png" % (ic["id"], tag))
                    im.save(out, optimize=True)
                    made.append(out)
                    labels.append("%s %s" % (ic["id"], tag))
                else:
                    raw = os.path.join(STAGING, "%s__%s.png" % (tag, ic["id"]))
                    if not os.path.exists(raw):
                        print("  跳过（没有原图，先用 --gen 生成）", ic["id"])
                        continue
                    size = args.size or SIZE_BY_KIND[ic["kind"]]
                    im = process(raw, ic, size, post)
                    out_dir = OUT_DIRS[ic["kind"]]
                    os.makedirs(out_dir, exist_ok=True)
                    out = os.path.join(out_dir, ic["id"] + ".png")
                    im.save(out, optimize=True)
                    made.append(out)
                    # 左侧圆钮那 7 个：再出一张"圆盘烤进去"的 48×48 版
                    if ic.get("nav"):
                        nav_dir = OUT_DIRS["nav"]
                        os.makedirs(nav_dir, exist_ok=True)
                        nav_out = os.path.join(nav_dir, ic["id"] + ".png")
                        compose_nav(im, man.get("navPlate", {})).save(nav_out, optimize=True)
                        print("  -> %-46s %dx%d  %5d B" % (
                            os.path.relpath(nav_out, ROOT), *compose_nav(im, man.get("navPlate", {})).size,
                            os.path.getsize(nav_out)))
                    labels.append(ic["id"])
                    print("  -> %-46s %dx%d  %5d B" % (
                        os.path.relpath(out, ROOT), im.size[0], im.size[1], os.path.getsize(out)))

    if (args.sheet or preview) and made:
        out = contact_sheet(made, os.path.join(STAGING, "sheet.png"), labels=labels)
        print("审阅图：", out)


if __name__ == "__main__":
    main()
