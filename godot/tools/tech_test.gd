extends SceneTree

# 科技面板门槛：进得去、列得全、点得动。
#
# 引擎侧（sim_core 的研究系统）与 golden 对拍已经各自验过；
# 这里只锁**界面到引擎的这条链路**：面板能开、能列出全部科技、
# 点「研究」真的把命令送进 pending。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("TECH TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	# 标题页会接管镜头并藏起游戏 UI，测游戏内 UI 前先关掉它
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	# 1. 入口必须存在：科技按钮现在在左侧小地图下方的圆钮列里（不在顶栏）
	var hud = node.get_node_or_null("UI/Root/HUD")
	if hud == null:
		_fail("找不到 UI/Root/HUD")
		return
	var tech_btn: Button = null
	var nav = hud.get_parent().get_node_or_null("NavCol")
	if nav == null:
		nav = hud.find_child("NavCol", true, false)
	if nav != null:
		for c in nav.get_children():
			if c is Button and String((c as Button).tooltip_text) == "科技":
				tech_btn = c
	if tech_btn == null:
		_fail("左侧圆钮列里找不到「科技」按钮")
		return
	if tech_btn.icon == null:
		_fail("「科技」圆钮没有图标")
		return

	# 2. 面板能开、能列出全部科技
	var panel = node.get_node_or_null("UI/Root/Tech")
	if panel == null:
		_fail("找不到 UI/Root/Tech")
		return
	panel.open()
	for i in 3:
		await process_frame

	var sim = node.runner.sim
	var db = node.runner.db
	if db.tech_ids.size() != 29:
		_fail("科技数应为 29，实际 %d" % db.tech_ids.size())
		return

	var labels := []
	for c in panel.find_children("*", "Label", true, false):
		labels.append((c as Label).text)
	var listed := 0
	for tid in db.tech_ids:
		var nm := String(db.techs[tid]["nameZh"])
		for t in labels:
			if String(t).begins_with(nm):
				listed += 1
				break
	if listed != 29:
		_fail("面板只列出了 %d/29 项科技" % listed)
		return

	# 3. 点「研究」→ 命令必须进 pending（次日 06:00 生效）
	var research_btns := []
	for c in panel.find_children("*", "Button", true, false):
		if (c as Button).text == "研究":
			research_btns.append(c)
	if research_btns.is_empty():
		_fail("开局一个可研究的科技都没有（研究所应该可研究）")
		return
	(research_btns[0] as Button).pressed.emit()
	await process_frame
	var queued := false
	for a in (sim.s["pending"] as Array):
		if String(a.get("type", "")) == "research":
			queued = true
	if not queued:
		_fail("点「研究」后没有把命令送进 pending")
		return

	# 4. 推进到次日：研究队列里应该真的出现这一项
	for h in 24:
		sim.tick_hour([])
	await process_frame
	var q: Array = sim.s["research"]["queue"]
	if q.is_empty():
		_fail("次日研究队列仍为空（命令没有被引擎接受）")
		return

	print("TECH TEST 科技=%d 已列出=%d 可研究=%d 队列=%s"
		% [db.tech_ids.size(), listed, research_btns.size(), JSON.stringify(q)])
	print("TECH TEST RESULT: PASS")
	quit(0)
