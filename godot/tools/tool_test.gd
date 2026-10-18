extends SceneTree

# 工具（石制工具）门槛：**消耗换产能**（用户 2026-10）。
#
# 用户原话："石制工具如果有可以消耗提升农业/工业/矿场产能的逻辑做一下。
# 之前好像说一个工人 10 天消耗 1 工具。"
#
# 所以这条盯五件事：
#   1. 汇率：`economy.tools.perWorkstation == 0.1` → **一个工人 10 天 1 件**
#   2. 黎明装配：有工具 → 那栋建筑 `toolBoost == 1.25`，库存扣 `0.1 × 在岗人数`，
#      台账 `consumed` 与 `consumedBy` 都记上（资源页的悬停明细要读它）
#   3. 三类都吃：农业 / 工业 / 矿场（有配方 + 开工 + 在岗有人）一视同仁
#   4. 真的提升产能：**产出 ×1.25、投入一件不多**（"虚空产量"）
#   5. 边界：没工具就不加成；空工坊（没人）不扣工具；不够时按 shops 顺序先到先得
#
# red 的含义：① 汇率被改回去了（又变成 20 天 1 件）② 工具白扣了却没加成（或反之）
# ③ 只有某个产业吃工具 ④ 投入跟着放大（那不是"成品率提高"，是整体放大）
# ⑤ 不够时随机分配（golden 会随机漂）。

const SEED := 20261019

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("TOOL TEST FAIL: ", msg)
	quit(1)

func _approx(a: float, b: float, eps: float = 0.001) -> bool:
	return absf(a - b) <= eps

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
	world.start_new_game(SEED, 1.0, "工具测试")
	await process_frame
	var runner = node.get("runner")
	var db = runner.db
	var sim = runner.sim

	# ---- 1. 汇率：一个工人 10 天 1 件 ---------------------------------------
	var per := float(db.economy["tools"]["perWorkstation"])
	if not _approx(per, 0.1):
		_fail("perWorkstation 是 %.3f，应当是 0.1（一个工人 10 天 1 件）" % per)
		return
	if int(round(1.0 / per)) != 10:
		_fail("换算成天数不是 10 天 1 件（1/%.3f = %.1f）" % [per, 1.0 / per])
		return
	if db.tool_bonus("stone_tools") <= 0.0:
		_fail("石制工具没有 toolBonus（工具就没有意义了）")
		return
	print("TOOL TEST 汇率：perWorkstation=%.2f → 一个工人 %d 天 1 件，产出 ×%.2f ✅" % [
		per, int(round(1.0 / per)), 1.0 + db.tool_bonus("stone_tools")])

	# ---- 2/3. 三类各建一座，给足工具，过一个黎明 ----------------------------
	# agri = 小麦农场（农田）、goods = 粗面包房、material = 采石场（要建在石矿上）
	var made := {}
	for def_id in ["wheat_farm", "coarse_bakery", "quarry"]:
		var d: Dictionary = db.buildings[def_id]
		var shops: Array = sim.s["shops"]
		sim.s["shops"].append({
			"id": "t_%s" % def_id, "defId": def_id, "owner": "state",
			"targetWorkers": int(d["workers"]),
			"wage": float(db.economy["refWage"]),
			"wageCap": float(db.economy["defaultWageCap"]),
			"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		})
		made[def_id] = "t_%s" % def_id
	# 人口够三座（12 + 8）
	for _i in 8:
		(sim.s["residents"] as Array).append({
			"id": "res#tool%d" % ((sim.s["residents"] as Array).size() + 1),
			"classId": "poor", "savings": 30.0, "satisfaction": 70.0,
			"skill": 50.0, "employed": false,
		})
	sim.s["goods"]["stone_tools"] = 100.0
	sim._run_dawn()
	var boosted := 0
	var consumed_by := 0.0
	for def_id in made.keys():
		var sid := String(made[def_id])
		var shop = null
		for sh in (sim.s["shops"] as Array):
			if String(sh["id"]) == sid:
				shop = sh
		if shop == null:
			_fail("找不到刚建的 %s" % def_id)
			return
		var workers: int = int(sim._assigned_workers(sid))
		var tb := float(shop.get("toolBoost", 1.0))
		if workers <= 0:
			_fail("%s 没分到工人（人口不够，测不了工具）" % def_id)
			return
		if not _approx(tb, 1.25):
			_fail("%s（%s）的 toolBoost 是 %.2f，应当是 1.25（有工具却没用上）"
				% [def_id, String(db.buildings[def_id]["sector"]), tb])
			return
		boosted += 1
		consumed_by += per * float(workers)
	if boosted < 3:
		_fail("农业 / 工业 / 矿场三类没有全部装配上工具（只装配了 %d 座）" % boosted)
		return
	var used := 100.0 - float(sim.s["goods"]["stone_tools"])
	if not _approx(used, SimUtil.r2(consumed_by), 0.02):
		_fail("扣的工具是 %.2f 件，按 0.1×在岗人数应当是 %.2f 件" % [used, consumed_by])
		return
	# 台账：总量与拆分表都要有，而且拆分的和 == 总量
	var led: Dictionary = sim.s["ledgerToday"]
	var total: float = float((led.get("consumed", {}) as Dictionary).get("stone_tools", 0.0))
	if not _approx(total, used, 0.02):
		_fail("台账 consumed[stone_tools] 是 %.2f，实际扣了 %.2f" % [total, used])
		return
	var by: Dictionary = (led.get("consumedBy", {}) as Dictionary).get("stone_tools", {})
	var by_sum := 0.0
	for k in by.keys():
		by_sum += float(by[k])
	if not _approx(by_sum, total, 0.02):
		_fail("台账 consumedBy[stone_tools] 加起来 %.2f，总量 %.2f（面板明细会打架）"
			% [by_sum, total])
		return
	for def_id in made.keys():
		if not by.has(String(def_id)):
			_fail("台账 consumedBy[stone_tools] 里没有「%s」（资源页看不到它吃了工具）" % def_id)
			return
	print("TOOL TEST 装配：农业/工业/矿场 %d 座全部 ×1.25，共扣 %.2f 件（台账总量与拆分表一致）✅"
		% [boosted, used])

	# ---- 4. 产出 ×1.25、投入不变 -------------------------------------------
	# 直接拿同一座面包房跑一个"整天"的生产步：toolBoost 1.25 vs 1.0 各跑一次
	var bakery := String(made["coarse_bakery"])
	var before_tools := float(sim.s["goods"].get("stone_tools", 0.0))
	var run_a: Dictionary = _produce_once(sim, bakery, 1.25)
	var run_b: Dictionary = _produce_once(sim, bakery, 1.0)
	var out_a := float(run_a["out"])
	var out_b := float(run_b["out"])
	var ratio := out_a / out_b if out_b > 0.0 else 0.0
	if out_b <= 0.0:
		_fail("没装工具时面包房一点都不产（planned/原料没配好，测不了倍率）")
		return
	if not _approx(ratio, 1.25, 0.01):
		_fail("装配工具后的产出是没有工具的 %.3f 倍，应当是 1.25 倍（%.3f vs %.3f）"
			% [ratio, out_a, out_b])
		return
	var in_a: Dictionary = run_a["inputs"]
	var in_b: Dictionary = run_b["inputs"]
	for gid in in_a.keys():
		if not _approx(float(in_a[gid]), float(in_b.get(gid, 0.0)), 0.01):
			_fail("「%s」的投入跟着变了（%.2f vs %.2f）—— 工具只该放大产出"
				% [gid, float(in_a[gid]), float(in_b.get(gid, 0.0))])
			return
	print("TOOL TEST 产能：产出 ×%.2f、投入不变 ✅" % ratio)

	# ---- 5a. 没工具就不加成 -------------------------------------------------
	sim.s["goods"]["stone_tools"] = 0.0
	# 把工具预留也清掉（上一步的生产步可能留了 reserved）
	sim.s["reserved"]["stone_tools"] = 0.0
	sim._run_dawn()
	for def_id in made.keys():
		var sid2 := String(made[def_id])
		for sh in (sim.s["shops"] as Array):
			if String(sh["id"]) == sid2:
				if not _approx(float(sh.get("toolBoost", 1.0)), 1.0):
					_fail("库存 0 件工具时 %s 还是装配着的（toolBoost=%.2f）"
						% [def_id, float(sh.get("toolBoost", 1.0))])
					return
	print("TOOL TEST 无工具：不装配、不加成 ✅")

	# ---- 5b. 空工坊不扣工具；不够时先到先得 --------------------------------
	var s3 = sim
	# 只留一座工坊有人：把面包房的 targetWorkers 设 0
	for sh in (s3.s["shops"] as Array):
		if String(sh["id"]) == bakery:
			sh["targetWorkers"] = 0
	s3.s["goods"]["stone_tools"] = 100.0
	s3._run_dawn()
	for sh in (s3.s["shops"] as Array):
		if String(sh["id"]) == bakery:
			if not _approx(float(sh.get("toolBoost", 1.0)), 1.0):
				_fail("没人上工的 %s 也装配了工具（工位 0 不该扣）" % bakery)
				return
	# 只够一座：农场（shops 里排在前面）应当拿到，面包房拿不到
	s3.s["goods"]["stone_tools"] = 0.4
	for sh in (s3.s["shops"] as Array):
		if String(sh["id"]) == String(made["wheat_farm"]):
			var w: int = int(s3._assigned_workers(String(sh["id"])))
			s3.s["goods"]["stone_tools"] = per * float(w) + 0.05
	s3._run_dawn()
	var farm_boost := 1.0
	for sh in (s3.s["shops"] as Array):
		if String(sh["id"]) == String(made["wheat_farm"]):
			farm_boost = float(sh.get("toolBoost", 1.0))
	if not _approx(farm_boost, 1.25):
		_fail("只够一座时，排在前面那座（小麦农场）应当拿到工具，实际 toolBoost=%.2f"
			% farm_boost)
		return
	print("TOOL TEST 边界：空工坊不扣、不够时先到先得（%s 装配）✅" % made["wheat_farm"])

	print("TOOL TEST RESULT: PASS")
	quit(0)

## 让一座工坊以固定 toolBoost 跑一次生产步（fraction=1），
## 返回 `{out: 主产出增量, inputs: {商品: 本次投入量}}`。
## ⚠️ 投入必须用**台账的差分**：`consumed` 是当天累计值，直接读会读到上一次的。
func _produce_once(sim, shop_id: String, boost: float) -> Dictionary:
	var shop = null
	for sh in (sim.s["shops"] as Array):
		if String(sh["id"]) == shop_id:
			shop = sh
	if shop == null:
		return {"out": 0.0, "inputs": {}}
	var def: Dictionary = sim.db.buildings[String(shop["defId"])]
	var rid := String(def.get("recipe", ""))
	var recipe: Dictionary = sim.db.recipes.get(rid, {})
	var out_map: Dictionary = recipe.get("output", {})
	if out_map.is_empty():
		return {"out": 0.0, "inputs": {}}
	shop["toolBoost"] = boost
	shop["planned"] = 10.0
	# 原料管够，免得"缺料"把产量压成 0
	for g in (recipe.get("inputs", {}) as Dictionary).keys():
		sim.s["goods"][String(g)] = maxf(float(sim.s["goods"].get(String(g), 0.0)), 500.0)
	var led: Dictionary = sim.s["ledgerToday"]["consumed"]
	var before_in := {}
	for g in (recipe.get("inputs", {}) as Dictionary).keys():
		before_in[String(g)] = float(led.get(String(g), 0.0))
	var gid := String((out_map as Dictionary).keys()[0])
	var before := float(sim.s["goods"].get(gid, 0.0))
	sim._run_production_step(1.0)
	var inputs := {}
	for g in before_in.keys():
		inputs[g] = float(led.get(g, 0.0)) - float(before_in[g])
	return {"out": float(sim.s["goods"].get(gid, 0.0)) - before, "inputs": inputs}
