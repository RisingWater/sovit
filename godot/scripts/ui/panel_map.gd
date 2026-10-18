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
const MAP_ASPECT := 1524.0 / 1008.0
const MAP_PATH := "res://assets/ui/map/kingdom_map_bare.jpg"
const ICON_DIR := "res://assets/ui/map/"
## 据点图标占地图高度的百分比（大城镇画得比村庄大，是**素材自带**的相对大小，
## 这里只给一个统一缩放比 —— 别按类型改，否则大城市和小村庄会长得一样大）。
const ICON_H := 0.085
## hover 时放大到多少（和鼠标一起晃一下就够了，别做动画）
const HOVER_SCALE := 1.14

## 城镇名/卡片用的墨色（羊皮纸上的深褐）
const INK := Color(0.24, 0.16, 0.10)
const INK_DIM := Color(0.36, 0.26, 0.17, 0.55)

## 区域名：text / fx / fy / size（size = 字号，0 = 默认 12）
const REGIONS := [
	{"text": "圣辉教国", "fx": 0.3020, "fy": 0.0620, "size": 22},
	{"text": "瓦尔登王国", "fx": 0.7180, "fy": 0.1320, "size": 26},
	{"text": "翡翠海", "fx": 0.8830, "fy": 0.3084, "size": 22},
	{"text": "铁峰公国", "fx": 0.0767, "fy": 0.2235, "size": 20},
	{"text": "灰岩山脉", "fx": 0.2984, "fy": 0.3396, "size": 18},
	{"text": "瓦尔河", "fx": 0.6129, "fy": 0.4690, "size": 14},
	{"text": "沙海汗国", "fx": 0.0817, "fy": 0.8563, "size": 20},
]

## 据点：id / kind / fx / fy / 名字 / 领主 / 特产。
## 名字与领主见 `docs/story.md` §1.1、§二；特产用国别表里那一列。
const MARKS := [
	{"id": "iron_crown", "kind": "town_large", "fx": 0.4546, "fy": 0.4293, "scale": 1.45,
		"name": "铁王城", "lord": "阿尔伯特（长子）· 兼掌国库", "specialty": "铁、马"},
	{"id": "iron_rook", "kind": "town_medium", "fx": 0.4043, "fy": 0.1951,
		"name": "铁鸦堡", "lord": "伯纳德（次子）", "specialty": "铁、军械"},
	{"id": "holy_flame", "kind": "town_medium", "fx": 0.6194, "fy": 0.1617,
		"name": "圣火城", "lord": "塞德里克（三子）", "specialty": "圣物、香火"},
	{"id": "dawn", "kind": "town_medium", "fx": 0.7835, "fy": 0.5833,
		"name": "曙光城", "lord": "伊莲娜（长女）", "specialty": "典籍、纸"},
	{"id": "golden_ear", "kind": "town_medium", "fx": 0.6159, "fy": 0.6173,
		"name": "金穗城", "lord": "狄奥多（四子）", "specialty": "粮食、盐"},
	{"id": "blackstone", "kind": "town_medium", "fx": 0.3639, "fy": 0.5200,
		"name": "黑石堡", "lord": "弗雷德里克（六子）", "specialty": "铁、煤"},
	{"id": "peak", "kind": "town_medium", "fx": 0.0800, "fy": 0.2649,
		"name": "铁峰城", "lord": "大公 赫尔曼", "specialty": "铁、煤"},
	{"id": "jade", "kind": "town_large", "fx": 0.8634, "fy": 0.8420,
		"name": "翡翠城", "lord": "女王 艾瑟琳", "specialty": "香料、丝绸、宝石"},
	{"id": "holy_see", "kind": "temple", "fx": 0.4820, "fy": 0.1157,
		"name": "圣都", "lord": "教皇 格里高利", "specialty": "圣物、书"},
	{"id": "khan", "kind": "camp", "fx": 0.2234, "fy": 0.9117,
		"name": "汗庭", "lord": "大汗 巴图尔", "specialty": "马匹、盐、皮毛"},
]

## 我们自己的那一座（图标按城镇中心段位换）
const HOME := {"id": "ashen_vale", "fx": 0.6959, "fy": 0.8682,
	"lord": "你（第七王子）", "specialty": "木材、石块、粘土"}

var _map: TextureRect
var _host: Control
var _marks: Array = []          # [{data, node, tex, tex_hover, icon_h}]
var _labels: Array = []         # [{node, fx, fy}]
var _card: PanelContainer
var _card_title: Label
var _card_body: Label
var _hover := -1
var _tex_cache: Dictionary = {}

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

## 区域名：大号褪色，压在底图上，不吃鼠标
func _build_regions() -> void:
	for r in REGIONS:
		var l := UIKit.label(String(r["text"]), INK_DIM)
		l.add_theme_font_size_override("font_size", int(r["size"]))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_host.add_child(l)
		_labels.append({"node": l, "fx": float(r["fx"]), "fy": float(r["fy"])})

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
	var kind := String(m["kind"])
	var tex := _icon(kind, false)
	var tex_hover := _icon(kind, true)
	var btn := TextureButton.new()
	btn.texture_normal = tex
	btn.texture_hover = tex
	btn.texture_pressed = tex
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
	_host.add_child(btn)
	var name_lb := UIKit.label(String(m["name"]), INK)
	name_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.add_child(name_lb)
	_marks.append({
		"data": m, "node": btn, "tex": tex, "tex_hover": tex_hover, "name_lb": name_lb,
	})

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
	_refresh_home()
	_layout()
	move_to_front()

func close_panel() -> void:
	visible = false

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
	btn.texture_hover = e["tex"]
	btn.texture_pressed = e["tex"]
	(e["name_lb"] as Label).text = String(data["name"])
	_layout()

var _home_index := -1

func _icon(kind: String, hover: bool) -> Texture2D:
	var path := "%s%s%s.png" % [ICON_DIR, kind, "_hover" if hover else ""]
	if not _tex_cache.has(path):
		_tex_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _tex_cache[path]

## 把比例坐标摊成像素：底图居中、保持 1536:952，所有图标/地名都按底图矩形算。
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
		var lb: Label = e["name_lb"]
		lb.size = Vector2(maxf(iw, 72.0), 16.0)
		lb.position = Vector2(cx - lb.size.x * 0.5, by + 2.0)
	# 区域名：按比例摆在底图上（居中）
	for r in _labels:
		var l: Label = r["node"]
		l.size = Vector2(240.0, 30.0)
		l.position = Vector2(
			rect.position.x + float(r["fx"]) * rect.size.x - 120.0,
			rect.position.y + float(r["fy"]) * rect.size.y - 15.0)
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
	_hover = i
	var e: Dictionary = _marks[i]
	var btn: TextureButton = e["node"]
	btn.texture_normal = e["tex_hover"]
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
	btn.texture_normal = e["tex"]
	btn.scale = Vector2.ONE
	if _hover == i:
		_hover = -1
		if _card != null:
			_card.visible = false

## Esc 关掉（和别的一样：只吃自己开着的那一下）
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_panel()
