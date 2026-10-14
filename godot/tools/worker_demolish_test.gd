extends SceneTree

# 建筑面板的「用工拖动条」与「拆除」门槛。
#
# 锁四件事：
#   1. 拖动条 max_value == **有效工位数**（含升级带来的 slotsPerLevel 工位，
#      不是 maxWorkers 那个常数）
#   2. 拖到 0 → 入队的是 `set_workers: 0`（0 就是停产）
#   3. 「拆除」按钮点两下（二次确认）→ 入队 `demolish`
#   4. 命令生效后，引擎的 `state.shops` 里**确实没有**那座建筑了
#      （只测入队不测结果的话，"动作没人处理"这种 bug 会漏过去）

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("WORKER TEST FAIL: ", msg)
	quit(1)

func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if (c as Button).text == text:
			return c
	return null

func _pending_types(sim) -> Array:
	var out := []
	for a in (sim.s["pending"] as Array):
		out.append(String(a.get("type", "")))
	return out

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var sim = node.runner.sim
	var ins = node.get_node_or_null("UI/Root/Inspector")
	if ins == null:
		_fail("找不到 UI/Root/Inspector")
		return
	# 暂停：不暂停的话 runner 每小时 tick 一次会不断 _rebuild() 面板，
	# 抓到的 HSlider 引用下一帧就成了 previously freed。
	node.runner.set_paused(true)

	# 直接塞一座研究所进 shops：它有 capacity.slotsPerLevel，正好验证"升级加工位"。
	# maxWorkers=6、slotsPerLevel=3 → L3 时有效工位 = 6 + 3*(3-1) = 12
	var sid := "research_institute#test"
	(sim.s["shops"] as Array).append({
		"id": sid, "defId": "research_institute", "owner": "state",
		"targetWorkers": 6, "wage": 3.0, "wageCap": 6.0, "level": 3, "active": true,
		"profit": 0.0, "skill": 50.0, "planned": 0.0, "toolBoost": 1.0,
	})
	var def: Dictionary = node.runner.db.buildings["research_institute"]
	var expect: int = sim.effective_slots(def, 3)
	if expect != 12:
		_fail("effective_slots(研究所, L3) 应为 12，实际 %d" % expect)
		return

	ins.show_building(sid)
	await process_frame

	# 1. 拖动条存在，且 max == 有效工位数
	var slider: HSlider = null
	for c in ins.find_children("*", "HSlider", true, false):
		slider = c
	if slider == null:
		_fail("建筑面板里没有 HSlider")
		return
	if int(slider.max_value) != expect:
		_fail("拖动条 max 应为有效工位数 %d，实际 %d（用了 maxWorkers 就会是 6）"
			% [expect, int(slider.max_value)])
		return
	# 立刻把值抄下来：后面 clear() 会 _rebuild()，这个 slider 引用就变成 previously freed
	var slider_max := int(slider.max_value)
	if int(slider.min_value) != 0:
		_fail("拖动条 min 应为 0（0 = 停产），实际 %d" % int(slider.min_value))
		return
	# 四个 ±按钮必须已经删掉
	for old in ["-10", "-1", "+1", "+10"]:
		if _find_button(ins, old) != null:
			_fail("旧的「%s」按钮还在" % old)
			return
	# 停产/复工 开关也必须删掉
	for old in ["停产", "复工"]:
		if _find_button(ins, old) != null:
			_fail("旧的「%s」按钮还在" % old)
			return

	# 2. 拖到 0 → 入队 set_workers: 0
	slider.value = 0
	await process_frame
	var got := -1
	for a in (sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_workers" and String(a.get("shopId", "")) == sid:
			got = int(a["value"])
	if got != 0:
		_fail("拖到 0 之后没有入队 set_workers: 0（实际 %d）" % got)
		return

	# 2b. 升级时的用工目标重算：满员 → 继续满员；不满员 → 数字不变
	#     （研究所 maxWorkers=6、slotsPerLevel=3：L1=6 → L2=9）
	var s2 = sim._find_shop(sid)
	s2["level"] = 1
	s2["targetWorkers"] = 6   # 满员
	sim._apply_actions([{"type": "upgrade_test_noop"}])   # 占位：不实际下施工单
	var c := {"id": "c#upgrade", "kind": "upgrade", "buildingId": "research_institute",
		"shopId": sid, "housingId": "", "remaining": 0.0, "totalRequired": 1.0, "started": true}
	(sim.s["construction"] as Array).append(c)
	sim._activate_completed()
	if int(s2["level"]) != 2 or int(s2["targetWorkers"]) != 9:
		_fail("满员时升级：应保持满员(9)，实际 Lv%d/%d" % [int(s2["level"]), int(s2["targetWorkers"])])
		return
	# 不满员：L2(9) 时开 4 个，升到 L3(12) 应仍是 4
	s2["targetWorkers"] = 4
	(sim.s["construction"] as Array).append({
		"id": "c#upgrade2", "kind": "upgrade", "buildingId": "research_institute",
		"shopId": sid, "housingId": "", "remaining": 0.0, "totalRequired": 1.0, "started": true})
	sim._activate_completed()
	if int(s2["targetWorkers"]) != 4:
		_fail("不满员时升级：数字应保持 4（不按比例缩放），实际 %d" % int(s2["targetWorkers"]))
		return
	s2["level"] = 3   # 还原，后面的拆除断言按 L3 走
	s2["targetWorkers"] = 6

	# 3. 拆除：按钮 → 弹出确认窗口 → 点「确定拆除」才入队
	var demo := _find_button(ins, "拆除")
	if demo == null:
		_fail("建筑面板里没有「拆除」按钮")
		return
	demo.pressed.emit()
	await process_frame
	if _pending_types(sim).has("demolish"):
		_fail("点「拆除」就直接入队了 —— 确认弹窗没生效")
		return
	var yes := _find_button(ins, "确定拆除")
	if yes == null:
		_fail("点「拆除」之后没有弹出确认窗口（找不到「确定拆除」）")
		return
	# 弹窗里必须能取消
	if _find_button(ins, "取消") == null:
		_fail("确认窗口里没有「取消」")
		return

	# 3b. 退料 + 引擎真的移除。
	#
	# ⚠️ 这里**不能** tick 24 小时再看库存：那一整天里村庄自己也在消耗木材
	# （烧砖、木柴坊…），数字会漂，断言必然失败（第一版就是这么挂的）。
	# 直接调黎明用的那条 `_apply_actions`，把 demolish 单独应用 —— 同一条代码路径，
	# 但不掺进当天的生产/消费。
	var before_goods := {}
	for gid in (def.get("buildCost", {}) as Dictionary).keys():
		before_goods[gid] = float(sim.s["goods"].get(gid, 0.0))

	yes.pressed.emit()
	await process_frame
	if not _pending_types(sim).has("demolish"):
		_fail("确认之后没有入队 demolish")
		return
	sim._apply_actions(sim.s["pending"])
	sim.s["pending"] = []

	var still := false
	for s in sim.s["shops"]:
		if String(s["id"]) == sid:
			still = true
	if still:
		_fail("demolish 应用之后，被拆的建筑还在 state.shops 里")
		return
	for gid in before_goods.keys():
		var want := float(before_goods[gid]) + float(def["buildCost"][gid])
		var got2 := float(sim.s["goods"].get(gid, 0.0))
		if absf(got2 - want) > 0.05:
			_fail("拆除没退回 %s：期望 %.2f，实际 %.2f" % [gid, want, got2])
			return

	# 3c. 工人必须变回失业（assignLabor 现算的自然结果）
	sim._assign_labor()
	var orphans := 0
	for r in sim.s["residents"]:
		if String(r.get("jobShopId", "")) == sid:
			orphans += 1
	if orphans > 0:
		_fail("拆完了还有 %d 个工人挂在被拆的建筑上" % orphans)
		return

	print("WORKER TEST 有效工位(L3)=%d 拖动条max=%d 拖到0=%d 拆除=弹窗确认 引擎已移除 退料%s 工人已释放"
		% [expect, slider_max, got, before_goods.keys()])
	print("WORKER TEST RESULT: PASS")
	quit(0)
