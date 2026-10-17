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

	# 开场剧情（见 scripts/ui/intro.gd）：intro = 第 1 幕，intro2..intro5 = 对应那一幕。
	# 走的是**真入口** `main._begin_intro()`（开新局时才会走那条），再 `jump_to_act()` 跳幕。
	# 这个模式自己出图就退（和 `title` 一样）—— 后面那些"摆建筑/跑天数"会让画面变掉。
	if mode.begins_with("intro"):
		if node.has_method("_begin_intro"):
			# 先收起标题页（真实流程里点「开始游戏」的时候就已经收了），
			# 否则截出来背景是标题页的 logo + 菜单
			if node.has_method("_end_title"):
				node._end_title()
				await process_frame
			node._begin_intro()
			await process_frame
			var act := 0
			if mode.length() > 5:
				act = maxi(0, int(mode.substr(5)) - 1)
			var intro = node.get("_intro")
			if intro != null:
				intro.jump_to_act(act)
			for f in 8:
				await process_frame
			await RenderingServer.frame_post_draw
			var iimg: Image = root.get_texture().get_image()
			if iimg != null:
				iimg.save_png(out_path)
			print("SCREENSHOT intro act=", act + 1, " -> ", out_path)
		quit(0)
		return

	# 左侧圆钮列的"中间插进来一个按钮"：科技（第 4 个）在预言（第 6 个）之后才出现。
	# 拍两张：`<out>`（第一章收尾后、还没有研究所 = 5 个）与 `<out>-tech.png`（+研究所 = 6 个）。
	if mode == "nav":
		if node.has_method("_end_title"):
			node._end_title()
			await process_frame
		var hud_n = node.get_node_or_null("UI/Root/HUD")
		var sim_n = runner.sim
		for t in sim_n.quest_talks_pending():
			sim_n.quest_talk_mark_shown(String((t as Dictionary)["key"]))
		sim_n.s["quests"]["chapters"]["1"] = int(sim_n.s["day"])
		hud_n.refresh_nav_buttons()
		# 只留圆钮列：面板/建造栏/追踪条全收掉，看的就是那条竖列
		# ⚠️ 圆钮列挂在 HUD 的**父节点**上（不是 HUD 的子节点），所以按名字放行
		var rootc: Node = node.get_node_or_null("UI/Root")
		for c in rootc.get_children():
			if not (c is CanvasItem):
				continue
			if String(c.name) in ["HUD", "NavCol"]:
				continue
			(c as CanvasItem).visible = false
		for _f in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var nimg: Image = root.get_texture().get_image()
		if nimg != null:
			nimg.save_png(out_path)
		# 加一座研究所 → 科技圆钮插到**中间**
		var dn: Dictionary = runner.db.buildings["research_institute"]
		(sim_n.s["shops"] as Array).append({
			"id": "inst#shot", "defId": "research_institute", "owner": "state",
			"targetWorkers": int(dn["workers"]), "wage": 5.0, "wageCap": 30.0,
			"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		})
		hud_n.refresh_nav_buttons()
		for _f in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var nimg2: Image = root.get_texture().get_image()
		if nimg2 != null:
			nimg2.save_png(out_path.replace(".png", "-tech.png"))
		print("SCREENSHOT nav -> ", out_path, " / -tech.png")
		quit(0)
		return

	# 剧情对话（任务触发 / 章节收尾，见 scripts/ui/quest_talk.gd）：
	#   questtalk  = 任务一出现时，发布人讲这条任务（塞巴斯蒂安 / 粗面包链）
	#   questoutro = 第一章全绿的收尾（瑟拉菲娜登场，最后一页带两个选项）
	# 走的是**真入口**：引擎给 `quest_talks_pending()`，`main._poll_quest_talks()` 播。
	# 这个模式自己出图就退 —— 后面那些"摆建筑/跑天数"会把画面变掉。
	if mode == "questtalk" or mode == "questoutro":
		if node.has_method("_end_title"):
			node._end_title()
			await process_frame
		var sim_q = runner.sim
		# 别的对话先记成"播过"，只留我们要拍的那一条
		if mode == "questoutro":
			# 第一章全绿：四条都建成 → 过一次黎明结算（章节奖励 + 收尾对话）
			for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
				var dq: Dictionary = runner.db.buildings[bid]
				(sim_q.s["shops"] as Array).append({
					"id": "%s#shot" % bid, "defId": bid, "owner": "state",
					"targetWorkers": int(dq["workers"]), "wage": 5.0, "wageCap": 30.0,
					"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
				})
			sim_q._run_dawn()
			for t in sim_q.quest_talks_pending():
				if String((t as Dictionary)["kind"]) == "quest":
					sim_q.quest_talk_mark_shown(String((t as Dictionary)["key"]))
		# 播第一条（main 那条真路径：暂停 + 播）
		node._poll_quest_talks()
		await process_frame
		await process_frame
		var qt = node.get("_quest_talk")
		if qt == null:
			push_error("SCREENSHOT: 没有 quest_talk 层")
			quit(1)
			return
		if mode == "questoutro":
			# 翻到最后一页（出选项那一页）
			for i in 24:
				if (qt.get("_choice_row") as HBoxContainer).visible:
					break
				qt._lock = 0.0
				qt._advance()
				await process_frame
		for f in 10:
			await process_frame
		await RenderingServer.frame_post_draw
		var qimg: Image = root.get_texture().get_image()
		if qimg != null:
			qimg.save_png(out_path)
		print("SCREENSHOT ", mode, " -> ", out_path)
		quit(0)
		return

	# 标题页模式：**不要**关标题页，等展示村庄铺好（铺路/摆建筑/快进几天要几秒）
	# 再出图。logo 的排版、上下压暗的渐变、居中菜单都在这张图上验。
	if mode == "title":
		for f in 40:
			await process_frame
		await RenderingServer.frame_post_draw
		var timg: Image = root.get_texture().get_image()
		if timg != null:
			timg.save_png(out_path)
		print("SCREENSHOT title -> ", out_path)
		quit(0)
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

	# 科技树（统计面板在下面另一段 —— 那边要多跑 24 天让折线有内容）
	if mode == "tech":
		var t_panel = node.get_node_or_null("UI/Root/Tech")
		if t_panel != null:
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
		# 日志由仿真自己攒（`sim.s["log"]`，面板读的就是它）—— 这里直接 tick 就行，
		# 不需要再手工往哪儿搬（以前要往 runner.recent_logs 抄一份）。
		for h in 24:
			runner.sim.tick_hour([])
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
		for e3 in runner.sim.log_tail(60):
			print("    ", String((e3 as Dictionary).get("text", "")))
		await process_frame
		await process_frame

	# 验证浮动对话框：城镇中心（人口）/ 仓库（资源 + 上限）/ 普通建筑（运营）
	# 走 main 的真实分派路径，保证截到的就是玩家点出来的那个东西
	if mode.begins_with("towncenter") or mode == "warehouse" or mode.begins_with("building") \
			or mode == "works" or mode == "institute":
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
			# 普通建筑面板（基础 / 员工 / 操作 三段）。
			# ⚠️ 这里**不塞假数据**（以前写过 planned=0.6、profit=12.5）：面板现在要显示
			# 「日产量 / 制造加成 / 员工工资」，假值只会截出一份自相矛盾的面板。
			# 所以走真实流程：塞一座伐木场 → 跑满一天让黎明排产算 planned/profit 并派工
			# （在岗人熟练度不同 → 工资不同，正好看「员工」那一段）。
			#
			# `works` / `institute` = **产能建筑的第二个页签**（建筑工坊 → 建造队列、
			# 研究所 → 研究队列）：塞对应的那一座、派人、钉一次当日预算、真推一两个
			# 工作小时（走 `_apply_*_hours()`，不伪造进度），再切到第 2 页。
			var shot_def := "lumberjack"
			if mode == "works":
				shot_def = "construction_works"
			elif mode == "institute":
				shot_def = "research_institute"
			var shot_id := "%s#shot" % shot_def
			(sim.s["shops"] as Array).append({
				"id": shot_id, "defId": shot_def, "owner": "state",
				"targetWorkers": 3, "wage": 3.0, "wageCap": 6.0, "level": 3,
				"active": true, "profit": 0.0, "skill": 60.0, "planned": 0.0,
			})
			# 手动派 3 个人（熟练度各不相同 → 工资不同，正好看「员工」段的那一列）。
			# 为什么不靠引擎派工：演示存档只有 12 个人、却有 30+ 座建筑，黎明分完经常一个人都不剩。
			# 这里不推进时间，所以不会被 `_assign_labor()` 覆盖。
			var shot_skills := [88.0, 62.0, 41.0]
			var shot_k := 0
			for r in (sim.s["residents"] as Array):
				if shot_k >= 3:
					break
				if r.get("jobShopId", null) == null:
					r["employed"] = true
					r["jobShopId"] = shot_id
					r["skill"] = shot_skills[shot_k]
					shot_k += 1
			# 现场重算当日排产，让 planned / profit 与上面这份用工一致
			# （正常是黎明算的；截图工具调内部函数，和 world._try_place 一个性质）
			sim._plan_production()
			target = shot_id
			var shot_shop = sim._find_shop(shot_id)
			print("SCREENSHOT building: 在岗=", sim._assigned_workers(shot_id),
				" 等级=", int(shot_shop["level"]), " planned=", float(shot_shop["planned"]),
				" profit=", float(shot_shop["profit"]),
				" boost=", sim.shop_output_boost(shot_id))
			if mode == "works":
				# 建造队列：钉一次当日建造力，推两个工作小时（队首会开工扣料、进度往前爬）。
				# ⚠️ fraction 要按**工作小时**给（1/12），给 1.0 等于"一整天的产能一次性投进去"，
				#    队首几秒就完工，截图里就只剩「已完成」了。
				sim._plan_construction_day()
				sim._apply_construction_hours(1.0 / 12.0)
				sim._apply_construction_hours(1.0 / 12.0)
				print("SCREENSHOT works: 建造力=", sim.construction_rate(),
					" 队列=", (sim.s["construction"] as Array).size())
			elif mode == "institute":
				# 研究队列：先排几项研究，再钉当日科研力、推两个工作小时
				# ⚠️ 本工具开头把**所有科技**都解锁了（不然建筑放不下），所以要先把这
				#    三项退回"未研究"才排得进队列 —— 与开头那句同样是"只为截图"的改动。
				for tid in ["stonework", "digging", "firewood"]:
					(sim.s["research"]["done"] as Array).erase(String(tid))
				for gid in ["wood", "stone", "clay"]:
					(sim.s["goods"] as Dictionary)[gid] = 900.0
				for tid in ["stonework", "digging", "firewood"]:
					sim._start_research(String(tid))
				sim._plan_research_day()
				sim._apply_research_hours(1.0 / 12.0)
				sim._apply_research_hours(1.0 / 12.0)
				print("SCREENSHOT institute: 科研力=", sim.research_rate(),
					" 队列=", (sim.s["research"]["queue"] as Array).size())
		if target != "" and node.has_method("_on_select_building"):
			node._on_select_building(target)
			await process_frame
			# `building_fold` = 折起「基础」与「操作」，只留「员工」展开：
			# 一条命验三件事 —— 段落能折叠、字形翻成 ＋、面板高度跟着缩（不留空白）
			if mode == "building_fold":
				var ins3 = node.get_node_or_null("UI/Root/Inspector")
				if ins3 != null:
					ins3._toggle_section("基础")
					ins3._toggle_section("操作")
					await process_frame
					await process_frame
					print("SCREENSHOT fold: 面板高=", ins3.size.y,
						" 基础可见=", (ins3._sections["基础"] as Control).visible,
						" 员工可见=", (ins3._sections["员工"] as Control).visible,
						" 操作可见=", (ins3._sections["操作"] as Control).visible)
			# `works` / `institute` = 切到第二页（建造队列 / 研究队列）
			if mode == "works" or mode == "institute":
				var ins4 = node.get_node_or_null("UI/Root/Inspector")
				if ins4 != null:
					ins4._select_tab(1)
					await process_frame
					await process_frame
					print("SCREENSHOT tabs: ", str(ins4._tabs), " 当前页=", ins4._tab,
						" 面板高=", ins4.size.y)
			# `towncenter2` / `towncenter3` / `towncenter4` = 打开后切到第 2/3/4 个页签
			# （资源 / 建造队列 / 公告）
			if mode.begins_with("towncenter") and mode.length() > 10:
				var dlg = node.get_node_or_null("UI/Root/Civic")
				var tab := int(mode.substr(10, 1)) - 1
				if dlg != null and tab > 0:
					dlg._select_tab(tab)
			# `towncenterq` = 建造队列页（第 3 个页签）：**先真下几单**再切过去 ——
			# 空队列看不出名堂，要能同时看到"建造中 / 排队中"两种状态。
			# `towncenterqc` = 再加一步：把某一条的撤单**点到第一次**（二次确认态，
			# 那一行会亮出"会退回什么"）。
			if mode == "towncenterq" or mode == "towncenterqc":
				for gid in ["wood", "stone", "clay", "brick"]:
					(sim.s["goods"] as Dictionary)[gid] = 900.0
				for bid in ["pastry_shop", "porcelain_works", "theater", "smokehouse"]:
					sim._try_build(String(bid))
				sim._try_build_housing("hut")
				# 走 3 个小时：黎明那一小时会开工扣料，白天逐小时往队首投产能
				# （⏱ 别走太多：队首 12 建造力的工程几小时就完工了，截图里就看不到"建造中"）
				for h in 3:
					sim.tick_hour([])
				var dlgq = node.get_node_or_null("UI/Root/Civic")
				if dlgq != null:
					dlgq._select_tab(2)
					if mode == "towncenterqc":
						# 二次确认态：把面板持有的队列状态袋点亮（`queue_box.gd` 读它，
						# 控件每个小时都会重建，所以状态不能记在控件上），再重画一次。
						for cc in (sim.s["construction"] as Array):
							if float(cc["remaining"]) > 0.0 and bool(cc["started"]):
								dlgq._qstate["confirm"] = "q:" + String(cc["id"])
								dlgq._refresh()
								break
				var q: Array = sim.s["construction"]
				print("SCREENSHOT queue: 队列=", q.size(), " 队首=",
					str(q[0]) if q.size() > 0 else "（空）")
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

	# 统计面板：stats / stats0 资源 / stats1（或 stats_people）人口 / stats2（或 stats_finance）财务
	#
	# ⚠️ 这一段是**唯一**处理统计面板的地方。上面原来还有一段"打开面板验证全屏"的，
	# 也按 `stats_people` 判过一次 —— 两段都跑，后一段 `open()` 会把页签重置回 0，
	# 结果"截 stats_people 出来的是资源页"。已把那一段合并掉，只留这里。
	if mode.begins_with("stats"):
		# 多跑几天让曲线有内容
		for h in 24 * 24:
			runner.sim.tick_hour([])
			await process_frame
		var panel = node.get_node_or_null("UI/Root/Stats")
		if panel != null:
			panel.open()
			await process_frame
			var tab := 0
			if mode == "stats_people":
				tab = 1
			elif mode == "stats_finance":
				tab = 2
			elif mode.length() > 5:
				tab = int(mode.substr(5))
			panel._select_tab(tab)
			await process_frame
			print("SCREENSHOT stats tab -> ", tab)

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

	# 任务追踪条（引导系统，见 docs/quests.md）：顶栏下面的右侧，只显示"当前任务"。
	#   `quest`     —— 开局那两条并行任务在跑（进度 0/1）
	#   `questdone` —— 跑一次黎明：任务 1、2 与第 1 章当场结算（标题变绿 + 「已完成」），
	#                  同时第 2 章的三条被"顶"出来（渐进显示）
	if mode == "quest" or mode == "questdone":
		if mode == "questdone" and runner.sim != null:
			for def_id in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
				var d: Dictionary = runner.db.buildings[def_id]
				runner.sim.s["shops"].append({
					"id": "%s#shot" % def_id, "defId": def_id, "owner": "state",
					"targetWorkers": int(d["workers"]),
					"wage": float(runner.db.economy["refWage"]),
					"wageCap": float(runner.db.economy["defaultWageCap"]),
					"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
				})
			runner.sim._run_dawn()
			runner.hour_ticked.emit()
		for _qf in 4:
			await process_frame
		print("SCREENSHOT quest view=", str(runner.sim.quest_view().size()), " 条当前任务")

	# AI 辅助（见 docs/ai-assist.md）：
	#   `ai`       —— 面板的「建议」页：问话栏（默认「我下一步要做什么」）+ 占位说明
	#   `aiset`    —— 「设置」页：base_url / api_key / model_name
	#   `aiask`    —— 用**默认那句**问一次（问完按钮上会带出「还有 5 天」的冷却）
	#   `aiwhy`    —— 把问话改成「为什么人口一直上不去」再问（玩家自己写的那一行）
	#   这四个都指向**本地假模型** `scripts/ai-mock-server.ts`（不联网、不花钱、可重复）
	#   —— 这两张图是端到端联调的证据（问话真的出去了、回来了、画上了）
	#   `aireal`   —— **不灌假配置**，用 `user://ai.cfg` 里那份真配置（默认就是 DeepSeek
	#                 `deepseek-flash`）真打一次。要联网、要花钱、答案不固定，所以不进门槛，
	#                 只在"换模型 / 改提示词之后确认真端点还通"的时候手动跑一次。
	if mode.begins_with("ai"):
		var panel = node.get_node_or_null("UI/Root/AiPanel")
		if panel != null:
			# ⚠️ 顺序要紧：`open()` 会**重新读盘**覆盖 `_cfg`，所以必须 open 之后再灌假配置，
			# 不然配置会被读回空的、`ask()` 直接判定"没配好"（第一次就这么踩了：等了 0 帧）。
			panel.open()
			panel._cfg = AiConfig.load_cfg()
			# `aireal` / `arealso`：**不灌假配置**，直接用玩家自己的 `user://ai.cfg`
			# （真打 DeepSeek 那种要联网 + 花钱的验证就走这条；其余模式一律指向本地假模型）。
			if not mode.begins_with("aireal"):
				panel._cfg["base_url"] = "http://127.0.0.1:8765/v1"
				panel._cfg["model"] = "mock-advisor"
				panel._cfg["api_key"] = "sk-mock-not-a-real-key"
			# 顶栏的数字要在打开面板**之前**刷一次：上面那 72 小时是直接调
			# `sim.tick_hour()` 推的，没有发 `hour_ticked`，顶栏还停在旧值 ——
			# 于是"面板说 66 人、顶栏说 12 人"（小地图的时钟是每帧读的，所以它是对的，
			# 更容易让人以为谁算错了）。发一次信号，两边就一致了。
			runner.hour_ticked.emit()
			await process_frame
			if mode == "aiset":
				panel.select_tab(1)
			else:
				panel.select_tab(0)
				panel._refresh_status()
				if mode == "aiask" or mode == "aiwhy" or mode.begins_with("aireal"):
					if mode == "aiwhy" or mode == "airealwhy" and panel._ask_input != null:
						# 玩家自己写的那一行问话（默认那句留着给 aiask）
						panel._ask_input.text = "为什么人口一直上不去"
					# 这两张图要能看出"方案之间真的有差别"，所以先把建造队列腾空：
					# 这个场景里排着一座剧院，5 天里建造力全被它吃了，于是**每个方案**
					# 都只报「队列 +N、建成 +0」—— 真话，但看不出沙盘在干活。
					runner.sim.s["construction"] = []
					panel.ask()
					# 一场问话是**多轮**的（试方案 → 看结果 → 再试 → 结论），
					# 所以等的是"会话结束"，不是"这次 HTTP 结束"。
					# ⚠️ 真模型一轮要几十秒，**按时间**等（帧数在真机上不可靠）。
					var t0 := Time.get_ticks_msec()
					while (panel._session or panel._client.is_busy()) \
							and Time.get_ticks_msec() - t0 < 600000:
						await process_frame
					var waited := int((Time.get_ticks_msec() - t0) / 1000.0)
					print("SCREENSHOT ", mode, " 等了 ", waited, " 秒；问话=「",
						panel._ask_input.text, "」试了 ", panel.trials_shown(), " 个方案，冷却剩 ",
						runner.sim.prophet_days_left(), " 天")
					# 全屏预言页里回答是从右栏**顶部**开始排的（历史在左边）。
					# 原来那个"滚到底"是给老的建议页写的（结论接在下面）。
					await process_frame
					await process_frame
					if panel._scroll != null:
						panel._scroll.scroll_vertical = 0
			for _af in 4:
				await process_frame
			print("SCREENSHOT ai panel mode=", mode)

	# 任务面板（见 docs/town.md §十九）：左侧圆钮列第 5 个打开。
	#   `questpanel`     —— 打开面板（默认选中**第一个未完成**的任务）
	#   `questpaneldone` —— 再选中一条**已完成**的任务，看"第几天完成"那一栏
	#   `questpanelmid`  —— 先把第 1~3 章的主线摆成"干完了"的样子，看**多章**的任务树
	if mode.begins_with("questpanel"):
		if mode == "questpanelmid" and runner.sim != null:
			# 和 tools/quest_test.gd 的 `_stage3()` 同一个摆法：直接塞建筑 / 科技 /
			# 住房 / 人口 / 台账，"单日产量"看的是 history 里的台账所以也得塞一天。
			for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm",
					"research_institute", "quarry", "clay_pit", "firewood_works",
					"brick_kiln", "construction_works"]:
				var d: Dictionary = runner.db.buildings[bid]
				runner.sim.s["shops"].append({
					"id": "%s#qp" % bid, "defId": bid, "owner": "state",
					"targetWorkers": int(d["workers"]),
					"wage": float(runner.db.economy["refWage"]),
					"wageCap": float(runner.db.economy["defaultWageCap"]),
					"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
				})
			runner.sim.s["housing"]["hut"] = 8
			var residents: Array = runner.sim.s["residents"]
			for k in 48:
				residents.append({"id": "res#shot%d" % (k + 100), "classId": "poor",
					"savings": 10.0, "satisfaction": 70.0, "skill": 50.0,
					"employed": false, "account": {}})
			runner.sim.s["research"]["done"] = ["stonework", "digging", "firewood",
				"brickmaking", "construction"]
			runner.sim.s["goods"]["brick"] = 100.0
			(runner.sim.s["history"] as Array).append({
				"day": 1, "population": residents.size(), "avgSatisfaction": 70.0,
				"money": 0.0, "hungry": 0, "employed": 0,
				"ledger": {"day": 1, "wages": 0.0, "tax": 0.0, "rent": 0.0, "sales": 0.0,
					"produced": {"coarse_bread": 40.0, "vegetable": 20.0},
					"consumed": {}, "bought": {}},
			})
			runner.sim._run_dawn()
			runner.hour_ticked.emit()
			await process_frame
		var qp = node.get_node_or_null("UI/Root/QuestPanel")
		if qp != null:
			qp.open()
			if mode == "questpaneldone":
				for q in runner.sim.quest_journal():
					if bool(q["done"]):
						qp._select(String(q["id"]))
						break
			await process_frame
			print("SCREENSHOT questpanel 选中=", qp._sel,
				" 已知任务=", runner.sim.quest_journal().size())

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
