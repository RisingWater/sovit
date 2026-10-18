extends SceneTree

# 「工业消耗 / 居民消耗」的悬停明细门槛（用户 2026-10）。
#
# 用户原话："资源面板里面，不是有工业消耗和居民消耗吗？我希望鼠标移过去可以看到，
# 工业消耗是哪类建筑多少个消耗了多少，比如面粉都是面包房消耗，写面包房 x3 消耗了 xx 面粉。
# 居民消耗应该是哪个等级的居民消耗了多少，比如中产 x11 消耗多少资源。"
#
# 所以这条门槛盯三件事：
#   1. **数据从哪来**：台账里真的有拆分表（`consumedBy` / `boughtBy`），
#      而且**加起来等于总量**（不然 tooltip 与上面那行大字对不上）；
#   2. **谁写的**：必须由引擎在真正扣料 / 成交的那一处写（这里跑真局验证，
#      不认 UI 自己算的数）；
#   3. **界面**：资源页那两行的 key 与数值都有 tooltip，内容里有"建筑名 ×N"
#      与"阶层名 ×N"，并且那个 N 就是村里真有的座数 / 人数。
#
# red 的含义：① 拆分表没写（tooltip 只能说"没有明细"）② 拆分加不出总量（数字打架）
# ③ 面板上没有 tooltip 或者 tooltip 里的座数/人数是编的。

const SEED := 20261018

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("CONSUMETIP TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame
	var world = node.get("world")
	world.start_new_game(SEED, 1.0, "消耗明细")
	await process_frame
	var runner = node.get("runner")
	var sim = runner.sim
	# 造一条真的会吃料的链：小麦农场 ×2 → 粗面粉磨坊 → 粗面包房
	# （磨坊吃小麦、面包房吃粗面粉；居民买粗面包 → 两条拆分表都有内容）
	# ⚠️ 必须用**完整字段**建 shop（wageCap / skill 少了会在夜结算里报错）
	for def_id in ["wheat_farm", "wheat_farm", "coarse_mill", "coarse_bakery"]:
		var shops: Array = sim.s["shops"]
		var d: Dictionary = runner.db.buildings[def_id]
		shops.append({
			"id": "%s#t%d" % [def_id, shops.size() + 1],
			"defId": def_id,
			"owner": "state",
			"targetWorkers": int(d["workers"]),
			"wage": float(runner.db.economy["refWage"]),
			"wageCap": float(runner.db.economy["defaultWageCap"]),
			"level": 1,
			"active": true,
			"profit": 0.0,
			"skill": 50.0,
			"planned": 0.0,
		})
	# 12 个居民不够 4 座建筑铺满（农场就吃掉 6+6）—— 加人、并把工位压到 3，
	# 让"磨坊吃小麦、面包房吃粗面粉"真的发生（否则工业消耗是 0，测不到拆分表）。
	for _i in 18:
		(sim.s["residents"] as Array).append({
			"id": "res#t%d" % ((sim.s["residents"] as Array).size() + 1),
			"classId": "poor", "savings": 40.0, "satisfaction": 72.0,
			"skill": 50.0, "employed": false,
		})
	for shop in (sim.s["shops"] as Array):
		if String(shop["id"]).contains("#t"):
			shop["targetWorkers"] = 3
	sim.s["goods"]["wheat"] = 400.0
	sim.s["goods"]["wood"] = 400.0
	# 跑一天（卯时 → 夜里结算写台账）
	for h in 24:
		sim.tick_hour([])
	await process_frame
	await process_frame

	var hist: Array = sim.s["history"]
	if hist.is_empty():
		_fail("跑了一天却没有 history 快照")
		return
	var led: Dictionary = (hist[hist.size() - 1] as Dictionary).get("ledger", {})
	if not led.has("consumedBy") or not led.has("boughtBy"):
		_fail("台账里没有 consumedBy / boughtBy 拆分表（引擎没写）")
		return

	# ---- 1. 工业消耗：拆分表必须加起来等于总量 ------------------------------
	var ind_total := 0.0
	var ind_rows := 0
	for gid in (led.get("consumedBy", {}) as Dictionary).keys():
		var by: Dictionary = led["consumedBy"][gid]
		var sum := 0.0
		for def_id in by.keys():
			sum += float(by[def_id])
			ind_rows += 1
		var total := float((led.get("consumed", {}) as Dictionary).get(gid, 0.0))
		if total <= 0.001:
			continue
		ind_total += total
		if absf(sum - total) > 0.05:
			_fail("「%s」的工业消耗拆分加起来是 %.2f，总量是 %.2f（数字打架）"
				% [gid, sum, total])
			return
	if ind_total <= 0.0 or ind_rows == 0:
		_fail("这一天没有任何工业消耗（测不到拆分表）")
		return
	print("CONSUMETIP TEST 工业消耗：%d 条拆分，合计 %.1f（与总量一致）✅" % [ind_rows, ind_total])

	# ---- 2. 居民消耗：同上 -------------------------------------------------
	var pop_total := 0.0
	var pop_rows := 0
	for gid in (led.get("boughtBy", {}) as Dictionary).keys():
		var by: Dictionary = led["boughtBy"][gid]
		var sum := 0.0
		for cid in by.keys():
			sum += float(by[cid])
			pop_rows += 1
		var total := float((led.get("bought", {}) as Dictionary).get(gid, 0.0))
		if total <= 0.001:
			continue
		pop_total += total
		if absf(sum - total) > 0.05:
			_fail("「%s」的居民消耗拆分加起来是 %.2f，总量是 %.2f（数字打架）"
				% [gid, sum, total])
			return
	if pop_total <= 0.0 or pop_rows == 0:
		_fail("这一天没有任何居民购买（测不到阶层拆分）")
		return
	print("CONSUMETIP TEST 居民消耗：%d 条拆分，合计 %.1f（与总量一致）✅" % [pop_rows, pop_total])

	# ---- 3. 界面：资源页那两行有 tooltip，内容是"名字 ×N 数量" --------------
	var panel = node.get_node_or_null("UI/Root/Stats")
	if panel == null:
		_fail("找不到 UI/Root/Stats")
		return
	# 选一个真的被工业消耗过的商品（优先粗面粉：面包房吃它）
	var pick := ""
	var best := 0.0
	for gid in (led.get("consumedBy", {}) as Dictionary).keys():
		var t := float((led.get("consumed", {}) as Dictionary).get(gid, 0.0))
		if t > best:
			best = t
			pick = String(gid)
	if pick == "":
		_fail("没有「被工业消耗过」的商品可选")
		return
	panel.open()
	await process_frame
	panel._on_pick_good(pick)
	for i in 3:
		await process_frame
	var stats = panel.get("stats")
	var tip: String = stats.industrial_tip(pick)
	if tip == "" or not tip.contains("工业消耗"):
		_fail("工业消耗的 tooltip 是空的或不含标题（%s）" % tip)
		return
	var any_building := false
	for def_id in ((led["consumedBy"][pick] as Dictionary).keys()):
		var bname := String(runner.db.buildings[def_id]["nameZh"])
		var cnt := 0
		for shop in (sim.s["shops"] as Array):
			if String(shop["defId"]) == String(def_id):
				cnt += 1
		if not tip.contains(bname):
			_fail("工业消耗 tooltip 里没有「%s」（实际：%s）" % [bname, tip])
			return
		if not tip.contains("%s ×%d" % [bname, cnt]):
			_fail("工业消耗 tooltip 里「%s」的座数不是村里的 %d 座（实际：%s）"
				% [bname, cnt, tip])
			return
		any_building = true
	if not any_building:
		_fail("这块商品的工业消耗没有任何建筑来源")
		return
	var rtip: String = stats.resident_tip(pick)
	if rtip == "" or not rtip.contains("居民消耗"):
		_fail("居民消耗的 tooltip 是空的或不含标题（%s）" % rtip)
		return
	print("CONSUMETIP TEST 工业消耗 tooltip：「%s」" % tip.replace("\n", " / "))

	# 居民那半：挑一个"居民买过"的商品，验阶层名 + 人数
	var pick2 := ""
	var best2 := 0.0
	for gid in (led.get("boughtBy", {}) as Dictionary).keys():
		var t2 := float((led.get("bought", {}) as Dictionary).get(gid, 0.0))
		if t2 > best2:
			best2 = t2
			pick2 = String(gid)
	var tip2: String = stats.resident_tip(pick2)
	if not tip2.contains("居民消耗"):
		_fail("居民消耗的 tooltip 不含标题（%s）" % tip2)
		return
	var any_class := false
	for cid in ((led["boughtBy"][pick2] as Dictionary).keys()):
		var cname := String(runner.db.classes[cid]["nameZh"])
		var cnt := 0
		for r in (sim.s["residents"] as Array):
			if String(r["classId"]) == String(cid):
				cnt += 1
		if not tip2.contains(cname):
			_fail("居民消耗 tooltip 里没有阶层「%s」（实际：%s）" % [cname, tip2])
			return
		if not tip2.contains("%s ×%d" % [cname, cnt]):
			_fail("居民消耗 tooltip 里「%s」的人数不是村里的 %d 人（实际：%s）"
				% [cname, cnt, tip2])
			return
		any_class = true
	if not any_class:
		_fail("这块商品的居民消耗没有任何阶层来源")
		return
	print("CONSUMETIP TEST 居民消耗 tooltip：「%s」" % tip2.replace("\n", " / "))

	# ---- 4. 面板上真的挂着 tooltip（不是只有函数）--------------------------
	var found := 0
	for c in panel.find_children("*", "Label", true, false):
		var lb := c as Label
		if lb.tooltip_text.contains("工业消耗") or lb.tooltip_text.contains("居民消耗"):
			found += 1
	if found < 2:
		_fail("资源页上没有挂 tooltip 的标签（找到 %d 个，至少该有 2 个：工业/居民）" % found)
		return
	print("CONSUMETIP TEST 面板：%d 个标签挂着消耗明细 tooltip ✅" % found)

	print("CONSUMETIP TEST RESULT: PASS")
	quit(0)
