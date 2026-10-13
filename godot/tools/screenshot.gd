extends SceneTree

# 截图工具：实例化主场景 → 摆一批建筑 → 跑若干天 → 保存 viewport PNG。
#
# 用法（需要窗口，不能用 --headless）：
#   godot --path godot -s res://tools/screenshot.gd -- <输出文件绝对路径> [模式]
#
# 模式：
#   full   （默认）地图 + 全部 UI 面板
#   map    只截地图（隐藏 UI），用于看美术
#
# 例：godot --path godot -s res://tools/screenshot.gd -- D:/tmp/shot.png map

const PLACE_IDS: Array[String] = [
	"wheat_farm", "vegetable_farm", "coarse_mill", "coarse_bakery",
	"coarse_weaver", "fine_weaver", "common_clothes_shop", "luxury_clothes_shop",
	"domestic_service", "construction_works", "smokehouse", "theater",
]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := "user://shot.png"
	if args.size() > 0:
		out_path = args[0]
	var mode := "full"
	if args.size() > 1:
		mode = args[1]

	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		push_error("SCREENSHOT: 无法加载 main.tscn")
		quit(1)
		return
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	var runner = node.get("runner")
	var world = node.get("world")
	if runner == null or world == null:
		push_error("SCREENSHOT: main 未创建 runner/world")
		quit(1)
		return

	# 标题页会盖住整个游戏 UI 并接管镜头 —— 不关掉的话截出来的永远是标题页。
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	# 建筑现在带科技锁，不先解锁的话 _try_place 全部会被拒（截图里空空如也）。
	# 这里只为截图把科技全开，不改引擎。
	if runner.sim != null and runner.db != null:
		var all: Array = []
		for t in runner.db.tech_ids:
			all.append(String(t))
		runner.sim.s["research"]["done"] = all
		# 人口上限放开，免得截图里没人
		runner.sim.s["government"]["populationCap"] = 999.0

	# 摆一批建筑，覆盖各种外形（农业 / 工坊 / 矿场 / 剧院 / 大工坊）
	# 间距要按新占地算：农田 6x6、大工坊 5x3，所以用 12x9 的网格
	var c: Vector2i = world.map.center
	if world.camera != null:
		world.camera.zoom = Vector2(2.0, 2.0)
	# 可选：第 4 个参数指定镜头缩放，用来验证"标签字号不随缩放变化"
	if args.size() > 3 and world.camera != null:
		var z := float(args[3])
		if z > 0.1:
			world.camera.zoom = Vector2(z, z)
	var i := 0
	for id in PLACE_IDS:
		var cell := c + Vector2i((i % 4) * 12 - 22, (i / 4) * 9 - 10)
		# 开发用：把"需地形"的建筑脚下刷成所需地形，保证截图能摆齐
		var need := ""
		if world.runner.db.buildings.has(id):
			need = String(world.runner.db.buildings[id].get("terrain", ""))
		if need != "":
			var code: int = {"forest": 1, "stone": 2, "clay": 3}.get(need, 0)
			var fp0 = world._footprint(id)
			var org = cell - Vector2i(1, 1)
			for dy in fp0.y + 2:
				for dx in fp0.x + 2:
					var cc = org + Vector2i(dx, dy)
					if world.map.in_bounds(cc):
						world.map.terrain[world.map.idx(cc.x, cc.y)] = code
		var ok = world._try_place(id, cell)
		if not ok:
			print("SCREENSHOT place FAIL ", id, " @ ", cell, " fp=", world._footprint(id),
				" 钱=", world._can_afford(id))
		i += 1

	# 跑 3 天：施工完工、小人上岗走动
	for h in 72:
		runner.sim.tick_hour([])
		await process_frame

	if mode == "map":
		var ui = node.get_node_or_null("UI")
		if ui != null:
			ui.visible = false

	# 验证笔刷：画一条路（含拐弯）+ 一块地板，看是否正确贴图而不是树
	if mode == "paint":
		world.camera.zoom = Vector2(3.0, 3.0)
		world.set_brush("road", 1)
		for x in range(14):
			world._paint_cell(c + Vector2i(x - 7, 5))
		for y in range(6):
			world._paint_cell(c + Vector2i(7, 5 + y))
		world.set_brush("floor", 3)
		for dy in 3:
			for dx in 6:
				world._paint_cell(c + Vector2i(dx - 8, 7 + dy))
		world._cancel_mode()

	# 验证资源设置弹窗
	if mode == "picker":
		var hud = node.get_node_or_null("UI/Root/HUD")
		if hud != null:
			hud._open_picker()
			await process_frame

	# 昼夜：模式 h<N> 表示推进到第 N 小时再截图（验证光影）
	if mode.begins_with("h") and mode.substr(1).is_valid_int():
		var target := int(mode.substr(1)) % 24
		var guard := 0
		while int(runner.sim.s["hour"]) != target and guard < 24 * 4:
			runner.sim.tick_hour([])
			guard += 1
		# 停在整点：把小时内进度清零，颜色才是该时刻的定格
		runner._accum = 0.0
		await process_frame
		print("SCREENSHOT hour -> ", target)

	# ESC 菜单
	if mode == "esc":
		var em = node.get_node_or_null("UI/Root/EscMenu")
		if em != null:
			em.open()
		await process_frame

	# 新游戏对话框
	if mode == "newgame":
		var ng = node.get_node_or_null("UI/Root/NewGame")
		if ng != null:
			ng.open()
		await process_frame

	# 统计面板：stats0 资源 / stats1 人口 / stats2 财务
	if mode.begins_with("stats"):
		# 多跑几天让曲线有内容
		for h in 24 * 24:
			runner.sim.tick_hour([])
			await process_frame
		var panel = node.get_node_or_null("UI/Root/Stats")
		if panel != null:
			panel.open()
			await process_frame
			panel._select_tab(int(mode.substr(5)) if mode.length() > 5 else 0)
			await process_frame
			print("SCREENSHOT stats tab -> ", mode)

	# 科技面板
	if mode == "tech":
		var tp = node.get_node_or_null("UI/Root/Tech")
		if tp != null:
			tp.open()
			await process_frame
			print("SCREENSHOT tech panel opened")

	# 可选：切到指定建造 Tab（0=住宅 1=农业 2=矿场 3=工业 4=娱乐 5=其它）
	if args.size() > 2:
		var bar = node.get_node_or_null("UI/Root/BuildBar")
		if bar != null:
			bar._select_tab(int(args[2]))
			await process_frame
			print("SCREENSHOT tab -> ", args[2])

	# 等渲染稳定
	for f in 8:
		await process_frame
	await RenderingServer.frame_post_draw

	var img: Image = root.get_texture().get_image()
	if img == null:
		push_error("SCREENSHOT: 拿不到 viewport 图像")
		quit(1)
		return
	var err := img.save_png(out_path)
	print("SCREENSHOT ", mode, " -> ", out_path, " err=", err, " size=", img.get_width(), "x", img.get_height())
	quit(0 if err == OK else 1)
