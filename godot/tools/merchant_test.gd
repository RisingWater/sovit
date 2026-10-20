extends SceneTree

# 游商门槛（M4，2026-10）。与 TS `scripts/check-merchant.ts` 同口径。
#
# red 的含义：① 第 3 章之前就来了 ② 章节数与队伍数不对
#              ③ 不是停留 7 天 / 不是每周一批
#              ④ 报价不是收 4 卖 4，或价格加成不是 1.6 / 1.3
#              ⑤ 买他的货不会让他现金变多（"买得越多他越有钱收你的货"）
#              ⑥ 同一状态两次生成不一致（不确定性会毁掉 golden / AI 沙盘）
#              ⑦ 交易不守恒（库存 / 国库对不上）
#              ⑧ 他收的又冒出"每种 20 件"这种配额（用户 2026-10：多多益善，
#                 阻止他收购的唯一就是"他自己钱不够了"）

const SEED := 20261024

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("MERCHANT TEST FAIL: ", msg)
	quit(1)

func _approx(a: float, b: float, eps: float = 0.02) -> bool:
	return absf(a - b) <= eps

func _run() -> void:
	var db = load("res://scripts/core/content_db.gd").load_all()
	var sim_script = load("res://scripts/sim/sim_core.gd")

	# ---- 1. 章节节奏 ------------------------------------------------------
	for case in [[2, 0], [3, 1], [4, 2], [5, 3]]:
		var sim = sim_script.new(db)
		sim.new_game("v0.3", SEED, 1.0)
		for i in range(1, int(case[0]) + 1):
			sim.s["quests"]["chapters"][str(i)] = i
		sim.s["trade"]["nextWaveDay"] = 1
		sim._update_caravans(10)
		var got: int = (sim.s["trade"]["caravans"] as Array).size()
		if got != int(case[1]):
			_fail("第 %d 章应当来 %d 队，实际 %d 队" % [case[0], case[1], got])
			return
	print("MERCHANT TEST 章节节奏：第 2 章 0 / 第 3 章 1 / 第 4 章 2 / 第 5 章 3 ✅")

	# ---- 2. 停留 7 天 + 每周一批 ------------------------------------------
	var sim2 = sim_script.new(db)
	sim2.new_game("v0.3", SEED, 1.0)
	sim2.s["quests"]["chapters"]["3"] = 3
	sim2.s["trade"]["nextWaveDay"] = 1
	sim2._update_caravans(10)
	var c: Dictionary = (sim2.s["trade"]["caravans"] as Array)[0]
	if int(c["arriveDay"]) != 10 or int(c["leaveDay"]) != 16:
		_fail("停留天数不对：%d → %d（应当 10 → 16）" % [int(c["arriveDay"]), int(c["leaveDay"])])
		return
	if int(sim2.s["trade"]["nextWaveDay"]) != 17:
		_fail("下一批 day %d，应当 17" % int(sim2.s["trade"]["nextWaveDay"]))
		return
	sim2._update_caravans(16)
	if (sim2.s["trade"]["caravans"] as Array).size() != 1:
		_fail("第 16 天（最后一天）人就走了")
		return
	sim2._update_caravans(17)
	for x in (sim2.s["trade"]["caravans"] as Array):
		if String(x["id"]) == String(c["id"]):
			_fail("第 17 天黎明他还没走")
			return
	print("MERCHANT TEST 停留：第 10 天到、16 天最后一天、17 天离开；下一批 +7 天 ✅")

	# ---- 3. 收 4 卖 4 + 价格加成 ------------------------------------------
	var sim3 = sim_script.new(db)
	sim3.new_game("v0.3", SEED, 1.0)
	sim3.s["quests"]["chapters"]["4"] = 4
	sim3.s["trade"]["nextWaveDay"] = 1
	sim3._update_caravans(10)
	for cv in (sim3.s["trade"]["caravans"] as Array):
		if (cv["buy"] as Array).size() != 4 or (cv["sell"] as Array).size() != 4:
			_fail("%s 的报价不是收 4 卖 4（收 %d / 卖 %d）"
				% [String(cv["id"]), (cv["buy"] as Array).size(), (cv["sell"] as Array).size()])
			return
		for o in (cv["sell"] as Array):
			var base := float(db.goods[String(o["good"])]["baseValue"])
			if not _approx(float(o["price"]), base * 1.3):
				_fail("%s 卖价 %.2f，应当是 %.2f" % [String(o["good"]), float(o["price"]), base * 1.3])
				return
		for o in (cv["buy"] as Array):
			var base2 := float(db.goods[String(o["good"])]["baseValue"])
			if not _approx(float(o["price"]), base2 * 1.6):
				_fail("%s 收价 %.2f，应当是 %.2f" % [String(o["good"]), float(o["price"]), base2 * 1.6])
				return
		# 存不住的东西不许进目录（用户 2026-10："娱乐可以出售……那种不能储存的商品，
		# 不要进游商的目录"）。判据：`perishRate >= 1`（当天归零）或服务/军备/工具三类。
		# ⚠️ 蔬菜 / 肉 / 鱼 是 `storable: false` 但 perishRate 只有 0.1~0.15（能放几天的鲜货），
		#    照常可交易 —— 别把 `storable` 当判据。
		for o2 in ((cv["sell"] as Array) + (cv["buy"] as Array)):
			var gid := String(o2["good"])
			var gdef: Dictionary = db.goods.get(gid, {})
			var cat := String(gdef.get("category", ""))
			var perish := float(gdef.get("perishRate", 0.0))
			if perish >= 1.0 or cat == "service" or cat == "military" or cat == "tool":
				_fail("%s（%s）不该进游商目录：category=%s perishRate=%.2f"
					% [gid, String(gdef.get("nameZh", gid)), cat, perish])
				return
	print("MERCHANT TEST 报价：每人收 4 卖 4，收价 ×1.6 / 卖价 ×1.3 ✅（目录里没有存不住的东西）")

	# ---- 4. 现金池：买他的货 → 他更有钱 -----------------------------------
	var sim4 = sim_script.new(db)
	sim4.new_game("v0.3", SEED, 1.0)
	sim4.s["quests"]["chapters"]["3"] = 3
	sim4.s["trade"]["nextWaveDay"] = 1
	sim4._update_caravans(10)
	var cv4: Dictionary = (sim4.s["trade"]["caravans"] as Array)[0]
	sim4.s["government"]["money"] = 5000.0
	var cash0 := float(cv4["cash"])
	var sell_offer: Dictionary = (cv4["sell"] as Array)[0]
	if sim4.buy_from_caravan(String(cv4["id"]), String(sell_offer["good"]), 2) != "":
		_fail("从他买 2 件被拒")
		return
	if float(cv4["cash"]) <= cash0:
		_fail("买他的货之后现金 %.2f → %.2f，应当变多" % [cash0, float(cv4["cash"])])
		return
	# 卖给他：国库增、库存减、他现金减
	var buy_offer: Dictionary = (cv4["buy"] as Array)[0]
	sim4.s["goods"][String(buy_offer["good"])] = 50.0
	var money0 := float(sim4.s["government"]["money"])
	var stock0 := float(sim4.s["goods"][String(buy_offer["good"])])
	if sim4.sell_to_caravan(String(cv4["id"]), String(buy_offer["good"]), 3) != "":
		_fail("卖给他 3 件被拒")
		return
	if float(sim4.s["government"]["money"]) <= money0:
		_fail("卖给他之后国库没增加")
		return
	if float(sim4.s["goods"][String(buy_offer["good"])]) >= stock0:
		_fail("卖给他之后库存没减少")
		return
	print("MERCHANT TEST 现金池：买他的货 → 他现金 %.0f → %.0f；卖给他 → 国库增 / 库存减 ✅"
		% [cash0, float(cv4["cash"])])

	# ---- 5. 确定性 -------------------------------------------------------
	var a = sim_script.new(db)
	a.new_game("v0.3", SEED, 1.0)
	a.s["quests"]["chapters"]["4"] = 4
	a.s["trade"]["nextWaveDay"] = 1
	a._update_caravans(10)
	var b = sim_script.new(db)
	b.new_game("v0.3", SEED, 1.0)
	b.s["quests"]["chapters"]["4"] = 4
	b.s["trade"]["nextWaveDay"] = 1
	b._update_caravans(10)
	if JSON.stringify(a.s["trade"]["caravans"]) != JSON.stringify(b.s["trade"]["caravans"]):
		_fail("同一状态两次生成的报价不一样（不确定性会毁掉 golden / AI 沙盘）")
		return
	print("MERCHANT TEST 确定性：同一状态两次生成完全一致 ✅")

	# ---- 6. 拒绝理由说人话 -----------------------------------------------
	if sim4.sell_to_caravan("cv#nope", "wood", 1) == "":
		_fail("不存在的游商居然能卖")
		return
	if sim4.buy_from_caravan(String(cv4["id"]), "no_such_good", 1) == "":
		_fail("他没带的商品居然能买")
		return
	print("MERCHANT TEST 拒绝：不存在的游商 / 没带的商品都给理由 ✅")

	# ---- 7. 他收的"多多益善"：没有每种配额 --------------------------------
	#
	# 用户 2026-10："游商本来就为了收购这个货物来的，所以是多多益善，阻止他收购这个货物的
	# 唯一就是自己钱不够了。" —— 所以：① 他收的报价里没有 `qty`；
	# ② 一次能卖多少只由"库存 + 他的现金"决定（旧规则每种只收 20 件，早没了）。
	var sim7 = sim_script.new(db)
	sim7.new_game("v0.3", SEED, 1.0)
	sim7.s["quests"]["chapters"]["3"] = 3
	sim7.s["trade"]["nextWaveDay"] = 1
	sim7._update_caravans(10)
	var cv7: Dictionary = (sim7.s["trade"]["caravans"] as Array)[0]
	var buy7: Dictionary = (cv7["buy"] as Array)[0]
	if buy7.has("qty"):
		_fail("他收的报价里还有 qty —— 用户要求多多益善，没有每种配额")
		return
	# 钱给足 → 一次卖 100 件应当全收（旧规则最多 20）
	var good7 := String(buy7["good"])
	var price7 := float(buy7["price"])
	cv7["cash"] = 100000.0
	sim7.s["goods"][good7] = 500.0
	if sim7.sell_to_caravan(String(cv7["id"]), good7, 100) != "":
		_fail("钱给足时卖给他 100 件被拒（旧规则的 20 件配额不许回来）")
		return
	if absf(float(sim7.s["goods"][good7]) - 400.0) > 0.001:
		_fail("卖 100 件之后库存是 %.2f，应当是 400（配额还在？）" % float(sim7.s["goods"][good7]))
		return
	# 只给 2.5 件的钱 → 成交 2 件（floor），他的钱花到买不起第 3 件
	cv7["cash"] = snappedf(price7 * 2.5, 0.01)
	sim7.s["goods"][good7] = 400.0
	if sim7.sell_to_caravan(String(cv7["id"]), good7, 50) != "":
		_fail("现金只够 2 件时，卖 50 件应当成交 2 件（部分成交，不是整单拒绝）")
		return
	var sold7 := 400.0 - float(sim7.s["goods"][good7])
	if absf(sold7 - 2.0) > 0.001:
		_fail("他的现金只够 2 件，却成交了 %.0f 件（唯一的上限应当是他的现金）" % sold7)
		return
	if float(cv7["cash"]) >= price7:
		_fail("钱花完了他的 cash 还有 %.2f（还够再收一件）" % float(cv7["cash"]))
		return
	print("MERCHANT TEST 多多益善：他收的报价没有 qty；钱够就一次收 100 件，钱不够只收到现金上限 ✅")

	print("MERCHANT TEST RESULT: PASS")
	quit(0)
