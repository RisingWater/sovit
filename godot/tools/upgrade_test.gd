extends SceneTree

# 建筑升级（`expand`）的进度条与悬停提示。
#
# 用户报的：**建筑升级没有进度条** —— 升级是从建筑面板下单的，地图上一点反馈都没有，
# 点完看不出"是在建、在排队、还是缺料"。修法与工地条共用同一支（`_draw_bar_at()`）：
#   · 灰 = 已下单但还没到黎明（动作还在 `pending` 里）
#   · 黄 = 已进队列、在排队 / 等材料
#   · 蓝 = 正在施工（填充比例 = 已投入 / 需要）
# 顺带盯住 `_bar_base_y()`：条要画在**占地顶边往上 16px**（锚点是"脚"，不能直接
# `cell.y * TILE - 16`，否则条压在屋顶那一行里）。
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/upgrade_test.gd

const SEED := 20261014
const RES_MULT := 20.0
const BID := "coarse_mill"

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("UPGRADE TEST FAIL: ", msg)
	print("UPGRADE TEST RESULT: FAIL（检查了 %d 条）" % _checks)
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
	world.start_new_game(SEED, RES_MULT, "升级测")
	world.runner.paused = true
	await process_frame
	world.runner.sim.s["research"]["done"] = db.tech_ids.duplicate()
	await process_frame

	# ---- 先建一座出来（直接塞进 sim + _sync 收成视图，和省一天时间）------------
	var fp: Vector2i = world._footprint(BID)
	var cell := Vector2i(-1, -1)
	var from: Vector2i = world.map.town_center.position + Vector2i(14, -10)
	for dy in range(0, 40):
		for dx in range(0, 60):
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
		_fail("放下 %s 失败" % BID)
		return
	await process_frame
	var sid := BID + "#1"
	world.runner.sim.s["shops"].append({
		"id": sid, "defId": BID, "owner": "state",
		"targetWorkers": int(db.buildings[BID]["workers"]),
		"wage": float(db.economy["refWage"]), "wageCap": float(db.economy["defaultWageCap"]),
		"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		"toolBoost": 1.0,
	})
	world.runner.sim.s["pending"] = []
	world.runner.sim.s["construction"] = []
	for f in 6:
		await process_frame
	if not world._shop_sprites.has(sid):
		_fail("商店视图没建出来：%s" % sid)
		return
	_ok("先建好一座 %s（锚点 %s，占地 %s）" % [BID, str(anchor), str(fp)])

	# ---- 0. 没升级时：不该有条 -------------------------------------------------
	if not world._upgrade_state(sid).is_empty():
		_fail("没点升级却有升级条：%s" % str(world._upgrade_state(sid)))
		return
	if world.site_tip_at(anchor) != "":
		_fail("没升级时不该有升级提示：%s" % world.site_tip_at(anchor))
		return
	_ok("没点升级：无进度条、无提示")

	# ---- 1. 条的位置口径：占地顶边往上 16px（防"条压在屋顶上"）-----------------
	var want_base := float(world._foot_top(anchor, fp).y) * 16.0 - 16.0
	var got_base: float = world._bar_base_y(anchor, fp)
	if absf(got_base - want_base) > 0.01:
		_fail("进度条基线应为占地顶边往上 16px（%.1f），实际 %.1f" % [want_base, got_base])
		return
	_ok("条基线 y=%.0f = 占地顶边 %d × 16 − 16（不会压在建筑上）"
		% [got_base, world._foot_top(anchor, fp).y])

	# ---- 2. 点了升级、命令还没生效：灰（pending / 0）--------------------------
	world.runner.enqueue([{"type": "expand", "shopId": sid}])
	await process_frame
	var st0: Dictionary = world._upgrade_state(sid)
	if String(st0.get("state", "")) != "pending" or float(st0.get("frac", 0.0)) != 0.0:
		_fail("刚点升级（命令未生效）应为 pending/0，实际 %s" % str(st0))
		return
	var tip0: String = world.site_tip_at(anchor)
	if not tip0.contains("已下单"):
		_fail("刚点升级的提示应含「已下单」：%s" % tip0)
		return
	_ok("刚点升级：pending / frac=0，提示「%s」" % tip0.replace("\n", " / "))

	# ---- 3. 命令生效后进队列：黄（排队/缺料）→ 施工后蓝（有填充）--------------
	for h in 8:
		world.runner.sim.tick_hour([])
		await process_frame
	var entry: Dictionary = world._upgrade_entry(sid)
	if entry.is_empty():
		_fail("黎明后施工队列里没有这座的升级条目")
		return
	var st1: Dictionary = world._upgrade_state(sid)
	if float(st1.get("frac", 0.0)) <= 0.0:
		# 可能是排在别的工程后面（黄/红）—— 那也是合法状态，但要报出来
		if String(st1.get("state", "")) == "building":
			_fail("标着 building 却没有进度：%s" % str(st1))
			return
	_ok("进队列后状态 = %s，填充 = %.0f%%" % [String(st1["state"]), float(st1["frac"]) * 100.0])
	if String(entry.get("kind", "")) != "upgrade" or String(entry.get("shopId", "")) != sid:
		_fail("条目不是这座的 upgrade：%s" % str(entry))
		return
	var tip1: String = world.site_tip_at(anchor)
	if not tip1.contains("升级"):
		_fail("升级中的提示里没有「升级」：%s" % tip1)
		return
	if not tip1.contains("建造力"):
		_fail("升级中的提示里没有建造力进度：%s" % tip1)
		return
	_ok("升级提示：%s" % tip1.replace("\n", " / "))

	# ---- 4. 推到头：升级完成 → 条消失、等级 +1 --------------------------------
	var lv0 := int(((world.runner.sim.s["shops"] as Array).filter(
		func(s): return String(s["id"]) == sid)[0])["level"])
	for h in 48:
		world.runner.sim.tick_hour([])
		await process_frame
	var lv1 := int(((world.runner.sim.s["shops"] as Array).filter(
		func(s): return String(s["id"]) == sid)[0])["level"])
	if lv1 <= lv0:
		_fail("升级推了两天等级还是 Lv%d（升级没完成？队列=%s）"
			% [lv1, str(world.runner.sim.s["construction"])])
		return
	if not world._upgrade_state(sid).is_empty():
		_fail("升级完成后还留着升级条：%s" % str(world._upgrade_state(sid)))
		return
	if world.site_tip_at(anchor) != "":
		_fail("升级完成后还留着提示：%s" % world.site_tip_at(anchor))
		return
	_ok("升级完成：Lv%d → Lv%d，进度条与提示都收掉了" % [lv0, lv1])

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("UPGRADE TEST 检查了 %d 条断言" % _checks)
	print("UPGRADE TEST RESULT: PASS")
	quit(0)
