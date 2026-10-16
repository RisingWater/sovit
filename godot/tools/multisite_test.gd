extends SceneTree

# 同类多个工地各对应**各自的**施工队列条目（进度条 / 悬停提示）。
#
# 用户报的 bug：放 4 个茅屋，工地是一个一个建的，但**4 条进度条一起涨**，满了之后
# 只有第一个建好。原因：进度按**类型**取"队首那条 / 那条 started 的"，同类型的工地
# 共用一份进度。修法：按"同类型里的第 i 个"配对（两侧都是 FIFO，序号自纠正）。
#
# 验三条：
#   1. 队列里 3 条 hut → 工地 0 = 建造中（有填充）、工地 1/2 = 排队中（frac 恰为 0）；
#   2. 施工推进一天后，**只有工地 0 的 frac 变大**，工地 1/2 仍然 0；
#   3. 队首建好后队首前进：新的工地 0 变成"建造中"，最后那个还是"排队中"。
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/multisite_test.gd

const SEED := 20261014
const RES_MULT := 20.0
const TYPE := "hut"
const N := 3

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("MULTISITE TEST FAIL: ", msg)
	print("MULTISITE TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _bar(world, site: Dictionary) -> Dictionary:
	return world._site_bar_state(site)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame
	var world = node.get_node_or_null("World")
	if world == null:
		_fail("找不到 World")
		return
	var db = world.runner.db
	world.start_new_game(SEED, RES_MULT, "多工地测")
	world.runner.paused = true
	await process_frame
	# 全解锁，免得茅屋被科技锁着
	world.runner.sim.s["research"]["done"] = db.tech_ids.duplicate()
	await process_frame

	# ---- 放 N 个同类工地 -------------------------------------------------------
	var fp: Vector2i = world._footprint(TYPE)
	var from: Vector2i = world.map.town_center.position + Vector2i(14, -10)
	var placed := 0
	for dy in range(0, 40):
		for dx in range(0, 60):
			if placed >= N:
				break
			var c: Vector2i = from + Vector2i(dx, dy)
			if world.place_reason(TYPE, c) == "" and world._try_place(TYPE, c):
				placed += 1
	if placed < N:
		_fail("只放下了 %d 个 %s（要 %d 个）" % [placed, TYPE, N])
		return
	await process_frame
	var sites: Array = world._site_by_type.get(TYPE, [])
	if sites.size() != N:
		_fail("登记了 %d 个工地，期望 %d" % [sites.size(), N])
		return
	_ok("放下 %d 个 %s 工地：%s" % [N, TYPE, str(sites.map(func(s): return str(s["cell"])))])

	# ---- 命令还没生效：三条都该是"已下单"（灰框，无填充）-----------------------
	for s in sites:
		var st := _bar(world, s)
		if String(st["state"]) != "pending" or float(st["frac"]) != 0.0:
			_fail("命令未生效时工地 %s 的状态应为 pending/0，实际 %s" % [str(s["cell"]), str(st)])
			return
		if not world.site_tip_at(s["cell"]).contains("已下单"):
			_fail("命令未生效时提示应含「已下单」：%s" % world.site_tip_at(s["cell"]))
			return
	_ok("命令未生效：%d 条都是 pending / frac=0，提示都是「已下单」" % N)

	# ---- 让命令生效（**黎明 hour=6 才应用**）+ 再走两小时让队首真的开工 ----------
	# 只 tick 1 小时的话还在 hour=1，队列是空的 —— 第一版就是这么写的，红在"只有 0 条"。
	for h in 8:
		world.runner.sim.tick_hour([])
		await process_frame
	var entries: Array = world._construction_entries(TYPE)
	if entries.size() != N:
		_fail("施工队列里 %s 只有 %d 条，期望 %d" % [TYPE, entries.size(), N])
		return
	await process_frame

	# ---- 只有工地 0 在动 -------------------------------------------------------
	var s0: Dictionary = sites[0]
	var st0 := _bar(world, s0)
	if String(st0["state"]) != "building":
		_fail("队首工地 %s 应为 building，实际 %s" % [str(s0["cell"]), str(st0)])
		return
	for i in range(1, N):
		var sti := _bar(world, sites[i])
		if float(sti["frac"]) != 0.0:
			_fail("第 %d 个工地不该有进度：%s" % [i, str(sti)])
			return
		if String(sti["state"]) == "building":
			_fail("第 %d 个工地不该是 building：%s" % [i, str(sti)])
			return
	_ok("队首 = 建造中；其后 %d 个都是排队中且 frac 恰为 0（不再共用队首进度）" % (N - 1))

	var tip1: String = world.site_tip_at(sites[1]["cell"])
	if not tip1.contains("排队中"):
		_fail("第 2 个工地的提示应说「排队中」：%s" % tip1)
		return
	if not tip1.contains("同类工地第 2 / %d 处" % N):
		_fail("第 2 个工地的提示没写清是第几个：%s" % tip1)
		return
	_ok("第 2 个工地的提示：%s" % tip1.replace("\n", " / "))

	# ---- 推进施工：只有工地 0 的进度涨 -----------------------------------------
	# ⚠️ 只推 **1 小时**：建造力约 25/天 → 每个工作小时约 2 点，而茅屋只要 12 点，
	#    推 6 小时就会把队首建好、队首前进，这时"第 2 个工地"本来就该变成建造中
	#    （第一版就是这么写红的：断言打得比真实节奏还宽）。
	var before := float(_bar(world, sites[0])["frac"])
	for h in 1:
		world.runner.sim.tick_hour([])
		await process_frame
	var after := float(_bar(world, sites[0])["frac"])
	if after <= before:
		_fail("施工推进后队首进度没涨：%.3f → %.3f" % [before, after])
		return
	for i in range(1, N):
		if float(_bar(world, sites[i])["frac"]) != 0.0:
			_fail("施工推进后第 %d 个工地竟然也有进度：%s" % [i, str(_bar(world, sites[i]))])
			return
	_ok("推进 1 小时后：队首 %.0f%% → %.0f%%，其余仍是 0%%" % [before * 100.0, after * 100.0])

	# ---- 再推一天：不变式仍成立（队首会前进，可能建好一到两座）-----------------
	for h in 24:
		world.runner.sim.tick_hour([])
		await process_frame
	var left: Array = world._site_by_type.get(TYPE, [])
	if left.is_empty():
		_ok("一天后 %d 座全部建好（也算正确）" % N)
	else:
		var nst0 := _bar(world, left[0])
		if String(nst0["state"]) != "building":
			_fail("队首前进后新的工地 0 应为 building，实际 %s" % str(nst0))
			return
		for i in range(1, left.size()):
			var sti2 := _bar(world, left[i])
			if float(sti2["frac"]) != 0.0 or String(sti2["state"]) == "building":
				_fail("队首前进后，第 %d 个工地仍应是排队中/0：%s" % [i, str(sti2)])
				return
		_ok("一天后剩 %d 个：新的队首 = 建造中，其余仍排队中（序号自动对齐）" % left.size())

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("MULTISITE TEST 检查了 %d 条断言" % _checks)
	print("MULTISITE TEST RESULT: PASS")
	quit(0)
