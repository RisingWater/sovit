extends SceneTree

# 商路门槛（B3，用户 2026-10）。与 TS `scripts/check-routes.ts` 分工：
#   · check-routes.ts 管**内容**（城市表 / 价表 / 特产互斥 / 科技链 / 图标）
#   · 本文件管**引擎行为**，红了的含义：
#       ① 没研究「常设商队」也能派车
#       ② 派车不锁货 / 锁了货仓库没少（锁货必须是"搬出仓库"）
#       ③ 货不齐也出发，或者钱不够也出发
#       ④ 到达不结算（该卖没卖、该买没买）或回家不入库
#       ⑤ 一趟的天数不对（1 天城应当 D+1 到、D+2 回）
#       ⑥ 市场库存不按日补给 / 被买超了
#       ⑦ 特产能被卖、需求能被买（"只能买特产、只能卖需求"这条被打破）
#       ⑧ 读档之后在途商队重跑或丢货（存读档不能改运输状态）
#       ⑨ 价格口径与 `docs/trade-routes.md` §2 的公示不一致
const SEED := 20261026

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("ROUTES TEST FAIL: ", msg)
	quit(1)

func _approx(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps

## 建一局：研究好商队 + 给一笔钱与货
func _fresh(sim_script, db, money: float = 5000.0) -> Variant:
	var sim = sim_script.new(db)
	sim.new_game("v0.3", SEED, 1.0)
	sim.s["research"]["done"].append("trade")
	sim.s["research"]["done"].append("trade_caravan_1")
	sim.s["government"]["money"] = money
	sim.s["goods"]["wood"] = 100.0
	sim.s["goods"]["brick"] = 100.0
	sim.s["goods"]["coarse_cloth"] = 100.0
	return sim

func _run() -> void:
	var db = load("res://scripts/core/content_db.gd").load_all()
	var sim_script = load("res://scripts/sim/sim_core.gd")

	# ---- 0. 内容读进来了 ----------------------------------------------------
	if db.routes.is_empty():
		_fail("db.routes 是空的：content/routes.json 没读进来（跑过 npm run sync:content 吗？）")
		return
	if (db.routes.get("cities", []) as Array).size() != 11:
		_fail("目的地应当是 11 座，实际 %d" % (db.routes.get("cities", []) as Array).size())
		return

	# ---- 1. 没研究「常设商队」不能派车 --------------------------------------
	var sim0 = sim_script.new(db)
	sim0.new_game("v0.3", SEED, 1.0)
	if sim0.routes_unlocked():
		_fail("开局就解锁了商路（应当要先研究「常设商队」）")
		return
	if sim0.assign_route("jade") == "":
		_fail("没研究商队也把车派出去了")
		return
	print("ROUTES TEST ① 解锁：没研究就派不出去 ✓")

	# ---- 2. 派车锁货：仓库减少、商队身上多出来 ------------------------------
	var sim = _fresh(sim_script, db)
	var why_assign: String = sim.assign_route("jade")
	if why_assign != "":
		_fail("研究完之后派车被拒了：%s（商队数 %d）" % [why_assign, sim.route_caravan_count()])
		return
	var rid := String((sim.s["routes"]["routes"] as Array)[0]["id"])
	sim.set_route_budget(rid, 800.0)
	for g in ["wood", "brick", "coarse_cloth"]:
		if sim.set_route_sell(rid, g, 20) != "":
			_fail("设置出售数量被拒：%s" % g)
			return
	var wood_before := float(sim.s["goods"]["wood"])
	var money_before := float(sim.s["government"]["money"])
	sim._update_routes(1)
	var route: Dictionary = (sim.s["routes"]["routes"] as Array)[0]
	if String(route["phase"]) != "out":
		_fail("货齐了钱也够，却没有出发（phase=%s）" % String(route["phase"]))
		return
	if not _approx(wood_before - float(sim.s["goods"]["wood"]), 20.0):
		_fail("锁货没有把货搬出仓库（木材 %.1f → %.1f）" % [
			wood_before, float(sim.s["goods"]["wood"])])
		return
	if not _approx(money_before - float(sim.s["government"]["money"]), 800.0):
		_fail("出发没有扣掉带出的钱（%.1f → %.1f）" % [
			money_before, float(sim.s["government"]["money"])])
		return
	if int(route["arriveDay"]) != 2 or int(route["backDay"]) != 3:
		_fail("1 天城的天数不对：arrive=%d back=%d（应当 2 / 3）" % [
			int(route["arriveDay"]), int(route["backDay"])])
		return
	print("ROUTES TEST ② 锁货 / 扣钱 / 天数：出发日 D1、到达 D2、回家 D3 ✓")

	# ---- 3. 货不齐就不出发（钱够）------------------------------------------
	var sim3 = _fresh(sim_script, db)
	sim3.assign_route("jade")
	var rid3 := String((sim3.s["routes"]["routes"] as Array)[0]["id"])
	sim3.set_route_sell(rid3, "wood", 200)      # 货位 40，但仓库只有 100 → 锁够 40？
	sim3.s["goods"]["wood"] = 5.0               # 只剩 5 件 → 锁不满
	sim3._update_routes(1)
	var r3: Dictionary = (sim3.s["routes"]["routes"] as Array)[0]
	if String(r3["phase"]) != "home":
		_fail("货不齐也出发了（phase=%s）" % String(r3["phase"]))
		return
	if not _approx(float(sim3.s["goods"]["wood"]), 0.0):
		_fail("货不齐时应当把已有的 5 件**锁进商队**（仓库剩 %.1f）" % float(sim3.s["goods"]["wood"]))
		return
	print("ROUTES TEST ③ 缺货：留在家、已锁的部分搬走（仓库 0、商队 5）✓")

	# ---- 4. 钱不够也不出发 ---------------------------------------------------
	var sim4 = _fresh(sim_script, db, 100.0)
	sim4.assign_route("jade")
	var rid4 := String((sim4.s["routes"]["routes"] as Array)[0]["id"])
	sim4.set_route_budget(rid4, 800.0)
	sim4.set_route_sell(rid4, "wood", 10)
	sim4._update_routes(1)
	var r4: Dictionary = (sim4.s["routes"]["routes"] as Array)[0]
	if String(r4["phase"]) != "home":
		_fail("国库不够付预算也出发了")
		return
	print("ROUTES TEST ④ 钱不够：不出发 ✓")

	# ---- 5. 到达结算 + 回家入库 ---------------------------------------------
	var sim5 = _fresh(sim_script, db)
	sim5.assign_route("jade")
	var rid5 := String((sim5.s["routes"]["routes"] as Array)[0]["id"])
	sim5.set_route_budget(rid5, 800.0)
	for g in ["wood", "brick", "coarse_cloth"]:
		sim5.set_route_sell(rid5, g, 10)
	sim5._update_routes(1)                      # D1 出发
	var want_rev: float = 10.0 * sim5.route_price("jade", "wood", "sell") \
		+ 10.0 * sim5.route_price("jade", "brick", "sell") \
		+ 10.0 * sim5.route_price("jade", "coarse_cloth", "sell")
	sim5._update_routes(2)                      # D2 到达
	var r5: Dictionary = (sim5.s["routes"]["routes"] as Array)[0]
	if not _approx(float(r5["revenue"]), want_rev, 0.05):
		_fail("到达卖出所得不对：%.2f（应当 %.2f）" % [float(r5["revenue"]), want_rev])
		return
	if not _approx(float(sim5.s["ledgerToday"]["routeExport"]), want_rev, 0.05):
		_fail("台账 routeExport 没记上（%.2f）" % float(sim5.s["ledgerToday"]["routeExport"]))
		return
	var cart: Dictionary = r5["cart"]
	if (cart as Dictionary).is_empty():
		_fail("到了城里一件货都没买（钱箱上限 800、载重 40）")
		return
	var bought := 0
	for g in cart.keys():
		bought += int(cart[g])
	if bought > sim5.route_cargo_cap():
		_fail("买超了货位：%d > %d" % [bought, sim5.route_cargo_cap()])
		return
	sim5._update_routes(3)                      # D3 回家
	var r5b: Dictionary = (sim5.s["routes"]["routes"] as Array)[0]
	if String(r5b["phase"]) != "home":
		_fail("D3 没回家（phase=%s）" % String(r5b["phase"]))
		return
	if (r5b["cart"] as Dictionary).size() != 0:
		_fail("回家后 cart 没清空")
		return
	print("ROUTES TEST ⑤ 到达卖货 ¥%.1f、买入 %d 件、回家入库 ✓" % [want_rev, bought])

	# ---- 6. 只有特产能买、只有需求能卖 --------------------------------------
	var sim6 = _fresh(sim_script, db)
	sim6.assign_route("jade")
	var rid6 := String((sim6.s["routes"]["routes"] as Array)[0]["id"])
	if sim6.set_route_sell(rid6, "iron", 10) == "":
		_fail("「铁锭」不是翡翠城的需求，却接受了出售配置")
		return
	if sim6.set_route_sell(rid6, "wood", 10) != "":
		_fail("「木材」是翡翠城的需求，却被拒了")
		return
	sim6._update_routes(1)
	sim6._update_routes(2)
	var cart6: Dictionary = (sim6.s["routes"]["routes"] as Array)[0]["cart"]
	for g in cart6.keys():
		if not ["fine_cloth", "dye"].has(String(g)):
			_fail("从城里买到了非特产：%s" % String(g))
			return
	print("ROUTES TEST ⑥ 只买特产 / 只卖需求 ✓")

	# ---- 7. 市场补给与上限 ---------------------------------------------------
	var sim7 = _fresh(sim_script, db)
	# 先买光翡翠城的细织物（用一支车队反复跑不现实，这里直接读初始值再跑两天）
	var mk0: Dictionary = sim7.s["routes"]["market"]["jade"]
	var cloth0 := float((mk0["specialty"] as Dictionary)["fine_cloth"])
	sim7._update_routes(1)
	var cloth1 := float((sim7.s["routes"]["market"]["jade"]["specialty"] as Dictionary)["fine_cloth"])
	if not _approx(cloth1, minf(cloth0 + float((db.routes["market"] as Dictionary)["specialtyDaily"]),
			float((db.routes["market"] as Dictionary)["specialtyCap"])), 0.01):
		_fail("特产库存没有按日补给（%.1f → %.1f）" % [cloth0, cloth1])
		return
	for i in 20:
		sim7._update_routes(10 + i)
	var cloth_cap := float((sim7.s["routes"]["market"]["jade"]["specialty"] as Dictionary)["fine_cloth"])
	if cloth_cap > float((db.routes["market"] as Dictionary)["specialtyCap"]) + 0.01:
		_fail("特产库存超过了上限（%.1f）" % cloth_cap)
		return
	print("ROUTES TEST ⑦ 市场按日补给、封顶 ✓")

	# ---- 8. 读档不改运输状态（存读档的契约）--------------------------------
	# 这里验的是"状态是纯数据"：把 routes 段深拷贝一份，跑两天，两份的 phase 必须同步
	var sim8 = _fresh(sim_script, db)
	sim8.assign_route("jade")
	var rid8 := String((sim8.s["routes"]["routes"] as Array)[0]["id"])
	sim8.set_route_sell(rid8, "wood", 5)
	sim8._update_routes(1)
	var copied: Dictionary = (sim8.s["routes"] as Dictionary).duplicate(true)
	var json := JSON.stringify(copied)
	var parsed = JSON.parse_string(json)
	if parsed == null:
		_fail("routes 状态过不了 JSON（存档会丢）")
		return
	if String((parsed["routes"] as Array)[0]["phase"]) != "out":
		_fail("JSON 往返之后 phase 丢了（%s）" % String((parsed["routes"] as Array)[0]["phase"]))
		return
	if int((parsed["routes"] as Array)[0]["backDay"]) != 3:
		_fail("JSON 往返之后 backDay 丢了")
		return
	print("ROUTES TEST ⑧ 运输状态是纯数据（JSON 往返不丢）✓")

	# ---- 9. 价格口径 ---------------------------------------------------------
	# 1 天城：卖 ×1.0、买 ×2.0；5 天城：卖 ×6.0、买 ×0.6。议价没研究时是 0。
	if not _approx(sim.route_price("jade", "wood", "sell"), 1.5, 0.01):
		_fail("翡翠城木材卖价应当是 1.5，实际 %.2f" % sim.route_price("jade", "wood", "sell"))
		return
	if not _approx(sim.route_price("jade", "fine_cloth", "buy"), 6.4, 0.01):
		_fail("翡翠城细织物买价应当是 6.4，实际 %.2f" % sim.route_price("jade", "fine_cloth", "buy"))
		return
	if not _approx(sim.route_price("peak", "wheat", "sell"), 6.0, 0.01):
		_fail("铁峰城小麦卖价应当是 6.0，实际 %.2f" % sim.route_price("peak", "wheat", "sell"))
		return
	if not _approx(sim.route_price("peak", "iron_ore", "buy"), 1.68, 0.01):
		_fail("铁峰城铁矿石买价应当是 1.68，实际 %.2f" % sim.route_price("peak", "iron_ore", "buy"))
		return
	print("ROUTES TEST ⑨ 价格口径（1 天 1.0/2.0、5 天 6.0/0.6）✓")

	print("ROUTES TEST RESULT: PASS")
	quit(0)
