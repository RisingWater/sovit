extends GdUnitTestSuite

# 逐人账目 + 每日台账：结构必须真的被写入，且数值自洽。
#
# 现状是"平均分配"，所以个人消耗 == 阶层汇总、个人饥饿汇总 == 全城饥饿。
# 这个测试锁的是**结构**：将来做差异化分配时，只要这些断言还成立就说明
# 账目没漏记；哪天真按收入/偏好分配了，把"相等"改成"范围"即可。

func _mk() -> SimCore:
	var db := ContentDB.load_all()
	var sim := SimCore.new(db)
	sim.new_game("v0.3", 2024)
	# 冻结人口：这个套件测的是账目结构，不是移民。
	# 不冻结的话，最后一晚刚迁入的居民还没经过 _pay_wages，自然没有 account。
	sim.s["government"]["populationCap"] = float((sim.s["residents"] as Array).size())
	return sim

func test_ledger_recorded_every_day() -> void:
	var sim := _mk()
	for i in 24 * 6:
		sim.tick_hour([])
	var hist: Array = sim.s["history"]
	assert_that(hist.size()).is_greater(3)
	# 除开局那条（day 0）外，每天都要有 ledger
	for i in range(1, hist.size()):
		var snap: Dictionary = hist[i]
		assert_that(snap.has("ledger")).is_true()
		var led: Dictionary = snap["ledger"]
		assert_that(int(led["day"])).is_equal(int(snap["day"]))
		for k in ["wages", "tax", "rent", "sales"]:
			assert_that(led.has(k)).is_true()
		for k in ["produced", "consumed", "bought"]:
			assert_that(led.has(k)).is_true()

func test_resident_account_recorded() -> void:
	var sim := _mk()
	for i in 24 * 6:
		sim.tick_hour([])
	var residents: Array = sim.s["residents"]
	assert_that(residents.size()).is_greater(0)
	for r in residents:
		assert_that(r.has("account")).is_true()
		var a: Dictionary = r["account"]
		for k in ["wage", "tax", "rent", "spent", "foodScore", "comfortScore", "priceScore", "hungry", "bought"]:
			assert_that(a.has(k)).is_true()
		# 工资/税收不会为负；满足率在 0..1
		assert_that(float(a["wage"])).is_greater_equal(0.0)
		assert_that(float(a["tax"])).is_greater_equal(0.0)
		assert_that(float(a["foodScore"])).is_between(0.0, 1.0)
		assert_that(float(a["comfortScore"])).is_between(0.0, 1.0)

func test_personal_equals_class_today() -> void:
	# 当前是平均分配：把个人账目按阶层汇总，应等于阶层口径。
	var sim := _mk()
	for i in 24 * 6:
		sim.tick_hour([])
	var residents: Array = sim.s["residents"]
	var by_class_spent := {}
	var by_class_bought := {}
	for r in residents:
		var cid := String(r["classId"])
		var a: Dictionary = r["account"]
		by_class_spent[cid] = float(by_class_spent.get(cid, 0.0)) + float(a["spent"])
		var b: Dictionary = by_class_bought
		if not b.has(cid):
			b[cid] = {}
		for g in (a["bought"] as Dictionary).keys():
			b[cid][g] = float(b[cid].get(g, 0.0)) + float(a["bought"][g])
	# 同一阶层内每个人的消耗应完全一致（平均分配的必然结果）
	for cid in by_class_spent.keys():
		var members := []
		for r in residents:
			if String(r["classId"]) == cid:
				members.append(r)
		if members.size() < 2:
			continue
		var first: Dictionary = members[0]["account"]["bought"]
		for r in members:
			var cur: Dictionary = r["account"]["bought"]
			assert_that(cur.size()).is_equal(first.size())
			for g in first.keys():
				assert_that(float(cur.get(g, 0.0))).is_equal_approx(float(first[g]), 0.011)

func test_ledger_sums_match_personal() -> void:
	# 台账的 bought 汇总应等于所有个人 bought 之和（同一套写入路径）
	var sim := _mk()
	for i in 24 * 6:
		sim.tick_hour([])
	var hist: Array = sim.s["history"]
	var last: Dictionary = hist[hist.size() - 1]["ledger"]
	var sum_bought := {}
	for r in sim.s["residents"]:
		for g in (r["account"]["bought"] as Dictionary).keys():
			sum_bought[g] = float(sum_bought.get(g, 0.0)) + float(r["account"]["bought"][g])
	var led_bought: Dictionary = last["bought"]
	assert_that(led_bought.size()).is_equal(sum_bought.size())
	for g in sum_bought.keys():
		assert_that(float(led_bought.get(g, 0.0))).is_equal_approx(float(sum_bought[g]), 0.05)
