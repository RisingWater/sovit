extends Node2D

# 世界视图：地形(TileMapLayer) + 仓库 + 建筑/施工点 + 小人 + 相机 + 交互。
# 只读仿真；建造/派人等命令交给 SimRunner（次日生效）。

signal select_building(shop_id: String)
signal select_housing(uid: String)
signal select_resident(resident_id: String)
signal select_none()
signal notice(text: String)

const TILE := 48

var runner: SimRunner
var map: GameMap

var terrain_layer: TileMapLayer
var floor_layer: TileMapLayer
var road_layer: TileMapLayer
var building_layer: Node2D
var agent_layer: Node2D
var camera: Camera2D
var ghost: Sprite2D

var _left_down := false
var _left_drag := false
var _press_pos := Vector2.ZERO
var _press_cell := Vector2i.ZERO

var _tex_cache := {}
var _shop_sprites := {}         # shop_id -> Node2D
var _shop_cell := {}            # shop_id -> Vector2i(origin)
var _housing_instances := []    # [{uid, type, cell, fw, fh, sprite, capacity, private, occupants}]
var _housing_by_uid := {}
var _sites := []                # [{kind, id, cell, fw, fh, node}]  待建
var _site_by_type := {}         # defId/housingType -> [site index...]
var _placed_housing_count := {} # type -> count already bound
var _prev_res := -1
var _prev_housing_n := -1

var build_mode := ""
var brush_mode := ""            # "", "road", "floor"
var brush_size := 1

var _agents := []               # [{id, pos:Vector2, target:Vector2, home:Vector2, work:Vector2}]
var _resident_home := {}        # id -> Vector2
var _picking := false
var _paint := false
var _warehouse_pos := Vector2.ZERO
var selected_resident := ""

func setup(r: SimRunner, seed_value: int) -> void:
	runner = r
	map = GameMap.new()
	map.generate(seed_value)

func _ready() -> void:
	_build_tileset()
	_build_warehouse()
	_camera_setup()
	_initial_housing()
	_sync()
	_assign_homes()
	_spawn_agents()

func _build_tileset() -> void:
	var tex: Texture2D = load("res://assets/tiles.svg")
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = Vector2i(TILE, TILE)
	for i in 7:
		src.create_tile(Vector2i(i, 0))
	ts.add_source(src, 0)

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

	building_layer = Node2D.new()
	add_child(building_layer)
	agent_layer = Node2D.new()
	agent_layer.z_index = 5
	add_child(agent_layer)

	# 铺地形（只铺一次）
	for y in GameMap.H:
		for x in GameMap.W:
			terrain_layer.set_cell(Vector2i(x, y), 0, Vector2i(map.terrain[map.idx(x, y)], 0))

func _build_warehouse() -> void:
	var spr := Sprite2D.new()
	spr.texture = load("res://assets/warehouse.svg")
	spr.centered = false
	spr.position = Vector2(map.warehouse.position.x * TILE, map.warehouse.position.y * TILE)
	building_layer.add_child(spr)
	_warehouse_pos = Vector2(map.warehouse.get_center().x * TILE, map.warehouse.get_center().y * TILE)

func _camera_setup() -> void:
	camera = Camera2D.new()
	camera.position = Vector2(map.center.x * TILE, map.center.y * TILE)
	camera.zoom = Vector2(1.0, 1.0)
	add_child(camera)
	camera.make_current()

	ghost = Sprite2D.new()
	ghost.centered = false
	ghost.modulate = Color(1, 1, 1, 0.5)
	ghost.visible = false
	ghost.z_index = 20
	add_child(ghost)

func _initial_housing() -> void:
	var housing: Dictionary = runner.sim.s["housing"]
	for type in housing.keys():
		var n = int(float(housing[type]))
		for i in n:
			var cell = _find_free_area(type, map.center, true)
			if cell.x >= 0:
				_place_housing_instance(type, cell)

func _find_free_area(type: String, near: Vector2i, spiral: bool) -> Vector2i:
	var fp = _footprint(type)
	var base = map.warehouse.position + Vector2i(-14, 8)
	for ring in range(0, 80):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if ring > 0 and abs(dx) != ring and abs(dy) != ring:
					continue
				var c = base + Vector2i(dx, dy)
				if map.terrain_ok(c, fp.x, fp.y, []):
					return c
	return Vector2i(-1, -1)

func _footprint(type: String) -> Vector2i:
	if runner.db.housing.has(type):
		return Vector2i(3, 3) if int(runner.db.housing[type]["quality"]) >= 3 else Vector2i(2, 2)
	if runner.db.buildings.has(type):
		return Vector2i(3, 3) if int(runner.db.buildings[type]["tier"]) == 3 else Vector2i(2, 2)
	return Vector2i(2, 2)

func _texture_for(type: String) -> Texture2D:
	if _tex_cache.has(type):
		return _tex_cache[type]
	var tex: Texture2D = load("res://assets/buildings/%s.svg" % type)
	_tex_cache[type] = tex
	return tex

func _place_housing_instance(type: String, cell: Vector2i) -> void:
	var fp = _footprint(type)
	var uid = "%s#%d" % [type, _housing_instances.size() + 1]
	map.occupy(cell, fp.x, fp.y, "housing", uid)
	var spr := Sprite2D.new()
	spr.texture = _texture_for(type)
	spr.centered = false
	spr.position = Vector2(cell.x * TILE, cell.y * TILE)
	building_layer.add_child(spr)
	var cap = 4
	if runner.db.housing.has(type):
		cap = int(runner.db.housing[type]["capacity"])
	var inst = {"uid": uid, "id": type, "type": type, "cell": cell, "fw": fp.x, "fh": fp.y, "sprite": spr, "capacity": cap, "private": false, "occupants": []}
	_housing_instances.append(inst)
	_housing_by_uid[uid] = inst

func housing_instance(uid: String) -> Variant:
	return _housing_by_uid.get(uid, null)

# ---- 同步仿真里的建筑 -----------------------------------------------------
func _sync() -> void:
	# 新店铺（含开局为空）→ 绑定到预留工地或找空地
	for shop in runner.sim.s["shops"]:
		var sid = String(shop["id"])
		if _shop_sprites.has(sid):
			continue
		var def_id = String(shop["defId"])
		var cell = _take_site_for(def_id)
		if cell.x < 0:
			cell = _find_free_area(def_id, map.center, true)
		if cell.x < 0:
			continue
		var fp = _footprint(def_id)
		map.occupy(cell, fp.x, fp.y, "shop", sid)
		var spr := Sprite2D.new()
		spr.texture = _texture_for(def_id)
		spr.centered = false
		spr.position = Vector2(cell.x * TILE, cell.y * TILE)
		building_layer.add_child(spr)
		_shop_sprites[sid] = spr
		_shop_cell[sid] = cell

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
			var cell = _find_free_area(type, map.center, true)
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
	if not agent_layer.draw.is_connected(_draw_agents):
		agent_layer.draw.connect(_draw_agents)
	_refresh_agents()

func _refresh_agents() -> void:
	var alive := {}
	for r in runner.sim.s["residents"]:
		alive[String(r["id"])] = true
	var kept := []
	for a in _agents:
		if alive.has(a["id"]):
			a["home"] = _resident_home.get(a["id"], _warehouse_pos)
			kept.append(a)
	_agents = kept
	var have := {}
	for a in _agents:
		have[a["id"]] = true
	for id in alive.keys():
		if not have.has(id):
			var home = _resident_home.get(id, _warehouse_pos)
			_agents.append({"id": id, "pos": home, "target": home, "home": home})

func _draw_agents() -> void:
	for a in _agents:
		var r := 8.0
		if a["id"] == selected_resident:
			agent_layer.draw_arc(a["pos"], r + 4.0, 0, TAU, 24, Color(1.0, 0.95, 0.2), 2.5)
		agent_layer.draw_circle(a["pos"], r, Color(0.95, 0.85, 0.55))
		agent_layer.draw_arc(a["pos"], r, 0, TAU, 20, Color(0.2, 0.15, 0.1), 1.5)
		agent_layer.draw_circle(a["pos"], r * 0.38, Color(0.35, 0.25, 0.15))

# ---- 每帧：移动小人 + 同步建筑 --------------------------------------------
func _process(delta: float) -> void:
	_pan_keyboard(delta)
	_sync()
	_update_agents(delta)
	agent_layer.queue_redraw()

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
	if runner == null or runner.sim == null:
		return
	var s = runner.sim.s
	var hour = int(s["hour"])
	var residents := {}
	for r in s["residents"]:
		residents[String(r["id"])] = r
	var home_by_type := {}
	for inst in _housing_instances:
		home_by_type[inst["type"]] = inst["cell"]
	for a in _agents:
		var r = residents.get(a["id"], null)
		var target: Vector2 = a["home"]
		if r != null and hour >= 6 and hour < 18:
			var sid = r.get("jobShopId", null)
			if sid != null and _shop_cell.has(sid):
				target = _cell_center(_shop_cell[sid])
				if (hour % 3) == 0:
					target = _warehouse_pos
		elif r != null and (hour >= 18 or hour < 6):
			target = a["home"]
		a["target"] = target
		var to = target - a["pos"]
		var dist = to.length()
		if dist > 2.0:
			a["pos"] += to / dist * minf(dist, 90.0 * delta)

func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE, cell.y * TILE + TILE)

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
			_resident_home[String(r["id"])] = _warehouse_pos
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
				_resident_home[rid] = _cell_center(inst["cell"])
				cursor = k
				placed = true
				break
		if not placed:
			_resident_home[rid] = _warehouse_pos

# ---- 交互 -----------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
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
			if brush_mode != "" and build_mode == "":
				_paint_cell(_mouse_cell())
			elif build_mode == "" and event.position.distance_to(_press_pos) > 6.0:
				_left_drag = true
				camera.position -= event.relative / camera.zoom
		if build_mode != "":
			_update_ghost(_mouse_cell())
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cancel_mode()

func _on_left_click(cell: Vector2i) -> void:
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
	var best := ""
	var best_d = 30.0 / maxf(0.05, camera.zoom.x)
	for a in _agents:
		var d = a["pos"].distance_to(pos)
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

func _try_place(id: String, cell: Vector2i) -> void:
	var origin = Vector2i(cell.x - 1, cell.y - 1)
	var fp = _footprint(id)
	var reason = _can_afford(id)
	if reason != "":
		notice.emit(reason)
		return
	if runner.db.buildings.has(id):
		var terr: Array = []
		var b = runner.db.buildings[id]
		if b.has("terrain"):
			terr = [String(b["terrain"])]
		if not map.terrain_ok(origin, fp.x, fp.y, terr):
			notice.emit("此处不能建造（资源/占地不符）")
			return
		_register_site("shop", id, origin, fp)
		runner.enqueue([{"type": "build", "buildingId": id}])
		notice.emit("已下单建造 %s（次日 06:00 生效）" % id)
	elif runner.db.housing.has(id):
		if not map.terrain_ok(origin, fp.x, fp.y, []):
			notice.emit("此处不能建造住房")
			return
		_register_site("housing", id, origin, fp)
		runner.enqueue([{"type": "build_housing", "goodId": id}])
		notice.emit("已下单建造住房 %s（次日 06:00 生效）" % id)

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
	var node := Sprite2D.new()
	node.texture = _texture_for(type)
	node.centered = false
	node.modulate = Color(1, 1, 1, 0.45)
	node.position = Vector2(cell.x * TILE, cell.y * TILE)
	building_layer.add_child(node)
	var site = {"kind": kind, "id": type, "cell": cell, "fw": fp.x, "fh": fp.y, "node": node}
	_sites.append(site)
	var list: Array = _site_by_type.get(type, [])
	list.append(site)
	_site_by_type[type] = list

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
			if brush_mode == "road":
				map.road[map.idx(c.x, c.y)] = 1
				road_layer.set_cell(c, 0, Vector2i(5, 0))
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
				floor_layer.set_cell(c, 0, Vector2i(6, 0))
