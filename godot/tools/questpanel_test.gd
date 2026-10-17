extends SceneTree

# 任务面板门槛（用户："任务面板放在左侧圆形菜单按钮…记录之前完成的所有任务…"）。
#
# 契约见 docs/town.md §十九。这条门槛查六件事（每条都写清"红了说明什么"）：
#
#   1. 左侧圆钮列里**真有**「任务」那一个，而且是第 5 个（F5）
#   2. 点它（`activate_nav(4)`）能打开面板 —— 入口接错了就是"按钮点了没反应"
#   3. 打开时**默认选中第一个未完成的任务**（用户点名要求的行为）
#   4. 左树按**章**分组、能展开收起；收起后那一章的条目不再画出来
#   5. 右栏四块齐全：描述（内容里的 `brief`）/ 要求（引擎拼的 goal.text）/ 完成情况 / 第几天完成
#   6. 完成过的任务**仍然留在树里**（面板要"记录之前完成的所有任务"），
#      而追踪条那时候已经把它收掉了 —— 两者数据源不同，别混
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/questpanel_test.gd

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("QUESTPANEL TEST FAIL: ", msg)
	print("QUESTPANEL TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _chk(cond: bool, msg: String) -> bool:
	if not cond:
		_fail(msg)
	return cond

## 某个节点子树里所有 Label / Button 的可见文本（面板内容全靠它们画）。
func _texts(root: Node) -> String:
	var parts := PackedStringArray()
	for c in root.find_children("*", "Label", true, false):
		parts.append((c as Label).text)
	for c in root.find_children("*", "Button", true, false):
		parts.append((c as Button).text)
	return " / ".join(parts)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		_fail("加载不了 res://scenes/main.tscn")
		return
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var hud = node.get_node_or_null("UI/Root/HUD")
	var panel = node.get_node_or_null("UI/Root/QuestPanel")
	var runner = node.get("runner")
	if hud == null or panel == null or runner == null:
		_fail("找不到 HUD / QuestPanel / runner")
		return

	# ---- 1. 圆钮列里那一个 ------------------------------------------------
	# ⚠️ 圆钮列**不是** HUD 的子节点：`hud._build_nav()` 把它挂到 HUD 的**父节点**
	# （`UI/Root`）上 —— PanelContainer 会把子节点拉满整个顶栏。所以从这里找。
	var root_ui = node.get_node_or_null("UI/Root")
	var btn: Button = null
	if root_ui != null:
		for b in root_ui.find_children("Nav_quest_panel", "Button", true, false):
			btn = b
	if not _chk(btn != null, "左侧圆钮列里没有 Nav_quest_panel（那一个按钮）"):
		return
	var idx := (hud._nav_btns as Array).find(btn)
	if not _chk(idx == 4, "「任务」应当是第 5 个圆钮（下标 4），实际下标 %d" % idx):
		return
	if not _chk(String(btn.tooltip_text).contains("F5"), "tooltip 里应当写 F5，实际「%s」" % btn.tooltip_text):
		return
	if not _chk(btn.icon != null, "圆钮上没有图标（quest_panel.png 没加载上？）"):
		return
	_ok("左侧圆钮第 5 个 = 任务（图标在位、tooltip 写着 F5）")

	# ---- 2. 点得开 --------------------------------------------------------
	if not _chk(not panel.visible, "面板一开始不该是打开的"):
		return
	if not _chk(hud.activate_nav(4), "activate_nav(4) 应当打到「任务」那个圆钮"):
		return
	await process_frame
	if not _chk(panel.visible, "点了「任务」圆钮面板没打开"):
		return
	_ok("点圆钮（或按 F5）能打开任务面板")

	# ---- 3. 默认选中第一个未完成的任务 -----------------------------------
	var sim = runner.sim
	var first_open := ""
	for q in sim.quest_journal():
		if not bool(q["done"]):
			first_open = String(q["id"])
			break
	if not _chk(String(panel._sel) == first_open and first_open != "",
			"打开时应当默认选中第一个未完成的任务（%s），实际选中「%s」" % [first_open, panel._sel]):
		return
	_ok("打开时默认选中第一个未完成的任务：%s" % first_open)

	# ---- 4. 左树：分章 + 展开收起 ----------------------------------------
	var tree: Node = panel._tree
	if not _chk(tree.get_child_count() > 0, "左树一条都没画出来"):
		return
	var head_txt := String((tree.get_child(0) as Button).text)
	if not _chk(head_txt.contains("第 1 章"), "左树第一行应当是章节行，实际「%s」" % head_txt):
		return
	if not _chk(head_txt.begins_with("▼"), "章节行展开时应当以 ▼ 开头，实际「%s」" % head_txt):
		return
	var expanded := tree.get_child_count()
	(tree.get_child(0) as Button).pressed.emit()
	await process_frame
	var shut := tree.get_child_count()
	if not _chk(shut < expanded, "收起第 1 章之后行数应当变少（%d → %d）" % [expanded, shut]):
		return
	if not _chk(String((tree.get_child(0) as Button).text).begins_with("▶"),
			"收起之后章节行应当以 ▶ 开头"):
		return
	(tree.get_child(0) as Button).pressed.emit()
	await process_frame
	if not _chk(tree.get_child_count() == expanded, "再点一次应当展开回原来的行数"):
		return
	_ok("左树分章、可展开收起（%d 行 ↔ %d 行）" % [expanded, shut])

	# ---- 5. 右栏四块齐全 --------------------------------------------------
	var detail := _texts(panel._detail)
	for need in ["描述", "要求", "完成情况", "奖励"]:
		if not _chk(detail.contains(need), "右栏少了「%s」那一块：%s" % [need, detail]):
			return
	var brief := String(sim.quest_progress(first_open).get("brief", ""))
	if not _chk(brief != "" and detail.contains(brief.substr(0, 12)),
			"右栏没有把内容里的 brief（智囊口吻的描述）画出来"):
		return
	if not _chk(detail.contains("尚未完成") or detail.contains("已达成"),
			"进行中的任务应当写明状态，实际：%s" % detail):
		return
	_ok("右栏四块齐全：描述（brief）/ 要求 / 完成情况 / 奖励")

	# ---- 6. 完成过的仍然在树里，并且写着第几天完成 ------------------------
	# 先把食物链建起来、跑一次黎明，让 q01 真的完成
	for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		var d: Dictionary = runner.db.buildings[bid]
		sim.s["shops"].append({
			"id": "%s#qp" % bid, "defId": bid, "owner": "state",
			"targetWorkers": int(d["workers"]),
			"wage": float(runner.db.economy["refWage"]),
			"wageCap": float(runner.db.economy["defaultWageCap"]),
			"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		})
	sim._run_dawn()
	# 再走一天：追踪条会把"今天刚完成"的收掉，面板必须留着
	for _h in 24:
		sim.tick_hour()
	panel.open()
	await process_frame
	var day := int(sim.s["quests"]["done"].get("q01_bread_chain", -1))
	if not _chk(day >= 0, "q01 应当已经在 quests.done 里（测试前置没满足）"):
		return
	var view_ids := []
	for q in sim.quest_view():
		view_ids.append(String(q["id"]))
	if not _chk(not view_ids.has("q01_bread_chain"), "追踪条这时候应当已经把 q01 收掉了"):
		return
	# 左树默认只展开"选中那条所在的章"，所以已完成的第 1 章是**收起**的 ——
	# 它的完成情况靠章节行本身交代（`1/2` 这样的计数 + 全绿时的 ★）。
	var tree_txt := _texts(panel._tree)
	if not _chk(tree_txt.contains("第 1 章"), "收起状态也应当看得见第 1 章那一行：%s" % tree_txt):
		return
	if not _chk(tree_txt.contains("2/2") or tree_txt.contains("1/2"),
			"章节行应当带完成计数：%s" % tree_txt):
		return
	# 展开（= 选中它里面的一条）之后，已完成的任务行要在树里
	panel._select("q01_bread_chain")
	await process_frame
	if not _chk(_texts(panel._tree).contains("粗面包链"),
			"选中已完成的任务后，左树里应当有它：%s" % _texts(panel._tree)):
		return
	var done_txt := _texts(panel._detail)
	if not _chk(done_txt.contains("第 %d 天完成" % day),
			"详情里应当写「第 %d 天完成」，实际：%s" % [day, done_txt]):
		return
	if not _chk(done_txt.contains("已入国库"), "已完成的奖励应当标成已入国库：%s" % done_txt):
		return
	_ok("已完成的任务留在面板里，详情写着「第 %d 天完成」（追踪条那时已经收掉了）" % day)

	# ---- 7. 关得掉 --------------------------------------------------------
	var close: Button = null
	for b in panel.find_children("*", "Button", true, false):
		if (b as Button).text == "关闭":
			close = b
	if not _chk(close != null, "面板上没有「关闭」按钮"):
		return
	close.pressed.emit()
	await process_frame
	if not _chk(not panel.visible, "点「关闭」之后面板还开着"):
		return
	_ok("点「关闭」能收掉面板")

	print("QUESTPANEL TEST 检查了 %d 条断言" % _checks)
	print("QUESTPANEL TEST RESULT: PASS")
	quit(0)
