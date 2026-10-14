extends SceneTree

# 在建工地的悬停提示门槛。
#
# 验的是"鼠标移到工地上能看到什么"：
#   · 刚放下、命令还没生效   → 已下单，次日 06:00 开工（不是"0 / 60"那种糊弄）
#   · 进了建造队列还没动工   → 排队中（等前面的工程）＋ 建造力 0 / N
#   · 真的在施工             → 建造中 ＋ 已投入 / 需要（百分比）
#   · 不是工地 / 移开鼠标     → 不显示
#
# 刻意**不用真鼠标**：提示文字由 `site_tip_at(cell)` 这个纯函数算出来，
# 门槛直接喂格子；可见性则用"格子 → 屏幕坐标"反算一个位置喂给 `_update_site_tip()`，
# 这样在 headless 下也完全确定（真鼠标在 headless 里永远是 0,0）。

var _fail_msg := ""

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("SITETIP TEST FAIL: ", msg)
	quit(1)

func _screen_pos_of(world, cell: Vector2i) -> Vector2:
	return world.get_global_transform_with_canvas() * world._cell_center(cell)

## 挑一座**工期最长**且材料够的非固定建筑：工期太短的话，两天内就完工、
## 工地消失，断言会变成薛定谔的。测试会先把科技全解锁，所以候选够多。
func _pick_building(world) -> String:
	var db = world.runner.db
	var best := ""
	var best_work := 0.0
	for bid in db.buildings.keys():
		var b := String(bid)
		if b == "town_center":
			continue
		var d: Dictionary = db.buildings[b]
		var work := float(d.get("buildWork", 0))
		if work <= best_work:
			continue
		if world._can_afford(b) != "":
			continue
		best = b
		best_work = work
	return best

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
	world.start_new_game(20261014, 1.0, "提示测")
	await process_frame

	# 先把科技全解锁：不然 v0.3 开局只有城镇中心是"解锁且够料"的，
	# 挑不出普通建筑（而城镇中心是地图固定建筑，正常玩放不出来）。
	world.runner.sim.s["research"]["done"] = world.runner.db.tech_ids.duplicate()

	var bid := _pick_building(world)
	if bid == "":
		_fail("找不到可建的建筑，测不了")
		return
	var fp: Vector2i = world._footprint(bid)
	# 找一块空地：从城镇中心往右扫
	var cell := Vector2i(-1, -1)
	for dy in range(0, 30):
		for dx in range(0, 40):
			var c: Vector2i = world.map.town_center.position + Vector2i(10 + dx, -4 + dy)
			if world.map.in_bounds(c + fp) and world._area_free(c, fp) \
					and world._can_afford(bid) == "":
				cell = c
				break
		if cell.x >= 0:
			break
	if cell.x < 0:
		_fail("地图上找不到能放 %s 的空地" % bid)
		return

	# 让这座建筑真的被解锁（上面已经把科技全解锁了，这里只是兜底）
	for tid in world.runner.db.tech_ids:
		if world.runner.db.techs[tid]["unlocks"]["buildings"].has(bid):
			var done: Array = world.runner.sim.s["research"]["done"]
			if not done.has(tid):
				done.append(tid)
	if not world.runner.sim.is_building_unlocked(bid):
		_fail("%s 还是锁着，测不了" % bid)
		return

	if not world._try_place(bid, cell):
		_fail("放置 %s 失败" % bid)
		return
	await process_frame
	var name_zh := String(world.runner.db.buildings[bid]["nameZh"])
	var origin := Vector2i(cell.x - 1, cell.y - 1)
	var probe := origin + Vector2i(fp.x / 2, fp.y / 2)   # 工地中心

	# ---- 1. 刚放下：命令还没生效
	var t1: String = world.site_tip_at(probe)
	if not t1.contains(name_zh):
		_fail("提示里没有建筑名「%s」：%s" % [name_zh, t1])
		return
	if not t1.contains("已下单"):
		_fail("刚放下时应提示「已下单」，实际：%s" % t1)
		return
	if world.site_tip_at(origin + Vector2i(-6, -6)) != "":
		_fail("不是工地也给了提示")
		return
	print("SITETIP TEST 刚下单一格：%s" % t1.replace("\n", " / "))

	# ---- 2. 提示真的会显示出来（按格子反算屏幕坐标喂进去）
	world._update_site_tip(_screen_pos_of(world, probe))
	await process_frame
	if not world._tip.visible:
		_fail("鼠标在工地上，提示没显示")
		return
	if not String(world._tip_label.text).contains(name_zh):
		_fail("提示框文字不对：%s" % world._tip_label.text)
		return
	# 移开 → 收起
	world._update_site_tip(_screen_pos_of(world, origin + Vector2i(-8, -8)))
	await process_frame
	if world._tip.visible:
		_fail("鼠标移开工地，提示没收起")
		return
	print("SITETIP TEST 显示 / 收起：OK")

	# ---- 3. 命令生效后：进队列 → 建造力 0 / N
	for h in 24:
		world.runner.sim.tick_hour([])
	var t2: String = world.site_tip_at(probe)
	if not t2.contains("建造力"):
		_fail("进队列后应报建造力，实际：%s" % t2)
		return
	var need := float(world.runner.db.buildings[bid]["buildWork"])
	if not t2.contains(str(int(need))):
		_fail("提示里没有需要的建造力 %d：%s" % [int(need), t2])
		return
	print("SITETIP TEST 进队列：%s" % t2.replace("\n", " / "))

	# ---- 4. 再过一天：进度必须往前；**完工也是正确行为**（那就不该再有工地）
	#
	# 不写"必须仍在施工"：建造力 ≈ 25/天，工期 48 的剧院正好第二天完工，
	# 这种断言会随任何数值调整变成薛定谔的。改成验两条互斥但都合法的结局。
	var done0 := _invested(world, bid)
	for h in 24:
		world.runner.sim.tick_hour([])
	var t3: String = world.site_tip_at(probe)
	if t3 == "":
		var occ = world.map.occupied_at(probe)
		if occ == null or String(occ["kind"]) != "shop":
			_fail("工地既没提示、也没变成商店：occ=%s" % str(occ))
			return
		print("SITETIP TEST 施工中：%s 已完工 → 工地变商店，提示正确消失" % name_zh)
	else:
		if not t3.contains("建造力"):
			_fail("施工中的提示没有建造力：%s" % t3)
			return
		var done1 := _invested(world, bid)
		if done1 <= done0:
			_fail("施工一天后已投入没涨：%s → %s" % [done0, done1])
			return
		if not t3.contains(str(int(round(done1)))):
			_fail("提示里的已投入与队列不一致：提示=%s 队列=%d" % [t3, int(round(done1))])
			return
		print("SITETIP TEST 施工中：%s（已投入 %.0f → %.0f）" % [
			t3.replace("\n", " / "), done0, done1])

	print("SITETIP TEST RESULT: PASS")
	quit(0)

## 建造队列里这座建筑已经投进去多少建造力（没有条目返回 0）。
func _invested(world, bid: String) -> float:
	for c in (world.runner.sim.s["construction"] as Array):
		if String(c["kind"]) == "shop" and String(c.get("buildingId", "")) == bid:
			return float(c["totalRequired"]) - float(c["remaining"])
	return 0.0
