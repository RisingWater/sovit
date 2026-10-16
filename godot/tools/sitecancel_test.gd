extends SceneTree

# 撤单之后：**地图上那处工地要跟着消失**（`world_view._prune_orphan_sites()`）。
#
# 为什么单独一条门槛：sim 里把队列条目删掉了，地图上的灰精灵和 `map.occupied` 里的
# 那几格**不会自己消失** —— 不收拾的话就是一处"永远不完工、地格也永远占着"的鬼工地。
#
# 同时盯住一个反向的坑（第一版就是这么红的）：**刚放下的工地，命令要等次日 06:00 才进
# 队列**，那半天里队列里根本没有它。若判据写成"工地数 > 队列条数就收"，刚放下的工地会被
# 当场收掉 —— 建筑落到了别处、悬停提示也空了（门槛 doortest / multisite 一起红）。
# 现在的判据是"**曾经真的对上过队列条目**（`seen_entry`）才有资格当孤儿"。
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/sitecancel_test.gd

const SEED := 20261022
const RES_MULT := 20.0
const TYPE := "hut"
const N := 2

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("SITECANCEL TEST FAIL: ", msg)
	print("SITECANCEL TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

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
	world.start_new_game(SEED, RES_MULT, "撤单测")
	world.runner.paused = true
	await process_frame
	world.runner.sim.s["research"]["done"] = db.tech_ids.duplicate()
	await process_frame

	# ---- 放下 N 个同类工地 ------------------------------------------------------
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
	var cells := []
	for s in world._site_by_type.get(TYPE, []):
		cells.append(s["cell"])
	if cells.size() != N:
		_fail("放下 %d 个工地，只登记了 %d 处" % [N, cells.size()])
		return
	_ok("放下 %d 处 %s 工地：%s" % [N, TYPE, str(cells)])

	# ---- 命令还没生效时**不许**把工地当孤儿收掉（反向的坑）---------------------
	world.runner.sim.tick_hour([])
	await process_frame
	await process_frame
	if (world._site_by_type.get(TYPE, []) as Array).size() != N:
		_fail("命令还没生效（队列里还没有它），工地却被收掉了：%d 处" % (
			world._site_by_type.get(TYPE, []) as Array).size())
		return
	_ok("命令未生效时工地原样留着（判据不能只看数量）")

	# ---- 推到黎明：命令生效 → 队列里有 N 条 -------------------------------------
	for h in 8:
		world.runner.sim.tick_hour([])
		await process_frame
	var entries: Array = world._construction_entries(TYPE)
	if entries.size() != N:
		_fail("施工队列里 %s 只有 %d 条，期望 %d" % [TYPE, entries.size(), N])
		return
	if (world._site_by_type.get(TYPE, []) as Array).size() != N:
		_fail("命令生效后工地数应还是 %d 处" % N)
		return
	_ok("黎明后：队列 %d 条、工地 %d 处（一一对上）" % [entries.size(), N])

	# ---- 撤掉队首那一条 → 次日黎明生效 → 多出来的工地要跟着消失 -----------------
	var head_id := String(entries[0]["id"])
	var logs_before: int = world.runner.sim.log_size()
	world.runner.enqueue([{"type": "cancel_construction", "id": head_id}])
	# 命令次日 06:00 生效 → 直接把时钟拨到 05:00，再走两小时（跨过黎明那一步）。
	# ⚠️ 不这么拨、改成"老老实实推 24 小时"的话，**剩下那条茅屋会在这一天里建完**
	#    （茅屋只要 12 建造力），队列变 0，断言就测不到"撤单留下的孤儿"了。
	world.runner.sim.s["hour"] = 5
	world.runner.sim.tick_hour([])
	world.runner.sim.tick_hour([])
	await process_frame
	await process_frame
	await process_frame

	var entries2: Array = world._construction_entries(TYPE)
	var sites2: Array = world._site_by_type.get(TYPE, [])
	if entries2.size() != 1:
		_fail("撤单后队列应剩 1 条，实际 %d 条" % entries2.size())
		return
	if sites2.size() != entries2.size():
		_fail("撤单后工地数(%d) 应等于队列条数(%d) —— 多出来的那处没被收掉" % [
			sites2.size(), entries2.size()])
		return
	_ok("撤单后：队列 %d 条、工地 %d 处（孤儿被收掉）" % [entries2.size(), sites2.size()])

	# 被收掉那处的**地格要放回**（能在那儿盖别的东西）
	var free_now := 0
	for c in cells:
		if world.map.occupied_at(c) == null:
			free_now += 1
	if free_now < 1:
		_fail("撤单后应有一处工地释放地格，实际一处都没释放：%s" % str(cells))
		return
	_ok("被收掉那处的地格放回了（%d / %d 处已空）" % [free_now, cells.size()])

	# 撤单要进公告（玩家得知道退回了什么）
	var found := ""
	for e in world.runner.sim.log_tail(world.runner.sim.log_size()):
		if String(e["text"]).contains("取消"):
			found = String(e["text"])
	if found == "":
		_fail("撤单没进公告（%d 条日志里没有「取消」）" % (
			world.runner.sim.log_size() - logs_before))
		return
	_ok("撤单进了公告：%s" % found)

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("SITECANCEL TEST 检查了 %d 条断言" % _checks)
	print("SITECANCEL TEST RESULT: PASS")
	quit(0)
