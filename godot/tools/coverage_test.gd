extends SceneTree

# 覆盖门槛（用户 2026-10 第二批）。
#
# 口径与 TS `scripts/check-coverage.ts` 完全一致：
#   · "学校根据人口，一座覆盖 100 人口，有覆盖就加成"
#   · "治安、诊所（医院）也是，一座覆盖 50 人，有覆盖才加成满意度"
#   · 医疗 / 教育只惠及中产以上；治安四阶层都有
#
# red 的含义：① 覆盖人数算错（应当是 建筑 × N × 等级）
#              ② 覆盖率不封顶 / 没人时不为 0
#              ③ 没原料（排不上产）还能覆盖 —— 服务"凭空开着门"
#              ④ 穷人拿到了医疗/教育加成（用户明确说只给中产以上）
#              ⑤ 学校没加速熟练度成长
#              ⑥ 覆盖率被写进了存档（应当每次现算）

const SEED := 20261022

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("COVERAGE TEST FAIL: ", msg)
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
	world.start_new_game(SEED, 1.0, "覆盖测试")
	await process_frame
	var runner = node.get("runner")
	var db = runner.db
	var sim = runner.sim

	# ---- 1. 覆盖人数与覆盖率（100 人 / 2 诊所 + 1 学校）----------------------
	_make_village(sim, 100, true)
	_clear_shops(sim)
	_add_shop(sim, db, "clinic", "c1")
	_add_shop(sim, db, "clinic", "c2")
	_add_shop(sim, db, "school", "s1")
	_hire(sim, 0, 2, "c1")
	_hire(sim, 2, 2, "c2")
	_hire(sim, 4, 3, "s1")
	_plan(sim, "c1")
	_plan(sim, "c2")
	_plan(sim, "s1")

	var cov: Dictionary = sim.coverage_ratios()
	if not _approx(float(cov["medical"]), 1.0):
		_fail("100 人 / 2 座诊所（50+50）→ 医疗覆盖 %.2f，应当是 1.0" % float(cov["medical"]))
		return
	if not _approx(float(cov["education"]), 1.0):
		_fail("100 人 / 1 座学校（100 人）→ 教育覆盖 %.2f，应当是 1.0" % float(cov["education"]))
		return
	if int(sim.covered_people("medical")) != 100:
		_fail("医疗覆盖人数 %d，应当是 100（2 × 50）" % int(sim.covered_people("medical")))
		return
	if not _approx(float(cov["safety"]), 0.0):
		_fail("本批还没实装治安所，治安覆盖应当是 0（实际 %.2f）" % float(cov["safety"]))
		return
	print("COVERAGE TEST 覆盖：2 座诊所 + 1 座学校 → 医疗 100%% / 教育 100%% / 治安 0%% ✅")

	# ---- 2. 覆盖率封顶（20 人配一座医院 = 150 人）----------------------------
	_make_village(sim, 20, false)
	_clear_shops(sim)
	_add_shop(sim, db, "hospital", "h1")
	_hire(sim, 0, 4, "h1")
	_plan(sim, "h1")
	if not _approx(float(sim.coverage_ratios()["medical"]), 1.0):
		_fail("20 人配一座医院（150 人）→ 覆盖率应当封顶 1.0（实际 %.2f）"
			% float(sim.coverage_ratios()["medical"]))
		return
	print("COVERAGE TEST 封顶：20 人 / 医院 150 人 → 1.0 ✅")

	# ---- 3. 缺原料 → 排不上产 → 覆盖归零 ------------------------------------
	_make_village(sim, 60, false)
	_clear_shops(sim)
	_add_shop(sim, db, "clinic", "c1")
	_hire(sim, 0, 2, "c1")
	# planned 保持 0（= 没药水，黎明排不上产）
	if int(sim.covered_people("medical")) != 0:
		_fail("排不上产（没药水）还能覆盖 %d 人 —— 服务不该凭空开着门"
			% int(sim.covered_people("medical")))
		return
	print("COVERAGE TEST 断供：没药水 → 排不上产 → 覆盖 0 人 ✅")

	# ---- 4. 医疗/教育只给中产以上（纯函数）----------------------------------
	var ecfg: Dictionary = db.economy["coverage"]
	var full := {"medical": 1.0, "education": 1.0, "safety": 1.0}
	var want_poor := float(ecfg["safety"])
	var want_rich := float(ecfg["medical"]) + float(ecfg["education"]) + float(ecfg["safety"])
	var got_poor: float = sim._coverage_sat_bonus(full, "poor")
	var got_rich: float = sim._coverage_sat_bonus(full, "middle")
	if not _approx(got_poor, want_poor):
		_fail("穷人只该拿治安加成 %.2f，实际 %.2f" % [want_poor, got_poor])
		return
	if not _approx(got_rich, want_rich):
		_fail("中产该拿医疗+教育+治安 %.2f，实际 %.2f" % [want_rich, got_rich])
		return
	print("COVERAGE TEST 阶层：穷人只有治安 +%.0f，中产医疗+教育+治安 +%.0f ✅"
		% [want_poor, want_rich])

	# ---- 5. 学校加速熟练度成长（满覆盖 ×1.5）--------------------------------
	_make_village(sim, 100, true)
	_clear_shops(sim)
	_add_shop(sim, db, "school", "s1")
	_hire(sim, 0, 3, "s1")
	_plan(sim, "s1")
	for r in (sim.s["residents"] as Array):
		r["employed"] = true
	var before: float = float((sim.s["residents"] as Array)[0]["skill"])
	sim._grow_skills()
	var gain: float = float((sim.s["residents"] as Array)[0]["skill"]) - before
	var base := float(db.economy["skillGainPerDay"])
	if not _approx(gain, base * 1.5, 0.001):
		_fail("满覆盖时熟练度成长 %.3f/日，应当是 %.3f（基础 %.2f × 1.5）" % [gain, base * 1.5, base])
		return
	print("COVERAGE TEST 学校：满覆盖时熟练度成长 %.2f/日（基础 %.2f × 1.5）✅" % [gain, base])

	# ---- 6. 覆盖率不写进 state ---------------------------------------------
	if (sim.s as Dictionary).has("coverage"):
		_fail("覆盖率被写进了 state —— 它应当每次现算（不动存档）")
		return
	print("COVERAGE TEST 存档：state 里没有 coverage 字段（每次现算）✅")

	print("COVERAGE TEST RESULT: PASS")
	quit(0)

func _make_village(sim, n: int, middle_half: bool) -> void:
	var arr: Array = []
	for i in n:
		var cid := "middle" if (middle_half and i < int(ceil(float(n) / 2.0))) else "poor"
		arr.append({
			"id": "res#c%d" % i, "classId": cid, "savings": 50.0,
			"satisfaction": 60.0, "skill": 30.0, "employed": false,
		})
	sim.s["residents"] = arr

func _clear_shops(sim) -> void:
	sim.s["shops"] = []

func _add_shop(sim, db, def_id: String, id: String) -> void:
	var d: Dictionary = db.buildings[def_id]
	(sim.s["shops"] as Array).append({
		"id": id, "defId": def_id, "owner": "state",
		"targetWorkers": int(d["workers"]),
		"wage": float(db.economy["refWage"]),
		"wageCap": float(db.economy["defaultWageCap"]),
		"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})

func _hire(sim, from: int, n: int, shop_id: String) -> void:
	var res: Array = sim.s["residents"]
	for i in range(from, mini(from + n, res.size())):
		res[i]["employed"] = true
		res[i]["jobShopId"] = shop_id

func _plan(sim, shop_id: String) -> void:
	for sh in (sim.s["shops"] as Array):
		if String(sh["id"]) == shop_id:
			sh["planned"] = 1.0
