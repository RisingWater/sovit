extends Node2D

# 世界视图：地形(TileMapLayer) + 仓库 + 建筑/施工点 + 小人 + 相机 + 交互。
# 只读仿真；建造/派人等命令交给 SimRunner（次日生效）。

signal select_building(shop_id: String)
signal select_housing(uid: String)
signal select_resident(resident_id: String)
signal select_none()
signal notice(text: String)

const TILE := 16
# Tiny 图集原生 16px。像素画必须用原生尺寸 + 整数缩放，否则笔画会糊。
const ZOOM := 3.0             # 默认缩放（16 x 3 = 48，与旧版 48px tile 的观感一致）
const TOWN_COLS := 12
const TOWN_ROWS := 11
const EXTRA_COLS := 8
const EXTRA_ROWS := 7
const DECO_VARIANTS := 4      # deco.png 里的树种类（每格 16x32）

var runner: SimRunner
var map: GameMap

var terrain_layer: TileMapLayer
var floor_layer: TileMapLayer
var road_layer: TileMapLayer
var deco_layer: TileMapLayer
## 建筑 + 小人共用的 **y 排序容器**（按地面线排序，见 _ready 里的说明）。
## 名字保留 building_layer 是历史原因；_reset_buildings() 会跳过带 "agent" meta 的子节点。
var building_layer: Node2D
## 选中小人的地面圈（z=-4，属于地面层）。
var ring_layer: Node2D
var camera: Camera2D
var ghost: Sprite2D

var _left_down := false
var _left_drag := false
var _press_pos := Vector2.ZERO
var _press_cell := Vector2i.ZERO

var _tex_cache := {}
var _actor_tex := {}
var _cursor_shape := Input.CURSOR_ARROW
var label_layer: CanvasLayer
var _label_items: Array = []
## 在建工地的悬停提示（独立 CanvasLayer，见 `_ready` 里的说明）
var tip_layer: CanvasLayer
## 工地头顶的进度条：世界空间的 `_draw` 层，跟着镜头走（和 `ring_layer` 同一套写法）。
## 研究所的进度条也画在这一层上（见 `_draw_site_bars`）—— 工地占的是 `map.occupied`
## 的 `"site"` 格，研究所是已建成的商店，两者永远不会落在同一格上，所以不必再开一层。
var site_layer: Node2D
## 调试：把每座建筑占的格子画成彩色方框（ESC 菜单里开），默认关。
var debug_footprints := false
var debug_layer: Node2D
## 这一帧有没有研究所要画进度条（`_sync` 里更新，`_process` 据此决定要不要重画）。
var _has_research_bar := false
var _tip: PanelContainer
var _tip_label: Label
## UI 根节点（由 main 注入）。用来判断鼠标是否落在 UI 面板上，
## 是的话就不把鼠标事件当成地图操作。
var ui_root: Control = null
var _shop_sprites := {}         # shop_id -> Node2D
var _shop_cell := {}            # shop_id -> Vector2i(origin)
var _shop_def := {}             # shop_id -> defId
var _map_seed := 12345
var _housing_instances := []    # [{uid, type, cell, fw, fh, sprite, capacity, private, occupants}]
var _housing_by_uid := {}
var _sites := []                # [{kind, id, cell, fw, fh, node}]  待建
var _site_by_type := {}         # defId/housingType -> [site index...]
var _placed_housing_count := {} # type -> count already bound
var _prev_res := -1
var _prev_housing_n := -1

var build_mode := ""
var brush_mode := ""            # "", "road", "floor"
var move_mode := ""             # "", "shop:<id>", "housing:<uid>"
var brush_size := 1
var _shop_label := {}

var _agents := []               # [{id, pos, home, goal_cell, path, pi, need_path}]
var _resident_home := {}        # id -> Vector2
var _shop_anchor := {}          # shop_id -> Vector2i（保留：施工点等）
var _shop_door := {}            # shop_id -> Array[Vector2i]（门格，可通行；声明式，可能多于一个）
var _shop_goal := {}            # shop_id -> Vector2i（屋内落脚格）
var _doors := {}                # Vector2i -> true（门格）
var _walk_inside := {}          # Vector2i -> true（门格 + 屋内格：可通行）
var _town_center_door := Vector2i.ZERO
var _town_center_goal := Vector2i.ZERO
var _astar: AStarGrid2D
var _nav_dirty := true
var _nav_timer := 0.0
var _picking := false
var _paint := false
var _town_center_pos := Vector2.ZERO
var town_center_sprite: Sprite2D = null
var selected_resident := ""
var _font: SystemFont

func setup(r: SimRunner, seed_value: int) -> void:
	runner = r
	_map_seed = seed_value
	map = GameMap.new()
	map.generate(seed_value)

func _ready() -> void:
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei", "sans-serif"])
	_setup_cursors()
	_build_tileset()
	_build_town_center()
	_camera_setup()
	_sync()
	_build_astar()
	_assign_homes()
	_spawn_agents()

func _area_center(cell: Vector2i, fw: int, fh: int) -> Vector2:
	return Vector2(cell.x * TILE + fw * TILE * 0.5, cell.y * TILE + fh * TILE * 0.5)

## 建筑名标签：放在**屏幕空间**的 CanvasLayer 上，字号固定 24px（= 12px 像素字体的
## 整数 2 倍，实测每像素正好 2x2，不糊）。这样镜头缩放时文字大小不变。
func _add_label(text: String, cell: Vector2i, fw: int, fh: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.add_theme_font_override("font", UIKit.pixel_font())
	l.add_theme_font_size_override("font_size", UIKit.LABEL_FS)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0.12, 0.09, 0.07))
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label_layer.add_child(l)
	# 锚点取**屋顶中心**：最下一行是墙体，屋顶占上面 fh-1 行，
	# 所以屋顶中心 = 占地顶边 + (fh-1)*TILE/2。牌子压在屋顶上而不是墙上。
	var cx := _area_center(cell, fw, fh).x
	var roof_cy := float(cell.y * TILE) + float(fh - 1) * TILE * 0.5
	_label_items.append({"node": l, "world": Vector2(cx, roof_cy)})
	return l

## 每帧把世界锚点投影到屏幕坐标（镜头位置 + 缩放变了都要重算）。
## 24px 的字比较大，逐个贪心占位，重叠的直接不画 —— 否则密集区糊成一团。
func _update_labels() -> void:
	if camera == null or label_layer == null:
		return
	var vp := get_viewport_rect().size
	var zoom := camera.zoom
	var placed: Array[Rect2] = []
	var live: Array = []
	for it in _label_items:
		# 必须先取无类型的 Variant 再判有效。
		# 直接写 `var l: Label = it["node"]` 的话，一旦该节点已被 queue_free，
		# **赋值本身**就会抛 "Trying to assign invalid previously freed instance"。
		# 移动建筑会释放旧标签，所以这条路径必然踩到。
		var raw = it["node"]
		if not is_instance_valid(raw):
			continue          # 顺手剔除，避免 _label_items 无上限增长
		live.append(it)
		var l: Label = raw
		var s: Vector2 = (it["world"] - camera.position) * zoom + vp * 0.5
		var sz := l.get_minimum_size()
		var box := Rect2((s - Vector2(sz.x * 0.5, sz.y * 0.5)).round(), sz)
		var on_screen := box.end.x > 0 and box.position.x < vp.x and box.end.y > 0 and box.position.y < vp.y
		var blocked := false
		for r in placed:
			if r.intersects(box):
				blocked = true
				break
		l.visible = on_screen and not blocked
		l.position = box.position
		if l.visible:
			placed.append(box)
	_label_items = live

func _clear_labels() -> void:
	for it in _label_items:
		var l = it["node"]
		if is_instance_valid(l):
			l.queue_free()
	_label_items.clear()

## 像素光标（Kenney Cursor Pixel Pack, CC0）。按热点对齐尖角。
func _setup_cursors() -> void:
	Input.set_custom_mouse_cursor(load("res://assets/cursors/default.png"),
		Input.CURSOR_ARROW, Vector2(1, 1))
	Input.set_custom_mouse_cursor(load("res://assets/cursors/pointer.png"),
		Input.CURSOR_POINTING_HAND, Vector2(5, 1))
	Input.set_custom_mouse_cursor(load("res://assets/cursors/cross.png"),
		Input.CURSOR_CROSS, Vector2(7, 7))
	Input.set_custom_mouse_cursor(load("res://assets/cursors/deny.png"),
		Input.CURSOR_FORBIDDEN, Vector2(7, 7))
	Input.set_custom_mouse_cursor(load("res://assets/cursors/wait.png"),
		Input.CURSOR_WAIT, Vector2(7, 7))

func _town_cell(idx: int) -> Vector2i:
	return Vector2i(idx % TOWN_COLS, idx / TOWN_COLS)

func _extra_cell(idx: int) -> Vector2i:
	return Vector2i(idx % EXTRA_COLS, idx / EXTRA_COLS)

func _is_land(c: Vector2i) -> bool:
	return (not map.in_bounds(c)) or map.terrain_at(c) != GameMap.WATER

func _water_index(c: Vector2i) -> int:
	# 自绘图集：水面 = 16 + 掩码 x2 + 内凹(0/1)
	var m := 0
	if _is_land(c + Vector2i(0, -1)): m |= 1
	if _is_land(c + Vector2i(0, 1)): m |= 2
	if _is_land(c + Vector2i(1, 0)): m |= 4
	if _is_land(c + Vector2i(-1, 0)): m |= 8
	var inner := 0
	# 对角内凹：两邻边是水、但对角是陆地
	var pairs = [[Vector2i(-1, -1), 1, 8], [Vector2i(1, -1), 1, 4],
		[Vector2i(-1, 1), 2, 8], [Vector2i(1, 1), 2, 4]]
	for p in pairs:
		if (m & int(p[1])) == 0 and (m & int(p[2])) == 0 and not _is_land(c + p[0]):
			inner = 1
			break
	return 16 + m * 2 + inner

func _road_index(c: Vector2i) -> int:
	var m := 0
	if map.in_bounds(c + Vector2i(0, -1)) and map.road[map.idx(c.x, c.y - 1)] != 0: m |= 1
	if map.in_bounds(c + Vector2i(0, 1)) and map.road[map.idx(c.x, c.y + 1)] != 0: m |= 2
	if map.in_bounds(c + Vector2i(1, 0)) and map.road[map.idx(c.x + 1, c.y)] != 0: m |= 4
	if map.in_bounds(c + Vector2i(-1, 0)) and map.road[map.idx(c.x - 1, c.y)] != 0: m |= 8
	return m

func _build_tileset() -> void:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)

	# source 0 = Tiny Town 原图集（草地 / 沙土 / 道具）
	var town := TileSetAtlasSource.new()
	town.texture = load("res://assets/tiny/town.png")
	town.texture_region_size = Vector2i(TILE, TILE)
	for i in TOWN_COLS * TOWN_ROWS:
		town.create_tile(Vector2i(i % TOWN_COLS, i / TOWN_COLS))
	ts.add_source(town, 0)

	# source 1 = 自绘地形（道路 0-15 / 水面 16-47 / 桥 48-49 / 补丁 50-52）
	var extra := TileSetAtlasSource.new()
	extra.texture = load("res://assets/tiny/extra.png")
	extra.texture_region_size = Vector2i(TILE, TILE)
	for i in EXTRA_COLS * EXTRA_ROWS:
		extra.create_tile(Vector2i(i % EXTRA_COLS, i / EXTRA_COLS))
	ts.add_source(extra, 1)

	# source 2 = 树的装饰（16x32，跨两格）
	var deco := TileSetAtlasSource.new()
	deco.texture = load("res://assets/tiny/deco.png")
	deco.texture_region_size = Vector2i(TILE, TILE * 2)
	for i in DECO_VARIANTS:
		deco.create_tile(Vector2i(i, 0))
	ts.add_source(deco, 2)

	terrain_layer = TileMapLayer.new()
	terrain_layer.tile_set = ts
	terrain_layer.z_index = -10
	add_child(terrain_layer)

	floor_layer = TileMapLayer.new()
	floor_layer.tile_set = ts
	floor_layer.z_index = -7
	add_child(floor_layer)

	road_layer = TileMapLayer.new()
	road_layer.tile_set = ts
	road_layer.z_index = -6
	add_child(road_layer)

	deco_layer = TileMapLayer.new()
	deco_layer.tile_set = ts
	# 树也要参与遮挡：人走在树后面时该被树冠挡住（原来是固定 z=-5 的地面层，
	# 谁都能从树冠里"穿"出来）。
	#
	# **实测结论：TileMapLayer 开了 y_sort_enabled、并作为 y 排序容器的子节点时，
	# 它的**每一块 tile** 会和兄弟 CanvasItem（建筑 / 小人）按 y 一起排序** ——
	# 所以不需要"每棵树一个 Sprite2D 节点"（全图几万棵树，那样代价太大）。
	# 排序键 = 格子 y × 16 + y_sort_origin；装饰图集是 16x32，贴图底边正好落在
	# 格子底边，所以 y_sort_origin 取一格(16) —— 实测验证过：人在 tree 的地面线
	# 之上被挡住、之下画在树前面，过渡点正好是格子底边（godot/tools/occlusion_test.gd）。
	deco_layer.y_sort_enabled = true
	deco_layer.y_sort_origin = TILE
	deco_layer.z_index = 0

	# 树图层是地面装饰，不是建筑 —— _reset_buildings() 清容器时要跳过它
	deco_layer.set_meta("keep", true)
	# 建筑和小人放在**同一个 y 排序容器**里，按"地面线"（建筑占地底边 / 小人的脚底）
	# 排序 —— 这是遮挡正确的前提：
	#   * 建筑贴图可以比占地高（content 的 art.foot，往上伸出去盖住身后那栋）。
	#     谁盖谁只能由地面线的先后决定。原来那套"后层 z=-1 / 前层 z=+1 两个图层"
	#     分不出"走在两栋互相重叠的房子**中间**的人"，所以小人从"一层 _draw 画所有人"
	#     改成一具一个 Sprite2D 节点，好在 y 排序里和建筑互相插队。
	#   * 道路/地板是地面，负 z_index，永远在这层下面，不会被压错；
	#     建筑压住的是"身后的路面"（正确的：它在路面前面），压不住身前的路面。
	building_layer = Node2D.new()
	building_layer.y_sort_enabled = true
	add_child(building_layer)
	# 树图层也挂进来（它的 z_index 已归零），试图让它和建筑/小人按 y 插队
	building_layer.add_child(deco_layer)

	# 选中小人的地面圈：属于地面，单独一层，不参与遮挡
	ring_layer = Node2D.new()
	ring_layer.z_index = -4
	add_child(ring_layer)

	# 建筑名标签走屏幕空间，字号不随镜头缩放变化
	label_layer = CanvasLayer.new()
	label_layer.layer = 1
	add_child(label_layer)

	# 工地悬停提示：也走屏幕空间（要贴着鼠标走），但**单独一层**。
	#
	# ⚠️ 不能挂进 `ui_root`：`_mouse_over_ui()` 是按"鼠标是否落在可见 Control 的
	# 矩形内"判定的，而这个提示是**跟着鼠标跑**的 —— 挂进去等于鼠标一碰到提示
	# 就自我判定成"在 UI 上"，滚轮缩放和拖拽平移会被自己挡掉。
	tip_layer = CanvasLayer.new()
	tip_layer.layer = 2
	add_child(tip_layer)
	_tip = PanelContainer.new()
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 8, 5, 8, 5))
	_tip.visible = false
	_tip_label = UIKit.label("", UIKit.FG_DARK)
	_tip.add_child(_tip_label)
	tip_layer.add_child(_tip)

	# 工地进度条：盖在建筑之上，`_process` 里每帧 queue_redraw（有工地才重画）
	site_layer = Node2D.new()
	site_layer.z_index = 6
	add_child(site_layer)
	site_layer.draw.connect(_draw_site_bars)

	# 调试层：建筑占地方框，压在所有东西之上，默认隐藏
	debug_layer = Node2D.new()
	debug_layer.z_index = 40
	debug_layer.visible = false
	add_child(debug_layer)
	debug_layer.draw.connect(_draw_footprints)

	_render_base_terrain()

## 整数哈希：把 (x,y) 混成均匀分布。
## 不能用 `x*a + y*b` 再取模 —— 那会形成斜条纹：
##   x*7+y*13 ≡ 0 (mod 3)  ⟺  x+y ≡ 0 (mod 3)   → 每三格一条对角线
##   x*7+y*13 ≡ 0 (mod 7)  ⟺  y   ≡ 0 (mod 7)   → 每七行一条横带
## 所以之前的花和树都是规则条纹，不是随机。
func _hash2(x: int, y: int) -> int:
	var n := (x * 73856093) ^ (y * 19349663)
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return absi(n)

## 草地变体：0 = 纯草，1 = 小白花，2 = 大黄花。大黄花必须很稀有。
func _grass_variant(hv: int) -> int:
	if hv % 61 == 0:
		return 2
	if hv % 7 == 0:
		return 1
	return 0

func _render_base_terrain() -> void:
	# 底色 + 水 + 地面补丁 + 树（只在生成 / 读档时铺一次）
	for y in GameMap.H:
		for x in GameMap.W:
			var c := Vector2i(x, y)
			var t: int = map.terrain[map.idx(x, y)]
			var hv := _hash2(x, y)
			var gv := _grass_variant(hv)
			match t:
				GameMap.WATER:
					terrain_layer.set_cell(c, 1, _extra_cell(_water_index(c)))
				GameMap.STONE:
					terrain_layer.set_cell(c, 0, _town_cell(gv))
					terrain_layer.set_cell(c, 1, _extra_cell(50))
				GameMap.CLAY:
					terrain_layer.set_cell(c, 0, _town_cell(gv))
					terrain_layer.set_cell(c, 1, _extra_cell(51))
				GameMap.FOREST:
					terrain_layer.set_cell(c, 0, _town_cell(gv))
					# 树：按哈希铺，靠 16x32 的重叠形成树冠。
					# 但被占用（建筑/仓库/道路/地板）的格子不能长树 —— 这一处原先不看占地，
					# 于是每次整体重画都把树加回房子和路面上，逼得每个落位路径都要自己
					# 补一次 erase_cell，也就必然会漏（之前连漏了三次）。
					if hv % 3 == 0 and not _cell_has_cover(c):
						deco_layer.set_cell(c, 2, Vector2i(hv % DECO_VARIANTS, 0))
				_:
					terrain_layer.set_cell(c, 0, _town_cell(gv))
				GameMap.GRASS:
					pass

## 这一格是否已被占用（建筑 / 仓库 / 道路 / 地板）—— 占用了就不该长树
func _cell_has_cover(c: Vector2i) -> bool:
	if map.occupied.has(c) or map.town_center.has_point(c):
		return true
	return map.road[map.idx(c.x, c.y)] != 0 or map.floor_tiles[map.idx(c.x, c.y)] != 0

## 恢复一块地面的自然装饰（树）。用于建筑挪走 / 拆除之后把地还原。
func _restore_deco(cell: Vector2i, w: int, h: int) -> void:
	for x in w:
		for y in h:
			var c := cell + Vector2i(x, y)
			if not map.in_bounds(c) or _cell_has_cover(c):
				continue
			if map.terrain[map.idx(c.x, c.y)] != GameMap.FOREST:
				continue
			var hv := _hash2(c.x, c.y)
			if hv % 3 == 0:
				deco_layer.set_cell(c, 2, Vector2i(hv % DECO_VARIANTS, 0))

func _build_town_center() -> void:
	var fp := map.town_center.size
	var spr := Sprite2D.new()
	town_center_sprite = spr
	spr.texture = load("res://assets/buildings/town_center.png")
	spr.centered = false
	# 和普通建筑同一条规则：横向居中、底边对齐，节点位置 = 地面线（供 y 排序）。
	# 城镇中心是 3 层楼（121x160），占地由 content 声明成 8x6 —— 贴图比占地高
	# 64px，往上伸出去盖住身后的建筑（这是"占地格数和实际高度可以不同"的直接后果）。
	var tex := spr.texture
	if tex != null:
		spr.position = Vector2(
			map.town_center.position.x * TILE + fp.x * TILE * 0.5,
			map.town_center.position.y * TILE + fp.y * TILE)
		spr.offset = Vector2(-tex.get_width() * 0.5, -tex.get_height())
	else:
		spr.position = Vector2(map.town_center.position.x * TILE, map.town_center.position.y * TILE)
	building_layer.add_child(spr)
	_town_center_pos = Vector2(map.town_center.get_center().x * TILE, map.town_center.get_center().y * TILE)
	# 门洞由 content 声明：`town_center.art.doors = [[3,5],[4,5]]` —— 贴图上画的是
	# **双开门**，门口本来就占两格（用户明确要求"门口两格都必须是门洞"）。
	# 两格门格 + 两格门前通行格全部预留，见 `_register_doors()`。
	var tc_doors := _register_doors("town_center", map.town_center.position, fp)
	_town_center_door = (tc_doors[0] as Array)[0]
	_town_center_goal = tc_doors[1]
	# ⚠️ **把占地登记成一条 shop 占格**，否则这座楼是"点不动"的。
	#
	# 点击选中走的是 `_on_left_click()` → `map.occupied_at(cell)` → `select_building`。
	# 城镇中心没有走 `_create_shop_view()`（它不需要再摆一个精灵，视觉就是这座固定建筑，
	# `_sync()` 里还专门跳过它的 shop 实例），所以**没人替它登记占格** ——
	# 结果是点它命中不到任何东西、什么都不弹（用户反馈："城镇中心的窗我弹不出去"）。
	# id 用 state.shops 里那条 town_center 的实例 id，这样点击 → select_building →
	# main 的分派就能认出它并弹出对话框。
	map.occupy(map.town_center.position, fp.x, fp.y, "shop", _town_center_shop_id())

## `state.shops` 里那条 town_center 的实例 id（没有就退回一个约定值）。
func _town_center_shop_id() -> String:
	if runner != null and runner.sim != null:
		for sh in runner.sim.s["shops"]:
			if String(sh["defId"]) == "town_center":
				return String(sh["id"])
	return "town_center#1"

func _camera_setup() -> void:
	camera = Camera2D.new()
	camera.position = Vector2(map.center.x * TILE, map.center.y * TILE)
	camera.zoom = Vector2(ZOOM, ZOOM)
	add_child(camera)
	camera.make_current()

	ghost = Sprite2D.new()
	ghost.centered = false
	ghost.modulate = Color(1, 1, 1, 0.5)
	ghost.visible = false
	ghost.z_index = 20
	add_child(ghost)

func _find_free_area(type: String, near: Vector2i, gap: int) -> Vector2i:
	var fp = _footprint(type)
	# 从**城镇中心紧邻的一格**开始，一圈圈往外找。
	#
	# 这里曾经是 `+ Vector2i(-14, 8)`（左 14 格、下 8 格）。后果不只是"不好看"：
	# 开局那 6 间茅屋会整齐地落在**屏幕外** —— 默认镜头 zoom=3 只看得到约 16 格宽，
	# 房子全在 14~18 格之外。玩家的第一反应就是"初始不给房子？"（用户原话），
	# 而 `state.housing` 里明明写着 6 间。挪到紧邻之后，开局的村子是围着
	# 城镇中心的一小簇，一眼看得见。
	var base = map.town_center.position + Vector2i(-1, -1)
	for ring in range(0, 90):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if ring > 0 and abs(dx) != ring and abs(dy) != ring:
					continue
				var c = base + Vector2i(dx, dy)
				if gap > 0:
					if map.terrain_ok(c - Vector2i(gap, gap), fp.x + gap * 2, fp.y + gap * 2, []):
						return c
				elif map.terrain_ok(c, fp.x, fp.y, []):
					return c
	return Vector2i(-1, -1)

func _art_of(type: String) -> Dictionary:
	if runner.db.housing.has(type):
		return runner.db.housing[type].get("art", {})
	if runner.db.buildings.has(type):
		return runner.db.buildings[type].get("art", {})
	return {}

func _footprint(type: String) -> Vector2i:
	# 占地由 art 规格决定。成品整图**优先用 content 声明的 art.foot** ——
	# 贴图可以比占地高（往上伸出去、和身后的建筑互相遮挡），两者不是一回事；
	# 不声明才退回"按贴图尺寸算"。
	var a := _art_of(type)
	if a.is_empty():
		return Vector2i(2, 2)
	var arch := String(a.get("arch", ""))
	if arch == "sprite":
		var foot = a.get("foot", null)
		if foot is Array and (foot as Array).size() == 2:
			return Vector2i(int(foot[0]), int(foot[1]))
		var tex := _texture_for(type)
		if tex != null:
			# ⚠️ 用 **floor**，不是 ceil。
			#
			# `_place_sprite()` 把贴图**底边**对齐占地的**底边**，所以多算出来的行
			# 全在占地顶部、**画面上什么都没有**，却实实在在占着格子挡建造 ——
			# 玩家报过"画面上明明没有占到，但是实际上占到了"（茅屋 64×48：
			# ceil(1.5)=2 格，顶部 16px 就是隐形的）。
			# floor 之后，贴图高出来的那部分变成"往上伸出去的装饰"，
			# 可以和后一格的建筑互相遮挡 —— 这正是本函数注释里写的设计本意。
			# 至少留 1 格，别让矮贴图算出 0 占地。
			return Vector2i(maxi(1, int(floor(tex.get_width() / float(TILE)))),
				maxi(1, int(floor(tex.get_height() / float(TILE)))))
		return Vector2i(3, 3)
	var w := int(a.get("w", 6 if arch == "field" else 3))
	if arch == "field" or a.has("rows"):
		return Vector2i(w, int(a.get("rows", 1)))
	# 屋顶行数：绿顶（谷仓）只有一行，其余两行（顶排 + 檐口）；再加一行墙
	var roof_rows := 1 if String(a.get("roof", "")) == "green" else 2
	return Vector2i(w, roof_rows + 1)

## 把成品整图摆进占地格：**横向居中、底边对齐**，并把节点自身的位置落在"地面线"
## （占地底边的中点）上 —— y 排序用的就是节点 y，所以必须让它等于地面线，
## 而不是贴图左上角（那样前排后排会排错）。
##
## **底部对齐**是正面平视图的关键：新素材是完全正面平视（无透视、看不到屋顶坡面），
## 建筑应该"站"在占地的底边上、向上生长；居中会让它一半陷进地里。
## 占地比贴图矮时 offset.y 为负 —— 贴图就往**上**伸出占地，盖住身后的建筑，
## 这正是 content 里 art.foot 想表达的东西。
func _place_sprite(spr: Sprite2D, type: String, origin: Vector2i, fp: Vector2i) -> void:
	var a := _art_of(type)
	if String(a.get("arch", "")) != "sprite" or spr.texture == null:
		spr.position = Vector2(origin.x * TILE, origin.y * TILE)
		return
	spr.position = Vector2(
		origin.x * TILE + fp.x * TILE * 0.5,
		origin.y * TILE + fp.y * TILE)
	spr.offset = Vector2(-spr.texture.get_width() * 0.5, -spr.texture.get_height())

func _texture_for(type: String) -> Texture2D:
	if _tex_cache.has(type):
		return _tex_cache[type]
	# 成品整图与程序化拼装都落在 assets/buildings/<id>.png，取法一致
	var tex: Texture2D = load("res://assets/buildings/%s.png" % type)
	_tex_cache[type] = tex
	return tex

func _place_housing_instance(type: String, cell: Vector2i) -> void:
	var fp = _footprint(type)
	var uid = "%s#%d" % [type, _housing_instances.size() + 1]
	map.occupy(cell, fp.x, fp.y, "housing", uid)
	_clear_deco(cell, fp.x, fp.y)
	var spr := Sprite2D.new()
	spr.texture = _texture_for(type)
	spr.centered = false
	_place_sprite(spr, type, cell, fp)
	building_layer.add_child(spr)
	var cap = 4
	if runner.db.housing.has(type):
		cap = int(runner.db.housing[type]["capacity"])
	var dd := _register_doors(type, cell, fp)
	var icell: Vector2i = dd[1]
	var inst = {"uid": uid, "id": type, "type": type, "cell": cell, "fw": fp.x, "fh": fp.y, "sprite": spr, "capacity": cap, "private": false, "occupants": [], "anchor": _anchor_cell(cell, fp.x, fp.y), "door": dd[0], "goal": icell}
	_housing_instances.append(inst)
	_housing_by_uid[uid] = inst
	_nav_dirty = true
	var hname = String(runner.db.housing[type]["nameZh"]) if runner.db.housing.has(type) else type
	inst["label"] = _add_label(hname, cell, fp.x, fp.y)

func housing_instance(uid: String) -> Variant:
	return _housing_by_uid.get(uid, null)

## 建筑占地范围内的装饰（树）要抹掉，否则房子四周会露出树。
## 道路/地板在 _rerender_terrain() 里抹过，建筑这条路径原本漏了。
func _clear_deco(cell: Vector2i, w: int, h: int) -> void:
	for x in w:
		for y in h:
			deco_layer.erase_cell(cell + Vector2i(x, y))

func _create_shop_view(sid: String, def_id: String, cell: Vector2i) -> void:
	if _shop_sprites.has(sid):
		return
	var fp = _footprint(def_id)
	map.occupy(cell, fp.x, fp.y, "shop", sid)
	_clear_deco(cell, fp.x, fp.y)
	var spr := Sprite2D.new()
	spr.texture = _texture_for(def_id)
	spr.centered = false
	_place_sprite(spr, def_id, cell, fp)
	building_layer.add_child(spr)
	_shop_sprites[sid] = spr
	_shop_cell[sid] = cell
	_shop_def[sid] = def_id
	_shop_anchor[sid] = _anchor_cell(cell, fp.x, fp.y)
	var dd := _register_doors(def_id, cell, fp)
	_shop_door[sid] = dd[0]
	_shop_goal[sid] = dd[1]
	_nav_dirty = true
	if runner.db.buildings.has(def_id):
		_shop_label[sid] = _add_label(String(runner.db.buildings[def_id]["nameZh"]), cell, fp.x, fp.y)

func _rerender_terrain() -> void:
	_clear_labels()
	terrain_layer.clear()
	floor_layer.clear()
	road_layer.clear()
	deco_layer.clear()
	_render_base_terrain()
	# 道路 / 地板按存档位图重铺。
	# 必须顺手 erase_cell 抹掉这些格子上的装饰（树）—— _render_base_terrain()
	# 是按地形撒树的，它不知道路网，不抹的话路面上会长树。
	# 笔刷 _paint_cell() 里本来就有这一步，整体重画这条路走漏了。
	for c in _cells_with(map.road):
		var rc := Vector2i(c[0], c[1])
		deco_layer.erase_cell(rc)
		road_layer.set_cell(rc, 1, _extra_cell(_road_index(rc)))
	for c in _cells_with(map.floor_tiles):
		var fc := Vector2i(c[0], c[1])
		deco_layer.erase_cell(fc)
		floor_layer.set_cell(fc, 1, _extra_cell(52))
	_rebuild_labels()

## 重画地形后**必须**把所有标签补回来。
##
## `_rerender_terrain()` 的第一行是 `_clear_labels()`，它会把 `_label_items` 全清空。
## 以前只有"后建的"商店/住房能重新拿到标签，而城镇中心是在 `start_new_game()` 里
## 建的、`_lay_showcase_ground()` 里的 `_rerender_terrain()` 排在它后面 ——
## 于是**标题页展示的那个村庄里，城镇中心（当时还叫仓库）没有名字**。
## 根因是语句顺序，修法是把它纳入"重画地形后统一重建"的清单：
## 这样任何调用顺序都不会再丢标签。
func _rebuild_labels() -> void:
	if map.town_center.size.x > 0:
		_add_label("城镇中心", map.town_center.position,
			map.town_center.size.x, map.town_center.size.y)
	for sid in _shop_sprites.keys():
		var def_id := String(_shop_def.get(sid, ""))
		if not runner.db.buildings.has(def_id):
			continue
		var fp := _footprint(def_id)
		_shop_label[sid] = _add_label(
			String(runner.db.buildings[def_id]["nameZh"]), _shop_cell[sid], fp.x, fp.y)
	for inst in _housing_instances:
		var htype := String(inst["type"])
		if not runner.db.housing.has(htype):
			continue
		inst["label"] = _add_label(
			String(runner.db.housing[htype]["nameZh"]), inst["cell"],
			int(inst["fw"]), int(inst["fh"]))

## 重算某格及其邻格的道路贴图（相邻关系变了）
func _refresh_road(c: Vector2i) -> void:
	var cells := [c, c + Vector2i(0, -1), c + Vector2i(0, 1), c + Vector2i(1, 0), c + Vector2i(-1, 0)]
	for n in cells:
		if map.in_bounds(n) and map.road[map.idx(n.x, n.y)] != 0:
			road_layer.set_cell(n, 1, _extra_cell(_road_index(n)))

func _cells_with(bitmap: PackedByteArray) -> Array:
	var out := []
	for y in GameMap.H:
		for x in GameMap.W:
			if bitmap[map.idx(x, y)] == 1:
				out.append([x, y])
	return out

# ---- 存档 / 读档（含地图与放置）-----------------------------------------
const SAVE_VERSION := 2

func save_to(path: String) -> Error:
	var data := {
		"saveVersion": SAVE_VERSION,
		"mapSeed": _map_seed,
		"sim": {
			"pack": String(runner.sim.s["pack"]),
			"seed": int(runner.sim.s["seed"]),
			"rngState": runner.sim.rng.state,
			"state": runner.sim.s,
		},
		"road": _cells_with(map.road),
		"floor": _cells_with(map.floor_tiles),
		"floorCharge": map.floor_charge,
		"shops": _shop_list(),
		"housing": _housing_list(),
		"sites": _site_list(),
	}
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data))
	f.close()
	return OK

func _shop_list() -> Array:
	var out := []
	for sid in _shop_cell.keys():
		var c = _shop_cell[sid]
		out.append({"id": String(sid), "defId": String(_shop_def.get(sid, "")), "cell": [c.x, c.y]})
	return out

func _housing_list() -> Array:
	var out := []
	for inst in _housing_instances:
		var c = inst["cell"]
		out.append({"type": String(inst["type"]), "cell": [c.x, c.y]})
	return out

func _site_list() -> Array:
	var out := []
	for s in _sites:
		var c = s["cell"]
		out.append({"kind": String(s["kind"]), "type": String(s["id"]), "cell": [c.x, c.y]})
	return out

func _reset_buildings() -> void:
	# ⚠️ 小人和树图层跟建筑共用 building_layer（y 排序要求同一个父节点），所以这里
	# 必须跳过带 "keep" meta 的子节点 —— 否则每次读档/重开都会把小人节点和整个
	# 树图层一并删掉（踩过：树图层被删 → 地面整片不渲染）。
	for ch in building_layer.get_children():
		if ch.has_meta("keep"):
			continue
		ch.queue_free()
	_shop_sprites.clear()
	_shop_cell.clear()
	_shop_def.clear()
	_shop_door.clear()
	_shop_goal.clear()
	_shop_label.clear()
	_doors.clear()
	_walk_inside.clear()
	_housing_instances.clear()
	_housing_by_uid.clear()
	_sites.clear()
	_site_by_type.clear()
	_placed_housing_count.clear()
	map.occupied.clear()
	map.reserved.clear()

## 标题页展示用的"像个村子"的村庄：额外铺一批建筑、补一批居民，
## 再快进一段让仿真自洽。只用于展示，开始游戏时会被真实开局覆盖。
func showcase_village(seed_value: int) -> void:
	start_new_game(seed_value, 10.0, "sovit")
	var s: Dictionary = runner.sim.s
	s["government"]["money"] = 500000.0
	s["government"]["populationCap"] = 100000.0
	# 开局物资：**够撑过下面那 6 天快进**就行，不再一味堆 20000。
	# 仓储上限是"全局总量"口径（城镇中心 1000 + 每座仓库 300，见 docs/town.md §三），
	# 堆多了当晚就被丢掉 —— 以前没上限才敢写 20000。
	# 这份小清单合计 580，留了足够余量给快进期间的产出。
	for g in (s["goods"] as Dictionary).keys():
		s["goods"][g] = 0.0
	var seed_goods := {
		"coarse_bread": 120.0, "vegetable": 60.0,       # 口粮（6 天里 40 来人吃得起）
		"wheat": 60.0, "coarse_flour": 40.0,            # 面包链的引子
		"wood": 120.0, "stone": 60.0, "clay": 40.0,     # 建材
		"firewood": 40.0, "brick": 40.0,
	}
	for gid in seed_goods.keys():
		if (s["goods"] as Dictionary).has(gid):
			s["goods"][gid] = float(seed_goods[gid])
	# 补 3 座仓库把容量从 1000 撑到 1900：快进 6 天里村子会持续产出，
	# 没有这几座的话产出会顶到 1000 上限被丢掉（而且仓库本身也是新建筑，正好展示）。
	# ⚠️ 仓库要**有在岗工人**才算容量（docs/town.md §3.2），所以 targetWorkers 给满 2。
	for i in 3:
		(s["shops"] as Array).append({
			"id": "show_wh#%d" % (i + 1), "defId": "warehouse", "owner": "state",
			"targetWorkers": 2, "wage": float(runner.db.economy["refWage"]),
			"wageCap": float(runner.db.economy["defaultWageCap"]),
			"level": int(runner.db.defaults["newShop"]["level"]),
			"active": true, "profit": 0.0,
			"skill": float(runner.db.defaults["newShop"]["skill"]),
			"planned": 0.0,
		})

	# 先铺路和地板 —— 没有路面的村庄看着非常奇怪（空地上一堆房子）。
	# 顺序很关键：路先铺，后面摆建筑时再避开路面。
	_lay_showcase_ground()

	# 额外工坊：从中心向外一圈圈找空位，跳过已占格
	var ids: Array = []
	for k in runner.db.buildings.keys():
		ids.append(String(k))
	ids.sort()
	var want := 30
	var placed := 0
	var ring := 2
	while placed < want and ring < 26:
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				if placed >= want:
					break
				if absi(dx) != ring and absi(dy) != ring:
					continue
				var cell: Vector2i = map.center + Vector2i(dx * 3, dy * 3)
				if not map.in_bounds(cell):
					continue
				var def_id: String = ids[placed % ids.size()]
				var fp: Vector2i = _footprint(def_id)
				if not _area_free(cell, fp):
					continue
				var d: Dictionary = runner.db.buildings[def_id]
				var sid := "show#%d" % placed
				(s["shops"] as Array).append({
					"id": sid, "defId": def_id, "owner": "state",
					"targetWorkers": int(d["workers"]),
					"wage": float(runner.db.economy["refWage"]),
					"wageCap": float(runner.db.economy["defaultWageCap"]),
					"level": int(runner.db.defaults["newShop"]["level"]),
					"active": true, "profit": 0.0,
					"skill": float(runner.db.defaults["newShop"]["skill"]),
					"planned": 0.0,
				})
				_create_shop_view(sid, def_id, cell)
				placed += 1
		ring += 1

	# 额外住房。这一步不能省：_refresh_agents() 是按住房实例分配住处的，
	# 分不到房的人**一律被放在仓库门口** —— 于是标题页上看到一群人挤在一点。
	var htypes: Array = []
	for k in runner.db.housing.keys():
		htypes.append(String(k))
	htypes.sort()
	var hwant := 14
	var hplaced := 0
	var hring := 2
	while hplaced < hwant and hring < 26:
		for dx in range(-hring, hring + 1):
			for dy in range(-hring, hring + 1):
				if hplaced >= hwant:
					break
				if absi(dx) != hring and absi(dy) != hring:
					continue
				var hcell: Vector2i = map.center + Vector2i(dx * 3 + 1, dy * 3 + 1)
				if not map.in_bounds(hcell):
					continue
				var htype: String = htypes[hplaced % htypes.size()]
				if not _area_free(hcell, _footprint(htype)):
					continue
				_place_housing_instance(htype, hcell)
				(s["housing"] as Dictionary)[htype] = float((s["housing"] as Dictionary).get(htype, 0.0)) + 1.0
				hplaced += 1
		hring += 1

	# 快进几天，让排产/满足度/行走目标都进入稳态
	for i in 24 * 6:
		runner.sim.tick_hour([])
	# 时间拨到 5:00 —— 0 点开局所有人都在屋里，5 点他们才出门。
	var guard := 0
	while int(s["hour"]) != 5 and guard < 48:
		runner.sim.tick_hour([])
		guard += 1

	# 补居民必须放在快进**之后**：快进期间会按满足度淘汰人口，
	# 先加的话这 40 人跑几天就没了（截图里街上只剩一两个人就是这么来的）。
	for i in 40:
		(s["residents"] as Array).append(runner.sim._make_resident("poor"))

	# ⚠️ 补完人**必须再派一次工**：`_assign_labor()` 只在黎明跑，而这 40 人是在
	# 快进结束之后才进来的 —— 不补这一下，他们全是失业状态（65 人里只有 21 人上岗），
	# 商店空着、**仓库也一个工人都没有 → 仓储容量加不上**（仓库要有在岗工人才算容量）。
	runner.sim._assign_labor()

	_prev_res = -1
	_prev_housing_n = -1

func _area_free(cell: Vector2i, fp: Vector2i) -> bool:
	for x in fp.x:
		for y in fp.y:
			var c := cell + Vector2i(x, y)
			if map.occupied.has(c) or map.reserved.has(c):
				return false
			# 别把房子盖在路中间
			if map.road[map.idx(c.x, c.y)] != 0:
				return false
	return true

## 展示村庄的路网与铺装：十字主干道 + 三层环路 + 中心广场。
func _lay_showcase_ground() -> void:
	var road_cells := []
	var add_road := func(c: Vector2i):
		if map.in_bounds(c) and not map.occupied.has(c):
			map.road[map.idx(c.x, c.y)] = 1
			road_cells.append(c)
	# 十字主干道（宽 4）
	for i in range(-36, 37):
		for w in range(-1, 3):
			add_road.call(map.center + Vector2i(i, w))
			add_road.call(map.center + Vector2i(w, i))
	# 三层环路
	for r in [9, 17, 25]:
		for a in range(0, 360, 2):
			var rad := deg_to_rad(float(a))
			add_road.call(map.center + Vector2i(int(round(cos(rad) * float(r))), int(round(sin(rad) * float(r) * 0.72))))
	# 中心广场铺装（半径 7 的实心圆）
	for dx in range(-7, 8):
		for dy in range(-7, 8):
			if dx * dx + dy * dy <= 49:
				var c := map.center + Vector2i(dx, dy)
				if map.in_bounds(c) and map.road[map.idx(c.x, c.y)] == 0:
					map.floor_tiles[map.idx(c.x, c.y)] = 1
	_rerender_terrain()
	for c in road_cells:
		_refresh_road(c)

## 从「新游戏」对话框重开一局：换种子重生成地图，按倍率给初始资源，写入村名。
func start_new_game(seed_value: int, resource_mult: float, village_name: String) -> void:
	runner.sim = SimCore.new(runner.db)
	runner.sim.new_game("v0.3", seed_value, resource_mult)
	# 截断放在这里 —— 这是重开一局的唯一入口，任何调用方都绕不过去。
	# 只在对话框里截断的话，直接调这个函数就会漏（测试就是这么抓到的）。
	var nm := village_name.strip_edges()
	if nm == "":
		nm = "sovit"
	if nm.length() > UIKit.NAME_MAX:
		nm = nm.substr(0, UIKit.NAME_MAX)
	runner.sim.s["villageName"] = nm
	runner.recent_logs = []
	_reset_buildings()
	_map_seed = seed_value
	map = GameMap.new()
	map.generate(_map_seed)
	_rerender_terrain()
	# 必须重建仓库精灵：上面刚换了一张全新的 GameMap，而 _reset_buildings()
	# 已经把 building_layer 清空了。load_from 里有这一步，这里漏了就会
	# 新游戏之后仓库不见了。
	_build_town_center()
	_prev_res = -1          # 强制 _sync() 重建居民与建筑精灵
	_prev_housing_n = -1

func load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null:
		return false
	var ver = int(data.get("saveVersion", 0))
	if ver < 1 or ver > SAVE_VERSION:
		return false

	# 兼容 v1：旧格式把 sim 字段(pack/seed/rngState/state)放在顶层
	var sp = data.get("sim", null)
	if sp == null:
		sp = data
	if not sp.has("state"):
		return false

	var sim := SimCore.new(runner.db)
	sim.s = sp["state"]
	sim.rng = Rng.new(int(sp.get("rngState", 0)))
	SaveManager._sanitize(sim.s, runner.db)
	runner.sim = sim
	runner.recent_logs = []

	_reset_buildings()

	if data.has("mapSeed") and data.has("shops"):
		_map_seed = int(data.get("mapSeed", _map_seed))
		map = GameMap.new()
		map.generate(_map_seed)
		_rerender_terrain()
		for pair in data.get("road", []):
			var c := Vector2i(int(pair[0]), int(pair[1]))
			if map.in_bounds(c):
				map.road[map.idx(c.x, c.y)] = 1
		for pair in data.get("floor", []):
			var c := Vector2i(int(pair[0]), int(pair[1]))
			if map.in_bounds(c):
				map.floor_tiles[map.idx(c.x, c.y)] = 1
		for c in _cells_with(map.road):
			road_layer.set_cell(Vector2i(c[0], c[1]), 1, _extra_cell(_road_index(Vector2i(c[0], c[1]))))
		for c in _cells_with(map.floor_tiles):
			floor_layer.set_cell(Vector2i(c[0], c[1]), 1, _extra_cell(52))
		map.floor_charge = int(data.get("floorCharge", 0))

	_build_town_center()

	if data.has("shops"):
		for s2 in data.get("sites", []):
			var c := Vector2i(int(s2["cell"][0]), int(s2["cell"][1]))
			var t = String(s2["type"])
			_register_site(String(s2["kind"]), t, c, _footprint(t))
		for sh in data.get("shops", []):
			var c := Vector2i(int(sh["cell"][0]), int(sh["cell"][1]))
			_create_shop_view(String(sh["id"]), String(sh["defId"]), c)
		for h in data.get("housing", []):
			var c := Vector2i(int(h["cell"][0]), int(h["cell"][1]))
			var t = String(h["type"])
			_place_housing_instance(t, c)
			_placed_housing_count[t] = int(_placed_housing_count.get(t, 0)) + 1
	# 旧档（无地图/放置）：保留当前地图，由 _sync 重新摆放建筑

	_prev_res = -1
	_prev_housing_n = -1
	_nav_dirty = true
	_nav_timer = 0.0
	_assign_homes()
	_refresh_agents()
	return true

# ---- 移动建筑 -------------------------------------------------------------
func begin_move_shop(sid: String) -> void:
	# 进入移动模式 = 取消选中：对话框会挡住要放的位置
	select_none.emit()
	if not _shop_cell.has(sid):
		return
	move_mode = "shop:" + sid
	build_mode = ""
	brush_mode = ""
	ghost.texture = _texture_for(String(_shop_def.get(sid, "")))
	ghost.visible = true
	notice.emit("点击新位置移动建筑（右键取消）")

func begin_move_housing(uid: String) -> void:
	# 进入移动模式 = 取消选中：对话框会挡住要放的位置
	select_none.emit()
	if not _housing_by_uid.has(uid):
		return
	var inst = _housing_by_uid[uid]
	move_mode = "housing:" + uid
	build_mode = ""
	brush_mode = ""
	ghost.texture = _texture_for(String(inst["type"]))
	ghost.visible = true
	notice.emit("点击新位置移动住房（右键取消）")

func _own_cells(cell: Vector2i, fp: Vector2i) -> Dictionary:
	var d := {}
	for dy in fp.y:
		for dx in fp.x:
			d[cell + Vector2i(dx, dy)] = true
	return d

func _move_ok(type: String, origin: Vector2i, fp: Vector2i, own: Dictionary) -> bool:
	var terrains := []
	if runner.db.buildings.has(type) and runner.db.buildings[type].has("terrain"):
		terrains = [String(runner.db.buildings[type]["terrain"])]
	for dy in fp.y:
		for dx in fp.x:
			var c = origin + Vector2i(dx, dy)
			if not map.in_bounds(c) or map.is_water(c):
				return false
			if own.has(c):
				continue
			if map.town_center.has_point(c) or map.occupied.has(c) or map.reserved.has(c):
				return false
			if not terrains.is_empty() and not terrains.has(GameMap.terrain_name(map.terrain_at(c))):
				return false
	return true

func _free_building_cells(cell: Vector2i, fp: Vector2i, doors: Array, interior: Vector2i) -> void:
	for dy in fp.y:
		for dx in fp.x:
			map.occupied.erase(cell + Vector2i(dx, dy))
	for d in doors:
		_doors.erase(d)
		_walk_inside.erase(d)
		map.reserved.erase(d)
		map.reserved.erase(d + Vector2i(0, 1))
	_walk_inside.erase(interior)

## 占格 + 门洞（`_register_doors`）。`type` 是**内容定义 id**（如 `coarse_weaver`、
## `hut`），不是实例 id —— 门洞要从 `art.doors` 读，实例 id 查不到 art。
func _occupy_building(kind: String, id: String, type: String, cell: Vector2i, fp: Vector2i) -> Array:
	map.occupy(cell, fp.x, fp.y, kind, id)
	_clear_deco(cell, fp.x, fp.y)
	return _register_doors(type, cell, fp)

func move_shop_to(sid: String, origin: Vector2i) -> bool:
	var def_id = String(_shop_def.get(sid, ""))
	if def_id == "" or not _shop_cell.has(sid) or not _shop_sprites.has(sid):
		return false
	var fp = _footprint(def_id)
	var old = _shop_cell[sid]
	if not _move_ok(def_id, origin, fp, _own_cells(old, fp)):
		return false
	_free_building_cells(old, fp, _shop_door.get(sid, []), _shop_goal.get(sid, old))
	_restore_deco(old, fp.x, fp.y)     # 旧址还原成自然地（该长树的把树补回来）
	if _shop_label.has(sid) and is_instance_valid(_shop_label[sid]):
		_shop_label[sid].queue_free()
	_shop_label.erase(sid)
	var spr = _shop_sprites[sid]
	_place_sprite(spr, def_id, origin, fp)
	_shop_label[sid] = _add_label(String(runner.db.buildings[def_id]["nameZh"]), origin, fp.x, fp.y)
	var d = _occupy_building("shop", sid, def_id, origin, fp)
	_shop_cell[sid] = origin
	_shop_door[sid] = d[0]
	_shop_goal[sid] = d[1]
	_shop_anchor[sid] = _anchor_cell(origin, fp.x, fp.y)
	# 新位置门口自动铺路。**旧址那格路故意不擦**（用户："移走的时候可以先不擦除"）——
	# 路面是"这里曾经有门"的痕迹，擦掉反而让玩家以为路是自己消失的。
	_pave_door_front(def_id, origin, fp)
	_after_move()
	return true

func move_housing_to(uid: String, origin: Vector2i) -> bool:
	if not _housing_by_uid.has(uid):
		return false
	var inst = _housing_by_uid[uid]
	if not is_instance_valid(inst.get("sprite", null)):
		return false
	var type = String(inst["type"])
	var fp = Vector2i(int(inst["fw"]), int(inst["fh"]))
	var old = inst["cell"]
	if not _move_ok(type, origin, fp, _own_cells(old, fp)):
		return false
	_free_building_cells(old, fp, inst["door"], inst["goal"])
	_restore_deco(old, fp.x, fp.y)     # 旧址还原成自然地
	if is_instance_valid(inst.get("label", null)):
		inst["label"].queue_free()
	# 贴图是按占地"横向居中、底边对齐"摆的，换位置后要重算
	_place_sprite(inst["sprite"], type, origin, fp)
	inst["cell"] = origin
	inst["label"] = _add_label(String(runner.db.housing[type]["nameZh"]), origin, fp.x, fp.y)
	var d = _occupy_building("housing", uid, type, origin, fp)
	inst["door"] = d[0]
	inst["goal"] = d[1]
	inst["anchor"] = _anchor_cell(origin, fp.x, fp.y)
	# 新位置门口自动铺路；旧址那格路**不擦**（同 move_shop_to）
	_pave_door_front(type, origin, fp)
	_after_move()
	return true

func _after_move() -> void:
	_nav_dirty = true
	_nav_timer = 0.0
	_prev_housing_n = -1
	_assign_homes()
	_refresh_agents()

# ---- 同步仿真里的建筑 -----------------------------------------------------
func _sync() -> void:
	# 拆除（demolish）：引擎里没了 → 收走精灵、**释放地格**。
	#
	# 这一步不做的话，拆掉的建筑会留下一张"鬼影"精灵，而且 `map.occupied`
	# 还占着那块地 —— 之后再也建不了东西，且看起来像没拆掉。
	var alive := {}
	for shop in runner.sim.s["shops"]:
		alive[String(shop["id"])] = true
	for sid in _shop_sprites.keys():
		if alive.has(sid):
			continue
		_remove_shop_view(String(sid))

	# 新店铺（含开局为空）→ 绑定到预留工地或找空地
	for shop in runner.sim.s["shops"]:
		var nid = String(shop["id"])
		if _shop_sprites.has(nid):
			continue
		var def_id = String(shop["defId"])
		# 城镇中心是**地图上固定那一座**（`game_map.town_center` + `_build_town_center()`）。
		# 开局 `state.shops` 里那条 `town_center` 说的就是它（引擎要靠它算仓储容量），
		# 但它的精灵/门/预留格已经由 `_build_town_center()` 摆好了 —— 这里再走一遍
		# 通用路径就会在地图上多出**第二座**城镇中心。
		if def_id == "town_center":
			continue
		var cell = _take_site_for(def_id)
		if cell.x < 0:
			cell = _find_free_area(def_id, map.center, 0)
		if cell.x < 0:
			continue
		_create_shop_view(nid, def_id, cell)

	# 研究所在场：头顶的科研进度条也跟着这个 `_draw` 层一起画（见 `_draw_site_bars`）。
	# 这一帧算一次，`_process` 就不必每帧去翻 shops。
	_has_research_bar = not _research_shops().is_empty()

	# 新住房实例
	var housing: Dictionary = runner.sim.s["housing"]
	for type in housing.keys():
		var want = int(float(housing[type]))
		var have = int(_placed_housing_count.get(type, 0))
		var site_cells := _take_sites_for(type, want - have)
		for cell in site_cells:
			_place_housing_instance(type, cell)
			have += 1
		while have < want:
			var cell = _find_free_area(type, map.center, 1)
			if cell.x < 0:
				break
			_place_housing_instance(type, cell)
			have += 1
		_placed_housing_count[type] = have

	var n = (runner.sim.s["residents"] as Array).size()
	if n != _prev_res or _housing_instances.size() != _prev_housing_n:
		_prev_res = n
		_prev_housing_n = _housing_instances.size()
		_assign_homes()
	_refresh_agents()

## 收掉一座建筑的视图：精灵 + 地格占用 + 所有按 shop_id 索引的表。
func _remove_shop_view(sid: String) -> void:
	var spr = _shop_sprites.get(sid, null)
	if spr != null and is_instance_valid(spr):
		spr.queue_free()
	var origin: Vector2i = _shop_cell.get(sid, Vector2i(-1, -1))
	if origin.x >= 0:
		var def_id := String(_shop_def.get(sid, ""))
		var fp := _footprint(def_id)
		var doors: Array = _shop_door.get(sid, [])
		var interior: Vector2i = _shop_goal.get(sid, Vector2i(-1, -1))
		# _free_building_cells 会把 map.occupied 上这几格一起擦掉
		_free_building_cells(origin, fp, doors, interior)
	for d in [_shop_sprites, _shop_cell, _shop_def, _shop_label,
			_shop_anchor, _shop_door, _shop_goal]:
		d.erase(sid)

func _take_site_for(type: String) -> Vector2i:
	var list: Array = _site_by_type.get(type, [])
	if list.is_empty():
		return Vector2i(-1, -1)
	var site = list.pop_front()
	_site_by_type[type] = list
	_sites.erase(site)
	if is_instance_valid(site["node"]):
		site["node"].queue_free()
	return site["cell"]

func _take_sites_for(type: String, n: int) -> Array:
	var out := []
	for i in n:
		var c = _take_site_for(type)
		if c.x < 0:
			break
		out.append(c)
	return out

func _spawn_agents() -> void:
	if not ring_layer.draw.is_connected(_draw_rings):
		ring_layer.draw.connect(_draw_rings)
	_refresh_agents()

func _refresh_agents() -> void:
	var alive := {}
	for r in runner.sim.s["residents"]:
		alive[String(r["id"])] = true
	var kept := []
	for a in _agents:
		var id := String(a["id"])
		if alive.has(id):
			a["home"] = _resident_home.get(id, _town_center_pos)
			kept.append(a)
		elif is_instance_valid(a.get("node", null)):
			# 人没了，把节点一起收掉（否则会留一个不动的"鬼影"站在街上）
			a["node"].queue_free()
	_agents = kept
	var have := {}
	for a in _agents:
		have[a["id"]] = true
	for id in alive.keys():
		if have.has(id):
			continue
		var home = _resident_home.get(id, _town_center_pos)
		var node := Sprite2D.new()
		node.centered = false
		# 标记"这不是建筑"：_reset_buildings() 清 building_layer 时要跳过小人
		# （小人和建筑共用同一个 y 排序容器，见 _ready 里的说明）。
		node.set_meta("keep", true)
		building_layer.add_child(node)
		_agents.append({"id": id, "pos": home, "target": home, "home": home, "node": node})

## 每帧把每具小人节点同步到脚底位置 / 朝向帧 / 是否进屋。
##
## **节点位置 = 脚底**，这不是随便定的：y 排序用的就是节点 y，只有让它等于脚底
## （= 人的"地面线"），人和建筑才能按地面线互相插队 —— 走在两栋互相重叠的房子
## 中间的人才会正确地被前排那栋挡住、同时压住后排那栋。
func _update_agent_nodes() -> void:
	var cls_of := {}
	if runner != null and runner.sim != null:
		for r in runner.sim.s["residents"]:
			cls_of[String(r["id"])] = String(r["classId"])
	var rows := ["S", "N", "W", "E"]
	for a in _agents:
		var node: Sprite2D = a.get("node", null)
		if not is_instance_valid(node):
			continue
		var tex := _actor_texture(String(cls_of.get(String(a["id"]), "poor")))
		node.texture = tex
		node.region_enabled = tex != null
		if tex != null:
			var row := rows.find(String(a.get("dir", "S")))
			if row < 0:
				row = 0
			var frame := int(a.get("anim", 0)) % 4
			node.region_rect = Rect2(frame * TILE, row * TILE, TILE, TILE)
		node.position = a["pos"]
		# 精灵脚底对齐坐标点（和原来 draw_texture_rect_region 的 dst 一致）
		node.offset = Vector2(-TILE * 0.5, 2.0 - TILE)
		# 进屋的人不画 —— 门格与屋内落脚格都在 _walk_inside 里（可通行），
		# 居民会真的走进房子里面停下，照画就会看到一个人站在屋子正中间。
		node.visible = not _agent_inside_building(a)

## 选中小人脚下的椭圆（画在地面层 ring_layer 上，不参与遮挡）。
func _draw_rings() -> void:
	if String(selected_resident) == "":
		return
	for a in _agents:
		if String(a["id"]) != String(selected_resident):
			continue
		# 把圆压扁，比正圆更贴地
		ring_layer.draw_set_transform(a["pos"] + Vector2(0, -1), 0.0, Vector2(1.0, 0.5))
		ring_layer.draw_arc(Vector2.ZERO, 9.0, 0, TAU, 24, Color(1.0, 0.95, 0.2), 1.5)
		ring_layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return

## 人是否在建筑/仓库的占地范围内 —— 也就是"进屋了"。
## 门格与屋内落脚格都在 _walk_inside 里（可通行），所以居民会真的走进房子**里面**
## 停下。如果照画，就会看到一个人站在屋子正中间。进屋的人应该看不见。
func _agent_inside_building(a: Dictionary) -> bool:
	var pos: Vector2 = a["pos"]
	var c := Vector2i(int(floor(pos.x / float(TILE))), int(floor(pos.y / float(TILE))))
	if not map.in_bounds(c):
		return false
	return map.occupied.has(c) or map.town_center.has_point(c)

func _actor_texture(cls: String) -> Texture2D:
	if _actor_tex.has(cls):
		return _actor_tex[cls]
	var tex: Texture2D = load("res://assets/actors/%s.png" % cls)
	if tex == null:
		tex = load("res://assets/actors/poor.png")
	_actor_tex[cls] = tex
	return tex

func _animate_agents(delta: float) -> void:
	# 由位移推朝向与步态（位移 < 阈值算站立）
	for a in _agents:
		var prev: Vector2 = a.get("prev_pos", a["pos"])
		var d: Vector2 = a["pos"] - prev
		a["prev_pos"] = a["pos"]
		if d.length() > 0.2:
			if absf(d.x) > absf(d.y):
				a["dir"] = "E" if d.x > 0.0 else "W"
			else:
				a["dir"] = "S" if d.y > 0.0 else "N"
			var sp := 1.0 if runner == null else maxf(0.2, runner.speed)
			a["anim"] = fmod(float(a.get("anim", 0.0)) + delta * 8.0 * sp, 4.0)
		else:
			a["anim"] = 0.0

# ---- 每帧：移动小人 + 同步建筑 --------------------------------------------
func _process(delta: float) -> void:
	_pan_keyboard(delta)
	_sync()
	if _nav_dirty:
		_nav_timer += delta
		if _nav_timer >= 0.4:
			_refresh_astar()
			_nav_timer = 0.0
	_update_agents(delta)
	_animate_agents(delta)
	_update_agent_nodes()
	_update_cursor()
	_update_labels()
	ring_layer.queue_redraw()
	if not _sites.is_empty():
		site_layer.queue_redraw()
	if debug_footprints:
		debug_layer.queue_redraw()
	elif _has_research_bar:
		site_layer.queue_redraw()

## 建造 / 笔刷模式下换成十字光标
func _update_cursor() -> void:
	var want := Input.CURSOR_ARROW
	if build_mode != "" or brush_mode != "" or move_mode != "":
		want = Input.CURSOR_CROSS
	if _cursor_shape != want:
		_cursor_shape = want
		Input.set_default_cursor_shape(want)

func _pan_keyboard(delta: float) -> void:
	if camera == null:
		return
	# 有输入框在打字时**不要**平移镜头：村名 / 存档名里都可能有 w、a、s、d，
	# 一边打字一边镜头乱飘（`_pan_keyboard` 是每帧轮询按键的，
	# `_unhandled_input` 那套漏到这里就拦不住了，得单独挡一次）。
	if _text_field_focused():
		return
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		camera.position += dir.normalized() * 700.0 * delta / camera.zoom.x

## 焦点是不是落在文本框里（LineEdit / TextEdit）。
##
## 快捷键那边用它来"打字时不抢键"（`main.gd::_shortcut_input`），
## 这里用它来"打字时不平移镜头"。两处都是同一套判断，别各写一份。
func _text_field_focused() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var fo := vp.gui_get_focus_owner()
	return fo is LineEdit or fo is TextEdit

## H：镜头回到城镇中心。
##
## 只挪位置、**不动缩放** —— 缩放是玩家自己调的手感，按一下 H 就跳回默认缩放
## 反而像"把我的视角搞乱了"。
func focus_town_center() -> void:
	if camera == null or map == null:
		return
	var c := map.town_center.get_center()
	camera.position = Vector2(c.x * TILE, c.y * TILE)

func _update_agents(delta: float) -> void:
	if runner == null or runner.sim == null or runner.paused:
		return
	var s = runner.sim.s
	var hour = int(s["hour"])
	var residents := {}
	for r in s["residents"]:
		residents[String(r["id"])] = r
	var budget := 4
	for a in _agents:
		var r = residents.get(a["id"], null)
		var base := _agent_goal_cell(a, r, hour)
		if base != a.get("base_goal", Vector2i(-9999, -9999)):
			a["base_goal"] = base
			a["goal_cell"] = base
			a["need_path"] = true
			a["wander_t"] = 0.0
		var goal_cell: Vector2i = a.get("goal_cell", base)
		if bool(a.get("need_path", false)) and budget > 0:
			budget -= 1
			a["need_path"] = false
			a["path"] = _path_points(_cell_of(a["pos"]), goal_cell)
			a["pi"] = 0
		var path: Array = a.get("path", [])
		if path.is_empty():
			var gp := _cell_center(goal_cell)
			_move_toward(a, gp, delta)
			if a["pos"].distance_to(gp) < 4.0 and hour >= 6 and hour < 18:
				# 到位后过一会儿在附近溜达（不要傻站着）——白天才溜达，夜里在屋里
				a["wander_t"] = float(a.get("wander_t", 0.0)) + delta * runner.speed
				if float(a["wander_t"]) > 2.0:
					a["wander_t"] = 0.0
					var w := _wander_cell(base)
					if w != goal_cell:
						a["goal_cell"] = w
						a["need_path"] = true
		else:
			var pi = int(a.get("pi", 0))
			var wp: Vector2 = path[pi]
			var to = wp - a["pos"]
			var d = to.length()
			if d < 4.0:
				pi += 1
				if pi >= path.size():
					a["path"] = []
					a["pi"] = 0
				else:
					a["pi"] = pi
			else:
				a["pos"] += to / d * minf(d, _agent_speed() * delta)

func _wander_cell(base: Vector2i) -> Vector2i:
	for i in 12:
		var c = base + Vector2i(randi_range(-3, 3), randi_range(-3, 3))
		if _astar != null and _astar.region.has_point(c) and not _blocked(c):
			return c
	return base

func _agent_speed() -> float:
	return 90.0 * (runner.speed if runner != null else 1.0)

func _move_toward(a: Dictionary, target: Vector2, delta: float) -> void:
	var to = target - a["pos"]
	var d = to.length()
	if d > 2.0:
		a["pos"] += to / d * minf(d, _agent_speed() * delta)

func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / TILE)), int(floor(pos.y / TILE)))

func _agent_goal_cell(a: Dictionary, r, hour: int) -> Vector2i:
	if r != null and hour >= 6 and hour < 18:
		var sid = r.get("jobShopId", null)
		if sid != null and _shop_goal.has(sid):
			if (hour % 3) == 0:
				return _town_center_goal
			return _shop_goal[sid]
	return _cell_of(a["home"])

func _blocked(c: Vector2i) -> bool:
	if map.is_water(c):
		return true
	if _walk_inside.has(c):
		return false
	if map.town_center.has_point(c):
		return true
	return map.occupied.has(c)

# 门格：占地底边中间那一格。
#
# ⚠️ 这是**缺省**门格，不再是无条件规则 —— content 的 `art.doors` 可以声明门在
# 哪几格（城镇中心贴图上画的是双开门，门口本来就占两格）。取门一律走
# `_door_cells()`；这个函数只用来算缺省偏移（`_default_door_offset`）。
func _door_cell(cell: Vector2i, fw: int, fh: int) -> Vector2i:
	return cell + _default_door_offset(Vector2i(fw, fh))

## 缺省门洞偏移（相对占地左上角）：底边、横向居中。
## 整数除法，所以宽 4 取第 2 列（0 起）——偏左的那一格，和改动前完全一致。
func _default_door_offset(fp: Vector2i) -> Vector2i:
	return Vector2i(fp.x / 2, fp.y - 1)

## 一栋建筑的**所有**门格（世界坐标），按 `art.doors` 的声明顺序。
##
## 声明式门洞：`art.doors = [[dx, dy], ...]`，偏移相对占地左上角，第一项是主门。
## 不声明就退回缺省（底边居中一格）—— 老内容 / 老存档行为不变。
## 声明非法（越界 / 格式错）时 `push_error` 喊一声再退回缺省：宁可门在缺省位置，
## 也不能让一栋建筑没有门（那等于居民进不了屋、也走不到门口）。
func _door_cells(type: String, cell: Vector2i, fp: Vector2i) -> Array:
	var art := _art_of(type)
	var declared: Variant = art.get("doors", null)
	var out: Array = []
	if declared is Array and not (declared as Array).is_empty():
		var errs := ContentDB.validate_doors(art, fp)
		if errs.is_empty():
			for d in (declared as Array):
				out.append(cell + Vector2i(int(d[0]), int(d[1])))
		else:
			push_error("建筑 %s 的 art.doors 非法：%s" % [type, "；".join(errs)])
	if out.is_empty():
		out.append(cell + _default_door_offset(fp))
	return out

## 登记一栋建筑的门洞：**每个**门格 + 每扇门**正下方**那一格（门前通行格）都写进
## `map.reserved`（语义见 game_map.gd 的声明注释），门格同时可通行（`_walk_inside`）。
## 返回 `[门格数组, 屋内落脚格]`。
func _register_doors(type: String, cell: Vector2i, fp: Vector2i) -> Array:
	var doors := _door_cells(type, cell, fp)
	for d in doors:
		_doors[d] = true
		_walk_inside[d] = true
		map.reserved[d] = true
		map.reserved[d + Vector2i(0, 1)] = true
	var interior := _interior_cell(cell, fp.x, fp.y, doors)
	_walk_inside[interior] = true
	return [doors, interior]

## 每扇门的**门前通行格**：门格正下方那一格（居民从这一格迈进门槛）。
## 它和门格一起进 `map.reserved` —— 门前站不了人，等于门被堵死。
func _door_front_cells(type: String, cell: Vector2i, fp: Vector2i) -> Array:
	var out: Array = []
	for d in _door_cells(type, cell, fp):
		out.append(d + Vector2i(0, 1))
	return out

## 在每扇门前的通行格自动铺一格路。
##
## 只在**玩家放下 / 移动**建筑时调用 —— 目的是给玩家一个"门在这一侧"的视觉提示
## （用户："防止用户不知道门洞"）。工地阶段就铺，玩家一放下就能看见。
## 移走时**不擦**（用户明确要求"可以先不擦除"），所以这里只有写、没有删。
##
## ⚠️ 只动 `map.road`，绝不碰 `map.floor_tiles`：地板是玩家自己花钱铺的，
## 两者是分开的两套位图（路画在地板上面，z_index -6 > -7），互不覆盖。
func _pave_door_front(type: String, cell: Vector2i, fp: Vector2i) -> void:
	for c in _door_front_cells(type, cell, fp):
		if not map.in_bounds(c) or map.is_water(c):
			continue
		# 路面上不能立着树 —— 和 _paint_cell() 的 road 分支同一条处理
		deco_layer.erase_cell(c)
		if map.road[map.idx(c.x, c.y)] != 0:
			continue
		map.road[map.idx(c.x, c.y)] = 1
		_refresh_road(c)
		_nav_dirty = true

# 屋内落脚格：大建筑取中心，小建筑(2×2)取主门格本身。
func _interior_cell(cell: Vector2i, fw: int, fh: int, doors: Array = []) -> Vector2i:
	if fw >= 3 and fh >= 3:
		return Vector2i(cell.x + fw / 2, cell.y + fh / 2)
	if not doors.is_empty():
		return doors[0]
	return _door_cell(cell, fw, fh)

func _anchor_cell(cell: Vector2i, fw: int, fh: int) -> Vector2i:
	var cands := [
		Vector2i(cell.x, cell.y + fh),
		Vector2i(cell.x, cell.y - 1),
		Vector2i(cell.x - 1, cell.y),
		Vector2i(cell.x + fw, cell.y),
	]
	for d in cands:
		if map.in_bounds(d) and not _blocked(d):
			return d
	for ring in range(1, 6):
		for dy in range(-ring, fh + ring + 1):
			for dx in range(-ring, fw + ring + 1):
				var c = cell + Vector2i(dx, dy)
				if map.in_bounds(c) and not _blocked(c):
					return c
	return cell

func _build_astar() -> void:
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(map.center - Vector2i(120, 120), Vector2i(240, 240))
	_astar.cell_size = Vector2(1, 1)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ALWAYS
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	_refresh_astar()

func _refresh_astar() -> void:
	if _astar == null:
		return
	var r = _astar.region
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c = Vector2i(x, y)
			var solid = _blocked(c)
			_astar.set_point_solid(c, solid)
			var w = 1.0 if (not solid and map.road[map.idx(x, y)] == 1) else 2.5
			_astar.set_point_weight_scale(c, w)
	_nav_dirty = false

func _path_points(from_cell: Vector2i, to_cell: Vector2i) -> Array:
	if _astar == null or from_cell == to_cell:
		return []
	if not _astar.region.has_point(from_cell) or not _astar.region.has_point(to_cell):
		return []
	if _astar.is_point_solid(from_cell) or _astar.is_point_solid(to_cell):
		return []
	var ids = _astar.get_id_path(from_cell, to_cell)
	if ids.size() <= 1:
		return []
	var pts := []
	for i in range(1, ids.size()):
		pts.append(_cell_center(Vector2i(int(ids[i].x), int(ids[i].y))))
	return pts

func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)

func _assign_homes() -> void:
	_resident_home.clear()
	for inst in _housing_instances:
		inst["occupants"] = []
	var priv: Dictionary = runner.sim.s["privateHousing"]
	var marked := {}
	for inst in _housing_instances:
		var t = inst["type"]
		var want = int(float(priv.get(t, 0.0)))
		var done = int(marked.get(t, 0))
		inst["private"] = done < want
		marked[t] = done + 1
	if _housing_instances.is_empty():
		for r in runner.sim.s["residents"]:
			_resident_home[String(r["id"])] = _cell_center(_town_center_goal)
		return
	var cursor := 0
	for r in runner.sim.s["residents"]:
		var rid = String(r["id"])
		var placed := false
		for step in _housing_instances.size():
			var k = (cursor + step) % _housing_instances.size()
			var inst = _housing_instances[k]
			if (inst["occupants"] as Array).size() < int(inst["capacity"]):
				inst["occupants"].append(rid)
				_resident_home[rid] = _cell_center(inst["goal"])
				cursor = k
				placed = true
				break
		if not placed:
			_resident_home[rid] = _cell_center(_town_center_goal)

# ---- 交互 -----------------------------------------------------------------
## 鼠标是否落在某个可见 UI 面板的矩形内。
##
## 为什么不用 gui_get_hovered_control()：
##   它依赖 Godot 的悬停状态，而悬停只在鼠标**移动**时更新；headless 下永远是 null，
##   没法写测试。用事件坐标直接做矩形判定则完全确定。
##
## 为什么需要这个守卫：
##   Control 的 mouse_filter = STOP 只挡住它**后面**的控件。像 ScrollContainer
##   只在自己真的滚动了的时候才 accept_event()，滚到顶/底之后事件会漏到
##   _unhandled_input，于是滚统计面板里的列表把外面的地图也缩放了。
func _mouse_over_ui(pos: Vector2) -> bool:
	if ui_root == null:
		return false
	for c in ui_root.get_children():
		if c is Control and (c as Control).visible and (c as Control).get_global_rect().has_point(pos):
			return true
	return false

func _unhandled_input(event: InputEvent) -> void:
	# 悬停在 UI 上时不碰镜头：不吃滚轮、不拖拽平移、不误触地图
	if (event is InputEventMouseButton or event is InputEventMouseMotion) \
			and _mouse_over_ui(event.position):
		if event is InputEventMouseMotion:
			_hide_site_tip()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera.zoom = (camera.zoom * 1.15).clamp(Vector2(0.25, 0.25), Vector2(4, 4))
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera.zoom = (camera.zoom / 1.15).clamp(Vector2(0.25, 0.25), Vector2(4, 4))
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_picking = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_cancel_mode()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_left_down = true
				_left_drag = false
				_press_pos = event.position
				_press_cell = _mouse_cell()
				if brush_mode != "" and build_mode == "":
					_paint_cell(_press_cell)
			else:
				if _left_down and not _left_drag:
					_on_left_click(_press_cell)
				_left_down = false
				_left_drag = false
	elif event is InputEventMouseMotion:
		if _picking:
			camera.position -= event.relative / camera.zoom
		if _left_down:
			if brush_mode != "" and build_mode == "" and move_mode == "":
				_paint_cell(_mouse_cell())
			elif build_mode == "" and move_mode == "" and event.position.distance_to(_press_pos) > 6.0:
				_left_drag = true
				camera.position -= event.relative / camera.zoom
		if build_mode != "" or move_mode != "":
			_update_ghost(_mouse_cell())
		_update_site_tip(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cancel_mode()

func _on_left_click(cell: Vector2i) -> void:
	if move_mode != "":
		var origin = Vector2i(cell.x - 1, cell.y - 1)
		var parts = move_mode.split(":")
		var ok = false
		if parts[0] == "shop":
			ok = move_shop_to(parts[1], origin)
		elif parts[0] == "housing":
			ok = move_housing_to(parts[1], origin)
		if ok:
			_cancel_mode()
		else:
			notice.emit("此处不能放置（资源/占地不符）")
		return
	if build_mode != "":
		_try_place(build_mode, cell)
		return
	if brush_mode != "":
		return
	var occ = map.occupied_at(cell)
	if occ != null:
		selected_resident = ""
		if occ["kind"] == "shop":
			select_building.emit(String(occ["id"]))
		elif occ["kind"] == "housing":
			select_housing.emit(String(occ["id"]))
		return
	var best = _nearest_agent(get_global_mouse_position())
	if best != "":
		selected_resident = best
		select_resident.emit(best)
	else:
		selected_resident = ""
		select_none.emit()

func _nearest_agent(pos: Vector2) -> String:
	# 精灵 16x16、脚底对齐 a["pos"]，所以命中判定以精灵中心为准
	var best := ""
	var best_d = 14.0 / maxf(0.05, camera.zoom.x)
	for a in _agents:
		var center: Vector2 = a["pos"] + Vector2(0, -6)
		var d = center.distance_to(pos)
		if d < best_d:
			best_d = d
			best = a["id"]
	return best

func _mouse_cell() -> Vector2i:
	var p = get_global_mouse_position()
	return Vector2i(int(floor(p.x / TILE)), int(floor(p.y / TILE)))

# ---- 在建工地的悬停提示 ---------------------------------------------------
## 这一格上的工地说明；不是工地就返回 ""（空串 = 不显示）。
##
## 为什么按**类型**去 sim 那边找工程条目，而不是按格子：`build` 动作里不带坐标，
## sim 也不认格子（它只知道"要建什么"），工地占格是表现层自己登记的。
## 所以同类工地共用一份进度 —— 真有多处时在文字里写明有几处，不假装精确。
func site_tip_at(cell: Vector2i) -> String:
	if map == null or runner == null or runner.sim == null:
		return ""
	if not map.in_bounds(cell):
		return ""
	var occ = map.occupied_at(cell)
	if occ == null or String(occ["kind"]) != "site":
		return ""
	var type := String(occ["id"])
	var name_zh := type
	if runner.db.buildings.has(type):
		name_zh = String(runner.db.buildings[type]["nameZh"])
	elif runner.db.housing.has(type):
		name_zh = String(runner.db.housing[type]["nameZh"])

	var list := _construction_entries(type)
	if list.is_empty():
		# 刚放下时队列里还没有它：命令在黎明生效、施工要等入夜结算。
		# 时刻从内容里读（别写死 06:00/18:00 —— 它们是 economy.json 的 time 块）。
		return "%s · 已下单（%02d:00 开工，白天按小时累积）" % [
			name_zh, int(db_time("dawnHour", 6))]
	# 优先报正在施工的那处；都在排队就报排最前的
	var best: Dictionary = list[0]
	for c in list:
		if bool(c.get("started", false)):
			best = c
			break
	var need := float(best.get("totalRequired", 0.0))
	var left := float(best.get("remaining", 0.0))
	var done := maxf(0.0, need - left)
	var pct := 0 if need <= 0.0 else int(roundf(done / need * 100.0))
	var head := "建造中" if bool(best.get("started", false)) else _why_waiting(best)
	var text := "%s · %s\n建造力 %d / %d（%d%%）" % [
		name_zh, head, int(roundf(done)), int(roundf(need)), pct]
	# ⚠️ 光说"等前面的工程"会骗人：**队首自己没开工时也是这句话**。
	# 玩家在"命令次日 06:00 才生效"的窗口里、或游戏暂停着，会以为后面一堆工程
	# 在抢产能，于是得出"12 个建造力一个都用不上"的结论。这里把队首的具体原因写出来。
	if not bool(best.get("started", false)):
		var ahead := _blocked_ahead(best)
		if ahead != "":
			text += "\n%s" % ahead
	if list.size() > 1:
		text += "\n同类工地共 %d 处" % list.size()
	return text

## 读 `content/economy.json` 的 time 块（时刻别在代码里写死）。
func db_time(key: String, fallback: int) -> int:
	var tt: Dictionary = runner.db.economy.get("time", {})
	return int(tt.get(key, fallback))

## 这一条还没开工，到底在等什么 —— 给玩家能动手的答案，而不是"等前面的工程"。
func _why_waiting(c: Dictionary) -> String:
	var pos: int = (runner.sim.s["construction"] as Array).find(c)
	if pos > 0:
		return "排队中（前面还有 %d 处工程）" % pos
	# 排在队首：要么在攒材料，要么就是还没到下一个 06:00
	var sim = runner.sim
	var spec: Dictionary = sim._cost_of(c)
	if spec.is_empty():
		return "等待开工（工程定义缺失）"
	if not sim._can_afford(spec):
		return "等待材料（缺 %s）" % _shortage_zh(spec)
	return "等待开工（下一个工作小时开工，届时扣材料）"

## 前面有没有"卡住"的工程：队首在等材料时，**后面的全都动不了**，
## 但玩家看到的只是一句"等前面的工程"。把那个罪魁祸首与缺口直接写出来。
func _blocked_ahead(c: Dictionary) -> String:
	var sim = runner.sim
	for other in (sim.s["construction"] as Array):
		if other == c:
			return ""
		if bool(other.get("started", false)):
			continue
		var spec: Dictionary = sim._cost_of(other)
		if not spec.is_empty() and not sim._can_afford(spec):
			return "前面「%s」在等材料（缺 %s），它开工前建造力用不上" % [
				_sim_label(other), _shortage_zh(spec)]
		return ""
	return ""

func _sim_label(c: Dictionary) -> String:
	var kind := String(c["kind"])
	if kind == "shop":
		var bid := String(c.get("buildingId", ""))
		return String(runner.db.buildings[bid]["nameZh"]) if runner.db.buildings.has(bid) else bid
	if kind == "housing":
		var hid := String(c.get("housingId", ""))
		return String(runner.db.housing[hid]["nameZh"]) if runner.db.housing.has(hid) else hid
	if kind == "upgrade":
		var up := String(c.get("buildingId", ""))
		var base := String(runner.db.buildings[up]["nameZh"]) if runner.db.buildings.has(up) else up
		return base + " 升级"
	return String(c.get("id", ""))

## 缺哪些材料 —— 说中文名（`_shortage_reason()` 报的是商品 id，玩家看不懂）。
func _shortage_zh(spec: Dictionary) -> String:
	var out := []
	for m in (spec["mats"] as Array):
		var gid := String(m[0])
		var need := float(m[1])
		var have := float(runner.sim.s["goods"].get(gid, 0.0))
		if have < need:
			var nm := gid
			if runner.db.goods.has(gid):
				nm = String(runner.db.goods[gid]["nameZh"])
			out.append("%s %.0f（现有 %.0f）" % [nm, need, have])
	if float(spec.get("money", 0.0)) > float(runner.sim.s["government"]["money"]):
		out.append("资金 %.0f" % float(spec["money"]))
	return "、".join(out) if not out.is_empty() else "材料"

## sim 建造队列里与这个工地类型匹配的条目（shop 按 buildingId，住房按 housingId）。
func _construction_entries(type: String) -> Array:
	var out := []
	for c in (runner.sim.s["construction"] as Array):
		var k := String(c["kind"])
		if k == "shop" and String(c.get("buildingId", "")) == type:
			out.append(c)
		elif k == "housing" and String(c.get("housingId", "")) == type:
			out.append(c)
	return out

func _update_site_tip(screen_pos: Vector2) -> void:
	if _tip == null:
		return
	# 屏幕坐标 → 世界坐标 → 格子：走画布变换，与 `_mouse_cell()` 同一套口径
	var world := get_global_transform_with_canvas().affine_inverse() * screen_pos
	var cell := Vector2i(int(floor(world.x / TILE)), int(floor(world.y / TILE)))
	var text := site_tip_at(cell)
	if text == "":
		_hide_site_tip()
		return
	_tip_label.text = text
	_tip.reset_size()
	# 贴着鼠标、但不盖住指针，也不越出屏幕
	var vp := get_viewport_rect().size
	var pos := screen_pos + Vector2(18, 10)
	pos.x = clampf(pos.x, 4.0, maxf(4.0, vp.x - _tip.size.x - 4.0))
	pos.y = clampf(pos.y, 4.0, maxf(4.0, vp.y - _tip.size.y - 4.0))
	_tip.position = pos
	_tip.visible = true

func _hide_site_tip() -> void:
	if _tip != null and _tip.visible:
		_tip.visible = false

# ---- 工地 / 研究所头顶的进度条 ---------------------------------------------
## 三色一眼看清状态（用户要的"红黄蓝"）：
##   红 = 卡在材料（队首缺料，后面全都动不了）
##   黄 = 排队中（前面还有工程）
##   蓝 = 正在施工（填充比例 = 已投入 / 需要）
##   灰 = 刚下单，还没进队列（命令次日黎明才生效）
const ST_BAR_COLOR := {
	"building": Color(0.30, 0.62, 0.95),
	"queued": Color(0.95, 0.80, 0.25),
	"blocked": Color(0.90, 0.30, 0.25),
	"pending": Color(0.72, 0.72, 0.72),
	# 研究所空闲（队列为空）= 灰：与"刚下单"共用一支，含义都是"这条没有在动"
	"idle": Color(0.72, 0.72, 0.72),
}

func _draw_site_bars() -> void:
	for s in _sites:
		var fp := Vector2i(int(s["fw"]), int(s["fh"]))
		var cell: Vector2i = s["cell"]
		var st := _site_bar_state(String(s["id"]))
		var w := 30.0
		var h := 6.0
		var origin := Vector2(_area_center(cell, fp.x, fp.y).x - w * 0.5,
			float(cell.y) * TILE - 16.0)
		# 底：深色描边，保证在草地/屋顶上都看得清
		site_layer.draw_rect(Rect2(origin + Vector2(-1, -1), Vector2(w + 2, h + 2)),
			Color(0.10, 0.08, 0.07, 0.9))
		var inner := Rect2(origin, Vector2(w, h))
		var col: Color = ST_BAR_COLOR[String(st["state"])]
		var frac := clampf(float(st["frac"]), 0.0, 1.0)
		if frac > 0.0:
			site_layer.draw_rect(Rect2(inner.position, Vector2(inner.size.x * frac, inner.size.y)), col)
		else:
			# 一点都没投入时别只剩一条黑杠：用状态色描个空框
			site_layer.draw_rect(inner, col, false, 1.0)
	_draw_research_bars()

## 研究所头顶的进度条（用户："科研也可以，以后研究所头上也放个进度条"）。
##
## 与工地条**同一层、同一位置口径**（占地顶边往上 16px、底衬深色描边 +2px），
## 所以镜头缩放时会跟着建筑一起放大缩小。两者不会重叠：工地是 `map.occupied`
## 的 `"site"` 格，研究所是**已建成**的商店，同一格不可能既是工地又是商店。
##
## 画的是**当前研究项目**（`research.queue[0]`）的进度
## （`(totalRequired − remaining) / totalRequired`）；队列空 = 一条灰色空框
## （见 `_research_bar_state` 的理由）。
func _draw_research_bars() -> void:
	for sh in _research_shops():
		var sid := String(sh["id"])
		var cell: Vector2i = _shop_cell.get(sid, Vector2i(-1, -1))
		if cell.x < 0:
			continue	# 还没落到地图上（刚建成那一帧）
		var fp := _footprint(String(sh["defId"]))
		var st := _research_bar_state()
		var w := 30.0
		var h := 6.0
		var origin := Vector2(_area_center(cell, fp.x, fp.y).x - w * 0.5,
			float(cell.y) * TILE - 16.0)
		site_layer.draw_rect(Rect2(origin + Vector2(-1, -1), Vector2(w + 2, h + 2)),
			Color(0.10, 0.08, 0.07, 0.9))
		var inner := Rect2(origin, Vector2(w, h))
		var col: Color = ST_BAR_COLOR[String(st["state"])]
		var frac := clampf(float(st["frac"]), 0.0, 1.0)
		if frac > 0.0:
			site_layer.draw_rect(Rect2(inner.position, Vector2(inner.size.x * frac, inner.size.y)), col)
		else:
			site_layer.draw_rect(inner, col, false, 1.0)

## 场上的研究所（`capacity.kind == "research"` 且已启用）。
func _research_shops() -> Array:
	var out := []
	for shop in runner.sim.s["shops"]:
		if not bool(shop.get("active", false)):
			continue
		var def = runner.db.buildings.get(String(shop["defId"]), null)
		if def == null:
			continue
		if runner.sim._capacity_kind(def, "research"):
			out.append(shop)
	return out

## 研究所进度条的两个数：状态 + 填充比例。与工地条同一口径（`_site_bar_state`）。
##
## 颜色（沿用现有 `ST_BAR_COLOR`，不新造颜色）：
##   - **蓝 = 正在研究**（进行中，填充比例 = 已投入 / 需要）—— 与工地"正在施工"同色，
##     一眼就知道"这条在动"
##   - **灰 = 队列空、研究所闲着**。这里**画一条灰色空框而不是干脆不画**：研究所是
##     可交互的经营建筑，玩家点开它就要下单；一条常在的灰框让"这里有座研究所、现在
##     闲着"一眼可辨 —— 不画的话，闲置的研究所和普通房子长得一模一样。
##   - **黄 = 已下单但还没开工**（`!started`，通常是在等材料）。这一条沿用工地那条
##     "黄 = 排队中"的语义，让两条进度条读法一致。
func _research_bar_state() -> Dictionary:
	var sim = runner.sim
	var q: Array = sim.s["research"].get("queue", [])
	if q.is_empty():
		return {"state": "idle", "frac": 0.0}
	var p: Dictionary = q[0]
	if not bool(p.get("started", false)):
		return {"state": "queued", "frac": 0.0}	# 还没开工（在等材料）：黄，与工地一致
	var need := float(p.get("totalRequired", 0.0))
	var done := maxf(0.0, need - float(p.get("remaining", 0.0)))
	return {"state": "building", "frac": (0.0 if need <= 0.0 else done / need)}

## 工地条需要的两个数：状态 + 填充比例。与悬停提示同一套判定口径。
func _site_bar_state(type: String) -> Dictionary:
	var list := _construction_entries(type)
	if list.is_empty():
		return {"state": "pending", "frac": 0.0}
	var best: Dictionary = list[0]
	for c in list:
		if bool(c.get("started", false)):
			best = c
			break
	var need := float(best.get("totalRequired", 0.0))
	var done := maxf(0.0, need - float(best.get("remaining", 0.0)))
	var state := "building"
	if not bool(best.get("started", false)):
		state = _site_queued_state(best)
	return {"state": state, "frac": (0.0 if need <= 0.0 else done / need)}

## 还没开工的那条：材料不够 → 红；否则 → 黄（在等前面的工程）。
func _site_queued_state(c: Dictionary) -> String:
	var sim = runner.sim
	var spec: Dictionary = sim._cost_of(c)
	if not spec.is_empty() and not sim._can_afford(spec):
		return "blocked"
	return "queued"

func _cancel_mode() -> void:
	build_mode = ""
	brush_mode = ""
	move_mode = ""
	ghost.visible = false
	notice.emit("")

func set_build(id: String) -> void:
	build_mode = id
	brush_mode = ""
	if id == "":
		ghost.visible = false
	else:
		ghost.texture = _texture_for(id)
		ghost.visible = true
		notice.emit("点击地图放置：%s（右键取消）" % id)
		# 开始放置就取消选中：否则建筑/居民的对话框杵在屏幕上，正好挡住要放的位置
		select_none.emit()

func set_brush(mode: String, size: int) -> void:
	brush_mode = mode
	brush_size = size
	build_mode = ""
	ghost.visible = false
	notice.emit("笔刷：%s  %dx%d（右键取消）" % [mode, size, size])

## 这一格能不能放下 `id`（空串 = 可以）。
##
## **幽灵图的红/白与真正下单共用这一个判定** —— 分成两套就会出现"看着是白的、
## 点下去却被拒"的错位（用户报过"放不下去要变成红色"）。
## `need_afford = false` 用于**移动已有建筑**：材料早就付过了，只判地形与占地。
func place_reason(id: String, cell: Vector2i, need_afford := true) -> String:
	if runner == null or runner.sim == null or map == null:
		return ""
	var origin = Vector2i(cell.x - 1, cell.y - 1)
	var fp = _footprint(id)
	if need_afford:
		var reason = _can_afford(id)
		if reason != "":
			return reason
	if runner.db.buildings.has(id):
		var terr: Array = []
		var b = runner.db.buildings[id]
		# 注意：必须判空串。content_db 会给每栋建筑都带上 terrain 键（缺省 ""），
		# 用 has() 判断会把 terrains 设成 [""]，结果任何地形都不匹配、全图无法建造。
		var tstr := String(b.get("terrain", ""))
		if tstr != "":
			terr = [tstr]
		if not map.terrain_ok(origin, fp.x, fp.y, terr):
			return "此处不能建造（资源/占地不符）"
		return ""
	if runner.db.housing.has(id):
		if not map.terrain_ok(origin, fp.x, fp.y, []):
			return "此处不能建造住房"
		return ""
	return ""

## 移动模式下这一格能不能放（空串 = 可以）。
##
## ⚠️ 与 `place_reason()` 的关键区别：`move_mode` 里存的是**实例 id**
## （shop 是 sid、住房是 `hut#1` 这种 uid），**不是定义 id** —— 拿它去查
## `db.buildings/housing` 会查不到、于是永远返回"可以放"，幽灵图就不变红
## （用户报过："移动的时候，不能放置的地方没有红色"）。
## 这里复用 `move_shop_to()` / `move_housing_to()` 真正用的 `_move_ok()`。
func move_reason(cell: Vector2i) -> String:
	var parts := move_mode.split(":")
	if parts.size() < 2:
		return ""
	var origin := Vector2i(cell.x - 1, cell.y - 1)
	if parts[0] == "shop":
		var sid := parts[1]
		var def_id := String(_shop_def.get(sid, ""))
		if def_id == "" or not _shop_cell.has(sid):
			return ""
		var fp := _footprint(def_id)
		return "" if _move_ok(def_id, origin, fp, _own_cells(_shop_cell[sid], fp)) else "此处不能放置"
	if parts[0] == "housing":
		var inst = _housing_by_uid.get(parts[1], null)
		if inst == null:
			return ""
		var fp2 := Vector2i(int(inst["fw"]), int(inst["fh"]))
		return "" if _move_ok(String(inst["type"]), origin, fp2,
			_own_cells(inst["cell"], fp2)) else "此处不能放置"
	return ""

func _try_place(id: String, cell: Vector2i) -> bool:
	var origin = Vector2i(cell.x - 1, cell.y - 1)
	var fp = _footprint(id)
	var reason := place_reason(id, cell)
	if reason != "":
		notice.emit(reason)
		return false
	if runner.db.buildings.has(id):
		_register_site("shop", id, origin, fp)
		# 工地阶段就把门口那一格铺上路：玩家一放下就能看见"门在这一侧"
		_pave_door_front(id, origin, fp)
		runner.enqueue([{"type": "build", "buildingId": id}])
		notice.emit("已下单建造 %s（次日 06:00 生效）" % id)
		return true
	elif runner.db.housing.has(id):
		_register_site("housing", id, origin, fp)
		_pave_door_front(id, origin, fp)
		runner.enqueue([{"type": "build_housing", "goodId": id}])
		notice.emit("已下单建造住房 %s（次日 06:00 生效）" % id)
		return true
	return false

func _can_afford(id: String) -> String:
	var sim = runner.sim
	var pack_goods: Array = runner.db.packs[String(sim.s["pack"])]["goods"]
	if runner.db.buildings.has(id):
		var b: Dictionary = runner.db.buildings[id]
		var costs: Dictionary = b.get("buildCost", {})
		var any := false
		for g in costs.keys():
			if pack_goods.has(g):
				any = true
				if sim.available(g) < float(costs[g]):
					return "材料不足（%s）" % g
		if not any:
			var cost = float(runner.db.economy["buildMoneyByTier"][str(int(b["tier"]))])
			if float(sim.s["government"]["money"]) < cost:
				return "资金不足"
	elif runner.db.housing.has(id):
		var hb: Dictionary = runner.db.housing[id]
		for g in (hb.get("buildCost", {}) as Dictionary).keys():
			if sim.available(g) < float(hb["buildCost"][g]):
				return "材料不足（%s）" % g
	return ""

func _register_site(kind: String, type: String, cell: Vector2i, fp: Vector2i) -> void:
	map.occupy(cell, fp.x, fp.y, "site", type)
	_clear_deco(cell, fp.x, fp.y)
	var node := Sprite2D.new()
	node.texture = _texture_for(type)
	node.centered = false
	node.modulate = Color(1, 1, 1, 0.45)
	_place_sprite(node, type, cell, fp)
	building_layer.add_child(node)
	var site = {"kind": kind, "id": type, "cell": cell, "fw": fp.x, "fh": fp.y, "node": node}
	_sites.append(site)
	var list: Array = _site_by_type.get(type, [])
	list.append(site)
	_site_by_type[type] = list
	_nav_dirty = true

func _update_ghost(cell: Vector2i) -> void:
	ghost.position = Vector2((cell.x - 1) * TILE, (cell.y - 1) * TILE)
	# 放不下就染红（用户："如果建房子的时候，建筑放不下去，要变成红色"）。
	# 判定与真正下单共用 `place_reason()`，所以不会"看着能放、点下去被拒"。
	var ok := true
	if move_mode != "":
		# 移动：材料早付过，只判地形/占地 —— 且必须用 `_move_ok()`（它带 own，
		# 自己原来那几格不算占），否则"原地挪一格"会被误判成撞自己。
		ok = move_reason(cell) == ""
	elif build_mode != "":
		ok = place_reason(build_mode, cell) == ""
	if build_mode == "" and move_mode == "":
		ghost.modulate = Color(1, 1, 1, 0.5)
		return
	ghost.modulate = Color(1, 1, 1, 0.5) if ok else Color(1.0, 0.32, 0.28, 0.6)

# ---- 道路 / 地板 ----------------------------------------------------------
func _paint_cell(cell: Vector2i) -> void:
	var size = 1 if brush_mode == "road" else brush_size
	var half = size / 2
	for dy in size:
		for dx in size:
			var c = cell + Vector2i(dx - half, dy - half)
			if not map.in_bounds(c) or map.is_water(c):
				continue
			if brush_mode == "erase":
				# 清除：把这一格的路和地板都抹掉，露出底下的草地。
				# 不补回装饰（树）—— 需求就是"恢复成草地就好了"。
				var changed := false
				if map.road[map.idx(c.x, c.y)] != 0:
					map.road[map.idx(c.x, c.y)] = 0
					road_layer.erase_cell(c)
					changed = true
				if map.floor_tiles[map.idx(c.x, c.y)] != 0:
					map.floor_tiles[map.idx(c.x, c.y)] = 0
					floor_layer.erase_cell(c)
					changed = true
				if changed:
					# 邻居的路面接缝要跟着重算，否则路口会留着残角
					_refresh_road(c)
					_nav_dirty = true
			elif brush_mode == "road":
				map.road[map.idx(c.x, c.y)] = 1
				deco_layer.erase_cell(c)
				_refresh_road(c)
				_nav_dirty = true
			elif brush_mode == "floor":
				if map.floor_tiles[map.idx(c.x, c.y)] == 1:
					continue
				if map.floor_charge <= 0:
					if not runner.sim.spend("stone", 1.0):
						notice.emit("石头不足（只能花未计划的石头）")
						return
					map.floor_charge += 100
				map.floor_charge -= 1
				map.floor_tiles[map.idx(c.x, c.y)] = 1
				deco_layer.erase_cell(c)
				floor_layer.set_cell(c, 1, _extra_cell(52))


# ---- 调试：建筑占地方框（ESC 菜单里的开关）---------------------------------
## 打开后把每座建筑占的格子画成方框：**同一座建筑同色、不同建筑不同色**。
## 用途：让"这块地到底占没占"肉眼可查 —— 来回争论截图不如把它画出来。
func set_debug_footprints(on: bool) -> void:
	debug_footprints = on
	if debug_layer != null:
		debug_layer.visible = on
		if on:
			debug_layer.queue_redraw()

## 由字符串算一个**稳定**的颜色。不能用 randf()：这一层每帧重画，
## 随机色会一直跳，就看不出"这几格属于同一座建筑"了。
func _debug_color(key: String) -> Color:
	var h := 0
	for i in key.length():
		h = (h * 131 + key.unicode_at(i)) % 1000003
	return Color.from_hsv(float(h % 360) / 360.0, 0.8, 0.95, 0.35)

func _draw_footprints() -> void:
	if not debug_footprints or map == null:
		return
	# 已建成建筑：占用表里 kind:id 相同的格子同色
	for c in map.occupied.keys():
		var occ: Dictionary = map.occupied[c]
		var col := _debug_color("%s:%s" % [String(occ.get("kind", "")), String(occ.get("id", ""))])
		var r := Rect2(Vector2(c.x * TILE, c.y * TILE), Vector2(TILE, TILE))
		debug_layer.draw_rect(r, col)
		debug_layer.draw_rect(r, col.lightened(0.55), false, 1.0)
	# 城镇中心：固定建筑，占格单独一张表
	if map.town_center.size.x > 0:
		var tc := _debug_color("fixed:town_center")
		for dy in map.town_center.size.y:
			for dx in map.town_center.size.x:
				var p: Vector2i = map.town_center.position + Vector2i(dx, dy)
				var r2 := Rect2(Vector2(p.x * TILE, p.y * TILE), Vector2(TILE, TILE))
				debug_layer.draw_rect(r2, tc)
				debug_layer.draw_rect(r2, tc.lightened(0.55), false, 1.0)
	# reserved = **门格与门前通行格**（见 game_map 的声明注释），只描橙框不填色 ——
	# 它们看着是空地，却**永久不可建**（否则会把门堵死、居民出不来）。
	# 用户开这个开关就是靠这几格看明白的："懂了，是门洞。"
	for c2 in map.reserved.keys():
		debug_layer.draw_rect(Rect2(Vector2(c2.x * TILE, c2.y * TILE), Vector2(TILE, TILE)),
			Color(1.0, 0.45, 0.15, 0.95), false, 2.0)
