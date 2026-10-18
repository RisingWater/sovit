extends Control

# 左上角小地图挂件：日期时间框 + 圆形小地图 + 村名红巾。
#
# 素材全部来自 UI Pack - Pixel Adventure 的 **Large tiles**（32x32）：
#   ring_tl / ring_tr / ring_bl / ring_br   四块拼成 64x64 圆环（上下左右各一个菱形凸起）
#   ribbon_l / ribbon_m / ribbon_r          左端折角 + 中段(可重复) + 右端折角
# 日期框用 **Small tiles** 的 tile_0033 木框做 9-slice。
#
# 尺寸都取素材尺寸的整数倍：192 = 64 x 3，红线 32 高保持 1 倍。
# 非整数倍会重采样把像素糊掉（项目默认 texture_filter = Nearest，整数倍才干净）。

const RING_D := 128                 # 圆环直径，必须是 64 的整数倍（128 = 64 * 2）
const RING_SRC := 64                # 四块 32x32 拼起来是 64x64
const RIB_H := 32
## 红巾宽度：要装得下 6 个汉字 @ 24px = 144px。圆盘只有 128，所以红巾比圆盘宽，
## 两端各探出 16px —— 和圆盘上下的日期框一样属于刻意压边。
const RIB_W := 160
## 村名长度上限与 UIKit 共用同一个来源
const NAME_MAX := UIKit.NAME_MAX
const BOX_W := 112
## 日期框高度。用户 2026-10（B0）：从一行「第 N 天 06:00」改成**两行**
## （上面日期、下面时刻），所以 26 → 40（两行 12px 字 + 上下各 4px 内边距）。
const BOX_H := 40
const PAD := 0                     # 不再留边：日期框与红巾直接叠在圆盘上
const UI_DIR := "res://assets/ui/"

## 兜底视野格数（拿不到镜头时用）。
const FALLBACK_VIEW_CELLS := 32.0
## 视野格数的上下限，避免极端缩放下小地图糊成一团或只剩一格。
const VIEW_MIN := 10.0
const VIEW_MAX := 96.0
## 静止时的兜底重绘间隔（秒）。镜头一动就立刻重绘。
const REDRAW_SEC := 0.3

const TERRAIN_COLORS := [
	Color(0.34, 0.55, 0.29),   # GRASS
	Color(0.20, 0.38, 0.20),   # FOREST
	Color(0.55, 0.55, 0.58),   # STONE
	Color(0.69, 0.47, 0.34),   # CLAY
	Color(0.27, 0.46, 0.67),   # WATER
	Color(0.42, 0.42, 0.50),   # IRON（铁矿，2026-10：比石矿更暗更冷）
	Color(0.20, 0.19, 0.21),   # COAL（煤矿，2026-10：近黑）
]
const ROAD_COLOR := Color(0.59, 0.50, 0.38)
const BUILDING_COLOR := Color(0.72, 0.42, 0.36)
const TOWN_CENTER_COLOR := Color(0.80, 0.74, 0.62)

var runner: SimRunner
var world: Node

var _time_label: Label
var _name_label: Label
var _accum := 0.0
var _last_center := Vector2(-9999, -9999)
var _last_view := -1.0
## 圆环四块贴图。必须在 _ready() 里加载好 —— 在 _draw() 里现 load() 会拿到
## 尚未完成的占位纹理，画出来是一整块白的。
var _ring_tex: Array = []
func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	for n in ["ring_tl", "ring_tr", "ring_bl", "ring_br"]:
		_ring_tex.append(load(UI_DIR + n + ".png"))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 整块只有圆盘那么大：日期框和红巾都叠在圆盘上，不外扩
	custom_minimum_size = Vector2(RING_D, RING_D)
	size = custom_minimum_size

	# --- 日期 + 时间框（木框 9-slice）
	var box := Panel.new()
	box.position = Vector2((RING_D - BOX_W) * 0.5, 0)
	box.size = Vector2(BOX_W, BOX_H)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxTexture.new()
	sb.texture = load(UI_DIR + "tile_0033.png")
	# 16x16 的框：四角各 5px，边与中心平铺
	sb.set_texture_margin_all(5)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	box.add_theme_stylebox_override("panel", sb)
	add_child(box)
	_time_label = UIKit.label("", Color(0.38, 0.23, 0.12))
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_time_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_time_label)

	# --- 圆形小地图：在挂件自己的 _draw() 里按 RING_ORIGIN 偏移画。
	# 不能挂 _ring.draw 信号 —— 那样回调仍是挂件的方法，draw_rect 会画在挂件原点，
	# 而不是圆环该在的位置。

	# --- 村名红巾
	var rib := HBoxContainer.new()
	rib.position = Vector2((RING_D - RIB_W) * 0.5, RING_D - RIB_H + 6)
	rib.add_theme_constant_override("separation", 0)
	rib.mouse_filter = Control.MOUSE_FILTER_STOP
	rib.tooltip_text = "点击修改村庄名"
	rib.gui_input.connect(_on_ribbon_input)
	add_child(rib)
	var n := RIB_W / 32                        # 5 段：左 + 3 中 + 右
	for i in n:
		var t := TextureRect.new()
		t.texture = load(UI_DIR + ("ribbon_l.png" if i == 0 else ("ribbon_r.png" if i == n - 1 else "ribbon_m.png")))
		t.custom_minimum_size = Vector2(32, RIB_H)
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rib.add_child(t)
	# 名字不能塞进 HBox —— 容器会把它排到 6 个贴图后面去。单独盖一层。
	_name_label = UIKit.label("sovit", Color(1.0, 0.94, 0.84))
	_name_label.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.position = rib.position
	_name_label.size = Vector2(RIB_W, RIB_H)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)

	_refresh_time()
	_refresh_name()

func _process(delta: float) -> void:
	if runner == null or runner.sim == null:
		return
	_refresh_time()
	_accum += delta
	# 跟随镜头：位置或缩放一变就重绘，停下才走兜底节流。
	var c := center_cell()
	var v := view_cells()
	if c.distance_to(_last_center) > 0.02 or absf(v - _last_view) > 0.05 or _accum >= REDRAW_SEC:
		_last_center = c
		_last_view = v
		_accum = 0.0
		queue_redraw()

## 小地图一次显示多少格 —— 直接由**镜头当前看到的范围**决定，
## 所以鼠标缩放地图时小地图跟着一起缩放。
## 镜头可视格数 = 视口宽度 / (TILE * zoom)。默认 zoom=3 时约 33 格，和原来接近。
func view_cells() -> float:
	if world != null and world.camera != null:
		var t := float(world.TILE)
		var z: float = maxf(0.01, float(world.camera.zoom.x))
		var vw := float(get_viewport_rect().size.x)
		if t > 0.0 and vw > 0.0:
			return clampf(vw / (t * z), VIEW_MIN, VIEW_MAX)
	return FALLBACK_VIEW_CELLS

## 小地图中心（地图格，浮点）。跟镜头走 —— 镜头在哪儿小地图就显示哪一块。
func center_cell() -> Vector2:
	if world != null:
		var cam = world.camera
		var tile := float(world.TILE)
		if cam != null and tile > 0.0:
			return cam.position / tile
		if world.map != null:
			return Vector2(world.map.center)
	return Vector2.ZERO

func _refresh_time() -> void:
	if _time_label == null or runner == null or runner.sim == null:
		return
	var s: Dictionary = runner.sim.s
	# 用户 2026-10（B0）：两行 —— 上面 AE 日期、下面时刻。
	# ⚠️ 历法一个字都不在这里拼：唯一实现是 `sim_core.gd::date_label()`。
	_time_label.text = "%s\n%02d:00" % [
		runner.sim.date_label(int(s["day"])), int(s["hour"])]

func village_name() -> String:
	if runner == null or runner.sim == null:
		return "sovit"
	return String(runner.sim.s.get("villageName", "sovit"))

func set_village_name(v: String) -> void:
	var clean := v.strip_edges()
	if clean == "":
		clean = "sovit"
	if clean.length() > NAME_MAX:
		clean = clean.substr(0, NAME_MAX)
	runner.sim.s["villageName"] = clean
	_refresh_name()

func _refresh_name() -> void:
	if _name_label != null:
		_name_label.text = village_name()

# ---------------------------------------------------------------------------
# 红巾改名
# ---------------------------------------------------------------------------
func _on_ribbon_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_open_rename()
		accept_event()

func _open_rename() -> void:
	var pop := PopupPanel.new()
	add_child(pop)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.custom_minimum_size = Vector2(300, 0)
	pop.add_child(vb)
	vb.add_child(UIKit.label("村庄名称", UIKit.FG_HEAD))
	# 自绘输入框（凹陷石板底 + 像素字），和主题里 LineEdit 那条保持一致
	var edit := UIKit.input("sovit", 16)
	edit.text = village_name()
	edit.custom_minimum_size = Vector2(280, 0)
	vb.add_child(edit)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(UIKit.spacer())
	var ok := UIKit.button("确定", true)
	ok.pressed.connect(func():
		set_village_name(edit.text)
		pop.hide())
	row.add_child(ok)
	vb.add_child(row)
	pop.popup_centered()
	edit.grab_focus()
	edit.select_all()

# ---------------------------------------------------------------------------
# 圆形小地图
# ---------------------------------------------------------------------------
func _draw() -> void:
	var m = world.map if world != null else null
	if m == null:
		return
	var o := Vector2(PAD, PAD)
	var c := o + Vector2(RING_D, RING_D) * 0.5
	var r_out := RING_D * 0.5
	var n := view_cells()
	var cell := float(RING_D) / n
	var span := int(ceil(n)) + 1

	# 中心跟镜头走。取左上角为基准，用 floor 定整格、用小数部分做亚格偏移 ——
	# 这样平移是滑动的，而不是一格一格地跳。
	var base := center_cell() - Vector2(n, n) * 0.5
	var bx := int(floor(base.x))
	var by := int(floor(base.y))
	var sub := (base - Vector2(bx, by)) * cell

	# 地形 + 道路 + 建筑：逐格画。
	# 只画圆心在圆内的格子 —— 边缘会有 1 格锯齿，但这是像素画，正好。
	for cy in span:
		for cx in span:
			var wx: int = bx + cx
			var wy: int = by + cy
			if wx < 0 or wy < 0 or wx >= m.W or wy >= m.H:
				continue
			var px := o + Vector2(cx, cy) * cell - sub
			if (px + Vector2(cell, cell) * 0.5 - c).length() > r_out - cell * 0.5:
				continue
			var rect := Rect2(px, Vector2(cell + 0.5, cell + 0.5))
			var t: int = m.terrain[m.idx(wx, wy)]
			draw_rect(rect, TERRAIN_COLORS[t] if t < TERRAIN_COLORS.size() else TERRAIN_COLORS[0])
			var wc := Vector2i(wx, wy)
			if m.occupied.has(wc):
				draw_rect(rect, BUILDING_COLOR)
			elif m.town_center.has_point(wc):
				draw_rect(rect, TOWN_CENTER_COLOR)
			elif m.road[m.idx(wx, wy)] != 0:
				draw_rect(rect, ROAD_COLOR)

	# 圆环盖在最上面（四块 32x32，整数放大到 RING_D/2）
	var q := RING_D / 2
	draw_texture_rect(_ring_tex[0], Rect2(o.x, o.y, q, q), false)
	draw_texture_rect(_ring_tex[1], Rect2(o.x + q, o.y, q, q), false)
	draw_texture_rect(_ring_tex[2], Rect2(o.x, o.y + q, q, q), false)
	draw_texture_rect(_ring_tex[3], Rect2(o.x + q, o.y + q, q, q), false)
