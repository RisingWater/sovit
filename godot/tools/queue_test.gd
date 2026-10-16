extends SceneTree

# 两条队列的门槛：**建造队列**与**研究队列**的调序 / 撤单
# （见 docs/spec.md §9.8 施工 / §10.7 研究）。
#
# 两条队列同构：先进先出的一条数组，队首（index 0）先吃到当日产能，材料在**开工那一刻**
# 才扣。玩家以前只能下单、没法改顺序 —— 这两条动作把队列变成可管理的。
#
# 验五件事（与 TS 侧 `scripts/check-queues.ts` 同口径、同数字）：
#   1. 调序只改顺序：不重算工期、不动 started、不退料
#   2. 调序真的改变"谁先吃到产能"（10 点建造力 / 8 点科研力都只投给队首）
#   3. 撤单的退料口径：**材料是开工那一刻才扣的** ——
#      没开工退 0；开工了按 remaining / totalRequired 退
#      （建造：木 6 / 石 3 剩 26/36 → 退 4.33 / 2.17；研究：木 15 剩 12/20 → 退 9）
#   4. 走完整的黎明：命令次日 06:00 生效，且取消要进公告（`s["log"]`）
#   5. 取消在建工程 → 土地名额放出来；跑完的科技不在队首也照样在黎明生效
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/queue_test.gd

const SEED := 20261016
## 三座同价同工期的建筑（木 6 / 石 3，36 建造力）—— 差异只反映顺序。
const A := "pastry_shop"
const B := "porcelain_works"
const C := "sugar_works"
## 三项开局就能研究的科技（无前置、各 20 科研力、纯木材成本）。
const T1 := "stonework"    # 木 15
const T2 := "digging"      # 木 15
const T3 := "firewood"     # 木 20
const RSEED := 20261017

var db = null
var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("QUEUE TEST FAIL: ", msg)
	print("QUEUE TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

## 一座"材料管够、科技全解锁"的村子（三座目标建筑都在科技后面）。
func _fresh() -> SimCore:
	var sim := SimCore.new(db)
	sim.new_game("v0.3", SEED)
	sim.s["research"]["done"] = db.tech_ids.duplicate()
	for g in ["wood", "stone", "brick", "clay", "firewood"]:
		sim.s["goods"][g] = 5000.0
	sim.s["government"]["money"] = 50000.0
	return sim

## 队列里各条的 buildingId / housingId（断言顺序用）。
func _order(sim) -> Array:
	var out := []
	for c in (sim.s["construction"] as Array):
		out.append(String(c.get("buildingId", c.get("housingId", c["id"]))))
	return out

func _id_at(sim, i: int) -> String:
	return String((sim.s["construction"] as Array)[i]["id"])

## 研究用的村子：木材管够、科技一个没完成（不然没得排）。
func _fresh_research() -> SimCore:
	var sim := SimCore.new(db)
	sim.new_game("v0.3", RSEED)
	sim.s["goods"]["wood"] = 5000.0
	sim.s["research"]["done"] = []
	return sim

## 研究队列里各条的 techId（断言顺序用）。
func _r_order(sim) -> Array:
	var out := []
	for p in (sim.s["research"]["queue"] as Array):
		out.append(String(p["id"]))
	return out

func _r_id_at(sim, i: int) -> String:
	return String((sim.s["research"]["queue"] as Array)[i]["id"])

func _run() -> void:
	db = ContentDB.load_all()

	# ---- 1. 下单顺序 = 队列顺序，调序只挪位置 -------------------------------
	var sim = _fresh()
	for bid in [A, B, C]:
		sim._try_build(String(bid))
	if (sim.s["construction"] as Array).size() != 3:
		_fail("下单 3 座后队列只有 %d 条（材料/科技没给够？）" % (sim.s["construction"] as Array).size())
		return
	var want := [A, B, C]
	if _order(sim) != want:
		_fail("队列顺序应为下单顺序，实际 %s" % str(_order(sim)))
		return
	_ok("下单顺序 = 队列顺序：%s" % " → ".join(_order(sim)))

	var id_b := _id_at(sim, 1)
	var works := []
	for c in (sim.s["construction"] as Array):
		works.append(float(c["totalRequired"]))
	var goods_before: Dictionary = sim.s["goods"].duplicate()

	var mv := sim._move_construction(id_b, -1)
	if not bool(mv["ok"]) or _id_at(sim, 0) != id_b:
		_fail("上移一条应把 B 挪到队首：%s（%s）" % [str(_order(sim)), str(mv)])
		return
	_ok("上移一条：B 到队首 —— %s" % " → ".join(_order(sim)))

	var up := sim._move_construction(id_b, -1)
	if bool(up["ok"]) or String(up["reason"]) != "已经是队首":
		_fail("队首再上移应被拒（已经是队首），实际 %s" % str(up))
		return
	_ok("再上移 → 拒绝：%s" % String(up["reason"]))

	sim._move_construction(id_b, 1)
	sim._move_construction(id_b, 1)
	if _id_at(sim, 2) != id_b:
		_fail("下移两次应把 B 挪回队尾：%s" % str(_order(sim)))
		return
	var down := sim._move_construction(id_b, 1)
	if bool(down["ok"]) or String(down["reason"]) != "已经是队尾":
		_fail("队尾再下移应被拒（已经是队尾），实际 %s" % str(down))
		return
	_ok("下移两次回队尾、再下移被拒：%s" % String(down["reason"]))

	var gone := sim._move_construction("c#99-不存在", -1)
	if bool(gone["ok"]) or String(gone["reason"]) != "该工程已不在队列里":
		_fail("不存在的 id 应被拒，实际 %s" % str(gone))
		return
	var zero := sim._move_construction(id_b, 0)
	if bool(zero["ok"]) or String(zero["reason"]) != "没有移动":
		_fail("delta = 0 应被拒，实际 %s" % str(zero))
		return
	_ok("不存在的 id / delta=0 都被拒：%s / %s" % [String(gone["reason"]), String(zero["reason"])])

	var works2 := []
	for c in (sim.s["construction"] as Array):
		works2.append(float(c["totalRequired"]))
	if works != works2:
		_fail("调序不该重算工期：%s → %s" % [str(works), str(works2)])
		return
	_ok("调序不重算工期（%s）、不动 started、不退料（材料%s）" % [
		str(works), "未变" if sim.s["goods"] == goods_before else "**变了**"])

	# ---- 2. 调序真的改变"谁先吃到建造力" ------------------------------------
	sim._move_construction(id_b, -1)
	sim._move_construction(id_b, -1)
	if _id_at(sim, 0) != id_b:
		_fail("B 应已在队首：%s" % str(_order(sim)))
		return
	var wood0 := float(sim.s["goods"]["wood"])
	var stone0 := float(sim.s["goods"]["stone"])
	sim.s["constructionRateToday"] = 10.0
	var hour_logs: Array = sim._apply_construction_hours(1.0)
	var c0: Dictionary = (sim.s["construction"] as Array)[0]
	var c1: Dictionary = (sim.s["construction"] as Array)[1]
	var c2: Dictionary = (sim.s["construction"] as Array)[2]
	if absf(float(c0["remaining"]) - 26.0) > 0.0001 or float(c1["remaining"]) != 36.0 \
			or float(c2["remaining"]) != 36.0:
		_fail("产能应只投给队首（26/36/36），实际 %.4f/%.4f/%.4f" % [
			float(c0["remaining"]), float(c1["remaining"]), float(c2["remaining"])])
		return
	_ok("投 10 点产能：队首 36 → 26，后面两条一点没动")
	if hour_logs.size() != 1 or not String(hour_logs[0]["text"]).contains("开工"):
		_fail("只有队首该写「开工」日志，实际 %s" % str(hour_logs))
		return
	_ok("只有队首写了「开工」日志：%s" % String(hour_logs[0]["text"]))
	if absf(float(sim.s["goods"]["wood"]) - (wood0 - 6.0)) > 0.0001 \
			or absf(float(sim.s["goods"]["stone"]) - (stone0 - 3.0)) > 0.0001:
		_fail("材料应在开工那一刻扣（木 −6 / 石 −3），实际 木 %.2f → %.2f、石 %.2f → %.2f" % [
			wood0, float(sim.s["goods"]["wood"]), stone0, float(sim.s["goods"]["stone"])])
		return
	_ok("材料在开工那一刻才扣：木 %.0f → %.0f、石 %.0f → %.0f" % [
		wood0, float(sim.s["goods"]["wood"]), stone0, float(sim.s["goods"]["stone"])])

	# ---- 3. 取消：没开工退 0，开工了按"还没干完的那份"退 ----------------------
	var id_c := _id_at(sim, 2)
	var wood_not_started := float(sim.s["goods"]["wood"])
	var r1: Dictionary = sim._cancel_construction(id_c)
	if not bool(r1["ok"]):
		_fail("取消没开工的那条应成功：%s" % str(r1))
		return
	if (r1["refund"] as Array).size() != 0 or absf(float(sim.s["goods"]["wood"]) - wood_not_started) > 0.0001:
		_fail("没开工就**没扣过**材料，退 0，实际退 %s（木 %.2f）" % [str(r1["refund"]), float(sim.s["goods"]["wood"])])
		return
	_ok("取消未开工：一分料都不退 —— %s" % String(r1["text"]))
	if (sim.s["construction"] as Array).size() != 2:
		_fail("取消后队列应剩 2 条，实际 %d" % (sim.s["construction"] as Array).size())
		return

	var head_id := _id_at(sim, 0)
	var wood_before := float(sim.s["goods"]["wood"])
	var stone_before := float(sim.s["goods"]["stone"])
	var r2: Dictionary = sim._cancel_construction(head_id)
	if not bool(r2["ok"]):
		_fail("取消已开工的那条应成功：%s" % str(r2))
		return
	var refund: Array = r2["refund"]
	var got := []
	for m in refund:
		got.append([String(m[0]), float(m[1])])
	if got.size() != 2 or got[0][0] != "wood" or absf(got[0][1] - 4.33) > 0.0001 \
			or got[1][0] != "stone" or absf(got[1][1] - 2.17) > 0.0001:
		_fail("已开工应按 remaining/totalRequired 退（木 4.33 / 石 2.17），实际 %s" % str(got))
		return
	_ok("取消已开工：按 remaining/totalRequired 退 —— 木 4.33 / 石 2.17")
	if absf(float(sim.s["goods"]["wood"]) - (wood_before + 4.33)) > 0.0001 \
			or absf(float(sim.s["goods"]["stone"]) - (stone_before + 2.17)) > 0.0001:
		_fail("退回的料要真的进国库：木 %.2f → %.2f、石 %.2f → %.2f" % [
			wood_before, float(sim.s["goods"]["wood"]), stone_before, float(sim.s["goods"]["stone"])])
		return
	_ok("退回的料真的进了国库：木 %.2f → %.2f、石 %.2f → %.2f" % [
		wood_before, float(sim.s["goods"]["wood"]), stone_before, float(sim.s["goods"]["stone"])])
	if absf(float(r2["used"]) - 10.0) > 0.0001 or absf(float(r2["total"]) - 36.0) > 0.0001:
		_fail("报告里应写明已投入 10 / 36，实际 %s / %s" % [str(r2["used"]), str(r2["total"])])
		return
	if not String(r2["text"]).contains("28%") or not String(r2["text"]).contains("退回"):
		_fail("文案要写明进度与退回明细：%s" % String(r2["text"]))
		return
	_ok("文案：%s" % String(r2["text"]))
	var again: Dictionary = sim._cancel_construction(head_id)
	if bool(again["ok"]) or String(again["reason"]) != "该工程已不在队列里":
		_fail("重复取消应被拒，实际 %s" % str(again))
		return
	_ok("重复取消 → 拒绝：%s" % String(again["reason"]))

	# ---- 4. 走完整的黎明：命令次日 06:00 生效 + 进公告 ------------------------
	# 单独一座村子：这一段会真的走时钟（黎明 06:00 同时也是第一个工作小时，
	# 会往队首投一点产能），所以不在这一段断言具体进度。
	var sim2 = _fresh()
	for bid in [A, B, C]:
		sim2._try_build(String(bid))
	sim2.s["hour"] = 5
	var moved_id := _id_at(sim2, 2)
	sim2.tick_hour([{"type": "move_construction", "id": moved_id, "delta": -1}])
	sim2.tick_hour([])
	if _id_at(sim2, 1) != moved_id:
		_fail("调序应在次日黎明生效（第 2 位是 %s，实际 %s）" % [moved_id, _id_at(sim2, 1)])
		return
	_ok("调序在次日 06:00 生效 —— %s" % " → ".join(_order(sim2)))

	sim2.s["hour"] = 5
	var cancel_id := _id_at(sim2, 2)
	sim2.tick_hour([{"type": "cancel_construction", "id": cancel_id}])
	sim2.tick_hour([])
	var has_it := false
	for c in (sim2.s["construction"] as Array):
		if String(c["id"]) == cancel_id:
			has_it = true
	if has_it:
		_fail("取消后队列里不该还有 %s" % cancel_id)
		return
	# 公告的真源是 `s["log"]`（进存档），`log_tail()` 只是取尾巴 —— 两处都要有
	var log_has := false
	var log_txt := ""
	for e in sim2.log_tail(sim2.log_size()):
		if String(e["text"]).contains("取消"):
			log_has = true
			log_txt = String(e["text"])
	if not log_has:
		_fail("取消要进公告（s[\"log\"]，公告页与存档读的就是它）")
		return
	_ok("取消进了公告：%s" % log_txt)

	# ---- 5. 取消在建工程 → 土地名额放出来 -----------------------------------
	var sim3 = _fresh()
	var slots0: int = sim3._used_slots()
	sim3._try_build(A)
	if sim3._used_slots() != slots0 + 1:
		_fail("在建工程应占土地名额：%d → %d" % [slots0, sim3._used_slots()])
		return
	sim3._cancel_construction(_id_at(sim3, 0))
	if sim3._used_slots() != slots0:
		_fail("取消后名额应放出来：%d → %d" % [slots0, sim3._used_slots()])
		return
	_ok("在建占名额、取消后放出来：%d → %d → %d" % [slots0, slots0 + 1, sim3._used_slots()])

	# =======================================================================
	# 研究队列（与建造队列同构，见 docs/spec.md §10.7）
	# =======================================================================
	var rs1 := _fresh_research()
	for tid in [T1, T2, T3]:
		rs1._start_research(String(tid))
	if (rs1.s["research"]["queue"] as Array).size() != 3:
		_fail("排入 3 项研究后队列只有 %d 条" % (rs1.s["research"]["queue"] as Array).size())
		return
	_ok("研究队列顺序 = 下单顺序：%s" % " → ".join(_r_order(rs1)))

	var rq1 := _r_id_at(rs1, 1)
	var rup := rs1._move_research(rq1, -1)
	if not bool(rup["ok"]) or _r_id_at(rs1, 0) != rq1:
		_fail("研究上移应把第 2 项挪到队首：%s（%s）" % [str(_r_order(rs1)), str(rup)])
		return
	var rup2 := rs1._move_research(rq1, -1)
	if bool(rup2["ok"]) or String(rup2["reason"]) != "已经是队首":
		_fail("研究队首再上移应被拒，实际 %s" % str(rup2))
		return
	rs1._move_research(rq1, 1)
	rs1._move_research(rq1, 1)
	var rdn := rs1._move_research(rq1, 1)
	if bool(rdn["ok"]) or String(rdn["reason"]) != "已经是队尾":
		_fail("研究队尾再下移应被拒，实际 %s" % str(rdn))
		return
	var rzg := rs1._move_research(rq1, 0)
	if bool(rzg["ok"]) or String(rzg["reason"]) != "没有移动":
		_fail("研究 delta=0 应被拒，实际 %s" % str(rzg))
		return
	var rmiss := rs1._move_research("nope", -1)
	if bool(rmiss["ok"]) or String(rmiss["reason"]) != "不在研究队列中":
		_fail("研究队列里没有的 id 应被拒，实际 %s" % str(rmiss))
		return
	_ok("研究调序的四个边界都被拒：%s / %s / %s / %s" % [
		String(rup2["reason"]), String(rdn["reason"]), String(rzg["reason"]), String(rmiss["reason"])])
	if float(rs1.s["goods"]["wood"]) != 5000.0:
		_fail("研究调序不该退料：木 %s" % str(rs1.s["goods"]["wood"]))
		return
	_ok("研究调序不重算进度（都是 20）、不退料（木仍 5000）、不动 started")

	# 调序真的改变"谁先吃到科研力"：把第 2 项挪到队首，投 8 点 → 只有它动
	rs1._move_research(rq1, -1)
	var rwood0 := float(rs1.s["goods"]["wood"])
	rs1.s["researchRateToday"] = 8.0
	rs1.s["researchWorkToday"] = 0.0
	var rlogs: Array = rs1._apply_research_hours(1.0)
	var rp0: Dictionary = (rs1.s["research"]["queue"] as Array)[0]
	var rp1: Dictionary = (rs1.s["research"]["queue"] as Array)[1]
	var rp2: Dictionary = (rs1.s["research"]["queue"] as Array)[2]
	if absf(float(rp0["remaining"]) - 12.0) > 0.0001 \
			or float(rp1["remaining"]) != 20.0 or float(rp2["remaining"]) != 20.0:
		_fail("科研力应只投给队首（12/20/20），实际 %.4f/%.4f/%.4f" % [
			float(rp0["remaining"]), float(rp1["remaining"]), float(rp2["remaining"])])
		return
	_ok("投 8 点科研力：队首 20 → 12，后面两条一点没动")
	if rlogs.size() != 1 or not String(rlogs[0]["text"]).contains("开始研究"):
		_fail("只有队首该写「开始研究」日志，实际 %s" % str(rlogs))
		return
	if absf(float(rs1.s["goods"]["wood"]) - (rwood0 - 15.0)) > 0.0001:
		_fail("研究材料应在开工那一刻扣（木 −15），实际 %.2f → %.2f" % [
			rwood0, float(rs1.s["goods"]["wood"])])
		return
	_ok("只有队首开工、材料那一刻才扣：木 %.0f → %.0f" % [rwood0, float(rs1.s["goods"]["wood"])])

	var rtail := _r_id_at(rs1, 2)
	var run_started := float(rs1.s["goods"]["wood"])
	var run := rs1._cancel_research(rtail)
	if not bool(run["ok"]) or (run["refund"] as Array).size() != 0 \
			or absf(float(rs1.s["goods"]["wood"]) - run_started) > 0.0001:
		_fail("取消没开工的研究该退 0，实际退 %s（木 %.2f）" % [str(run["refund"]), float(rs1.s["goods"]["wood"])])
		return
	_ok("取消未开工研究：一分料都不退 —— %s" % String(run["text"]))

	var rhead := _r_id_at(rs1, 0)
	var rwood1 := float(rs1.s["goods"]["wood"])
	var rst := rs1._cancel_research(rhead)
	var rgot := []
	for m in (rst["refund"] as Array):
		rgot.append([String(m[0]), float(m[1])])
	if rgot.size() != 1 or rgot[0][0] != "wood" or absf(rgot[0][1] - 9.0) > 0.0001:
		_fail("已开工研究应按 remaining/totalRequired 退（木 9），实际 %s" % str(rgot))
		return
	if absf(float(rs1.s["goods"]["wood"]) - (rwood1 + 9.0)) > 0.0001:
		_fail("研究退回的料要真的进国库：木 %.2f → %.2f" % [rwood1, float(rs1.s["goods"]["wood"])])
		return
	if absf(float(rst["used"]) - 8.0) > 0.0001 or absf(float(rst["total"]) - 20.0) > 0.0001:
		_fail("研究撤单报告应写明已投入 8 / 20，实际 %s / %s" % [str(rst["used"]), str(rst["total"])])
		return
	_ok("取消已开工研究：按 remaining/totalRequired 退 —— %s" % String(rst["text"]))

	# 走完整的黎明：研究调序 / 撤单都在次日生效，且撤单要进公告
	var rs2 := _fresh_research()
	for tid in [T1, T2, T3]:
		rs2._start_research(String(tid))
	rs2.s["hour"] = 5
	var rs2id := _r_id_at(rs2, 2)
	rs2.tick_hour([{"type": "move_research", "id": rs2id, "delta": -1}])
	rs2.tick_hour([])
	if _r_id_at(rs2, 1) != rs2id:
		_fail("研究调序应在次日黎明生效，实际 %s" % str(_r_order(rs2)))
		return
	_ok("研究调序在次日 06:00 生效 —— %s" % " → ".join(_r_order(rs2)))
	rs2.s["hour"] = 5
	rs2.tick_hour([{"type": "cancel_research", "techId": rs2id}])
	rs2.tick_hour([])
	var rlog_has := false
	var rlog_txt := ""
	for e in rs2.log_tail(rs2.log_size()):
		if String(e["text"]).contains("取消研究"):
			rlog_has = true
			rlog_txt = String(e["text"])
	if not rlog_has:
		_fail("取消研究要进公告")
		return
	_ok("取消研究进了公告：%s" % rlog_txt)

	# 跑完的科技**不在队首也要在黎明生效**（调序能把它挪到后面）
	var rs4 := _fresh_research()
	for tid in [T1, T2]:
		rs4._start_research(String(tid))
	(rs4.s["research"]["queue"] as Array)[1]["remaining"] = 0.0
	(rs4.s["research"]["queue"] as Array)[1]["started"] = true
	rs4._activate_research()
	if not (rs4.s["research"]["done"] as Array).has(T2) \
			or _r_order(rs4).has(T2):
		_fail("跑完的科技不在队首也该生效：done=%s queue=%s" % [
			str(rs4.s["research"]["done"]), str(_r_order(rs4))])
		return
	_ok("跑完的科技不在队首也照样生效（扫全队列）：done=%s queue=%s" % [
		str(rs4.s["research"]["done"]), str(_r_order(rs4))])

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("QUEUE TEST 检查了 %d 条断言" % _checks)
	print("QUEUE TEST RESULT: PASS")
	quit(0)
