class_name GoodIcons
extends RefCounted

# ---------------------------------------------------------------------------
# 商品图标：**全 UI 唯一的加载入口**。
#
#   res://assets/icons/<id>.png  —— 手绘图标（2026-10 的 v7 那批起是 **64×64**；
#                                  更早的 36 张是 32×32，另有三张住房图标 32×32）
#
# **没有兜底图**（2026-10 用户拍板）：以前 icons/ 缺图时会静默回滚到
# `assets/goods/` 那套程序化 16×16 旧图 —— 旧图和手绘风格不一致，缺了哪张
# 根本看不出来。现在缺图直接返回**亮品红方块**（FF00FF）：刺眼、一眼定位，
# 比"悄悄换旧图"好修得多。`assets/goods/` 目录（连同 `gen:art` 的生成逻辑）
# 已整体删除。
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

## 图标**原生**尺寸：v7 那批是 64，更早的是 32。各面板按自己的格子缩放，
## 别拿这个常量当显示尺寸硬取。
const SIZE := 64

static var _cache: Dictionary = {}
static var _missing: ImageTexture = null

## 缺图占位：亮品红方块（故意刺眼，方便快速定位缺的是哪张）。
static func _placeholder() -> ImageTexture:
	if _missing != null:
		return _missing
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.0, 1.0, 1.0))
	_missing = ImageTexture.create_from_image(img)
	return _missing

## 取某商品的图标；库里没有就返回亮品红方块占位（永远不会是 null）。
static func tex(gid: String) -> Texture2D:
	if _cache.has(gid):
		return _cache[gid]
	var found: Texture2D = null
	var path: String = ICON_DIR + gid + ".png"
	if ResourceLoader.exists(path):
		found = load(path)
	if found == null:
		push_warning("缺商品图标：%s（显示为品红方块）" % path)
		found = _placeholder()
	_cache[gid] = found
	return found

## 该商品有没有手绘图标（没有就是缺图，UI 上会是品红方块）。
static func is_hand_drawn(gid: String) -> bool:
	return ResourceLoader.exists(ICON_DIR + gid + ".png")

## 手绘图标的张数（门槛测试用）。
static func count_hand_drawn() -> int:
	var n := 0
	for f in DirAccess.get_files_at("res://assets/icons"):
		if f.ends_with(".png"):
			n += 1
	return n
