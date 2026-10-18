extends SceneTree

# 需求系统门槛（2026-10 定稿，见 docs/needs.md）。与 TS `scripts/check-needs.ts` 同口径。
#
# 盯的是"内容与规则的契约"：
#   1. 治安 / 医疗 / 教育是**三件独立商品**（各自价格 0.3 / 0.5 / 0.5，当日归零）
#   2. 四阶层的需求集合就是晋升阶梯（穷人只要治安；医疗从中学起；教育从富起）
#   3. 单座建筑产量够养一大片（诊所 20 / 医院 60 / 学校 20 / 治安所 20 / 瞭望台 10）
#   4. 治安所**不吃武器**（否则开局到民兵之前没人能升中产）
#   5. 岗位工资：公共事业统一 3.6、私营按 tier（3.0 / 3.6 / 4.5）

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("NEEDS TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var db = load("res://scripts/core/content_db.gd").load_all()

	# ---- 1. 三项服务 ------------------------------------------------------
	var want := {"safety": 0.3, "medical_service": 0.5, "education": 0.5}
	for gid in want.keys():
		if not db.goods.has(gid):
			_fail("内容里没有 %s" % gid)
			return
		var g: Dictionary = db.goods[gid]
		if String(g.get("category", "")) != "service":
			_fail("%s 的 category 应当是 service（实际 %s）" % [gid, g.get("category", "")])
			return
		if bool(g.get("storable", true)):
			_fail("%s 应当不可储存（当日归零）" % gid)
			return
		if absf(float(g.get("baseValue", 0.0)) - float(want[gid])) > 0.001:
			_fail("%s 的基准价是 %.2f，应当是 %.2f" % [gid, float(g.get("baseValue", 0.0)), float(want[gid])])
			return
	if not db.goods.has("weapons"):
		_fail("内容里没有 weapons（留给以后的兵营）")
		return
	print("NEEDS TEST 服务：治安 0.3 / 医疗 0.5 / 教育 0.5，都是独立且当日归零的商品 ✅")

	# ---- 2. 需求集合 = 晋升阶梯 -------------------------------------------
	var need := func(cls: String, gid: String) -> float:
		var total := 0.0
		for n in (db.classes[cls].get("needs", []) as Array):
			if String(n["good"]) == gid:
				total += float(n["perCapita"])
		return total
	if need.call("poor", "safety") <= 0.0:
		_fail("穷人应当要治安")
		return
	if need.call("poor", "medical_service") > 0.0 or need.call("poor", "education") > 0.0:
		_fail("穷人**不**该要医疗 / 教育")
		return
	if need.call("middle", "medical_service") <= 0.0 or need.call("middle", "education") > 0.0:
		_fail("中产要医疗、不要教育")
		return
	if need.call("rich", "education") <= 0.0 or need.call("rich", "entertainment") > 0.05:
		_fail("富人要教育、娱乐应当已砍到 ≤ 0.05")
		return
	if need.call("rich", "domestic_service") > 0.0:
		_fail("家政只有老板要")
		return
	if need.call("boss", "domestic_service") <= 0.0 or need.call("boss", "domestic_service") > 0.1:
		_fail("老板要家政且应当 ≤ 0.1")
		return
	print("NEEDS TEST 阶梯：穷人治安 → 中产医疗 → 富人教育+娱乐 → 老板家政 ✅")

	# ---- 3. 产能 ---------------------------------------------------------
	var out_of := func(bid: String) -> float:
		var def: Dictionary = db.buildings[bid]
		var rec: Dictionary = db.recipes.get(String(def.get("recipe", "")), {})
		var best := 0.0
		for k in (rec.get("output", {}) as Dictionary).keys():
			best = maxf(best, float(rec["output"][k]))
		return best
	var want_out := {"clinic": 20.0, "hospital": 60.0, "school": 20.0, "guard_station": 20.0, "watchtower": 10.0}
	for bid in want_out.keys():
		if absf(out_of.call(bid) - float(want_out[bid])) > 0.001:
			_fail("%s 产量 %.1f，应当是 %.1f" % [bid, out_of.call(bid), float(want_out[bid])])
			return
	var gs: Dictionary = db.recipes.get(String(db.buildings["guard_station"].get("recipe", "")), {})
	if (gs.get("inputs", {}) as Dictionary).size() != 0:
		_fail("治安所不该有输入（不然开局到民兵之前没人能满足治安）")
		return
	print("NEEDS TEST 产能：诊所 20 / 医院 60 / 学校 20 / 治安所 20 / 瞭望台 10，治安所零输入 ✅")

	# ---- 4. 岗位工资 ------------------------------------------------------
	var pub := ["research_institute", "construction_works", "clinic", "hospital", "school",
		"guard_station", "watchtower"]
	var pub_wage := float(db.economy.get("publicServiceWage", 3.6))
	for bid in pub:
		if absf(db.default_wage(bid) - pub_wage) > 0.001:
			_fail("%s 默认工资 %.2f，应当是公共事业统一 %.2f" % [bid, db.default_wage(bid), pub_wage])
			return
	var priv := {"wheat_farm": 3.0, "coarse_mill": 3.6, "theater": 4.5}
	for bid in priv.keys():
		if absf(db.default_wage(bid) - float(priv[bid])) > 0.001:
			_fail("%s 默认工资 %.2f，应当是 %.2f（按 tier）" % [bid, db.default_wage(bid), float(priv[bid])])
			return
	print("NEEDS TEST 工资：公共事业统一 %.1f，私营按 tier 3.0 / 3.6 / 4.5 ✅" % pub_wage)

	# ---- 5. 晋升 / 降级规则 ------------------------------------------------
	# 规则本体在 sim_core 的 _update_classes（needsMet = 1.0 才升、连续 3 天 < 0.8 才降），
	# 这里只钉"两个常量写在代码里且可被读到"，行为由 quest/tool 门槛里的日常回归覆盖。
	var src := FileAccess.get_file_as_string("res://scripts/sim/sim_core.gd")
	if not src.contains("var demote_days := 3"):
		_fail("sim_core 里找不到降级宽限期（应当是 3 天）")
		return
	if not src.contains("demote_ratio := 0.8"):
		_fail("sim_core 里找不到降级阈值（应当是 0.8）")
		return
	if not src.contains("met >= 1.0 and float(r[\"savings\"]) >= float(nxt[\"wealthThreshold\"])"):
		_fail("sim_core 里找不到晋升条件（needsMet >= 1.0 且存款够）")
		return
	print("NEEDS TEST 流动：晋升 needsMet = 1.0 且存款够；降级连续 3 天 < 0.8 ✅")

	print("NEEDS TEST RESULT: PASS")
	quit(0)
