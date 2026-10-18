extends PanelContainer

# 王国地图（2026-10-20）—— 点左上角的小地图进来。
#
# 底图 `assets/ui/map/kingdom_map_bare.jpg`（1536×952，羊皮纸手绘风，已经裁掉右下角的水印）。
# 底图**一个字都没有**：地名、据点、箭头全由这一层按**比例坐标**画上去，
# 所以换分辨率/换窗口大小都只是缩放，不会错位。
#
# 图上的东西分三种：
#   · 区域名（大号、褪色）—— 瓦尔登王国 / 圣辉教国 / 铁峰公国 / 沙海汗国 / 翡翠海 / 灰岩山脉
#   · 据点（图标 + 名字）—— 六种图标：大城镇 / 中城镇 / 小城镇 / 村庄 / 蛮族部落 / 圣城
#   · hover 卡片 —— 城镇名 + 领主 + 特产（用户 2026-10-20 点名要这三样）
#
# ⚠️ **我们自己的据点跟着城镇中心变**（用户 2026-10-20）：
#   废墟（开局）= 村庄 → 初步修缮 = 小城镇 → 修好 = 中城镇。
# ⚠️ 点位是**表现层数据**（下面的 `MARKS` / `REGIONS`），仿真一个字节都不读它；
#   坐标是底图的**比例**（0..1），改底图/改点位只动这两张表。
# ⚠️ 图标是 `assets/ui/map/<kind>.png` + `<kind>_hover.png`（第二行那张点亮版）。

var runner: SimRunner
var world: Node

## 底图（比例 = 1536 : 952）。`_layout()` 按它算居中矩形。
const MAP_ASPECT := 2048.0 / 1366.0
const MAP_PATH := "res://assets/ui/map/kingdom_map_bare.jpg"
## 地图上那几行英文地名用的字体（用户 2026-10-20 指定 Lin Libertine，衬线体，手绘古地图的味道）。
## 授权：GPL + 字体例外 / 另附 OFL 1.1 —— 文本随字体放在 `assets/fonts/libertine/`。
## ⚠️ 只给**地图上的字**用：面板标题、卡片、按钮仍然走像素字体（那是 UI，不是地图）。
const MAP_FONT := "res://assets/fonts/libertine/LinLibertine_DR.otf"
const ICON_DIR := "res://assets/ui/map/"
## 据点图标占地图高度的百分比（大城镇画得比村庄大，是**素材自带**的相对大小，
## 这里只给一个统一缩放比 —— 别按类型改，否则大城市和小村庄会长得一样大）。
const ICON_H := 0.085
## hover 时放大到多少（和鼠标一起晃一下就够了，别做动画）
const HOVER_SCALE := 1.14

## 城镇名/卡片用的墨色（羊皮纸上的深褐）
const INK := Color(0.24, 0.16, 0.10)
## 地图地名：深褐近黑、几乎不透（用户 2026-10-20："颜色太浅了，加深" + "白边去掉"）
const INK_DIM := Color(0.19, 0.11, 0.04, 0.95)
## 地名的**首字母**比其余字大这么多号（用户 2026-10-20："首字母再加两个字号" → 2 → 4）
const FIRST_EXTRA := 4

## 区域名：text / fx / fy / size（size = 正文字号，首字母自动 +FIRST_EXTRA）
## ⚠️ 2026-10-20 用户："汉字，瓦尔登王国，圣辉教国，沙海汗国，翡翠海，全地图的文字都写英文" ——
##    地图上的字**一律英文**（羊皮纸手绘地图的味道），中文只出现在 hover 卡片里。
## ⚠️ 2026-10-20 又一版："整体字号加大 1-2 个字号"（下面已经是加大后的）、
##    "西边国家叫做 DUCHY，北边的英文叫 THE HOLY"。
const REGIONS := [
	{"text": "THE HOLY", "fx": 0.4080, "fy": 0.0620, "size": 22},
	{"text": "WALDEN", "fx": 0.6820, "fy": 0.2150, "size": 30},
	{"text": "JADE SEA", "fx": 0.8840, "fy": 0.3150, "size": 24},
	{"text": "DUCHY", "fx": 0.1330, "fy": 0.2560, "size": 18},
	{"text": "GREYROCK RANGE", "fx": 0.3000, "fy": 0.3400, "size": 18},
	{"text": "VALR RIVER", "fx": 0.6300, "fy": 0.5300, "size": 16},
	{"text": "KHANATE", "fx": 0.1500, "fy": 0.7950, "size": 22},
]

## 据点：id / kind / fx / fy / 名字 / 领主 / 特产。
## 名字与领主见 `docs/story.md` §1.1、§二；特产用国别表里那一列。
## ⚠️ 2026-10-20 用户："所有城镇地图上不显示名字，城镇名字放在 tip 里显示" ——
##    地图上只画图标，名字/领主/特产全在 hover 卡片里。
## ⚠️ 首都单独一座（用户："首都应该是铁王城哪个位置吧，刚刚放大的应该是首都，
##    铁王城应该在首都东边吧"）：中心放大那座是**王都**，铁王城在东边。
const MARKS := [
	{"id": "capital", "kind": "town_large", "fx": 0.4546, "fy": 0.4293, "scale": 1.45,
		"name": "王都", "lord": "国王 奥德里克三世（长子阿尔伯特留守）", "specialty": "铁、马"},
	{"id": "iron_crown", "kind": "town_medium", "fx": 0.6058, "fy": 0.3955,
		"name": "铁王城", "lord": "阿尔伯特（长子）· 掌国库", "specialty": "铁、马"},
	{"id": "iron_rook", "kind": "town_medium", "fx": 0.3908, "fy": 0.2343,
		"name": "铁鸦堡", "lord": "伯纳德（次子）", "specialty": "铁、军械"},
	{"id": "holy_flame", "kind": "town_medium", "fx": 0.6084, "fy": 0.1914,
		"name": "圣火城", "lord": "塞德里克（三子）", "specialty": "圣物、香火"},
	{"id": "dawn", "kind": "town_medium", "fx": 0.7764, "fy": 0.6108,
		"name": "曙光城", "lord": "伊莲娜（长女）", "specialty": "典籍、纸"},
	{"id": "golden_ear", "kind": "town_medium", "fx": 0.5840, "fy": 0.6562,
		"name": "金穗城", "lord": "狄奥多（四子）", "specialty": "粮食、盐"},
	{"id": "blackstone", "kind": "town_medium", "fx": 0.3572, "fy": 0.5605,
		"name": "黑石堡", "lord": "弗雷德里克（六子）", "specialty": "铁、煤"},
	{"id": "peak", "kind": "town_medium", "fx": 0.0867, "fy": 0.1914,
		"name": "铁峰城", "lord": "大公 赫尔曼", "specialty": "铁、煤"},
	{"id": "jade", "kind": "town_large", "fx": 0.7453, "fy": 0.7582,
		"name": "翡翠城", "lord": "女王 艾瑟琳", "specialty": "香料、丝绸、宝石"},
	{"id": "holy_see", "kind": "temple", "fx": 0.4740, "fy": 0.1121,
		"name": "圣都", "lord": "教皇 格里高利", "specialty": "圣物、书"},
	{"id": "khan", "kind": "camp", "fx": 0.2035, "fy": 0.9181,
		"name": "汗庭", "lord": "大汗 巴图尔", "specialty": "马匹、盐、皮毛"},
]

## 我们自己的那一座（图标按城镇中心段位换）
const HOME := {"id": "ashen_vale", "fx": 0.6823, "fy": 0.8854,
	"lord": "你（第七王子）", "specialty": "木材、石块、粘土"}

var _map: TextureRect
var _host: Control
var _marks: Array = []          # [{data, node, tex, tex_hover}]
var _labels: Array = []         # [{text, node, fx, fy}]
var _card: PanelContainer
var _card_title: Label
var _card_body: Label
var _hover := -1
var _tex_cache: Dictionary = {}
## 当前底图矩形（`_layout()` 算完存一份，拖拽换算坐标要用）
var _rect := Rect2()
## 布置模式：拖图标 / 拖地名，松手自动写盘（用户自己校点位，不必改代码）
var _edit := false
var _drag := -1
## 布置模式下"当前选中的那一个"（据点下标；<= -1000 表示地名 -1000-i），方向键微调它
var _sel := -1
## 拖拽起点（按下时的比例坐标 + 鼠标在 host 里的像素位置）—— 这样拖谁都不会"跳一下"
var _grab_frac := Vector2.ZERO
var _grab_pos := Vector2.ZERO
var _readout: Label
var _edit_btn: Button
## 布置工具那一整块（默认隐藏，ESC 菜单开了「调试功能」才露）
var _tools_box: VBoxContainer
## 内置坐标的原始值（"恢复默认"用）
var _defaults: Dictionary = {}

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	# 全屏（和其它圆钮面板同一口径），盖住地图与建造栏，只留顶栏
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	# 用户 2026-10-20："这个窗口直接占满了，不要留上面顶栏" —— 地图面板**连顶栏一起盖**。
	# 于是回到村子只能靠右上角「关闭」或 Esc（两处都在，`main._unhandled_input` 里先关地图）。
	offset_top = 0.0
	offset_bottom = 0.0
	offset_left = 0.0
	offset_right = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 用户 2026-10-20："这里不要是灰色，面板黄色" —— 用和其它面板同一套米黄底
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 14, 10, 14, 12))
	visible = false

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# 标题行：「王国地图」+ 一句提示 + 关闭
	# （没有合适的图标素材 —— 宁可只有字，也不要挂一个语义不对的图标）
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	var title := UIKit.label("王国地图", UIKit.FG_HEAD)
	title.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(title)
	var hint := UIKit.label("（五国与七子的领地 —— 点地图左上角的小地图随时回来）", UIKit.FG_DIM)
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(hint)
	head.add_child(UIKit.spacer())
	var close := UIKit.button("关闭", true)
	close.tooltip_text = "回到村子（Esc 也行）"
	close.pressed.connect(close_panel)
	head.add_child(close)

	root.add_child(UIKit.hsep())

	# 第二行：**布置工具**（用户 2026-10-20："你能不能让我自己调整城镇的位置，
	# 有修改坐标什么的，这样我就不用叫你改了"）。
	# 点「布置城市」→ 图标和地名都能拖，松手**自动存盘**；坐标也手写在 JSON 里。
	# ⚠️ 这一整块**默认藏起来**（用户 2026-10-20："这四个按钮默认都隐藏掉，
	# 如果在 esc 把调试开关打开……才显示"）—— 总闸是 `world.debug_footprints`
	# （ESC 菜单里的「调试功能」，见 `esc_menu.gd::_toggle_debug`）。
	_tools_box = VBoxContainer.new()
	_tools_box.add_theme_constant_override("separation", 6)
	_tools_box.visible = false
	root.add_child(_tools_box)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 5)
	_tools_box.add_child(tools)
	_edit_btn = UIKit.button("布置城市", false)
	_edit_btn.toggle_mode = true
	_edit_btn.tooltip_text = "打开后：拖动图标/地名即可改位置，松手自动保存（坐标存在 res://data/map_layout.json，导出后退回 user://）"
	_edit_btn.toggled.connect(_on_edit_toggled)
	tools.add_child(_edit_btn)
	var reload := UIKit.button("重新读入", false)
	reload.tooltip_text = "比如你在文本编辑器里手改了 JSON —— 点这里马上生效"
	reload.pressed.connect(func(): _load_layout())
	tools.add_child(reload)
	var open_dir := UIKit.button("打开文件夹", false)
	open_dir.tooltip_text = "在资源管理器里打开那个 JSON 所在的文件夹"
	open_dir.pressed.connect(_open_layout_dir)
	tools.add_child(open_dir)
	var reset := UIKit.button("恢复默认", false)
	reset.tooltip_text = "删掉自己调过的坐标，回到代码里写的那一套"
	reset.pressed.connect(_reset_layout)
	tools.add_child(reset)
	tools.add_child(UIKit.hsep())
	_readout = UIKit.label("", UIKit.FG_DIM)
	_readout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tools.add_child(_readout)
	_tools_box.add_child(UIKit.hsep())

	# 地图书：底图 + 据点 + 地名，全部手动摆（按比例）
	_host = Control.new()
	_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_host)

	_map = TextureRect.new()
	_map.texture = load(MAP_PATH)
	_map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map.stretch_mode = TextureRect.STRETCH_SCALE
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 底图是画出来的羊皮纸（不是像素图）：用线性过滤缩，最近邻会满屏锯齿
	_map.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_host.add_child(_map)

	_build_regions()
	_build_marks()
	_build_card()
	_host.resized.connect(_layout)
	_layout()

## 区域名：深墨衬线体，压在底图上；平时不吃鼠标，**布置模式下可以拖**
##
## ⚠️ 每个地名是**两块** Label：首字母（大 `FIRST_EXTRA` 号）+ 其余（正文号）。
## 手绘古地图上那种"A 比后面的大一圈"的味道，单块 Label 做不出来。
## 两块用同一个盒高 + 底部对齐 —— 基线就对上了（字号差几号时下沉量差不到 1px）。
## ⚠️ 布置模式下拖的不是那两块字本身，而是盖在它们上面的一块**透明命中框**
##    （`_label_hits`）：字是镂空的，点空白就漏过去太难拖了（用户 2026-10-20：
##    "字能不能和城镇一样移动"）。命中框只在布置模式吃鼠标。
func _build_regions() -> void:
	var map_font: Font = load(MAP_FONT) if ResourceLoader.exists(MAP_FONT) else null
	var idx := 0
	for r in REGIONS:
		var text := String(r["text"])
		var size := int(r["size"])
		var big := size + FIRST_EXTRA
		var l1 := _region_label(text.substr(0, 1), big, map_font)
		var l2 := _region_label(text.substr(1), size, map_font)
		_host.add_child(l1)
		_host.add_child(l2)
		var hit := Control.new()
		hit.name = "RegionHit%d" % idx
		hit.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hit.mouse_default_cursor_shape = Control.CURSOR_MOVE
		hit.gui_input.connect(_on_label_gui_input.bind(idx, hit))
		_host.add_child(hit)
		_labels.append({"text": text, "nodes": [l1, l2], "hit": hit,
			"fx": float(r["fx"]), "fy": float(r["fy"]), "size": size, "big": big})
		idx += 1

## 一块地名 Label（**不加描边**：用户 2026-10-20 "字为什么有白边？白边去掉"）
func _region_label(t: String, fs: int, f: Font) -> Label:
	var l := Label.new()
	l.text = t
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", INK_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## 据点：图标（默认/hover 两张）+ 底下的城名
func _build_marks() -> void:
	for m in MARKS:
		_add_mark(m)
	# 我们那一座放最后一个（画在最上层）
	var home := {
		"id": String(HOME["id"]), "kind": _home_kind(), "fx": float(HOME["fx"]),
		"fy": float(HOME["fy"]), "name": _home_name(),
		"lord": String(HOME["lord"]), "specialty": String(HOME["specialty"]),
	}
	_add_mark(home)
	_home_index = _marks.size() - 1

func _add_mark(m: Dictionary) -> void:
	# ⚠️ 复制一份：`MARKS` 是 const（只读），布置模式要就地改 fx/fy —— 直接引用会报
	#    "Cannot modify a read-only dictionary"。
	var data: Dictionary = m.duplicate(true)
	var kind := String(data["kind"])
	var tex := _icon(kind, false)
	var tex_hover := _icon(kind, true)
	var btn := TextureButton.new()
	btn.texture_normal = tex
	# ⚠️ hover 用的是**橙色那版**图标（用户 2026-10-20："hover 要变成橙色，我刚刚有给橙色的资源"）。
	# 之前这里写的是 `tex`，而 `_on_mark_enter` 去改 `texture_normal` —— `TextureButton`
	# 在悬停时**优先显示 `texture_hover`**，所以橙色那张永远轮不到上屏。直接给它就行。
	btn.texture_hover = tex_hover
	btn.texture_pressed = tex_hover
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 图标是手绘的（缩到 ~68px 显示）：线性过滤比最近邻干净
	btn.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	btn.tooltip_text = ""
	var i := _marks.size()
	btn.mouse_entered.connect(_on_mark_enter.bind(i))
	btn.mouse_exited.connect(_on_mark_exit.bind(i))
	btn.gui_input.connect(_on_mark_gui_input.bind(i))
	_host.add_child(btn)
	# ⚠️ 地图上**不画城名**（用户 2026-10-20："所有城镇地图上不显示名字，城镇名字放在 tip 里"）——
	# 名字/领主/特产只在 hover 卡片里。
	_marks.append({"data": data, "node": btn, "tex": tex, "tex_hover": tex_hover})
	# 记一份"内置默认值"，以后「恢复默认」要靠它
	_defaults[String(data["id"])] = {
		"fx": float(data["fx"]), "fy": float(data["fy"]),
		"scale": float(data.get("scale", 1.0)),
	}

## 我们这座现在是村 / 小城 / 中城（用户 2026-10-20：跟着城镇中心变）
func _home_kind() -> String:
	if runner == null or runner.sim == null:
		return "village"
	match String(runner.sim.town_center_stage()):
		"patched":
			return "town_small"
		"restored":
			return "town_medium"
		_:
			return "village"

func _home_name() -> String:
	if runner == null or runner.sim == null:
		return "灰谷"
	var n := String(runner.sim.s.get("villageName", "灰谷")).strip_edges()
	return "灰谷" if n == "" else n

## hover 卡片：城镇名 / 领主 / 特产（用户 2026-10-20 点名要这三样）
func _build_card() -> void:
	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 10, 6, 10, 8))
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.visible = false
	_host.add_child(_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	_card.add_child(v)
	_card_title = UIKit.label("", UIKit.FG_HEAD)
	_card_title.add_theme_font_size_override("font_size", UIKit.FS + 2)
	v.add_child(_card_title)
	_card_body = UIKit.label("", UIKit.FG_DARK)
	_card_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_body.custom_minimum_size = Vector2(190, 0)
	v.add_child(_card_body)

func open() -> void:
	visible = true
	# 布置工具只在**调试模式**下露出来（ESC 菜单 →「调试功能」）
	if _tools_box != null:
		_tools_box.visible = _debug_on()
		if not _tools_box.visible and _edit:
			_on_edit_toggled(false)
	_refresh_home()
	_load_layout()
	_layout()
	move_to_front()

## 调试总闸（真源是 `world.debug_footprints`，ESC 菜单里的「调试功能」拨它）
func _debug_on() -> bool:
	return world != null and bool(world.get("debug_footprints"))

func close_panel() -> void:
	visible = false

# ---------------------------------------------------------------------------
# 布置模式：自己拖点位（2026-10-20 用户："你能不能让我自己调整城镇的位置，
# 有修改坐标什么的，这样我就不用叫你改了"）
#
# · 拖 == 改 `fx` / `fy`（底图上的**比例坐标** 0..1），松手立刻写盘
# · 存 `user://map_layout.json`（不是 `res://`：不脏仓库、导出后也能写）；
#   文件不存在时第一次打开会自动导出一份当前坐标当模板
# · 手改 JSON 之后点「重新读入」就生效，不用重启
# ---------------------------------------------------------------------------
# 坐标存哪儿：**优先项目内**（`res://data/map_layout.json`，用编辑器/调试跑时可写，
# 好处是它就在仓库里，能直接手改、能 git diff、能提交）；导出成 exe 之后 res:// 只读，
# 自动退回 `user://map_layout.json`。
const LAYOUT_RES := "res://data/map_layout.json"
const LAYOUT_USER := "user://map_layout.json"
## 这次实际用的那个（`_resolve_path()` 决定，UI 上要显示给用户看）
var _layout_path := LAYOUT_RES

func _resolve_layout_path() -> String:
	if FileAccess.file_exists(LAYOUT_RES):
		return LAYOUT_RES
	if FileAccess.file_exists(LAYOUT_USER):
		return LAYOUT_USER
	return LAYOUT_RES      # 都不存在时先试 res://（写不进去再退 user://）

func _on_edit_toggled(on: bool) -> void:
	_edit = on
	_drag = -1
	_edit_btn.text = "布置中（拖吧）" if on else "布置城市"
	for e in _marks:
		var b: TextureButton = e["node"]
		b.mouse_default_cursor_shape = Control.CURSOR_MOVE if on else Control.CURSOR_POINTING_HAND
	for r in _labels:
		var hit: Control = r["hit"]
		hit.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	if on:
		_readout.text = "拖动图标 / 地名，松手自动保存 → %s" % ProjectSettings.globalize_path(_layout_path)
	else:
		_save_layout()
		_readout.text = "已保存 → %s" % ProjectSettings.globalize_path(_layout_path)

## 鼠标在控件里的位置 → **`_host` 里的像素坐标**（拖拽用相对位移，不直接跳）
func _host_pos(ctrl: Control, local_in_ctrl: Vector2) -> Vector2:
	return ctrl.get_global_transform() * local_in_ctrl - _host.global_position

## 鼠标在控件里的位置 → 底图上的比例坐标（夹在 0..1）
func _to_frac(ctrl: Control, local_in_ctrl: Vector2) -> Vector2:
	var p := _host_pos(ctrl, local_in_ctrl)
	if _rect.size.x <= 0.0 or _rect.size.y <= 0.0:
		return Vector2.ZERO
	return Vector2(
		clampf((p.x - _rect.position.x) / _rect.size.x, 0.0, 1.0),
		clampf((p.y - _rect.position.y) / _rect.size.y, 0.0, 1.0))

func _on_mark_gui_input(event: InputEvent, i: int) -> void:
	if not _edit or i < 0 or i >= _marks.size():
		return
	var e: Dictionary = _marks[i]
	var btn: TextureButton = e["node"]
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (event as InputEventMouseButton).pressed:
			_drag = i
			_sel = i
			var d: Dictionary = e["data"]
			_grab_frac = Vector2(float(d["fx"]), float(d["fy"]))
			_grab_pos = _host_pos(btn, (event as InputEventMouseButton).position)
			_readout.text = "抓住「%s」—— 也可以按方向键微调" % String(d["name"])
		else:
			if _drag == i:
				_drag = -1
				_save_layout()
				var d2: Dictionary = e["data"]
				_readout.text = "%s → fx %.4f  fy %.4f（已保存）" % [
					String(d2["name"]), float(d2["fx"]), float(d2["fy"])]
		btn.accept_event()
	elif event is InputEventMouseMotion and _drag == i:
		var d: Dictionary = e["data"]
		var dv := (_host_pos(btn, (event as InputEventMouseMotion).position) - _grab_pos)
		d["fx"] = clampf(_grab_frac.x + dv.x / maxf(1.0, _rect.size.x), 0.0, 1.0)
		d["fy"] = clampf(_grab_frac.y + dv.y / maxf(1.0, _rect.size.y), 0.0, 1.0)
		_layout()
		_readout.text = "%s → fx %.4f  fy %.4f" % [String(d["name"]), float(d["fx"]), float(d["fy"])]
		btn.accept_event()

func _on_label_gui_input(event: InputEvent, i: int, hit: Control) -> void:
	if not _edit or i < 0 or i >= _labels.size():
		return
	var r: Dictionary = _labels[i]
	var lb: Control = hit
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (event as InputEventMouseButton).pressed:
			_drag = -1000 - i
			_sel = -1000 - i
			_grab_frac = Vector2(float(r["fx"]), float(r["fy"]))
			_grab_pos = _host_pos(lb, (event as InputEventMouseButton).position)
			_readout.text = "抓住地名「%s」—— 也可以按方向键微调" % String(r["text"])
		else:
			if _drag == -1000 - i:
				_drag = -1
				_save_layout()
				_readout.text = "%s → fx %.4f  fy %.4f（已保存）" % [
					String(r["text"]), float(r["fx"]), float(r["fy"])]
		lb.accept_event()
	elif event is InputEventMouseMotion and _drag == -1000 - i:
		var d := (_host_pos(lb, (event as InputEventMouseMotion).position) - _grab_pos)
		r["fx"] = clampf(_grab_frac.x + d.x / maxf(1.0, _rect.size.x), 0.0, 1.0)
		r["fy"] = clampf(_grab_frac.y + d.y / maxf(1.0, _rect.size.y), 0.0, 1.0)
		_layout()
		_readout.text = "%s → fx %.4f  fy %.4f" % [String(r["text"]), float(r["fx"]), float(r["fy"])]
		lb.accept_event()

## 写盘：把现在所有据点 + 地名的坐标存成 JSON（没有就新建）
func _save_layout() -> void:
	var marks := {}
	for e in _marks:
		var d: Dictionary = e["data"]
		var o := {"fx": snappedf(float(d["fx"]), 0.0001), "fy": snappedf(float(d["fy"]), 0.0001)}
		if d.has("scale"):
			o["scale"] = float(d["scale"])
		marks[String(d["id"])] = o
	var regions := {}
	for r in _labels:
		regions[String(r["text"])] = {
			"fx": snappedf(float(r["fx"]), 0.0001),
			"fy": snappedf(float(r["fy"]), 0.0001)}
	if _layout_path == LAYOUT_RES:
		# `res://data/` 可能还不存在 —— FileAccess 不会自己建目录
		var dir := ProjectSettings.globalize_path("res://data")
		if not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(_layout_path, FileAccess.WRITE)
	if f == null and _layout_path == LAYOUT_RES:
		# 导出后 res:// 只读：退回 user://
		_layout_path = LAYOUT_USER
		f = FileAccess.open(_layout_path, FileAccess.WRITE)
	if f == null:
		_readout.text = "写不进去：%s" % ProjectSettings.globalize_path(_layout_path)
		return
	# `_help` 是写给人看的：JSON 里不能写注释，只好放一个字段
	f.store_string(JSON.stringify({
		"version": 1,
		"_help": [
			"fx / fy = 这张底图上的**比例坐标**（0..1），锚点是图标脚底中点；x 向右、y 向下。",
			"marks 里每个 id 对应一座据点（capital=王都、iron_crown=铁王城、jade=翡翠城…）。",
			"regions 里每个键就是地图上那行英文地名的原文。",
			"scale 可选：图标放大倍数（王都 1.45）。",
			"改完存盘 → 游戏里点「重新读入」立刻生效；删掉本文件 = 回到 Godot 脚本里的内置坐标。",
			"也可以在游戏里点「布置城市」直接拖，松手会自动写回这里。",
		],
		"marks": marks,
		"regions": regions,
	}, "  "))
	f.close()

## 读盘（没有就导出一份默认值当模板）
func _load_layout() -> void:
	_layout_path = _resolve_layout_path()
	if not FileAccess.file_exists(_layout_path):
		_save_layout()
		if _readout != null:
			_readout.text = "已导出当前坐标（照着改就行）→ %s" % ProjectSettings.globalize_path(_layout_path)
		return
	var txt := FileAccess.get_file_as_string(_layout_path)
	var j = JSON.parse_string(txt)
	if typeof(j) != TYPE_DICTIONARY:
		if _readout != null:
			_readout.text = "map_layout.json 读不懂（JSON 语法？）"
		return
	var n := 0
	var marks: Dictionary = (j as Dictionary).get("marks", {})
	for e in _marks:
		var d: Dictionary = e["data"]
		var id := String(d["id"])
		if marks.has(id):
			var o: Dictionary = marks[id]
			if o.has("fx"):
				d["fx"] = float(o["fx"])
			if o.has("fy"):
				d["fy"] = float(o["fy"])
			if o.has("scale"):
				d["scale"] = float(o["scale"])
			n += 1
	var regions: Dictionary = (j as Dictionary).get("regions", {})
	for r in _labels:
		var t := String(r["text"])
		if regions.has(t):
			r["fx"] = float(regions[t]["fx"])
			r["fy"] = float(regions[t]["fy"])
			n += 1
	if _readout != null:
		_readout.text = "读入 %d 条自己的坐标 → %s" % [n, ProjectSettings.globalize_path(_layout_path)]

func _open_layout_dir() -> void:
	OS.shell_open(ProjectSettings.globalize_path(_layout_path.get_base_dir()))

## 删掉自己调过的，回到代码里的内置坐标
func _reset_layout() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_layout_path))
	for e in _marks:
		var d: Dictionary = e["data"]
		var def: Dictionary = _defaults.get(String(d["id"]), {})
		if not def.is_empty():
			d["fx"] = float(def["fx"])
			d["fy"] = float(def["fy"])
			if def.has("scale") and is_equal_approx(float(def["scale"]), 1.0) == false:
				d["scale"] = float(def["scale"])
	for i in _labels.size():
		var r: Dictionary = _labels[i]
		r["fx"] = float(REGIONS[i]["fx"])
		r["fy"] = float(REGIONS[i]["fy"])
	_drag = -1
	_layout()
	_save_layout()
	_readout.text = "已恢复内置坐标（并重新导出模板）"

## 城镇中心修过一段就换一次图标（打开面板时重算，免得读档/修缮之后不更新）
func _refresh_home() -> void:
	if _home_index < 0 or _home_index >= _marks.size():
		return
	var e: Dictionary = _marks[_home_index]
	var kind := _home_kind()
	var data: Dictionary = e["data"]
	data["kind"] = kind
	data["name"] = _home_name()
	e["tex"] = _icon(kind, false)
	e["tex_hover"] = _icon(kind, true)
	var btn: TextureButton = e["node"]
	btn.texture_normal = e["tex"]
	btn.texture_hover = e["tex_hover"]
	btn.texture_pressed = e["tex_hover"]
	_layout()

var _home_index := -1

func _icon(kind: String, hover: bool) -> Texture2D:
	var path := "%s%s%s.png" % [ICON_DIR, kind, "_hover" if hover else ""]
	if not _tex_cache.has(path):
		_tex_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _tex_cache[path]

## 把比例坐标摊成像素：底图居中、保持 MAP_ASPECT，所有图标/地名都按底图矩形算。
func _layout() -> void:
	if _host == null or _map == null:
		return
	var vp := _host.size
	if vp.x < 8.0 or vp.y < 8.0:
		return
	var w := minf(vp.x, vp.y * MAP_ASPECT)
	var h := w / MAP_ASPECT
	if h > vp.y:
		h = vp.y
		w = h * MAP_ASPECT
	var rect := Rect2(Vector2((vp.x - w) * 0.5, (vp.y - h) * 0.5), Vector2(w, h))
	_rect = rect          # 拖拽换算要用（见 `_to_frac()`）
	_map.position = rect.position
	_map.size = rect.size
	# 图标：统一高度缩放，底部中点钉在点位
	# `scale` 是**单店覆盖**（用户 2026-10-20 在图上标了「放大显示」给铁王城）——
	# 首都本来就该比中城镇显眼，而素材里两者差不多大。
	var icon_h := rect.size.y * ICON_H
	for e in _marks:
		var d: Dictionary = e["data"]
		var tex: Texture2D = e["tex"]
		var k := float(d.get("scale", 1.0))
		var ih := icon_h * k
		var iw := ih
		if tex != null and tex.get_height() > 0:
			iw = ih * float(tex.get_width()) / float(tex.get_height())
		var cx := rect.position.x + float(d["fx"]) * rect.size.x
		var by := rect.position.y + float(d["fy"]) * rect.size.y
		var btn: TextureButton = e["node"]
		btn.size = Vector2(iw, ih)
		btn.position = Vector2(cx - iw * 0.5, by - ih)
		# 放大的轴心放在脚底中点：hover 时像是"从地上长出来"，不会飘
		btn.pivot_offset = Vector2(iw * 0.5, ih)
	# 区域名：首字母一块、其余一块，两块**共用一个盒高 + 底部对齐**（基线就齐了），
	# 宽度用字体的 `get_string_size()` 量，整组按 fx 居中。
	for r in _labels:
		var nodes: Array = r["nodes"]
		var l1: Label = nodes[0]
		var l2: Label = nodes[1]
		var font: Font = l1.get_theme_font("font")
		var s1 := float(r["big"])
		var s2 := float(r["size"])
		var w1 := 0.0
		var w2 := 0.0
		if font != null:
			w1 = font.get_string_size(l1.text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(s1)).x
			w2 = font.get_string_size(l2.text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(s2)).x
		var box_h := s1 * 1.6
		var cx := rect.position.x + float(r["fx"]) * rect.size.x
		var cy := rect.position.y + float(r["fy"]) * rect.size.y
		var left := cx - (w1 + w2) * 0.5
		var top := cy - box_h * 0.5
		l1.size = Vector2(maxf(w1 + 2.0, 8.0), box_h)
		l1.position = Vector2(left, top)
		l2.size = Vector2(maxf(w2 + 2.0, 8.0), box_h)
		l2.position = Vector2(left + w1, top)
		# 透明命中框：只在布置模式吃鼠标，直接拖它（比点镂空的字好抓）
		var hit: Control = r["hit"]
		hit.position = Vector2(left - 3.0, top - 3.0)
		hit.size = Vector2(w1 + w2 + 6.0, box_h + 6.0)
	_place_card()

## 卡片跟着 hover 的那个据点走（贴在图内，别溢出边界）
func _place_card() -> void:
	if _card == null or _hover < 0 or _hover >= _marks.size():
		return
	var e: Dictionary = _marks[_hover]
	var btn: TextureButton = e["node"]
	_card.size = _card.get_combined_minimum_size()
	var vp := _host.size
	var w := maxf(_card.size.x, 190.0)
	var h := maxf(_card.size.y, 48.0)
	var x := btn.position.x + btn.size.x * 0.5 - w * 0.5
	var y := btn.position.y - h - 6.0
	x = clampf(x, 8.0, maxf(8.0, vp.x - w - 8.0))
	if y < 6.0:
		y = btn.position.y + btn.size.y + 6.0
	_card.size = Vector2(w, h)
	_card.position = Vector2(x, y)

func _on_mark_enter(i: int) -> void:
	if i < 0 or i >= _marks.size():
		return
	# 布置模式下不弹卡片：挡着看地形了（拖的时候也碍事）
	if _edit:
		return
	_hover = i
	var e: Dictionary = _marks[i]
	var btn: TextureButton = e["node"]
	# 橙色那版图标由 `texture_hover` 自动换上（见 `_add_mark`），这里只负责放大 + 卡片
	btn.scale = Vector2(HOVER_SCALE, HOVER_SCALE)
	var d: Dictionary = e["data"]
	_card_title.text = String(d["name"])
	_card_body.text = "领主：%s\n特产：%s" % [String(d["lord"]), String(d["specialty"])]
	_card.visible = true
	_place_card()
	# 卡片永远压在图标上面（图标是先加的，卡片后加但可能被后来的……这里保险一次）
	_card.move_to_front()

func _on_mark_exit(i: int) -> void:
	if i < 0 or i >= _marks.size():
		return
	var e: Dictionary = _marks[i]
	var btn: TextureButton = e["node"]
	btn.scale = Vector2.ONE
	if _hover == i:
		_hover = -1
		if _card != null:
			_card.visible = false

## Esc 关掉；布置模式下方向键微调选中的那个（拖是粗调，方向键是精调）
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey) or not (event as InputEventKey).pressed:
		return
	var k := (event as InputEventKey).keycode
	if _edit and _sel != -1 and k in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		# Shift = 细调（0.0005），否则 0.002（差不多 2~3 像素）
		var step := 0.0005 if (event as InputEventKey).shift_pressed else 0.002
		var dv := Vector2.ZERO
		match k:
			KEY_LEFT: dv.x = -step
			KEY_RIGHT: dv.x = step
			KEY_UP: dv.y = -step
			KEY_DOWN: dv.y = step
		_nudge(dv)
		get_viewport().set_input_as_handled()
		return
	if k == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_panel()

## 布置模式下用方向键把选中的那个挪一点点，并写盘
func _nudge(dv: Vector2) -> void:
	if _sel >= 0 and _sel < _marks.size():
		var d: Dictionary = _marks[_sel]["data"]
		d["fx"] = clampf(float(d["fx"]) + dv.x, 0.0, 1.0)
		d["fy"] = clampf(float(d["fy"]) + dv.y, 0.0, 1.0)
		_layout()
		_readout.text = "%s → fx %.4f  fy %.4f（已保存）" % [
			String(d["name"]), float(d["fx"]), float(d["fy"])]
		_save_layout()
	elif _sel <= -1000 and (-_sel - 1000) < _labels.size():
		var r: Dictionary = _labels[-_sel - 1000]
		r["fx"] = clampf(float(r["fx"]) + dv.x, 0.0, 1.0)
		r["fy"] = clampf(float(r["fy"]) + dv.y, 0.0, 1.0)
		_layout()
		_readout.text = "%s → fx %.4f  fy %.4f（已保存）" % [
			String(r["text"]), float(r["fx"]), float(r["fy"])]
		_save_layout()
