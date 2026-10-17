extends SceneTree

# 任务（引导系统）门槛：判定 / 发钱 / 渐进显示 / 可追溯 / 支线不挡主线。
#
# 契约见 docs/quests.md。与 TS 侧 `scripts/check-quests.ts` **同口径、同数字**：
#   1. 渐进显示：`requires` 没全完成的任务看不见（玩家不知道后面还有什么）
#   2. 黎明结算：达成即完成、发钱、写公告 —— 不需要玩家"提交"
#   3. 可追溯：玩家先干了、任务后出现（同一次黎明里连锁解锁）也当场算完成
#   4. 支线不挡主线：章节奖励只数非支线任务
#   5. 不回退：完成过就是完成过，钱不重复发
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/quest_test.gd

const SEED := 20261016

var db = null
var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("QUEST TEST FAIL: ", msg)
	print("QUEST TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _money(sim) -> float:
	return float(sim.s["government"]["money"])

func _fresh() -> SimCore:
	var sim := SimCore.new(db)
	sim.new_game("v0.3", SEED)
	for g in db.goods.keys():
		sim.s["goods"][g] = 5000.0
	sim.s["government"]["money"] = 10000.0
	return sim

## 直接塞一座"已建成"的建筑（任务判定看的是 `s["shops"]`，在途工地不算）。
func _add_shop(sim, def_id: String, n: int = 1) -> void:
	var shops: Array = sim.s["shops"]
	for _i in n:
		var d: Dictionary = db.buildings[def_id]
		shops.append({
			"id": "%s#q%d" % [def_id, shops.size() + 1],
			"defId": def_id,
			"owner": "state",
			"targetWorkers": int(d["workers"]),
			"wage": float(db.economy["refWage"]),
			"wageCap": float(db.economy["defaultWageCap"]),
			"level": 1,
			"active": true,
			"profit": 0.0,
			"skill": 50.0,
			"planned": 0.0,
		})

func _add_residents(sim, n: int, class_id: String = "poor", sat: float = 70.0) -> void:
	var residents: Array = sim.s["residents"]
	for _i in n:
		residents.append({
			"id": "res#q%d" % (residents.size() + 1),
			"classId": class_id,
			"savings": 10.0,
			"satisfaction": sat,
			"skill": 50.0,
			"employed": false,
		})

func _view_ids(sim) -> Array:
	var out := []
	for q in sim.quest_view():
		out.append(String(q["id"]))
	return out

## 面板的数据源（`quest_journal()`）里的任务 id。
func _journal_ids(sim) -> Array:
	var out := []
	for q in sim.quest_journal():
		out.append(String(q["id"]))
	return out

func _texts(sim, qid: String) -> Array:
	var out := []
	for g in (sim.quest_progress(qid)["goals"] as Array):
		out.append(String(g["text"]))
	return out

func _log_text(logs: Array) -> String:
	var parts := PackedStringArray()
	for l in logs:
		parts.append(String(l["text"]))
	return " / ".join(parts)

## 摆一个"第 1~3 章主线全都已经干完了"的村子（建筑 / 科技 / 住房 / 人口 / 台账）。
func _stage3(sim) -> void:
	for id in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm",
			"research_institute", "quarry", "clay_pit", "firewood_works",
			"brick_kiln", "construction_works"]:
		_add_shop(sim, String(id))
	sim.s["housing"]["hut"] = 8                      # 容量 32 → 「住得下」
	_add_residents(sim, 60, "poor", 70.0)            # 人口 60 + 满意度均值约 69
	sim.s["research"]["done"] = ["stonework", "digging", "firewood", "brickmaking", "construction"]
	sim.s["goods"]["brick"] = 100.0
	# 单日产能看的是**台账**（history），不是库存 —— 所以这儿得塞一天的历史
	(sim.s["history"] as Array).append({
		"day": 1, "population": 60, "avgSatisfaction": 70.0, "money": 0.0,
		"hungry": 0, "employed": 0,
		"ledger": {"day": 1, "wages": 0.0, "tax": 0.0, "rent": 0.0, "sales": 0.0,
			"produced": {"coarse_bread": 40.0, "vegetable": 20.0},
			"consumed": {}, "bought": {}},
	})

func _near(a: float, b: float) -> bool:
	return absf(a - b) < 1e-6

func _run() -> void:
	db = ContentDB.load_all()
	if db.quest_ids.is_empty():
		_fail("content/quests.json 没被加载（quest_ids 为空）")
		return

	# ---- 0. 追踪条标题上那张图标得真的在 ---------------------------------
	# 图标被删掉或改名时，Godot **不报错**，只是标题旁边空一块（`panel_icon()`
	# 拿不到就返回 null，代码里是 `if ico != null`）。这条专门把它兜住。
	var qico: Texture2D = UIKit.panel_icon("quest_panel")
	if qico == null:
		_fail("追踪条标题的图标 `assets/ui/panel/quest_panel.png` 不见了（标题旁边会空一块）")
		return
	if qico.get_width() != 32 or qico.get_height() != 32:
		_fail("quest_panel.png 应当是 32x32（追踪条按 16 = 一半显示，非 32 会重采样发糊），实际 %dx%d"
			% [qico.get_width(), qico.get_height()])
		return
	_ok("追踪条标题图标在位：quest_panel.png 32x32（按 16px 显示）")

	# ---- 0b. 任务面板的数据源：quest_journal() ---------------------------
	# 面板与追踪条**不是**一回事：追踪条只要"当前该做 / 今天刚做完"，
	# 面板要把做过的历史都留着给玩家翻（用户："此面板记录之前完成的所有任务"）。
	var sj := _fresh()
	if _journal_ids(sj).size() != 2:
		_fail("开局：面板里应当就是那两条并行任务，实际 %s" % str(_journal_ids(sj)))
		return
	var j0 := sj.quest_journal()
	for q in j0:
		if String(q.get("brief", "")) == "" or int(q.get("reward", 0)) <= 0:
			_fail("任务「%s」的面板数据少了 brief 或 reward（右侧会空一块）" % String(q["id"]))
			return
	if _journal_ids(sj).has("q04_institute"):
		_fail("锁着的任务不该进面板（渐进显示在面板上也要守）")
		return
	_ok("面板：开局两条 + 每条都带 brief / reward，锁着的仍然看不见")

	for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(sj, bid, 1)
	sj._run_dawn()
	if not _journal_ids(sj).has("q03a_housing_capacity"):
		_fail("第 1 章两条完成后，面板里应当多出第 2 章那三条，实际 %s" % str(_journal_ids(sj)))
		return
	# 走够一天：追踪条会把"今天刚完成"的收掉，面板必须留着
	for _h in 24:
		sj.tick_hour()
	if _view_ids(sj).has("q01_bread_chain"):
		_fail("隔天追踪条应当已经收掉 q01（不再是今天完成的）")
		return
	var jq := {}
	for q in sj.quest_journal():
		if String(q["id"]) == "q01_bread_chain":
			jq = q
	if jq.is_empty() or not bool(jq["done"]) or int(jq["day"]) < 0:
		_fail("隔天面板里 q01 应当还在、并记着第几天完成，实际 %s" % str(jq))
		return
	if _journal_ids(sj).has("q18_pop1000"):
		_fail("终点任务（锁着的）混进面板了")
		return
	_ok("面板：隔天 still 留着已完成的 q01（第 %d 天），锁着的一律不进" % int(jq["day"]))

	# ---- 1. 开局：只看得见两条并行任务，后面的一律不可见 -------------------
	var s1 := _fresh()
	var ids1 := _view_ids(s1)
	if ids1 != ["q01_bread_chain", "q02_vegetable"]:
		_fail("开局可见任务不对：%s" % str(ids1))
		return
	_ok("开局只看得到第 1 章的两条任务：%s" % str(ids1))
	if ids1.has("q03a_housing_capacity") or ids1.has("q04_institute"):
		_fail("未解锁的任务不该可见")
		return
	_ok("未解锁的任务不可见（别让玩家知道后面干嘛）")
	if str(_texts(s1, "q03a_housing_capacity")[0]) != "住房容量 24/32":
		_fail("住房容量文案不对：%s" % str(_texts(s1, "q03a_housing_capacity")))
		return
	_ok("开局进度文案：住房容量 24/32")
	if str(_texts(s1, "q01_bread_chain")[0]) != "小麦农场 0/1":
		_fail("小麦农场文案不对：%s" % str(_texts(s1, "q01_bread_chain")))
		return
	_ok("开局进度文案：小麦农场 0/1")

	# ---- 2. 黎明结算：达成即完成、发钱、写公告、章节奖励一起发 ------------
	var s2 := _fresh()
	_add_shop(s2, "wheat_farm")
	_add_shop(s2, "coarse_mill")
	_add_shop(s2, "coarse_bakery")
	_add_shop(s2, "vegetable_farm")
	var before2 := _money(s2)
	var logs2: Array = s2._run_dawn()
	var gain2 := _money(s2) - before2
	if not _near(gain2, 2000.0):
		_fail("同一次黎明两条任务 + 第 1 章应当 +2000，实际 +%s" % str(gain2))
		return
	_ok("同一次黎明完成两条任务，一起结算（+2000 金 = 两条任务 + 第 1 章）")
	if int(s2.s["quests"]["chapters"].get("1", -1)) != int(s2.s["day"]):
		_fail("第 1 章奖励没发：%s" % str(s2.s["quests"]["chapters"]))
		return
	_ok("第 1 章全绿 → 章节奖励也当场发（第 %d 天）" % int(s2.s["day"]))
	if int(s2.s["quests"]["done"].get("q01_bread_chain", -1)) != int(s2.s["day"]):
		_fail("完成记录没写进 quests.done")
		return
	_ok("完成记录写在 quests.done 里")
	var text2 := _log_text(logs2)
	if not text2.contains("完成 2 项任务（+1000 金）：粗面包链、蔬菜农场"):
		_fail("公告没写清楚：%s" % text2)
		return
	_ok("公告里写明完成了什么、加了多少钱")
	if not text2.contains("新任务：住得下、按人口配产能、让人愿意来"):
		_fail("公告没报出新任务：%s" % text2)
		return
	_ok("公告里报出被\"顶\"出来的新任务")
	if not text2.contains("章节「先吃饱」全部完成（+1000 金）"):
		_fail("章节奖励没写公告：%s" % text2)
		return
	_ok("章节奖励也写公告")

	# ---- 3. 渐进显示：完成后才露出下一层，且是三条并行 ---------------------
	var s3 := _fresh()
	for id in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(s3, String(id))
	s3._run_dawn()
	var ids3 := _view_ids(s3)
	for need in ["q03a_housing_capacity", "q03b_output", "q03c_satisfaction"]:
		if not ids3.has(need):
			_fail("第 2 章的三条任务应当同时可见：%s" % str(ids3))
			return
	_ok("第 2 章的三条任务同时可见（可并行）")
	if ids3.has("q04_institute"):
		_fail("第 3 章还不该可见：%s" % str(ids3))
		return
	_ok("第 3 章仍然不可见（前置没完成）")
	if ids3.has("q01_bread_chain") or ids3.has("q02_vegetable"):
		_fail("已完成的任务不该留在追踪条上（6:00 结算完就收走）：%s" % str(ids3))
		return
	_ok("6:00 结算掉的任务立刻从追踪条上收走（用户 2026-10 的要求）")
	if not (ids3.has("q03a_housing_capacity") and ids3.has("q03b_output")
			and ids3.has("q03c_satisfaction")):
		_fail("新解锁的三条该接上追踪条：%s" % str(ids3))
		return
	_ok("新解锁的任务接上追踪条")
	s3._run_dawn()
	var ids3b := _view_ids(s3)
	if ids3b.has("q01_bread_chain") or ids3b.has("q02_vegetable"):
		_fail("隔天之后已经完成的任务更不该回来：%s" % str(ids3b))
		return
	_ok("已完成的不会回到追踪条上")

	# ---- 4. 可追溯：先干了、任务后出现 —— 同一次黎明里连锁完成 ------------
	var s4 := _fresh()
	for id in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(s4, String(id))
	s4.s["housing"]["hut"] = 8                       # 早就把容量撑到 32 了
	var before4 := _money(s4)
	var logs4: Array = s4._run_dawn()
	var gain4 := _money(s4) - before4
	if int(s4.s["quests"]["done"].get("q03a_housing_capacity", -1)) != int(s4.s["day"]) \
			or not _near(gain4, 2500.0):
		_fail("连锁结算不对：done=%s 钱 +%s" % [str(s4.s["quests"]["done"]), str(gain4)])
		return
	_ok("同一次黎明连锁完成 3 条（含那条\"早就干完了\"的）+2500 金")
	if not _log_text(logs4).contains("完成 3 项任务（+1500 金）"):
		_fail("连锁完成的公告没合并：%s" % _log_text(logs4))
		return
	_ok("公告把连锁的几条合并成一条")

	# ---- 5. 没达成就不结算，而且钱不会重复发 ------------------------------
	var s5 := _fresh()
	for id in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(s5, String(id))
	s5._run_dawn()
	var money5a := _money(s5)
	var logs5: Array = s5._run_dawn()
	if not _near(_money(s5), money5a):
		_fail("没达成却发了钱：%s → %s" % [str(money5a), str(_money(s5))])
		return
	_ok("没达成 → 一分钱不发")
	for l in logs5:
		if String(l["text"]).contains("完成任务：") or String(l["text"]).contains("完成 2 项任务"):
			_fail("没达成却写了完成公告：%s" % String(l["text"]))
			return
	_ok("没达成 → 不写\"完成\"公告")

	# ---- 6. 支线不挡主线 + 可追溯 + 不回退 --------------------------------
	var s6 := _fresh()
	_stage3(s6)
	var before6 := _money(s6)
	s6._run_dawn()
	var gain6 := _money(s6) - before6
	if not _near(gain6, 12 * 500.0 + 3 * 1000.0):
		_fail("1~3 章主线连锁结算应为 +9000，实际 +%s（done=%s）"
			% [str(gain6), str(s6.s["quests"]["done"].keys())])
		return
	_ok("同一次黎明把 1~3 章主线连锁结算完（12 条任务 + 3 个章节奖励 = +9000 金）")
	if int(s6.s["quests"]["done"].get("q06_pop50", -1)) != int(s6.s["day"]):
		_fail("人口早过 50 却没当场结算")
		return
	_ok("前置齐了 → 人口早过 50 也当场算完成（可追溯）")
	if int(s6.s["quests"]["chapters"].get("3", -1)) != int(s6.s["day"]) \
			or s6.s["quests"]["done"].has("q08_tools"):
		_fail("支线影响了章节奖励：chapters=%s done=%s"
			% [str(s6.s["quests"]["chapters"]), str(s6.s["quests"]["done"].keys())])
		return
	_ok("第 3 章支线没做也照样拿章节奖励")
	if not _view_ids(s6).has("q08_tools"):
		_fail("支线本身应当仍可见：%s" % str(_view_ids(s6)))
		return
	_ok("支线本身仍可见（只是不挡路）")
	var day6 := int(s6.s["quests"]["done"]["q06_pop50"])
	(s6.s["residents"] as Array).resize(10)
	s6._run_dawn()
	if int(s6.s["quests"]["done"]["q06_pop50"]) != day6:
		_fail("人口掉回去后完成记录被改了")
		return
	_ok("人口掉回去也不回退（完成过就是完成过）")

	# ---- 7. 进度文案与"看产量不看库存" ------------------------------------
	var s7 := _fresh()
	s7.s["goods"]["coarse_bread"] = 9999.0
	if bool(s7.quest_progress("q03b_output")["met"]):
		_fail("库存再多也不算完成：单日产量看的是台账")
		return
	_ok("库存再多也不算：单日产量看的是台账")
	s7.s["ledgerToday"]["produced"]["coarse_bread"] = 31.0
	s7.s["ledgerToday"]["produced"]["vegetable"] = 16.0
	var p7: Dictionary = s7.quest_progress("q03b_output")
	if not bool(p7["met"]) or bool(p7["done"]):
		_fail("当天产量达标应当显示达成（但未结算）")
		return
	_ok("当天产量达标 → 立刻显示达成（但要等黎明结算）")
	if String((p7["goals"] as Array)[0]["text"]) != "粗面包单日产量 31/30":
		_fail("产量文案不对：%s" % String((p7["goals"] as Array)[0]["text"]))
		return
	_ok("产量文案：粗面包单日产量 31/30")
	var s8 := _fresh()
	if String((s8.quest_progress("q05a_stone")["goals"] as Array)[0]["text"]) != "研究「石作」":
		_fail("科技文案不对")
		return
	_ok("科技目标显示成勾选项文案：研究「石作」")
	if String((s8.quest_progress("q15_private_housing")["goals"] as Array)[0]["text"]) != "私有住房 0/5 户":
		_fail("私有住房文案不对")
		return
	_ok("私有住房文案：私有住房 0/5 户")

	# ---- 8. 一整天：结算只发生一次 ----------------------------------------
	var s9 := _fresh()
	for id in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(s9, String(id))
	for _h in range(int(db.time["hoursPerDay"])):
		s9.tick_hour()
	if (s9.s["quests"]["done"] as Dictionary).size() != 2 \
			or not (s9.s["quests"]["chapters"] as Dictionary).has("1"):
		_fail("走完一天后的完成记录不对：%s / %s"
			% [str(s9.s["quests"]["done"].keys()), str(s9.s["quests"]["chapters"].keys())])
		return
	_ok("一整天下来：两条任务 + 第 1 章的完成记录各只记一次")
	var hits := 0
	for l in s9.log_tail(s9.log_size()):
		if String(l["text"]).contains("完成 2 项任务"):
			hits += 1
	if hits != 1:
		_fail("完成公告在这一天里出现了 %d 次" % hits)
		return
	_ok("完成公告在这一天里只出现一次")

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("QUEST TEST 检查了 %d 条断言" % _checks)
	print("QUEST TEST RESULT: PASS")
	quit(0)
