extends SceneTree

# 占地锚点（"脚" = 底边那一行的最左格）与"命中区"（点屋顶/塔尖也能选中建筑）的门槛。
#
# 2026-10 改动的三条不变量：
#   1. `map.occupied` 只占"脚踩的那几行"：从锚点往上数 fh 行。锚点**下面**那一行、
#      以及贴图往上伸出去的那几行，都**不占**（那才是"顶行不占地"的意思）；
#   2. 贴图节点 y = (锚点行 + 1) × 16（= 地面线），不是贴图左上角；
#   3. 点到"贴图画着、却不占地"的格子（屋顶 / 塔尖），`_pick_building_at()` 要返回
#      那座建筑，并且 `_on_left_click()` 真的把它选中 —— 用户明确否掉了"点屋顶选不中"。
#
# 用法（在 godot/ 下，走带超时的独立进程）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/roofclick_test.gd

const SEED := 20261014
const RES_MULT := 20.0
const BID := "coarse_mill"          # 64x52 → 占地 4x2（顶行不占地）

var _checks := 0
var _selected: Array = []

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("ROOFCLICK TEST FAIL: ", msg)
	print("ROOFCLICK TEST RESULT: FAIL（检查了 %d 条）" % _checks)
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
	if db == null or (db.buildings as Dictionary).is_empty():
		_fail("内容库是空的（假绿）")
		return

	world.start_new_game(SEED, RES_MULT, "屋顶测")
	world.runner.paused = true
	await process_frame
	world.select_building.connect(func(id): _selected.append(String(id)))
	world.select_housing.connect(func(id): _selected.append(String(id)))

	# ---- 1. 城镇中心：塔尖（贴图画着、不占地）也要点得中 -----------------------
	var tc: Rect2i = world.map.town_center
	var tc_fp: Vector2i = world._footprint("town_center")
	if Vector2i(tc.size.x, tc.size.y) != tc_fp:
		_fail("城镇中心的 code 矩形 %s 与 content 的 art.foot %s 不一致"
			% [str(tc.size), str(tc_fp)])
		return
	var tc_anchor: Vector2i = world._foot_anchor(tc.position, tc_fp)
	# 塔尖那几行：占格顶边再往上 1..4 行 —— 在贴图覆盖格里，但在占格之外。
	# 这些格子里有些会被开局那 6 间茅屋占掉（那正是"层叠"），所以挑一个空着的。
	var tc_top := Vector2i(tc_anchor.x, tc_anchor.y - tc_fp.y + 1)
	var spire := Vector2i(-1, -1)
	for dy in range(1, 5):
		for dx in tc_fp.x:
			var c := Vector2i(tc_top.x + dx, tc_top.y - dy)
			if world.map.occupied_at(c) == null:
				spire = c
				break
		if spire.x >= 0:
			break
	if spire.x < 0:
		_fail("城镇中心顶上四行全是占格（挑不出塔尖格）")
		return
	_ok("塔尖 %s 不在 map.occupied（能盖别的建筑 = 层叠）" % str(spire))
	var tc_id := String(world._town_center_shop_id())
	var pick_tc = world._pick_building_at(spire)
	if pick_tc == null or String(pick_tc["id"]) != tc_id:
		_fail("点塔尖 %s 没命中城镇中心（%s）：%s" % [str(spire), tc_id, str(pick_tc)])
		return
	_selected.clear()
	world._on_left_click(spire)
	if _selected.is_empty() or String(_selected[0]) != tc_id:
		_fail("点塔尖没选中城镇中心：%s" % str(_selected))
		return
	_ok("点塔尖 %s 选中了城镇中心（命中区覆盖贴图画到的格）" % str(spire))

	# ---- 2. 普通建筑：占格 = 从锚点往上 fh 行 ---------------------------------
	var fp: Vector2i = world._footprint(BID)
	var cell := Vector2i(-1, -1)
	var from: Vector2i = world.map.town_center.position + Vector2i(12, -8)
	for dy in range(0, 40):
		for dx in range(0, 50):
			var c: Vector2i = from + Vector2i(dx, dy)
			if world.place_reason(BID, c) == "":
				cell = c
				break
		if cell.x >= 0:
			break
	if cell.x < 0:
		_fail("找不到能放 %s 的空地" % BID)
		return
	var anchor := Vector2i(cell.x - 1, cell.y)
	if not world._try_place(BID, cell):
		_fail("放下 %s 失败：%s" % [BID, world.place_reason(BID, cell)])
		return
	await process_frame
	for i in fp.y:
		var oc = world.map.occupied_at(Vector2i(anchor.x, anchor.y - i))
		if oc == null or String(oc.get("id", "")) != BID:
			_fail("占格少了从锚点 %s 往上第 %d 行（%s）"
				% [str(anchor), i, str(Vector2i(anchor.x, anchor.y - i))])
			return
	_ok("%s 占地 = 从锚点 %s 往上 %d 行（%s）" % [BID, str(anchor), fp.y, str(fp)])

	for probe in [Vector2i(anchor.x, anchor.y + 1), Vector2i(anchor.x, anchor.y - fp.y)]:
		var oc2 = world.map.occupied_at(probe)
		if oc2 != null and String(oc2.get("id", "")) == BID:
			_fail("%s 占了不该占的格子 %s（锚点下面那行 / 屋顶那行）" % [BID, str(probe)])
			return
	_ok("锚点下面那行、屋顶那行都不占（改 foot 高度只影响顶部）")

	# ---- 3. 结算成商店视图：地面线 = 锚点那一行的底边 --------------------------
	world.runner.sim.s["shops"].append({
		"id": BID + "#1", "defId": BID, "owner": "state",
		"targetWorkers": int(db.buildings[BID]["workers"]),
		"wage": float(db.economy["refWage"]), "wageCap": float(db.economy["defaultWageCap"]),
		"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		"toolBoost": 1.0,
	})
	world.runner.sim.s["pending"] = []
	world.runner.sim.s["construction"] = []
	for f in 6:
		await process_frame
	var sid := BID + "#1"
	if not world._shop_sprites.has(sid):
		_fail("工地没被 _sync 收成商店视图：%s" % sid)
		return
	var spr = world._shop_sprites[sid]
	var want_y := float((anchor.y + 1) * 16)
	if absf(spr.position.y - want_y) > 0.01:
		_fail("贴图地面线应为 %d（锚点那一行的底边），实际 %.1f" % [int(want_y), spr.position.y])
		return
	if world._shop_cell[sid] != anchor:
		_fail("_shop_cell 应存锚点 %s，实际 %s" % [str(anchor), str(world._shop_cell[sid])])
		return
	_ok("地面线 y=%d（锚点 %s 那一行的底边）；_shop_cell 存的就是锚点" % [int(want_y), str(anchor)])

	# ---- 4. 点屋顶 = 选中这座建筑 --------------------------------------------
	var roof := Vector2i(anchor.x + fp.x / 2, anchor.y - fp.y)
	if world.map.occupied_at(roof) != null:
		_fail("屋顶那一格 %s 不该在 map.occupied" % str(roof))
		return
	var pick = world._pick_building_at(roof)
	if pick == null or String(pick["id"]) != sid:
		_fail("点屋顶 %s 没选中 %s：%s" % [str(roof), sid, str(pick)])
		return
	_selected.clear()
	world._on_left_click(roof)
	if _selected.is_empty() or String(_selected[0]) != sid:
		_fail("_on_left_click 点屋顶没选中 %s：%s" % [sid, str(_selected)])
		return
	_ok("点屋顶 %s 选中了 %s" % [str(roof), sid])

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("ROOFCLICK TEST 检查了 %d 条断言" % _checks)
	print("ROOFCLICK TEST RESULT: PASS")
	quit(0)
