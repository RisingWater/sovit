extends SceneTree

# 科技树面板门槛。
#
# 面板从"列表"改成"树"之后，这里锁的本质没变，但换了形式：
#   1. 圆钮入口还在（左侧小地图下方那一列）
#   2. **28 项科技一个不缺**：每一项都要能在树里找到自己的卡片，卡片名字 = nameZh、且有图标
#   3. **点卡片真的会把研究命令送进 pending**（走真实的按下/抬起路径，不是直接调激活函数）
#   4. 新增：**树的正确性** —— 任何前置的 x 都必须严格小于后继的 x，
#      且每条前置关系都要有连线。不测这条的话，布局算法改坏了没人知道。
#
# 拖动也测：按住 → 移动超过阈值 → 画布必须真的动了，而且**不能**顺手下一个研究单
# （拖动被当成点击是这个交互最容易出的 bug）。

## 科技总数。
##
## 29 → 28：`research_institute` 那条科技已删除（研究所改成开局可建建筑，见 docs/town.md §6）。
## 28 → 43：新增 15 项**效率科技**（农业食品/工业商品/建材/研究速度/建造速度 各 3 级，
## 分布在 era2/3/4，逐级 +10%/+15%/+20%，加法叠加）。见 docs/technology.md。
## 43 → 42：`housing_works`（住房坊）已删除 —— 它产的 `hut` 商品没有任何消费者，
## 建房走的是 `build_housing` 动作。见 docs/technology.md。
## **刻意写死**而不是取 `db.tech_ids.size()`：这样"某项科技莫名消失/多出来"
## 才会被这条门抓住 —— 用 size 就等于把断言变成恒真式。
const EXPECTED_TECHS := 46

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("TECH TEST FAIL: ", msg)
	quit(1)

## ⚠️ InputEventMouseButton **没有** relative 属性（那是 MouseMotion 才有的）。
## 早先这里给它赋 relative，GDScript 报错后整个函数提前返回，
## 结果 _gui_input 收到 null、什么也没发生 —— 表现为"拖动没反应"，查了半天。
func _mouse(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	return e

func _motion(pos: Vector2, rel: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = rel
	return e

func _click(card: Node, pos: Vector2) -> void:
	card._gui_input(_mouse(pos, true))
	card._gui_input(_mouse(pos, false))

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

	# ⚠️ 必须再开一局**真游戏**：`_end_title()` 只是露出 UI，它保留的是标题页的
	# "展示村庄"状态（`showcase_village()` 把每种物资都设成 20000）。
	# 仓储上限上来之后，那份状态第一天就被丢光了（日志里能看到丢了 66 万单位），
	# 于是木材 = 0，第 6 步下的研究命令会因"材料不足"被引擎拒掉 —— 表现为
	# "次日研究队列仍为空"。用真开局（v0.3：木材 300）就没有这个前提问题。
	var world = node.get("world")
	if world != null:
		world.start_new_game(20261014, 1.0, "科技测试")
		await process_frame

	var db = node.runner.db
	var sim = node.runner.sim

	# ---- 1. 入口：科技按钮在左侧小地图下方的圆钮列里（不在顶栏）
	var hud = node.get_node_or_null("UI/Root/HUD")
	if hud == null:
		_fail("找不到 UI/Root/HUD")
		return
	var tech_btn: Button = null
	var nav = hud.get_parent().get_node_or_null("NavCol")
	if nav == null:
		nav = hud.find_child("NavCol", true, false)
	if nav != null:
		# ⚠️ 不要拿 tooltip 做**全等**匹配：圆钮的 tooltip 现在带快捷键提示
		# （"科技（F4）"，`hud.gd::_build_nav`），全等会认不出来。
		# 认节点名（`Nav_research`）最稳，tooltip 前缀只作兜底。
		tech_btn = nav.get_node_or_null("Nav_research") as Button
		if tech_btn == null:
			for c in nav.get_children():
				if c is Button and String((c as Button).tooltip_text).begins_with("科技"):
					tech_btn = c
	if tech_btn == null:
		_fail("左侧圆钮列里找不到「科技」按钮（节点名应是 Nav_research）")
		return
	if tech_btn.icon == null:
		_fail("「科技」圆钮没有图标")
		return

	# ---- 2. 面板打开，全部科技都在树里
	var panel = node.get_node_or_null("UI/Root/Tech")
	if panel == null:
		_fail("找不到 UI/Root/Tech")
		return
	panel.open()
	for i in 3:
		await process_frame
	if db.tech_ids.size() != EXPECTED_TECHS:
		_fail("科技数应为 %d，实际 %d" % [EXPECTED_TECHS, db.tech_ids.size()])
		return

	var cards: Dictionary = panel.get("_cards")
	if cards.size() != EXPECTED_TECHS:
		_fail("树里只建出 %d 张卡片（应 %d）" % [cards.size(), EXPECTED_TECHS])
		return
	for tid in db.tech_ids:
		var t := String(tid)
		if not cards.has(t):
			_fail("科技「%s」没有卡片" % t)
			return
		var card = cards[t]
		var found_name := false
		for c in card.find_children("*", "Label", true, false):
			if String((c as Label).text) == String(db.techs[t]["nameZh"]):
				found_name = true
		if not found_name:
			_fail("卡片「%s」上没有名字标签「%s」" % [t, db.techs[t]["nameZh"]])
			return
		# 科技树是"图标 + 名字"，图标不能缺
		var has_icon := false
		for c in card.find_children("*", "TextureRect", true, false):
			if (c as TextureRect).texture != null:
				has_icon = true
		if not has_icon:
			_fail("卡片「%s」没有图标" % t)
			return

	# ---- 3. 树的正确性：前置 x 严格小于后继 x；每条前置关系都有连线
	var posn: Dictionary = panel.get("_pos")
	var bad := 0
	var edges := 0
	for tid in db.tech_ids:
		var t := String(tid)
		if not posn.has(t):
			_fail("科技「%s」没有布局坐标" % t)
			return
		var px: float = (posn[t] as Vector2).x
		for r in db.techs[t]["requires"]:
			var rt := String(r)
			if not posn.has(rt):
				_fail("科技「%s」的前置「%s」没有坐标" % [t, rt])
				return
			edges += 1
			if (posn[rt] as Vector2).x >= px:
				bad += 1
	if bad > 0:
		_fail("有 %d 条前置关系的 x 没有严格小于后继（树画错了）" % bad)
		return
	var lines = panel.get("_lines")
	if lines == null:
		_fail("没有连线层")
		return
	var got: int = (lines.get("_segs") as Array).size()
	if got != edges:
		_fail("连线数 %d != 前置关系数 %d" % [got, edges])
		return

	# ---- 4. 拖动：按住 → 移动超过阈值 → 画布必须真的动，且不能误触发研究
	#
	# ⚠️ 面板改成**全屏**之后视口变得很大，整棵科技树往往**装得下** ——
	# 那种情况下 `_clamp_pan` 会把可平移量夹成 0，拖动本来就不该动
	# （这是正确行为，不是 bug）。所以先把视口压小，制造"装不下"的场景，
	# 否则这条断言测的其实是"树刚好装下时不许平移"。
	var canvas = panel.get("_canvas")
	var card0 = cards[String(db.tech_ids[0])]     # research_institute：开局可研究
	for a in sim.s["pending"]:
		if String(a.get("type", "")) == "research":
			_fail("拖动之前 pending 里就有研究指令，测试前提不成立")
			return
	panel._view.size = Vector2(420, 300)
	if panel._clamp_pan(Vector2(-400, -400)) == Vector2.ZERO:
		_fail("视口压到 420x300 之后仍然无处可平移，测不出拖动")
		return
	var before: Vector2 = canvas.position
	card0._gui_input(_mouse(Vector2(200, 200), true))
	card0._gui_input(_motion(Vector2(200, 160), Vector2(0, -40)))
	card0._gui_input(_mouse(Vector2(200, 160), false))
	await process_frame
	var after: Vector2 = canvas.position
	if after == before:
		_fail("按住拖了 40px 画布却没动（before=%s after=%s）" % [before, after])
		return
	for a in sim.s["pending"]:
		if String(a.get("type", "")) == "research":
			_fail("拖动被当成了点击，误下单研究")
			return

	# ---- 5. 点卡片（位移为 0）→ 研究**当场进队列**（2026-10：研究三类动作即时生效）
	#
	# 用户："我白天点了一个研究……结果队列里没有，没有实时出现。要到第二天才能调整顺序太蠢了。"
	var want := String(db.tech_ids[0])
	var q_before := (sim.s["research"]["queue"] as Array).size()
	_click(card0, Vector2(300, 300))
	await process_frame
	var q_now: Array = sim.s["research"]["queue"]
	var has_want := false
	for p in q_now:
		if String((p as Dictionary).get("id", "")) == want:
			has_want = true
	if not has_want:
		_fail("点卡片后研究队列里没有当场出现「%s」（q=%s）" % [want, JSON.stringify(q_now)])
		return
	if q_now.size() != q_before + 1:
		_fail("点一次卡片队列应当只多一条（%d → %d）" % [q_before, q_now.size()])
		return
	for a in sim.s["pending"]:
		if String(a.get("type", "")) == "research":
			_fail("research 还留在 pending 里（应当当场生效）")
			return

	# ---- 6. 「研究队列」页：tab 在科技面板里，↑↓ 当场改顺序
	var qpage = panel.find_child("QueuePage", true, false)
	if qpage == null:
		_fail("科技面板里没有「研究队列」页（QueuePage）")
		return
	if panel.get("_tab_btns").size() != 2:
		_fail("科技面板应当有两个页签（科技树 / 研究队列），实际 %d" % panel.get("_tab_btns").size())
		return
	panel._select_tab(1)
	await process_frame
	if not (qpage as Control).visible:
		_fail("切到「研究队列」页之后它没显示出来")
		return
	if (panel.get("_view") as Control).visible:
		_fail("切到队列页之后科技树应当收起来（两页互斥）")
		return
	var qbox = panel.get("_queue_box")
	if qbox == null:
		_fail("队列页里没有 QueueBox")
		return
	# 再排一条，然后点 ↑ 把第二条挪到前面（走真实按钮）
	panel._select_tab(0)
	await process_frame
	var tech2 := String(db.tech_ids[1])
	sim.enqueue([{"type": "research", "techId": tech2}])
	panel._select_tab(1)
	await process_frame
	await process_frame
	var order_before := []
	for p in (sim.s["research"]["queue"] as Array):
		order_before.append(String((p as Dictionary)["id"]))
	if order_before.size() < 2:
		_fail("队列里应当有两条（实际 %s）" % str(order_before))
		return
	var up := _find_queue_button(qbox, "▲", 1)
	if up == null:
		_fail("队列第二行没有「▲」按钮")
		return
	up.pressed.emit()
	await process_frame
	var order_after := []
	for p in (sim.s["research"]["queue"] as Array):
		order_after.append(String((p as Dictionary)["id"]))
	if order_after.size() != order_before.size() or order_after[0] != order_before[1]:
		_fail("点 ↑ 之后顺序没变（%s → %s）—— 调序应当当场生效"
			% [str(order_before), str(order_after)])
		return
	print("TECH TEST 队列页：tab 切得动、↑ 当场改顺序 %s → %s" % [str(order_before), str(order_after)])

	# ---- 7. 推进到次日：队列还在（研究做完之前不会掉）
	for h in 24:
		sim.tick_hour([])
	await process_frame
	var q: Array = sim.s["research"]["queue"]
	if q.is_empty():
		_fail("次日研究队列空了（研究不该被吞）；木材=%s" % str(sim.s["goods"].get("wood", -1)))
		return

	print("TECH TEST 科技=%d 卡片=%d 连线=%d(前置边 %d) 拖动 %s->%s 队列=%s" % [
		db.tech_ids.size(), cards.size(), got, edges, before, after, JSON.stringify(q)])
	print("TECH TEST RESULT: PASS")
	quit(0)

## 队列页里找某一行（row_index 起）的按钮（按钮文字是 "↑" / "↓" / "×"）。
## 行结构在 `queue_box.gd` 里（每行一个 HBox，按钮是最后三个）。
func _find_queue_button(box, text: String, row_index: int) -> Button:
	var rows: Array = []
	for c in box.get_children():
		if c is HBoxContainer or c is PanelContainer or c is VBoxContainer:
			rows.append(c)
	# QueueBox 直接把行挂在自身上（构造见 `queue_box.gd::refresh()`），所以先找按钮再按行筛
	var hits: Array = []
	for c in box.find_children("*", "Button", true, false):
		if String((c as Button).text) == text:
			hits.append(c)
	if hits.is_empty():
		return null
	return hits[clampi(row_index, 0, hits.size() - 1)]