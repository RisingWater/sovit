extends SceneTree

# 贸易市场面板门槛（M4，2026-10）。
#
# red 的含义：① 点不开（open_trade 之后不可见）② 有游商却画不出行
#              ③ 点按钮不发命令（玩家会以为"点了没反应"）④ 快照里的剩余天数不对
#              ⑤ 建造栏里找不到「贸易市场」/ 圆钮不出现（用户："市场这个建筑没了，
#                 这样游商系统的入口在哪里？"）

const SEED := 20261025

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("TRADEPANEL TEST FAIL: ", msg)
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
	world.start_new_game(SEED, 1.0, "贸易测试")
	await process_frame
	var runner = node.get("runner")
	var sim = runner.sim

	# 让游商到货（第 3 章 + 当天到）
	sim.s["quests"]["chapters"]["3"] = 3
	sim.s["trade"]["nextWaveDay"] = int(sim.s["day"])
	sim._update_caravans(int(sim.s["day"]))
	if (sim.s["trade"]["caravans"] as Array).is_empty():
		_fail("第 3 章了却没有游商到货（引擎侧没生成）")
		return

	var panel = node.get("_panel_trade")
	if panel == null:
		_fail("main.tscn 里没有创建贸易市场面板（_panel_trade）")
		return
	panel.open_trade()
	await process_frame
	if not panel.visible:
		_fail("open_trade() 之后面板不可见")
		return

	var body: VBoxContainer = panel.get("_body")
	if body == null or body.get_child_count() == 0:
		_fail("有游商时面板一行都没画出来")
		return
	print("TRADEPANEL TEST 打开：面板可见，%d 个内容块 ✅" % body.get_child_count())

	# 快照：剩余天数 = leaveDay - day + 1
	var snap: Dictionary = sim.trade_snapshot()
	var cv: Dictionary = (snap["caravans"] as Array)[0]
	var want := int(sim.s["trade"]["caravans"][0]["leaveDay"]) - int(sim.s["day"]) + 1
	if int(cv["daysLeft"]) != want:
		_fail("剩余天数 %d，应当 %d" % [int(cv["daysLeft"]), want])
		return
	if (cv["buy"] as Array).size() != 4 or (cv["sell"] as Array).size() != 4:
		_fail("快照里的收/卖报价不是 4/4")
		return
	print("TRADEPANEL TEST 快照：剩余 %d 天、收 4 卖 4 ✅" % want)

	# 点按钮必须发命令（走 runner.enqueue）
	var before: int = (sim.s["pending"] as Array).size()
	panel._send("sell_to_caravan", String(cv["id"]), String((cv["buy"] as Array)[0]["good"]), 1)
	var after: int = (sim.s["pending"] as Array).size()
	if after <= before:
		_fail("点「卖」没有把命令排进 pending（玩家会以为点了没反应）")
		return
	var last: Dictionary = (sim.s["pending"] as Array)[after - 1]
	if String(last["type"]) != "sell_to_caravan":
		_fail("排进去的命令类型是 %s" % String(last["type"]))
		return
	print("TRADEPANEL TEST 命令：点了「卖」→ pending 多了一条 sell_to_caravan ✅")

	# 关闭
	panel.close_panel()
	await process_frame
	if panel.visible:
		_fail("close_panel() 之后还可见")
		return

	# ---- 入口：建造栏里找得到 + 圆钮不依赖那座建筑 -------------------------
	# 用户 2026-10："市场这个建筑没了，这样游商系统的入口在哪里？"
	# ① 贸易市场必须在建造栏「市政」页（以前埋在「工业」页第 2 页里，等于没有）
	var bar = node.get_node_or_null("UI/Root/BuildBar")
	if bar == null:
		_fail("找不到建造栏（UI/Root/BuildBar）")
		return
	if not (bar._ids_of("市政") as Array).has("trade_market"):
		_fail("贸易市场不在建造栏「市政」页（现在在：%s）" % str(bar._ids_of("市政")))
		return
	for cat in ["民生工业", "重工业"]:
		if (bar._ids_of(cat) as Array).has("trade_market"):
			_fail("贸易市场跑到「%s」页去了（那两页是工坊，市场属于市政）" % cat)
			return
	print("TRADEPANEL TEST 建造栏：「市政」页里有贸易市场 ✅")

	# ② 圆钮：开局（没市场、没通商）藏着 → 研究完「通商」就出现
	var hud = node.get("_hud")
	if hud == null:
		_fail("找不到 HUD（main 的 _hud）")
		return
	var btn: Button = hud.get("_trade_nav_btn")
	if btn == null:
		_fail("HUD 里没有贸易圆钮（_trade_nav_btn）")
		return
	hud.refresh_nav_buttons()
	if btn.visible:
		_fail("还没有市场、也没研究「通商」，贸易圆钮就已经露出来了")
		return
	var done: Array = sim.s["research"]["done"]
	if not done.has("trade"):
		done.append("trade")
	hud.refresh_nav_buttons()
	if not btn.visible:
		_fail("研究完「通商」之后贸易圆钮还是不出现（游商系统就没有入口了）")
		return
	print("TRADEPANEL TEST 入口：研究「通商」之后贸易圆钮出现（不必先建市场）✅")

	print("TRADEPANEL TEST RESULT: PASS")
	quit(0)
