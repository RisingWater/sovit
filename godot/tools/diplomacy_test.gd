extends SceneTree

# 外交 / 军事面板门槛（B4，2026-10）。见 docs/diplomacy.md §11。
#
# 红了说明什么：
#   ① 外交办公室建起来之后左侧圆钮还是 7 个 / 第 8 个点不开（面板进不去）
#   ② 面板不是两个页签，或者「世界」页没有地图 / 没有 13 个势力
#   ③ 关系写的是数字而不是档位名（用户："右侧是好感（只显示敌对，友善等状态）"）
#   ④ 送礼不扣钱 / 不涨好感，或者送到天花板还在收钱
#   ⑤ 「结盟」该灰（好感不够 / 不可结盟）时亮了，或者该亮时灰着
#   ⑥ 「派兵进攻」不把关系打到敌对，或者对盟友 / 附庸也放行
#   ⑦ 商路门槛没接上（冷淡的城还能「派车」）
#   ⑧ 米拉立绘不在面板上

const SEED := 20261101

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("DIPLOMACY TEST FAIL: ", msg)
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
	world.start_new_game(SEED, 1.0, "外交测试")
	await process_frame
	var runner = node.get("runner")
	var sim = runner.sim
	var hud = node.get("_hud")
	var panel = node.get("_panel_war")

	if panel == null:
		_fail("main.tscn 里没有创建外交面板（_panel_war）")
		return

	# ---- ① 没有外交办公室：圆钮藏着、面板也打不开
	hud.refresh_nav_buttons()
	var war_btn: Button = hud.get("_war_nav_btn")
	if war_btn == null:
		_fail("HUD 里没有第 8 个圆钮（_war_nav_btn）")
		return
	if war_btn.visible:
		_fail("还没建外交办公室，左侧「外交」圆钮就已经露出来了")
		return
	hud._open_war()
	if panel.visible:
		_fail("还没建外交办公室就能打开外交面板")
		return

	# ---- ② 建一座外交办公室（直接塞进 shops，绕开建造流程），圆钮该出现
	var emb := {"id": "embassy#1", "defId": "embassy", "owner": "state", "targetWorkers": 2,
		"wage": 3.0, "wageCap": 6.0, "level": 1, "active": true, "profit": 0.0,
		"skill": 1.0, "planned": 0.0}
	(sim.s["shops"] as Array).append(emb)
	hud.refresh_nav_buttons()
	if not war_btn.visible:
		_fail("外交办公室建起来了，左侧「外交」圆钮还是藏着")
		return
	hud.activate_nav(7)   # 第 8 个圆钮
	await process_frame
	if not panel.visible:
		_fail("点第 8 个圆钮没打开外交面板")
		return

	# ---- ③ 两个页签 + 表格里 13 个势力
	var tab_btns: Array = panel.get("_tab_btns")
	if tab_btns.size() != 2:
		_fail("页签应当两个（世界 / 军事），实际 %d 个" % tab_btns.size())
		return
	if String((tab_btns[0] as Button).text) != "世界" or String((tab_btns[1] as Button).text) != "军事":
		_fail("页签名字不对：%s / %s" % [
			String((tab_btns[0] as Button).text), String((tab_btns[1] as Button).text)])
		return

	var snap: Dictionary = sim.factions_snapshot()
	var list: Array = snap["factions"]
	if list.size() != 13:
		_fail("势力应当 13 个，快照里只有 %d 个" % list.size())
		return
	var cards: Dictionary = panel.get("_cards")
	if cards.size() != 11:
		_fail("面板上只建出 %d 张势力卡（应 11：13 家减去没城的银叶 / 灰烬）" % cards.size())
		return

	# ---- ④ 关系只写档位名（不许出现数字）
	for f in list:
		var label := String((f as Dictionary)["label"])
		if label.is_empty() or label.contains("0") or label.contains("-"):
			_fail("「%s」的关系写着 %s —— 只该写档位名" % [String((f as Dictionary)["nameZh"]), label])
			return

	# ---- ⑤ 送礼：扣钱 + 涨好感
	var peak: Dictionary = {}
	for f2 in list:
		if String((f2 as Dictionary)["id"]) == "peak":
			peak = f2
	if peak.is_empty():
		_fail("快照里没有铁峰公国")
		return
	if String(peak["band"]) != "cold":
		_fail("铁峰开局应当是冷淡，实际 %s" % String(peak["band"]))
		return
	var money0 := float(sim.s["government"]["money"])
	var rep0 := int(peak["rep"])
	# 外交范围（B4-6）：邦交只给 2 天，铁峰城 4 天 —— 先验"够不着就不许送钱"
	if bool(peak.get("inRange", true)):
		_fail("邦交（2 天）刚研究完就够得着 4 天外的铁峰城 —— 范围闸没生效")
		return
	sim.s["government"]["money"] = 5000.0
	panel._on_gift("peak", 500)
	if float(sim.s["government"]["money"]) != 5000.0:
		_fail("超出外交范围还把钱扣了（国库 %.2f）" % float(sim.s["government"]["money"]))
		return
	# 「使节驿站」→ 范围 4 天：够得着 4 天内的（圣火 / 沙海 / 铁鸦堡），铁峰城 5 天还不够
	sim.s["research"]["done"].append("diplomacy_range_1")
	var snap_r: Dictionary = sim.factions_snapshot()
	if int(snap_r.get("rangeDays", 0)) != 4:
		_fail("研究「使节驿站」之后范围应当是 4 天，实际 %d" % int(snap_r.get("rangeDays", 0)))
		return
	for fr in (snap_r["factions"] as Array):
		var f0 := fr as Dictionary
		# 范围 4 天：1/2/3/4 天的九家够得着；5 天的圣都 / 铁峰城还不够
		# 5 天的圣都 / 铁峰城还不够；没城的银叶 / 灰烬要等「常驻使团」
		var want := not (String(f0["id"]) in ["holy_see", "peak", "silverleaf", "ashen_circle"])
		if bool(f0.get("inRange", false)) != want:
			_fail("范围 4 天时「%s」的够得着应当是 %s" % [String(f0["nameZh"]), str(want)])
			return
	# 「常驻使团」→ 全图：铁峰城（5 天）这才够得着
	sim.s["research"]["done"].append("diplomacy_range_2")
	if int(sim.factions_snapshot().get("rangeDays", 0)) != -1:
		_fail("研究「常驻使团」之后应当是全图（-1）")
		return
	panel._on_gift("peak", 500)
	var after: Dictionary = sim.factions_snapshot()
	var peak2: Dictionary = {}
	for f3 in (after["factions"] as Array):
		if String((f3 as Dictionary)["id"]) == "peak":
			peak2 = f3
	if float(sim.s["government"]["money"]) != 4500.0:
		_fail("送 500 钱之后国库应当是 4500，实际 %.2f" % float(sim.s["government"]["money"]))
		return
	if int(peak2["rep"]) != rep0 + 500:
		_fail("送 500 钱之后好感应当 +500（%d → %d）" % [rep0, int(peak2["rep"])])
		return
	# 天花板：一路送到冷淡的上限（-2001）就不许再收钱
	sim.s["government"]["money"] = 5000.0
	for i in 10:
		panel._on_gift("peak", 5000)
	var after2: Dictionary = sim.factions_snapshot()
	for f4 in (after2["factions"] as Array):
		if String((f4 as Dictionary)["id"]) == "peak":
			if int((f4 as Dictionary)["rep"]) != int((f4 as Dictionary)["cap"]):
				_fail("铁峰好感应当停在它的天花板 %d，实际 %d" % [
					int((f4 as Dictionary)["cap"]), int((f4 as Dictionary)["rep"])])
				return
	if String(peak2["band"]) == "neutral":
		_fail("铁峰在天花板时不该变成中立（天花板是冷淡）")
		return

	# ---- ⑥ 结盟：好感没满时不能结；曙光城是可以结盟的那一类
	var dawn: Dictionary = {}
	for f5 in (sim.factions_snapshot()["factions"] as Array):
		if String((f5 as Dictionary)["id"]) == "dawn":
			dawn = f5
	if not bool(dawn.get("allyable", false)):
		_fail("曙光城应当是可以结盟的（allyable）")
		return
	if bool(dawn.get("canAlly", false)):
		_fail("曙光城好感没满就允许结盟了")
		return

	# ---- ⑦ 开战：关系直接到 -6000（敌对）
	panel._on_attack("dawn")
	var dawn2: Dictionary = {}
	for f6 in (sim.factions_snapshot()["factions"] as Array):
		if String((f6 as Dictionary)["id"]) == "dawn":
			dawn2 = f6
	if int(dawn2["rep"]) != -6000:
		_fail("宣战之后曙光城的好感应当是 -6000，实际 %d" % int(dawn2["rep"]))
		return
	if String(dawn2["band"]) != "enemy":
		_fail("宣战之后应当是「敌对」，实际「%s」" % String(dawn2["band"]))
		return

	# ---- ⑧ 商路门槛：敌对的城「派车」要被拒（理由说人话）
	sim.s["research"]["done"].append("trade_caravan_1")
	var why: String = sim.assign_route("dawn")
	if why == "":
		_fail("曙光城已经敌对，却还能派商队过去")
		return
	if not why.contains("关系"):
		_fail("派车被拒的理由没说清是关系问题：%s" % why)
		return

	# ---- ⑨ 米拉立绘
	var portrait = panel.get("_portrait")
	if portrait == null or String(portrait.get("id")) != "milla":
		_fail("外交面板右下角不是米拉立绘")
		return
	if portrait.get("tex") == null:
		_fail("米拉立绘的贴图没载进来（assets/portraits/milla.png）")
		return

	print("DIPLOMACY TEST 面板：两页签 / 13 张卡 / 关系只写档位 / 送礼·结盟·开战 / 商路门槛 / 米拉 ✅")
	print("DIPLOMACY TEST RESULT: PASS")
	quit(0)
