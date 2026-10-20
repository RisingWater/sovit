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
## 42 → 53：手工核对时已经涨到 53（几十项解锁建筑/商品的科技陆续加进来）。
## 53 → 56：新增 3 项**民生服务**科技（培训 / 民生工程 / 治理，治安+医疗+教育一起加成）。
## 56 → 72：新增 **16 项贸易科技**（商路 B3：商队 4 / 货箱 3 / 钱箱 3 / 议价买 3 / 议价卖 3），
## 它们带 `trade` 块、只出现在科技面板的「贸易」页，见 docs/trade-routes.md §6。
## **刻意写死**而不是取 `db.tech_ids.size()`：这样"某项科技莫名消失/多出来"
## 才会被这条门抓住 —— 用 size 就等于把断言变成恒真式。
const EXPECTED_TECHS := 72

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

	# ---- 2. 面板打开：**两个页签各建一棵树**，合起来一项科技不缺
	#
	# 用户 2026-10："科技树太复杂了，拆分几个 tab：1、制造（专门用来解锁新的建筑新的产品）
	# 2、效率（专门用来提升各种效率，各种加成）"。
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

	var ids_make: Array = panel._ids_for(0)     # 制造
	var ids_eff: Array = panel._ids_for(1)      # 效率
	var ids_trade: Array = panel._ids_for(2)    # 贸易（B3）
	if ids_make.is_empty() or ids_eff.is_empty():
		_fail("制造 %d 项 / 效率 %d 项 —— 有一页是空的" % [ids_make.size(), ids_eff.size()])
		return
	# 三棵树加起来必须等于总数：贸易科技只进贸易页，别的科技不进贸易页（`_ids_for` 的互斥）
	if ids_make.size() + ids_eff.size() + ids_trade.size() != EXPECTED_TECHS:
		_fail("三页加起来 %d 项，科技总数 %d（有科技哪一页都不显示，或进了两页）"
			% [ids_make.size() + ids_eff.size() + ids_trade.size(), EXPECTED_TECHS])
		return
	if ids_trade.size() != 16:
		_fail("贸易页应当是 16 项贸易科技，实际 %d" % ids_trade.size())
		return
	for t2 in ids_eff:
		if ids_make.has(t2):
			_fail("科技「%s」同时出现在两页（制造 / 效率 应当互斥）" % String(t2))
			return
	# 分工要对：效率页里必须都是"有 effects 的"，制造页里必须都是"有 unlocks 的"
	for t3 in ids_eff:
		if (db.techs[String(t3)].get("effects", {}) as Dictionary).is_empty():
			_fail("效率页里有「%s」，但它没有任何加成（effects）" % String(t3))
			return
	for t4 in ids_make:
		var u: Dictionary = db.techs[String(t4)].get("unlocks", {})
		var has_u: bool = not (u.get("buildings", []) as Array).is_empty() \
			or not (u.get("housing", []) as Array).is_empty()
		if not has_u:
			_fail("制造页里有「%s」，但它不解锁任何建筑/住房" % String(t4))
			return

	# 每页的卡片数 = 这一页的科技数；名字与图标都要在
	var cards: Dictionary = panel.get("_cards")
	if cards.size() != ids_make.size():
		_fail("「制造」页只建出 %d 张卡片（应 %d）" % [cards.size(), ids_make.size()])
		return
	for page in [[0, ids_make], [1, ids_eff]]:
		panel._select_tab(int(page[0]))
		await process_frame
		var want_ids: Array = page[1]
		cards = panel.get("_cards")
		if cards.size() != want_ids.size():
			_fail("第 %d 页建出 %d 张卡片（应 %d）" % [int(page[0]), cards.size(), want_ids.size()])
			return
		for tid in want_ids:
			var t := String(tid)
			if not cards.has(t):
				_fail("第 %d 页里科技「%s」没有卡片" % [int(page[0]), t])
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
	print("TECH TEST 两页：制造 %d 项 / 效率 %d 项（合计 %d）"
		% [ids_make.size(), ids_eff.size(), EXPECTED_TECHS])

	# ---- 3. 每棵树的正确性：前置 x 严格小于后继 x；前置关系（同一页内的）都有连线
	panel._select_tab(0)
	await process_frame
	cards = panel.get("_cards")
	var total_edges := 0
	for page in [[0, ids_make], [1, ids_eff]]:
		panel._select_tab(int(page[0]))
		await process_frame
		var ids: Array = page[1]
		var posn: Dictionary = panel.get("_pos")
		var bad := 0
		var edges := 0
		for tid in ids:
			var t5 := String(tid)
			if not posn.has(t5):
				_fail("第 %d 页「%s」没有布局坐标" % [int(page[0]), t5])
				return
			var px: float = (posn[t5] as Vector2).x
			for r in db.techs[t5]["requires"]:
				var rt := String(r)
				# 跨页的前置（例如「轮作」要「石作」）不画线也不定列号，
				# 它只出现在卡片的"需先研究"里 —— 见 panel_tech._compute_layout 的注释。
				if not posn.has(rt):
					continue
				edges += 1
				if (posn[rt] as Vector2).x >= px:
					bad += 1
		if bad > 0:
			_fail("第 %d 页有 %d 条前置关系的 x 没有严格小于后继（树画错了）" % [int(page[0]), bad])
			return
		var lines = panel.get("_lines")
		if lines == null:
			_fail("第 %d 页没有连线层" % int(page[0]))
			return
		var got: int = (lines.get("_segs") as Array).size()
		if got != edges:
			_fail("第 %d 页连线数 %d != 页内前置关系数 %d" % [int(page[0]), got, edges])
			return
		total_edges += edges
	if total_edges <= 0:
		_fail("两页加起来一条前置连线都没有")
		return

	# 回到「制造」页做拖动与点击那两组（第 0 项科技 stonework 在这一页）
	panel._select_tab(0)
	await process_frame
	cards = panel.get("_cards")

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
	if panel.get("_tab_btns").size() != 4:
		_fail("科技面板应当有四个页签（制造 / 效率 / 贸易 / 研究队列），实际 %d"
			% panel.get("_tab_btns").size())
		return
	# 页签顺序：制造(0) 效率(1) 贸易(2) 研究队列(3)
	panel._select_tab(3)
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
	panel._select_tab(3)
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

	# ---- 7. 民生服务科技：培训 / 民生工程 / 治理 三级一起加（治安 / 医疗 / 教育）
	#
	# 用户 2026-10："新增，增加（治安、教育、医疗）的科技（三个一起加）培训、民生工程、治理三级"。
	# 它们是**效率科技**（只放大产出，不放大投入），加法叠加：+10% +20% +30% = +60%。
	for need in ["training", "public_works", "governance"]:
		if not db.techs.has(need):
			_fail("内容里没有民生服务科技「%s」" % need)
			return
		if not (sim.s["research"]["done"] as Array).has(need):
			sim.s["research"]["done"].append(need)
	var svc := float(sim.tech_bonuses().get("services", 0.0))
	if absf(svc - 0.60) > 0.0001:
		_fail("三级都研究完之后 services 加成是 %.3f，应当是 0.60（加法叠加）" % svc)
		return
	for g in ["safety", "medical_service", "education"]:
		if absf(sim._service_output_boost(g) - 1.60) > 0.0001:
			_fail("「%s」的产出倍率是 %.2f，应当是 1.60" % [g, sim._service_output_boost(g)])
			return
	if absf(sim._service_output_boost("coarse_bread") - 1.0) > 0.0001:
		_fail("民生服务科技不该给面包加成（现在给了 %.2f）" % sim._service_output_boost("coarse_bread"))
		return
	print("TECH TEST 民生服务：培训+民生工程+治理 = +60%%，只作用于治安/医疗/教育 ✅")

	# ---- 8. 推进到次日：队列还在（研究做完之前不会掉）
	for h in 24:
		sim.tick_hour([])
	await process_frame
	var q: Array = sim.s["research"]["queue"]
	if q.is_empty():
		_fail("次日研究队列空了（研究不该被吞）；木材=%s" % str(sim.s["goods"].get("wood", -1)))
		return

	print("TECH TEST 科技=%d（制造 %d / 效率 %d） 页内连线=%d 拖动 %s->%s 队列=%s" % [
		db.tech_ids.size(), ids_make.size(), ids_eff.size(), total_edges, before, after, JSON.stringify(q)])
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