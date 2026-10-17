extends SceneTree

# 开发用：把建筑按实际尺寸规则摆到地图上截图，核对
#   * 显示尺寸（层数是否递增、同层是否齐平、占地几格）
#   * 底部是否站在地面上、彼此有没有重叠
#
# 用法（在 godot/ 下，**不能加 --headless**：headless 下没有渲染，
# `await RenderingServer.frame_post_draw` 永远不返回，进程会挂住）：
#   <godot> --path . -s res://tools/scale_shot.gd -- user://scale.png [zoom] [ids]
#
#   zoom  镜头缩放，默认 1.0（要看清细节用 2.0，看全局用 0.5）
#   ids   逗号分隔的建筑 id；给了就只摆这些，顺序按给定的来
#         例：research_institute,lumberjack,hunting_camp,brick_house,theater
#
# 为什么不用 screenshot.gd：
#   * 它只摆固定的 12 座，且靠 tick_hour 等施工 —— 建造力不够时大部分建筑
#     还停在半透明"工地"状态，看不出最终尺寸；
#   * 这里直接把订单结算成已完工（把 site 交给 _sync() 去绑定），
#     默认还按显示高度排序摆放，尺寸顺序一眼可见。

const SEED := 20261014
const GAP_X := 13
const GAP_Y := 13
const LOG_PATH := "user://scale_progress.log"

var _log_first := true

## 带 flush 的进度日志：headless / 重定向时 stdout 是块缓冲的，卡住就看不到 print。
func _log(msg: String) -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE if _log_first else FileAccess.READ_WRITE)
	_log_first = false
	f.seek_end()
	f.store_line(msg)
	f.flush()
	f.close()

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := "user://scale.png"
	if args.size() > 0:
		out_path = args[0]
	var zoom := 1.0
	if args.size() > 1 and args[1].is_valid_float():
		zoom = float(args[1])
	var only: Array = []
	# 传 "all"（或空）表示摆全部建筑。不能用空字符串占位：PowerShell 的
	# Start-Process -ArgumentList 遇到空元素直接报参数校验失败。
	if args.size() > 2 and args[2] != "" and args[2] != "all":
		only = args[2].split(",", false)
	# 可选：每行几座 / 网格间距（格）。间距小于贴图高度就能看到"前排压后排"的遮挡。
	var cols_arg := 0
	if args.size() > 3 and args[3].is_valid_int():
		cols_arg = int(args[3])
	var gap_x := GAP_X
	var gap_y := GAP_Y
	if args.size() > 4 and args[4].is_valid_int():
		gap_x = int(args[4])
		gap_y = gap_x
	# 第 6 个参数给 "roads" = 井字形街区模式（铺街 + 建筑各占一个地块、门朝街）
	var want_roads := args.size() > 5 and args[5] == "roads"

	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		push_error("SCALE: 无法加载 main.tscn")
		quit(1)
		return
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	var runner = node.get("runner")
	var world = node.get("world")
	if runner == null or world == null:
		push_error("SCALE: main 未创建 runner/world")
		quit(1)
		return
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	world.start_new_game(SEED, 1.0, "尺寸核对")

	# 科技全开 + 放开人口上限，否则带科技锁的建筑会被建造栏拒掉
	var all: Array = []
	for t in runner.db.tech_ids:
		all.append(String(t))
	runner.sim.s["research"]["done"] = all
	runner.sim.s["government"]["populationCap"] = 999.0
	for gid in runner.sim.s["goods"].keys():
		runner.sim.s["goods"][gid] = 9999.0
	runner.sim.s["government"]["money"] = 999999.0
	# 正午，免得截出夜景
	runner.sim.s["hour"] = 12
	_log("start_new_game ok")

	# 清单：默认 v0.3 全部建筑 + 全部住房，按"实际贴图高度"排序（同高再按宽度）。
	# 排序是为了让"层数 -> 高度"的关系在同一张图里直接看出来。
	var ids: Array = []
	if only.is_empty():
		ids.append_array(runner.db.packs["v0.3"]["buildings"])
		ids.append_array(runner.db.packs["v0.3"]["housing"])
	else:
		ids = only
	var sized := []
	for id in ids:
		var tex: Texture2D = world._texture_for(String(id))
		if tex == null:
			push_error("SCALE: 没有贴图 " + String(id))
			continue
		sized.append({"id": String(id), "w": tex.get_width(), "h": tex.get_height()})
	if only.is_empty():
		sized.sort_custom(func(a, b):
			if a["h"] != b["h"]:
				return a["h"] < b["h"]
			return a["w"] < b["w"])
	_log("sized %d" % sized.size())

	# 摆放：紧凑网格（间距要容下最大占地 10x10 的剧院）
	var cols := cols_arg if cols_arg > 0 else int(ceil(sqrt(float(sized.size()))))
	var c: Vector2i = world.map.center
	var placed := 0
	var failed := []
	var cells := []
	# 井字形街区：先铺横竖两条街把地切成方块地块，再把建筑放进地块里、**底边贴着
	# 下面那条街**（门就朝着街）。这样看到的是"真村子"的排布，而不是一堆建筑悬在草地上。
	var grid_rect := Rect2i()
	if want_roads:
		var slot := 12          # 地块边长（最大占地是剧院的 10x10）
		var street := 2         # 街宽
		var pitch := slot + street
		var rows_n := int(ceil(float(sized.size()) / float(cols)))
		var gw := cols * pitch + street
		var gh := rows_n * pitch + street
		var g0 := c - Vector2i(gw / 2, gh / 2)
		grid_rect = Rect2i(g0, Vector2i(gw, gh))
		# 先把整块网格的地形清成草地、抹掉装饰：不清的话每个地块都是一片森林，
		# 建筑埋在林子里根本看不清（地块内部本来就不该长树）。
		for y in gh:
			for x in gw:
				var cc := g0 + Vector2i(x, y)
				if world.map.in_bounds(cc):
					world.map.terrain[world.map.idx(cc.x, cc.y)] = GameMap.GRASS
					world.deco_layer.erase_cell(cc)
		for i in range(rows_n + 1):          # 横向街道
			var y0 := g0.y + i * pitch
			for t in street:
				for x in gw:
					_paint_road(world, Vector2i(g0.x + x, y0 + t))
		for j in range(cols + 1):            # 纵向街道
			var x0 := g0.x + j * pitch
			for t in street:
				for y in gh:
					_paint_road(world, Vector2i(x0 + t, g0.y + y))
		world._rerender_terrain()
		_log("grid %dx%d at %s" % [gw, gh, str(g0)])
	# 地图正中央压着固定的城镇中心，落在那儿的会建造失败；所以失败就挪几格重试。
	const NUDGES := [Vector2i(0, 0), Vector2i(0, -7), Vector2i(0, 7),
		Vector2i(-7, 0), Vector2i(7, 0), Vector2i(0, -14), Vector2i(0, 14)]
	for i in sized.size():
		var e: Dictionary = sized[i]
		var base: Vector2i
		if want_roads:
			# 放进地块：横向居中、纵向贴底（底边 = 地块底边，门朝下面那条街）
			var slot := 12
			var street := 2
			var pitch := slot + street
			var fp: Vector2i = world._footprint(e["id"])
			var so := grid_rect.position + Vector2i(
				(i % cols) * pitch + street + (slot - fp.x) / 2,
				(int(i / cols)) * pitch + street + slot - fp.y)
			base = so + Vector2i(1, 1)   # _try_place 收的是"中心格"，内部会 -(1,1)
		else:
			base = c + Vector2i(
				(i % cols) * gap_x - (cols * gap_x) / 2,
				int(i / cols) * gap_y - (int(ceil(float(sized.size()) / cols)) * gap_y) / 2)
		var cell: Vector2i = base
		var ok := false
		var why := ""
		var tries: Array = [Vector2i(0, 0)] if want_roads else NUDGES
		if want_roads:
			tries = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 1)]
		for nudge in tries:
			cell = base + nudge
			_paint_terrain(world, runner.db, e["id"], cell)
			if world._try_place(e["id"], cell):
				ok = true
				break
			why = world._can_afford(e["id"])
		cells.append(cell)
		if ok:
			placed += 1
		else:
			failed.append("%s@%s %s" % [e["id"], cell, why])
		i += 1
	# 需地形的建筑刚给脚下刷过地形，重画一次让它显出来（顺手重建标签）
	if want_roads:
		world._rerender_terrain()
	_log("place done %d/%d failed=%s" % [placed, sized.size(), str(failed)])

	# 结算：把工地直接变成已完工。_sync() 会把 site 绑成正式建筑精灵，
	# 所以这里只改仿真状态，再让 _sync() 去消费 world._sites。
	var shops: Array = runner.sim.s["shops"]
	var housing: Dictionary = runner.sim.s["housing"]
	var n := 0
	for site in world._sites:
		var type := String(site["id"])
		if String(site["kind"]) == "housing":
			runner.sim._add_housing_unit(type)
			continue
		n += 1
		shops.append({
			"id": "%s#%d" % [type, n], "defId": type, "owner": "state",
			"targetWorkers": int(runner.db.buildings[type]["workers"]),
			"wage": float(runner.db.economy["refWage"]),
			"wageCap": float(runner.db.economy["defaultWageCap"]),
			"level": 1, "active": true, "profit": 0.0, "skill": 50.0,
			"planned": 0.0, "toolBoost": 1.0,
		})
	runner.sim.s["pending"] = []
	runner.sim.s["construction"] = []
	_log("settle done shops=%d" % shops.size())

	for f in 10:
		await process_frame
	_log("frames done, sprites=%d" % world._shop_sprites.size())

	# 镜头对准摆放区域中心；zoom 传 0 表示自动裁到刚好装下整个街区
	var ui = node.get_node_or_null("UI")
	if ui != null:
		ui.visible = false
	if want_roads and zoom <= 0.0 and grid_rect.size.x > 0:
		var vp: Vector2 = root.get_visible_rect().size
		zoom = minf(vp.x / float(grid_rect.size.x * 16), vp.y / float(grid_rect.size.y * 16)) * 0.96
		_log("auto zoom %.3f for %s" % [zoom, str(grid_rect.size)])
	if world.camera != null:
		if want_roads and grid_rect.size.x > 0:
			world.camera.position = Vector2(grid_rect.get_center()) * float(world.TILE)
		else:
			var sum := Vector2.ZERO
			for cell in cells:
				sum += Vector2(cell)
			if not cells.is_empty():
				world.camera.position = (sum / float(cells.size())) * float(world.TILE)
		world.camera.zoom = Vector2(zoom, zoom)
	_log("camera ok")

	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	_log("frame_post_draw ok")

	var img: Image = root.get_texture().get_image()
	if img == null:
		push_error("SCALE: 拿不到 viewport 图像")
		quit(1)
		return
	var err := img.save_png(out_path)
	print("SCALE ", placed, "/", sized.size(), " failed=", failed)
	print("SCALE -> ", out_path, " err=", err, " size=", img.get_width(), "x", img.get_height())

	# 街区模式再多出一张**不带文字标签**的：一张用来认建筑，一张用来看纯粹的
	# 尺寸/遮挡/贴图（标签是屏幕空间 12px 字，在缩小的全景图里会糊住建筑）。
	if want_roads and world.label_layer != null:
		world.label_layer.visible = false
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img2: Image = root.get_texture().get_image()
		if img2 != null:
			var p2 := out_path.get_basename() + "_clean.png"
			print("SCALE clean -> ", p2, " err=", img2.save_png(p2))
	quit(0 if err == OK else 1)

## 铺一格街。（真正的贴图由 _rerender_terrain() 里的 _road_index 自动选）
func _paint_road(world, c: Vector2i) -> void:
	if world.map.in_bounds(c):
		world.map.road[world.map.idx(c.x, c.y)] = 1

## 需地形的建筑（伐木场/采石场/粘土坑）脚下刷成所需地形，否则根本下不了单。
## 只改 map.terrain 数组 —— `terrain_ok` 读的就是它；不重绘地形图，
## 那会重建整张 512x512 的 TileMap，慢到像卡死。
func _paint_terrain(world, db: ContentDB, id: String, cell: Vector2i) -> void:
	var need := ""
	if db.buildings.has(id):
		need = String(db.buildings[id].get("terrain", ""))
	if need == "":
		return
	var code: int = {"forest": 1, "stone": 2, "clay": 3}.get(need, 0)
	var fp: Vector2i = world._footprint(id)
	var org := cell - Vector2i(1, 1)
	for dy in fp.y + 2:
		for dx in fp.x + 2:
			var cc := org + Vector2i(dx, dy)
			if world.map.in_bounds(cc):
				world.map.terrain[world.map.idx(cc.x, cc.y)] = code
