# 读取同目录 prompt.json，调用 ComfyUI(z-image-turbo) 生成白底立绘到本目录，同名覆盖。
#
# 用法（不带参数 = 全部生成）：
#   python generate.py            # 生成全部 21 张
#   python generate.py 1-10       # 生成序号 1..10
#   python generate.py 11,13,15   # 生成序号 11、13、15 这三张
# 序号即文件名前缀（01_sebastian.png 的 01、11_adderick.png 的 11 ...）。
import json, os, random, re, shutil, sys, time, urllib.request

try:  # 控制台是 GBK 时也正确打印中文
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
COMFY = "http://127.0.0.1:8188"
OUTPUT_DIR = r"D:\wangxu\Ai\ComfyUI\output"
PROMPT_FILE = os.path.join(HERE, "prompt.json")
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "src"))  # 生成结果放到 ../src/
PREFIX = "origin2gen"


def build_workflow(prompt_text, seed):
    return {
        "3": {"class_type": "KSampler", "inputs": {
            "model": ["11", 0], "positive": ["27", 0], "negative": ["33", 0],
            "latent_image": ["13", 0], "seed": seed, "steps": 8, "cfg": 1,
            "sampler_name": "res_multistep", "scheduler": "simple", "denoise": 1}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["29", 0]}},
        "9": {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": PREFIX}},
        "11": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["28", 0], "shift": 3}},
        "13": {"class_type": "EmptySD3LatentImage", "inputs": {
            "width": 1024, "height": 1536, "batch_size": 1}},
        "27": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["30", 0], "text": prompt_text}},
        "28": {"class_type": "UNETLoader", "inputs": {
            "unet_name": "z_image_turbo_bf16.safetensors", "weight_dtype": "default"}},
        "29": {"class_type": "VAELoader", "inputs": {"vae_name": "ae.safetensors"}},
        "30": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": "qwen_3_4b.safetensors", "type": "lumina2", "device": "default"}},
        "33": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["27", 0]}},
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
    """按命令行参数筛选要生成的名字；无参数返回全部。"""
    if not spec:
        return all_names
    # 收集所有合法序号（文件名前导数字）
    num_to_name = {}
    for name in all_names:
        m = re.match(r"^(\d+)", name)
        if m:
            num_to_name[int(m.group(1))] = name
    picked_nums = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        m = re.match(r"^(\d+)\s*-\s*(\d+)$", tok)
        if m:  # 区间，如 1-10
            lo, hi = int(m.group(1)), int(m.group(2))
            if lo > hi:
                lo, hi = hi, lo
            picked_nums.extend(range(lo, hi + 1))
        elif tok.isdigit():  # 单个，如 13
            picked_nums.append(int(tok))
        else:
            raise SystemExit("无法识别的选择项: %r（支持 1-10 或 11,13,15）" % tok)
    seen, names = set(), []
    for n in picked_nums:
        if n in num_to_name and n not in seen:
            seen.add(n)
            names.append(num_to_name[n])
    if not names:
        raise SystemExit("参数 %r 没有匹配到任何角色" % spec)
    return names


def generate_one(name, prompt_text):
    seed = random.randint(0, 2 ** 32 - 1)
    wf = build_workflow(prompt_text, seed)
    res = post_json(COMFY + "/prompt", {"prompt": wf})
    pid = res.get("prompt_id")
    if not pid:
        return False, "SUBMIT-FAIL %s" % json.dumps(res)[:300]
    hist, deadline = None, time.time() + 300
    while time.time() < deadline:
        h = get_json(COMFY + "/history/" + pid)
        if pid in h:
            hist = h[pid]
            break
        time.sleep(1.5)
    if hist is None:
        return False, "TIMEOUT"
    saved = None
    for node_out in hist.get("outputs", {}).values():
        for img in node_out.get("images", []):
            src = os.path.join(OUTPUT_DIR, img.get("subfolder", ""), img.get("filename"))
            if os.path.exists(src):
                saved = src
                break
        if saved:
            break
    if not saved:
        return False, "NO-OUTPUT %s" % json.dumps(hist)[:300]
    dst = os.path.join(OUT_DIR, name + ".png")
    shutil.copyfile(saved, dst)  # 默认覆盖
    return True, "seed=%d -> %s" % (seed, dst)


def main():
    spec = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    with open(PROMPT_FILE, encoding="utf-8") as f:
        prompts = json.load(f)
    all_names = list(prompts.keys())
    names = parse_selection(spec, all_names)
    if os.environ.get("DRYRUN"):
        print("DRYRUN 全部 %d 张，本次选中 %d 张: %s" % (
            len(all_names), len(names), ", ".join(names)), flush=True)
        return
    print("全部 %d 张，本次生成 %d 张: %s" % (len(all_names), len(names), ", ".join(names)), flush=True)
    ok = fail = 0
    for i, name in enumerate(names, 1):
        try:
            success, msg = generate_one(name, prompts[name]["prompt"])
        except Exception as e:
            success, msg = False, "ERROR %s" % e
        tag = "OK  " if success else "FAIL"
        print("[%d/%d] %s %s %s" % (i, len(names), tag, name, msg), flush=True)
        ok += success
        fail += (not success)
    print("完成：成功 %d，失败 %d" % (ok, fail), flush=True)


if __name__ == "__main__":
    main()
