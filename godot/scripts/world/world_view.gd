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
var _shop_door := {}            # shop_id -> Vector2i（门格，可通行）
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
	spr.texture = load("res://assets/buildings/_warehouse.png")
	spr.centered = false
	# 和普通建筑同一条规则：横向居中、底边对齐，节点位置 = 地面线（供 y 排序）。
	# 仓库原生 128x62，占地 8x3 -> 贴图比占地高 14px，往上伸出去。
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
	_town_center_door = _door_cell(map.town_center.position, fp.x, fp.y)
	_doors[_town_center_door] = true
	_town_center_goal = _interior_cell(map.town_center.position, fp.x, fp.y)
	_walk_inside[_town_center_door] = true
	_walk_inside[_town_center_goal] = true
	map.reserved[_town_center_door] = true
	map.reserved[_town_center_door + Vector2i(0, 1)] = true

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
	var base = map.town_center.position + Vector2i(-14, 8)
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
			return Vector2i(int(ceil(tex.get_width() / float(TILE))),
				int(ceil(tex.get_height() / float(TILE))))
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
	var dcell = _door_cell(cell, fp.x, fp.y)
	_doors[dcell] = true
	var icell = _interior_cell(cell, fp.x, fp.y)
	_walk_inside[dcell] = true
	_walk_inside[icell] = true
	map.reserved[dcell] = true
	map.reserved[dcell + Vector2i(0, 1)] = true
	var inst = {"uid": uid, "id": type, "type": type, "cell": cell, "fw": fp.x, "fh": fp.y, "sprite": spr, "capacity": cap, "private": false, "occupants": [], "anchor": _anchor_cell(cell, fp.x, fp.y), "door": dcell, "goal": icell}
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
	var d = _door_cell(cell, fp.x, fp.y)
	_doors[d] = true
	_shop_door[sid] = d
	var ic = _interior_cell(cell, fp.x, fp.y)
	_walk_inside[d] = true
	_walk_inside[ic] = true
	_shop_goal[sid] = ic
	map.reserved[d] = true
	map.reserved[d + Vector2i(0, 1)] = true
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
	for g in (s["goods"] as Dictionary).keys():
		s["goods"][g] = 20000.0

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
	if not _shop_cell.has(sid):
		return
	move_mode = "shop:" + sid
	build_mode = ""
	brush_mode = ""
	ghost.texture = _texture_for(String(_shop_def.get(sid, "")))
	ghost.visible = true
	notice.emit("点击新位置移动建筑（右键取消）")

func begin_move_housing(uid: String) -> void:
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

func _free_building_cells(cell: Vector2i, fp: Vector2i, door: Vector2i, interior: Vector2i) -> void:
	for dy in fp.y:
		for dx in fp.x:
			map.occupied.erase(cell + Vector2i(dx, dy))
	_doors.erase(door)
	_walk_inside.erase(door)
	_walk_inside.erase(interior)
	map.reserved.erase(door)
	map.reserved.erase(door + Vector2i(0, 1))

func _occupy_building(kind: String, id: String, cell: Vector2i, fp: Vector2i) -> Array:
	map.occupy(cell, fp.x, fp.y, kind, id)
	_clear_deco(cell, fp.x, fp.y)
	var door = _door_cell(cell, fp.x, fp.y)
	var interior = _interior_cell(cell, fp.x, fp.y)
	_doors[door] = true
	_walk_inside[door] = true
	_walk_inside[interior] = true
	map.reserved[door] = true
	map.reserved[door + Vector2i(0, 1)] = true
	return [door, interior]

func move_shop_to(sid: String, origin: Vector2i) -> bool:
	var def_id = String(_shop_def.get(sid, ""))
	if def_id == "" or not _shop_cell.has(sid) or not _shop_sprites.has(sid):
		return false
	var fp = _footprint(def_id)
	var old = _shop_cell[sid]
	if not _move_ok(def_id, origin, fp, _own_cells(old, fp)):
		return false
	_free_building_cells(old, fp, _shop_door.get(sid, old), _shop_goal.get(sid, old))
	_restore_deco(old, fp.x, fp.y)     # 旧址还原成自然地（该长树的把树补回来）
	if _shop_label.has(sid) and is_instance_valid(_shop_label[sid]):
		_shop_label[sid].queue_free()
	_shop_label.erase(sid)
	var spr = _shop_sprites[sid]
	_place_sprite(spr, def_id, origin, fp)
	_shop_label[sid] = _add_label(String(runner.db.buildings[def_id]["nameZh"]), origin, fp.x, fp.y)
	var d = _occupy_building("shop", sid, origin, fp)
	_shop_cell[sid] = origin
	_shop_door[sid] = d[0]
	_shop_goal[sid] = d[1]
	_shop_anchor[sid] = _anchor_cell(origin, fp.x, fp.y)
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
	var d = _occupy_building("housing", uid, origin, fp)
	inst["door"] = d[0]
	inst["goal"] = d[1]
	inst["anchor"] = _anchor_cell(origin, fp.x, fp.y)
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
		var cell = _take_site_for(def_id)
		if cell.x < 0:
			cell = _find_free_area(def_id, map.center, 0)
		if cell.x < 0:
			continue
		_create_shop_view(nid, def_id, cell)

## 收掉一座建筑的视图：精灵 + 地格占用 + 所有按 shop_id 索引的表。
func _remove_shop_view(sid: String) -> void:
	var spr = _shop_sprites.get(sid, null)
	if spr != null and is_instance_valid(spr):
		spr.queue_free()
	var origin: Vector2i = _shop_cell.get(sid, Vector2i(-1, -1))
	if origin.x >= 0:
		var def_id := String(_shop_def.get(sid, ""))
		var fp := _footprint(def_id)
		var door: Vector2i = _shop_door.get(sid, Vector2i(-1, -1))
		var interior := _interior_cell(origin, fp.x, fp.y)
		# _free_building_cells 会把 map.occupied 上这几格一起擦掉
		_free_building_cells(origin, fp, door, interior)
		_walk_inside.erase(_shop_goal.get(sid, Vector2i(-1, -1)))
	for d in [_shop_sprites, _shop_cell, _shop_def, _shop_label,
			_shop_anchor, _shop_door, _shop_goal]:
		d.erase(sid)

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
func _door_cell(cell: Vector2i, fw: int, fh: int) -> Vector2i:
	return Vector2i(cell.x + fw / 2, cell.y + fh - 1)

# 屋内落脚格：大建筑取中心，小建筑(2×2)取门格本身。
func _interior_cell(cell: Vector2i, fw: int, fh: int) -> Vector2i:
	if fw >= 3 and fh >= 3:
		return Vector2i(cell.x + fw / 2, cell.y + fh / 2)
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

func set_brush(mode: String, size: int) -> void:
	brush_mode = mode
	brush_size = size
	build_mode = ""
	ghost.visible = false
	notice.emit("笔刷：%s  %dx%d（右键取消）" % [mode, size, size])

func _try_place(id: String, cell: Vector2i) -> bool:
	var origin = Vector2i(cell.x - 1, cell.y - 1)
	var fp = _footprint(id)
	var reason = _can_afford(id)
	if reason != "":
		notice.emit(reason)
		return false
	if runner.db.buildings.has(id):
		var terr: Array = []
		var b = runner.db.buildings[id]
		# 注意：必须判空串。content_db 会给每栋建筑都带上 terrain 键（缺省 ""），
		# 用 has() 判断会把 terrains 设成 [""]，结果任何地形都不匹配、全图无法建造。
		var tstr := String(b.get("terrain", ""))
		if tstr != "":
			terr = [tstr]
		if not map.terrain_ok(origin, fp.x, fp.y, terr):
			notice.emit("此处不能建造（资源/占地不符）")
			return false
		_register_site("shop", id, origin, fp)
		runner.enqueue([{"type": "build", "buildingId": id}])
		notice.emit("已下单建造 %s（次日 06:00 生效）" % id)
		return true
	elif runner.db.housing.has(id):
		if not map.terrain_ok(origin, fp.x, fp.y, []):
			notice.emit("此处不能建造住房")
			return false
		_register_site("housing", id, origin, fp)
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
