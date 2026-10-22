# 抠图：读取本目录(origin2)中指定的立绘 PNG，经 ComfyUI BiRefNet 抠图，
# 输出到 ../cast/ 同名文件（默认覆盖）。
#
# 用法（与 generate.py 相同的选择语法，不带参数 = 全部）：
#   python cutout.py            # 抠本目录全部立绘
#   python cutout.py 1-10       # 序号 1..10
#   python cutout.py 11,13,15   # 序号 11、13、15
import json, os, re, shutil, sys, time, urllib.request

try:  # 控制台是 GBK 时也正确打印中文
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
COMFY = "http://127.0.0.1:8188"
COMFY_INPUT = r"D:\wangxu\Ai\ComfyUI\input"
COMFY_OUTPUT = r"D:\wangxu\Ai\ComfyUI\output"
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "cast"))  # 抠图结果，覆盖同名旧文件
BG_MODEL = "background_removal\\birefnet.safetensors"  # 与面板抠图工作流一致


def build_workflow(filename):
    # 注意：JoinImageWithAlpha 内部会把 alpha 取反(comfy_extras/nodes_compositing.py
    # 的 `1.0 - resize_mask(...)`)，所以 RemoveBackground 之后必须接 InvertMask，
    # 否则人物透明、背景不透明（面板里的 utility_birefnet 工作流同样有 InvertMask）。
    return {
        "1": {"class_type": "LoadImage", "inputs": {"image": filename}},
        "2": {"class_type": "LoadBackgroundRemovalModel", "inputs": {"bg_removal_name": BG_MODEL}},
        "3": {"class_type": "RemoveBackground", "inputs": {
            "bg_removal_model": ["2", 0], "image": ["1", 0]}},
        "6": {"class_type": "InvertMask", "inputs": {"mask": ["3", 0]}},
        "4": {"class_type": "JoinImageWithAlpha", "inputs": {
            "image": ["1", 0], "alpha": ["6", 0]}},
        "5": {"class_type": "SaveImage", "inputs": {
            "images": ["4", 0], "filename_prefix": "npc3cut"}},
    }


def post_json(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_json(url):
    with urllib.request.urlopen(url, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def parse_selection(spec, all_names):
    """按命令行参数筛选；无参数返回全部。支持 1-10 区间与 11,13,15 列表。"""
    if not spec:
        return all_names
    num_to_name = {}
    for name in all_names:
        m = re.match(r"^(\d+)", name)
        if m:
            num_to_name[int(m.group(1))] = name
    picked = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        m = re.match(r"^(\d+)\s*-\s*(\d+)$", tok)
        if m:
            lo, hi = int(m.group(1)), int(m.group(2))
            if lo > hi:
                lo, hi = hi, lo
            picked.extend(range(lo, hi + 1))
        elif tok.isdigit():
            picked.append(int(tok))
        else:
            raise SystemExit("无法识别的选择项: %r（支持 1-10 或 11,13,15）" % tok)
    seen, names = set(), []
    for n in picked:
        if n in num_to_name and n not in seen:
            seen.add(n)
            names.append(num_to_name[n])
    if not names:
        raise SystemExit("参数 %r 没有匹配到任何文件" % spec)
    return names


def check_alpha(path):
    """极性/条纹自检：返回 None=正常，否则返回警告文本。"""
    im = Image.open(path).convert("RGBA")
    w, h = im.size
    px = im.load()
    corner = px[2, 2][3]
    center = px[w // 2, int(h * 0.5)][3]
    if corner > 64 and center < 64:
        return "alpha 极性反了 (bg=%d figure=%d)" % (corner, center)
    if corner > 64:
        return "背景不透明 corner=%d" % corner
    if center < 128:
        return "人物疑似透明 center=%d" % center
    return None


def cutout_one(name):
    src = os.path.join(HERE, "..", "src", name + ".png")
    if not os.path.exists(src):
        return False, "源文件不存在 %s" % src
    # LoadImage 只认 ComfyUI input 目录，先拷过去（同名则覆盖内容）
    shutil.copyfile(src, os.path.join(COMFY_INPUT, name + ".png"))
    res = post_json(COMFY + "/prompt", {"prompt": build_workflow(name + ".png")})
    pid = res.get("prompt_id")
    if not pid:
        return False, "SUBMIT-FAIL %s" % json.dumps(res)[:300]
    hist, deadline = None, time.time() + 300
    while time.time() < deadline:
        h = get_json(COMFY + "/history/" + pid)
        if pid in h:
            hist = h[pid]
            break
        time.sleep(1)
    if hist is None:
        return False, "TIMEOUT"
    if hist.get("status", {}).get("status_str") != "success":
        return False, "FAILED %s" % json.dumps(hist.get("status", {}))[:300]
    saved = None
    for node_out in hist.get("outputs", {}).values():
        for img in node_out.get("images", []):
            src_path = os.path.join(COMFY_OUTPUT, img.get("subfolder", ""), img.get("filename"))
            if os.path.exists(src_path):
                saved = src_path
                break
        if saved:
            break
    if not saved:
        return False, "NO-OUTPUT"
    os.makedirs(OUT_DIR, exist_ok=True)
    dst = os.path.join(OUT_DIR, name + ".png")
    shutil.copyfile(saved, dst)  # 覆盖 npc3 里的旧文件
    warn = check_alpha(dst)
    if warn:
        return False, "%s -> %s" % (dst, warn)
    return True, "size=%s -> %s" % (Image.open(dst).size, dst)


def main():
    spec = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    files = sorted(f[:-4] for f in os.listdir(HERE)
                   if f.lower().endswith(".png") and re.match(r"^\d+", f))
    if not files:
        raise SystemExit("本目录没有可抠图的 PNG（先跑 generate.py）")
    names = parse_selection(spec, files)
    print("本目录 %d 张，本次抠图 %d 张: %s" % (len(files), len(names), ", ".join(names)), flush=True)
    ok = fail = 0
    for i, name in enumerate(names, 1):
        try:
            success, msg = cutout_one(name)
        except Exception as e:
            success, msg = False, "ERROR %s" % e
        print("[%d/%d] %s %s %s" % (i, len(names), "OK  " if success else "FAIL", name, msg), flush=True)
        ok += success
        fail += (not success)
    print("完成：成功 %d，失败 %d" % (ok, fail), flush=True)


if __name__ == "__main__":
    main()
