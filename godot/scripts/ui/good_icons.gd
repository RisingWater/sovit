class_name GoodIcons
extends RefCounted

# ---------------------------------------------------------------------------
# 商品图标：**全 UI 唯一的加载入口**。
#
# 两套图标共存，手绘优先：
#   res://assets/icons/<id>.png  —— 手绘图标（2026-10 的 v7 那批起是 **64×64**；
#                                  更早的 36 张是 32×32，另有三张住房图标 32×32）
#   res://assets/goods/<id>.png  —— `npm run gen:art` 程序化生成的 16x16 兜底
#
# 为什么必须分两个目录：gen:art 每次跑都会**整体重写** goods/，
# 手绘图标放同一个目录会被无声覆盖（4 个速度图标就栽在这上面）。
#
# 为什么要有这个单点入口：顶栏 / 统计面板 / 资源选择 / 科技面板四处都要图标，
# 各写一份 load 路径的话，将来换目录或加新图源必然漏改一两处，
# 表现就是"某个面板的图标突然变回旧的"，而且很难查。
#
# ⚠️ **显示尺寸各处自己定（16 / 32），但一律用 `STRETCH_KEEP_ASPECT_CENTERED`**：
#    原生 64 的图标放进 32 的格子，用 `KEEP_CENTERED` 会画到格子外面去。
#    64 → 32、64 → 16 都是整除，像素不糊。
# ---------------------------------------------------------------------------

const ICON_DIR := "res://assets/icons/"
const FALLBACK_DIR := "res://assets/goods/"

## 图标**原生**尺寸：v7 那批是 64，更早的是 32，程序化兜底是 16。
## 各面板按自己的格子缩放，别拿这个常量当显示尺寸硬取。
const SIZE := 64

static var _cache: Dictionary = {}

## 取某商品的图标；两处都没有则返回 null（调用方自己决定要不要占位）。
static func tex(gid: String) -> Texture2D:
	if _cache.has(gid):
		return _cache[gid]
	var found: Texture2D = null
	for dir in [ICON_DIR, FALLBACK_DIR]:
		var path: String = String(dir) + gid + ".png"
		if ResourceLoader.exists(path):
			found = load(path)
			break
	_cache[gid] = found
	return found

## 该商品有没有手绘图标（没有就是还在用程序化兜底）。
static func is_hand_drawn(gid: String) -> bool:
	return ResourceLoader.exists(ICON_DIR + gid + ".png")

## 手绘图标的张数（门槛测试用）。
static func count_hand_drawn() -> int:
	var n := 0
	for f in DirAccess.get_files_at("res://assets/icons"):
		if f.ends_with(".png"):
			n += 1
	return n
