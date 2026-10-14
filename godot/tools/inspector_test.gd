extends SceneTree

# 面板与对话框的分派门槛。
#
# 用户要的三件事，逐条锁住：
#   1. **没选中任何东西时右侧面板收起来** —— 全局数字顶栏已经全有
#      （人口/满意度/钱/建造力/科研/移民），不该再占一屏。
#   2. 选中**城镇中心 / 仓库** → 弹**浮动对话框**（`panel_civic.gd`，
#      和点左侧圆钮出来的「统计」面板同一套形式：标题栏 + 拖动把手 + 关闭），
#      **不是**右侧那条常驻面板；同时右侧面板必须收起来，别两个东西讲同一件事。
#   3. 选中**其它建筑** → 仍旧走右侧建筑面板。
#
# 另外锁住"上限只在仓库对话框里设"：ESC 的「设置资源」里不该再有任何输入框。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("PANEL DISPATCH FAIL: ", msg)
	quit(1)

func _labels(root: Node) -> Array:
	var out := []
	for l in root.find_children("*", "Label", true, false):
		out.append((l as Label).text)
	return out

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var runner = node.get("runner")
	var ins = node.get_node_or_null("UI/Root/Inspector")
	var civic = node.get_node_or_null("UI/Root/Civic")
	if runner == null or ins == null or civic == null:
		_fail("找不到 runner / Inspector / Civic")
		return
	var s: Dictionary = runner.sim.s

	# 造一座普通建筑和一座仓库（新开局只有城镇中心）
	(s["shops"] as Array).append({
		"id": "lumberjack#t", "defId": "lumberjack", "owner": "state",
		"targetWorkers": 3, "wage": 3.0, "wageCap": 6.0, "level": 1,
		"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	(s["shops"] as Array).append({
		"id": "warehouse#t", "defId": "warehouse", "owner": "state",
		"targetWorkers": 1, "wage": 3.0, "wageCap": 6.0, "level": 1,
		"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	var tc_id := ""
	for sh in s["shops"]:
		if String(sh["defId"]) == "town_center":
			tc_id = String(sh["id"])

	# ---- 1. 未选中 → 右侧面板收起来，且对话框也不该在
	ins.clear()
	civic.close_panel()
	await process_frame
	if ins.visible:
		_fail("没选中任何东西时右侧面板仍然显示")
		return
	# ⚠️ 不能查整棵树里的 Label —— 浮动框的标题栏（标题/副标题）是常驻子节点，
	# 隐藏时也在。要看**内容区**有没有东西。
	if (ins._body as VBoxContainer).get_child_count() > 0:
		_fail("未选中时内容区还留着 %d 个节点" % (ins._body as VBoxContainer).get_child_count())
		return

	# ---- 2a. 城镇中心 → 浮动对话框（人口），右侧面板收起
	#
	# ⚠️ 这里走**真实的点击路径**：城镇中心是地图上那座固定建筑（没有普通 shop 精灵），
	# 点击靠 `map.occupied_at()` 命中，占格必须由 `_build_town_center()` 自己登记 ——
	# 漏登记的话它"点不动"，什么窗都弹不出来（用户反馈过）。
	var world = node.get_node_or_null("World")
	if world == null:
		_fail("找不到 World")
		return
	world._on_left_click(world.map.town_center.get_center())
	await process_frame
	if not civic.visible:
		_fail("点地图上的城镇中心没有弹出对话框（占格没登记？）")
		return
	if ins.visible:
		_fail("城镇中心弹了对话框，右侧面板不该同时显示")
		return
	node._on_select_building(tc_id)
	await process_frame
	if not civic.visible:
		_fail("选中城镇中心没有弹出对话框")
		return
	if ins.visible:
		_fail("城镇中心弹了对话框，右侧面板不该同时显示")
		return
	var keys: Array = _labels(civic)
	for need in ["城镇中心", "人口上限", "当前人口", "空房", "本回合想来", "次日会来", "公告"]:
		if not keys.has(need):
			_fail("城镇中心对话框缺少「%s」，实际：%s" % [need, keys])
			return
	# 对话框形式：必须有拖动把手与关闭按钮（和「统计」面板一致）
	var has_drag := false
	for c in civic.find_children("*", "Control", true, false):
		if String(c.tooltip_text) == "按住拖动对话框":
			has_drag = true
	if not has_drag:
		_fail("对话框没有拖动把手（tooltip 应为「按住拖动对话框」）")
		return
	if not _has_button(civic, "关闭"):
		_fail("对话框没有「关闭」按钮")
		return

	# ---- 2b. 仓库 → 浮动对话框（资源 + 上限）
	node._on_select_building("warehouse#t")
	await process_frame
	if not civic.visible:
		_fail("选中仓库没有弹出对话框")
		return
	if ins.visible:
		_fail("仓库弹了对话框，右侧面板不该同时显示")
		return
	keys = _labels(civic)
	for need in ["仓库 · 仓储", "本座容量", "全村仓储"]:
		if not keys.has(need):
			_fail("仓库对话框缺少「%s」，实际：%s" % [need, keys])
			return
	var goods_n: int = (runner.db.packs[String(s["pack"])]["goods"] as Array).size()
	var edits := civic.find_children("*", "LineEdit", true, false)
	if edits.size() != goods_n:
		_fail("仓库对话框的上限输入框应有 %d 个（每种货一个），实际 %d" % [goods_n, edits.size()])
		return

	# 上限真的进队列：填 120 → pending 出现 set_storage_caps[gid]=120
	#
	# ⚠️ 必须"先改控件文本、再直接调处理器"：Godot 4.7 里 `LineEdit.text = x`
	# **不会**发 `text_changed`（只有真实键盘/GUI 输入才发，实测确认过）。
	var gid0 := String((runner.db.packs[String(s["pack"])]["goods"] as Array)[0])
	var le0: LineEdit = civic._cap_inputs.get(gid0, null)
	if le0 == null:
		_fail("仓库对话框里找不到「%s」的上限输入框" % gid0)
		return
	le0.text = "120"
	civic._on_cap_text("120", gid0)
	if int(_pending_caps(runner).get(gid0, 0)) != 120:
		_fail("填了 120 之后 pending 里没有 set_storage_caps[%s]=120" % gid0)
		return
	# 非数字要被过滤掉（12a3 → 123）
	le0.text = "12a3"
	civic._on_cap_text("12a3", gid0)
	if le0.text != "123":
		_fail("非数字没有被过滤：输入 12a3，输入框里是「%s」（应 123）" % le0.text)
		return
	if int(_pending_caps(runner).get(gid0, 0)) != 123:
		_fail("过滤后 pending 里的值不是 123")
		return
	# 清空 = 不限
	le0.text = ""
	civic._on_cap_text("", gid0)
	if _pending_caps(runner).has(gid0):
		_fail("清空输入框后该项仍在上限表里（留空应 = 不限）")
		return

	# ---- 3. 普通建筑 → 同一个浮动对话框（形式一致：标题 + 拖动把手 + 关闭）
	node._on_select_building("lumberjack#t")
	await process_frame
	if not ins.visible:
		_fail("选中普通建筑没有显示对话框")
		return
	if civic.visible:
		_fail("选中普通建筑时城镇中心/仓库的对话框还开着")
		return
	var ins_keys: Array = _labels(ins)
	if not ins_keys.has("用工"):
		_fail("普通建筑的对话框内容不对（缺「用工」）：%s" % [ins_keys])
		return
	if not ins_keys.has("伐木场"):
		_fail("普通建筑的对话框标题栏没写建筑名：%s" % [ins_keys])
		return
	var ins_drag := false
	for c in ins.find_children("*", "Control", true, false):
		if String(c.tooltip_text) == "按住拖动对话框":
			ins_drag = true
	if not ins_drag:
		_fail("普通建筑的对话框没有拖动把手")
		return
	if ins.find_children("*", "HSlider", true, false).size() == 0:
		_fail("普通建筑的对话框里没有用工拖动条")
		return

	# ---- 4.「设置资源」不再管上限
	var hud = node.get_node_or_null("UI/Root/HUD")
	hud._open_picker()
	await process_frame
	var picker = hud.get("_picker")
	if picker == null:
		_fail("找不到 HUD 的 _picker")
		return
	if picker.find_children("*", "LineEdit", true, false).size() > 0:
		_fail("「设置资源」里还有输入框 —— 上限应只在仓库对话框里设")
		return
	picker.hide()

	print("PANEL DISPATCH 商品=%d 上限框=%d" % [goods_n, edits.size()])
	print("PANEL DISPATCH RESULT: PASS")
	quit(0)

## pending 里那条 set_storage_caps 的 caps（没有就是空表）。
func _pending_caps(runner) -> Dictionary:
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_storage_caps":
			return (a.get("caps", {}) as Dictionary)
	return {}

## 有没有文本为 `text` 的按钮（按钮的文字不在 Label 里，得单独找）。
func _has_button(root: Node, text: String) -> bool:
	for b in root.find_children("*", "Button", true, false):
		if String((b as Button).text) == text:
			return true
	return false
