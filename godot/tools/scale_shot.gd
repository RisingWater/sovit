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
	if args.size() > 2 and args[2] != "":
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
	# 地图正中央压着固定的"仓库"（GameMap.warehouse，4x3），落在那儿的会建造失败；
	# 所以失败就横向/纵向挪几格重试，而不是直接算失败。
	const NUDGES := [Vector2i(0, 0), Vector2i(0, -7), Vector2i(0, 7),
		Vector2i(-7, 0), Vector2i(7, 0), Vector2i(0, -14), Vector2i(0, 14)]
	for i in sized.size():
		var e: Dictionary = sized[i]
		var base: Vector2i = c + Vector2i(
			(i % cols) * gap_x - (cols * gap_x) / 2,
			int(i / cols) * gap_y - (int(ceil(float(sized.size()) / cols)) * gap_y) / 2)
		var cell: Vector2i = base
		var ok := false
		var why := ""
		for nudge in NUDGES:
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
	_log("place done %d/%d failed=%s" % [placed, sized.size(), str(failed)])

	# 结算：把工地直接变成已完工。_sync() 会把 site 绑成正式建筑精灵，
	# 所以这里只改仿真状态，再让 _sync() 去消费 world._sites。
	var shops: Array = runner.sim.s["shops"]
	var housing: Dictionary = runner.sim.s["housing"]
	var n := 0
	for site in world._sites:
		var type := String(site["id"])
		if String(site["kind"]) == "housing":
			housing[type] = float(housing.get(type, 0.0)) + 1.0
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

	# 镜头对准摆放区域中心
	var ui = node.get_node_or_null("UI")
	if ui != null:
		ui.visible = false
	if world.camera != null:
		var sum := Vector2.ZERO
		for cell in cells:
			sum += Vector2(cell)
		if not cells.is_empty():
			var mid: Vector2 = sum / float(cells.size())
			world.camera.position = mid * float(world.TILE)
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
	quit(0 if err == OK else 1)

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
