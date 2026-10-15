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

func _init() -> void:	call_deferred("_run")

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
	#
	# ⚠️ 但**截科技树时不能全开** —— 全开之后 29 张卡片全变"已完成"，
	#    就看不出"可研究 / 需先研究"这些状态了。所以 tech* 模式跳过这一步。
	var is_tech_shot: bool = mode.begins_with("tech")
	if not is_tech_shot and runner.sim != null and runner.db != null:
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
		# 间距要按**新建筑素材**的占地算：v3 整图最宽 145px(10 格)、最高 160px(10 格)，
		# 原来 12x9 的间距会让剧院这种 10x10 的放不下、也会互相叠。
		var cell := c + Vector2i((i % 4) * 20 - 30, (i / 4) * 16 - 16)
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

	# 门洞验收：开「建筑占地」调试开关 + 镜头怼到城镇中心，并在它下面摆一排建筑。
	#
	# 一张图里同时看得到三件事：
	#   · 城镇中心的**两格门洞**（占地上两格，门前两格 —— 橙色描边 = map.reserved）；
	#   · 每座建筑的**门格**（彩色占格里的那一格）；
	#   · 门前那一格**自动铺的路**（放下就在了，不用等建成）。
	#
	# 开一局全新的：默认地图没有一格路，"门前那格是这次铺的"才看得出来。
	if mode == "doors":
		world.start_new_game(20261014, 20.0, "门洞")
		if runner.sim != null and runner.db != null:
			var all3: Array = []
			for t in runner.db.tech_ids:
				all3.append(String(t))
			runner.sim.s["research"]["done"] = all3          # 建筑有科技锁
			runner.sim.s["government"]["populationCap"] = 999.0
		await process_frame
		var tc: Rect2i = world.map.town_center
		# 一排无地形要求的建筑（有 terrain 的会把脚下的地刷成别的地形，画面变花）
		var row := ["coarse_bakery", "coarse_weaver", "common_clothes_shop"]
		var ox := tc.position.x - 6
		var oy := tc.end.y + 3                                  # 城镇中心占地底边往下 3 格
		for k in row.size():
			var id: String = row[k]
			var fp2: Vector2i = world._footprint(id)
			var origin3 := Vector2i(ox, oy)
			if not world._try_place(id, origin3 + Vector2i.ONE):
				print("SCREENSHOT doors: 放不下 ", id, " @ ", origin3,
					" 钱=", world._can_afford(id), " 原因=", world.place_reason(id, origin3 + Vector2i.ONE))
			ox += fp2.x + 1
		# 住房也放一间（hut 是另一条入口：_place_housing_instance）
		var hfp: Vector2i = world._footprint("hut")
		if not world._try_place("hut", Vector2i(ox, oy) + Vector2i.ONE):
			print("SCREENSHOT doors: 放不下 hut @ ", Vector2i(ox, oy))
		world.set_debug_footprints(true)                        # 彩色占地格 + 橙框（门洞预留格）
		world.camera.zoom = Vector2(3.0, 3.0)
		world.camera.position = Vector2(world.map.center.x * world.TILE,
			(oy - 1) * world.TILE)
		print("SCREENSHOT doors: 城镇中心门洞=", world._door_cells("town_center", tc.position,
			Vector2i(tc.size.x, tc.size.y)), " 门前=", world._door_front_cells("town_center",
			tc.position, Vector2i(tc.size.x, tc.size.y)))

	# 仓库换成成品整图（用户："这个缩略图不对，我记得我有一个仓库的建筑图片"）：
	# 开一局新的 → 在城镇中心下面摆两座仓库 → 镜头怼过去。
	# 配合第 3 个参数（建造栏 Tab）用：「工业」是 4，一张图里同时看到卡面与世界里的样子。
	if mode == "wh":
		world.start_new_game(20261014, 20.0, "仓库")
		if runner.sim != null and runner.db != null:
			var all4: Array = []
			for t in runner.db.tech_ids:
				all4.append(String(t))
			runner.sim.s["research"]["done"] = all4
			runner.sim.s["government"]["populationCap"] = 999.0
		await process_frame
		var tc2: Rect2i = world.map.town_center
		var wh_fp: Vector2i = world._footprint("warehouse")
		var wh_cells: Array = []
		for k in 2:
			var origin4 := Vector2i(tc2.position.x - 14 + k * (wh_fp.x + 2), tc2.end.y + 3)
			if world._try_place("warehouse", origin4 + Vector2i.ONE):
				wh_cells.append(origin4)
			else:
				print("SCREENSHOT wh: 放不下 warehouse @ ", origin4,
					" 钱=", world._can_afford("warehouse"),
					" 原因=", world.place_reason("warehouse", origin4 + Vector2i.ONE))
		# 让工地立刻变"建成"：走真实入口（往 sim 里加 shop 记录，`_sync` 会把
		# 对应的工地收成成品视图）—— 和 door_test 用的是同一条路，
		# 不用在这儿等 6 天建造力。
		var idx := 0
		for origin5 in wh_cells:
			idx += 1
			(runner.sim.s["shops"] as Array).append({
				"id": "warehouse#%d" % idx, "defId": "warehouse", "owner": "state",
				"targetWorkers": 2, "wage": float(runner.db.economy["refWage"]),
				"wageCap": float(runner.db.economy["defaultWageCap"]),
				"level": int(runner.db.defaults["newShop"]["level"]),
				"active": true, "profit": 0.0,
				"skill": float(runner.db.defaults["newShop"]["skill"]),
				"planned": 0.0,
			})
		await process_frame
		await process_frame
		world.camera.zoom = Vector2(3.0, 3.0)
		world.camera.position = Vector2((tc2.position.x + wh_fp.x) * world.TILE,
			(tc2.end.y + 4) * world.TILE)
		print("SCREENSHOT wh: warehouse foot=", wh_fp, " 贴图=",
			world._texture_for("warehouse").get_size(), " 建成 ", idx, " 座")

	# 验证资源设置弹窗
	if mode == "picker":
		var hud = node.get_node_or_null("UI/Root/HUD")
		if hud != null:
			hud._open_picker()
			await process_frame

	# 验证存档 / 读档对话框（自绘，不是 Godot 的 FileDialog）
	if mode == "savedlg" or mode == "loaddlg":
		var dlg = node.get_node_or_null("DialogLayer/SaveDialog")
		if dlg != null:
			if mode == "savedlg":
				dlg.open_save(runner, world)
			else:
				dlg.open_load(runner, world)
			await process_frame
			await process_frame

	# 验证新游戏对话框（难度是三格像素按钮，不是 OptionButton）
	if mode == "newgame":
		var ng = node.get_node_or_null("UI/Root/NewGame")
		if ng != null:
			ng.open()
			await process_frame
			await process_frame

	# 在建工地的悬停提示：真开一局（失业人口就是建造力）→ 放一座 → 跑一天 → 显示提示
	if mode == "sitetip":
		world.start_new_game(20261014, 1.0, "提示")
		if runner.sim != null and runner.db != null:
			var all2: Array = []
			for t in runner.db.tech_ids:
				all2.append(String(t))
			runner.sim.s["research"]["done"] = all2
			runner.sim.s["government"]["populationCap"] = 999.0
		await process_frame
		var bid := "theater"   # 工期 48：跑一天是"施工中 25/48"，比刚好完工的更能说明问题
		var fp: Vector2i = world._footprint(bid)
		var site_cell := Vector2i(-1, -1)
		for dy in range(0, 24):
			for dx in range(0, 36):
				var cand: Vector2i = world.map.town_center.position + Vector2i(10 + dx, -6 + dy)
				if world.map.in_bounds(cand + fp) and world._area_free(cand, fp):
					site_cell = cand
					break
			if site_cell.x >= 0:
				break
		if site_cell.x >= 0 and world._try_place(bid, site_cell):
			# 跑满一天：它就会在施工中，提示上能看到"已投入 / 需要"
			for h in 24:
				runner.sim.tick_hour([])
			await process_frame
			var probe := Vector2i(site_cell.x - 1 + fp.x / 2, site_cell.y - 1 + fp.y / 2)
			var scr: Vector2 = world.get_global_transform_with_canvas() * world._cell_center(probe)
			world._update_site_tip(scr)
			await process_frame
			await process_frame

	# 验证全屏面板：统计（资源/人口/财务）与科技 —— 顶栏保留、地图与建造栏被盖住
	if mode == "stats" or mode == "stats_people" or mode == "stats_finance" or mode == "tech":
		var s_panel = node.get_node_or_null("UI/Root/Stats")
		var t_panel = node.get_node_or_null("UI/Root/Tech")
		if mode.begins_with("stats") and s_panel != null:
			var tab := 0
			if mode == "stats_people":
				tab = 1
			elif mode == "stats_finance":
				tab = 2
			s_panel.open_tab(tab)
			await process_frame
			await process_frame
		elif mode == "tech" and t_panel != null:
			t_panel.open()
			await process_frame
			await process_frame

	# 仓储超限（2026-10 用户报的 bug）：开局资源 x2 = 1960，城镇中心上限 2000。
	# 再往里塞一批木材让它爆仓，跑满一天 → 夜里按**同一比例**削减，公告页出现那条 log。
	#
	# 这张图同时是"削减规则已生效"的证据：旧规则按 baseValue 升序丢，
	# 粗面包 / 蔬菜会被丢光（接着饿死人），新规则下它们只按比例缩水。
	if mode == "overflow":
		world.start_new_game(20261014, 2.0, "爆仓")
		if runner.sim != null and runner.db != null:
			runner.sim.s["government"]["populationCap"] = 999.0
			(runner.sim.s["goods"] as Dictionary)["wood"] = 1200.0
		# 日志要自己并进 runner.recent_logs（面板读的是它，不是 sim.s["log"]）——
		# 这里直接 tick 仿真，绕过了 SimRunner._process 里那段搬运代码。
		for h in 24:
			for e2 in runner.sim.tick_hour([]):
				runner.recent_logs.append(e2)
		if runner.recent_logs.size() > 60:
			runner.recent_logs = runner.recent_logs.slice(runner.recent_logs.size() - 60)
		await process_frame
		var sim_o = runner.sim
		var target_o := ""
		for sh in sim_o.s["shops"]:
			if String(sh["defId"]) == "town_center":
				target_o = String(sh["id"])
		if target_o != "" and node.has_method("_on_select_building"):
			node._on_select_building(target_o)
			await process_frame
			var dlg_o = node.get_node_or_null("UI/Root/Civic")
			if dlg_o != null:
				dlg_o._select_tab(2)
		print("SCREENSHOT overflow: 容量=", sim_o.storage_capacity(), " 总量=", sim_o.stored_total(),
			" 木头=", float((sim_o.s["goods"] as Dictionary).get("wood", 0.0)),
			" 面包=", float((sim_o.s["goods"] as Dictionary).get("coarse_bread", 0.0)))
		for e3 in runner.recent_logs:
			print("    ", String(e3.get("text", "")))
		await process_frame
		await process_frame

	# 验证浮动对话框：城镇中心（人口）/ 仓库（资源 + 上限）/ 普通建筑（运营）
	# 走 main 的真实分派路径，保证截到的就是玩家点出来的那个东西
	if mode.begins_with("towncenter") or mode == "warehouse" or mode == "building":
		var sim = runner.sim
		var target := ""
		if mode.begins_with("towncenter"):
			for sh in sim.s["shops"]:
				if String(sh["defId"]) == "town_center":
					target = String(sh["id"])
		elif mode == "warehouse":
			# 新开局没有仓库 → 现场塞一座（只为截图，不写存档）
			(sim.s["shops"] as Array).append({
				"id": "warehouse#shot", "defId": "warehouse", "owner": "state",
				"targetWorkers": 1, "wage": 3.0, "wageCap": 6.0, "level": 1,
				"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
			})
			# 顺便填两个上限，让"数量 / 上限"两列都看得出效果
			(runner.sim.s["government"] as Dictionary)["storageCaps"] = {"wood": 150, "coarse_bread": 200}
			target = "warehouse#shot"
		else:
			(sim.s["shops"] as Array).append({
				"id": "lumberjack#shot", "defId": "lumberjack", "owner": "state",
				"targetWorkers": 3, "wage": 3.0, "wageCap": 6.0, "level": 2,
				"active": true, "profit": 12.5, "skill": 60.0, "planned": 0.6,
			})
			target = "lumberjack#shot"
		if target != "" and node.has_method("_on_select_building"):
			node._on_select_building(target)
			await process_frame
			# `towncenter2` / `towncenter3` = 打开后切到第 2 / 3 个页签（资源 / 公告）
			if mode.begins_with("towncenter") and mode.length() > 10:
				var dlg = node.get_node_or_null("UI/Root/Civic")
				var tab := int(mode.substr(10, 1)) - 1
				if dlg != null and tab > 0:
					dlg._select_tab(tab)
			await process_frame
			await process_frame

	# 验证居民 / 住房的浮动对话框（走世界层的真实信号）
	if mode == "resident" or mode == "housing":
		var ins2 = node.get_node_or_null("UI/Root/Inspector")
		var sim2 = runner.sim
		if ins2 != null and mode == "resident" and (sim2.s["residents"] as Array).size() > 0:
			ins2.show_resident(String((sim2.s["residents"] as Array)[0]["id"]))
			await process_frame
			await process_frame
		elif ins2 != null and mode == "housing":
			var insts: Array = world._housing_instances
			if insts.size() > 0:
				ins2.show_housing(String(insts[0]["uid"]))
				await process_frame
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

	# 顶栏资源 chip 的 tooltip：合成一个鼠标移动事件悬停到第一条 chip 上，
	# 等过 tooltip 延迟再截图（headless 下没法真悬停，只能这样验证 tip 弹不弹）
	if mode == "tip":
		var hud2 = node.get_node_or_null("UI/Root/HUD")
		if hud2 != null:
			var chips: Dictionary = hud2.get("_chip_nodes")
			if not chips.is_empty():
				var chip: Control = chips.values()[0]
				var gp := chip.get_global_rect().get_center()
				# 先把指针挪开、再挪上去 —— Godot 只在"鼠标**移入**"时起 tooltip 计时，
				# 直接原地发一个 motion 事件有时不触发（实测时灵时不灵）。
				for pos in [Vector2(4, 4), gp]:
					var ev := InputEventMouseMotion.new()
					ev.position = pos
					ev.global_position = pos
					Input.parse_input_event(ev)
					await create_timer(0.15).timeout
				await create_timer(1.5).timeout
				print("SCREENSHOT tip hover at ", gp, " tip=", chip.tooltip_text.replace("\n", " / "))

	# 建筑检视面板（用工拖动条 + 拆除按钮）
	#
	# 特意把等级抬到 3：研究所 maxWorkers=6、slotsPerLevel=3，
	# L3 时拖动条上限应是 12 —— 一眼就能看出"上限用的是有效工位而不是 maxWorkers"。
	if mode == "shop" or mode == "shopdlg":
		var ins2 = node.get_node_or_null("UI/Root/Inspector")
		if ins2 != null and runner.sim.s["shops"].size() > 0:
			var pick = null
			for sh in runner.sim.s["shops"]:
				var dd = runner.db.buildings.get(String(sh["defId"]), null)
				if dd != null and dd.has("capacity") and float(dd["capacity"]["slotsPerLevel"]) > 0.0:
					pick = sh
					break
			if pick == null:
				pick = runner.sim.s["shops"][0]
			if int(pick["level"]) < 3:
				pick["level"] = 3
			ins2.show_building(String(pick["id"]))
			await process_frame
			if mode == "shopdlg":
				ins2._demolish()
				await process_frame
			print("SCREENSHOT inspector -> ", pick["defId"], " Lv", pick["level"])

	# 科技面板（科技树）。
	#
	# ⚠️ 面板现在**本身就是全屏**的（顶栏以下全铺满），所以这里**不再**手工设
	#    position/size —— 原来那几行会把面板挪到 (20,16)、尺寸 1520x856，
	#    结果截图里底部建造栏从面板下沿露出来，看着像"没盖住"。
	# 只保留"把画布向下平移一段"这条（让一张图里看得到树的上下两端）。
	# 第 3 个参数是画布的 y 平移量（传正数 = 向下看多少像素），例如 `tech 0` / `tech 520`
	if mode == "tech" or mode == "techtip":
		var tp = node.get_node_or_null("UI/Root/Tech")
		if tp != null:
			tp.open()
			for _k in 3:
				await process_frame
			var vs: Vector2 = tp._view.size
			var cs: Vector2 = tp._canvas_size
			var py := 0.0
			if args.size() > 2:
				# 传正数 = 向下滚多少像素。
				# ⚠️ 不能直接传 "-520"：Godot 会把以 `-` 开头的参数当成引擎开关吃掉
				#    （踩过：截图看起来"平移没生效"）。
				py = -absf(float(String(args[2])))
			# 横向居中；纵向夹在可平移范围内（全屏视口很大时整棵树装得下 → 停在 0）
			tp._pan = Vector2(maxf(0.0, (vs.x - cs.x) * 0.5),
				clampf(py, minf(0.0, vs.y - cs.y), 0.0))
			tp._canvas.position = tp._pan
			for _k2 in 2:
				await process_frame
			print("SCREENSHOT tech view=", vs, " canvas=", cs, " pan=", tp._pan)
			# techtip：把某个科技的 tooltip 直接摆出来。
			# headless 下没法真悬停，而 tooltip 的内容（尤其是**带图标的解锁项**）
			# 只能靠眼看，所以这里直接调 build_tooltip 摆到画面上。
			if mode == "techtip":
				var tid := "carpentry"
				if args.size() > 3:
					tid = String(args[3])
				var tip: Control = tp.build_tooltip(tid)
				tip.position = Vector2(200, 220)
				node.get_node("UI/Root").add_child(tip)
				for _k3 in 2:
					await process_frame
				print("SCREENSHOT techtip for ", tid)

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
