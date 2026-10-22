extends SceneTree

# ESC 菜单门槛。
#
# 查四件事：
#   1. ESC 能开关菜单（顶层入口）
#   2. 顶栏只剩 快存/快读/统计/菜单，被移走的那些按钮不能再出现
#   3. 保存 / 读取 开的是**自绘的存档对话框**（`save_dialog.gd`），
#      **不是** Godot 的 FileDialog —— 后者自带默认皮肤，就是"一半游戏风
#      一半默认风"的来源。顺便断言整个场景树里再也没有 FileDialog。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("ESC TEST FAIL: ", msg)
	quit(1)

func _labels(root: Node) -> Array:
	var out := []
	for b in root.find_children("*", "Button", true, false):
		out.append((b as Button).text)
	return out

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	# 标题页期间 ESC 不弹菜单（那时 HUD 是隐藏的），所以先关掉标题页
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var hud = node.get_node_or_null("UI/Root/HUD")
	var menu = node.get_node_or_null("UI/Root/EscMenu")
	if hud == null or menu == null:
		_fail("找不到 HUD 或 EscMenu")
		return

	# 1. ESC 开关（直接调 main 的处理入口，等价于按 ESC）
	var main = node
	if menu.visible:
		_fail("菜单一开始不该是打开的")
		return
	main._unhandled_input(_esc())
	await process_frame
	if not menu.visible:
		_fail("按 ESC 没有打开菜单")
		return
	# 菜单打开时世界层要停止处理输入，否则 ESC 会同时被当成取消建造
	var world = node.get_node_or_null("World")
	if world != null and world.is_processing_unhandled_input():
		_fail("菜单打开时 world 仍在处理 unhandled_input，ESC 会同时取消建造模式")
		return
	main._unhandled_input(_esc())
	await process_frame
	if menu.visible:
		_fail("再按 ESC 没有关闭菜单")
		return
	if world != null and not world.is_processing_unhandled_input():
		_fail("菜单关闭后 world 没有恢复输入处理")
		return

	# 2. 顶栏：必须有 快存/快读/菜单。
	#    「统计 / 科技」已经搬到左侧小地图下方的圆形按钮列，顶栏不许再有它们。
	var tops: Array = _labels(hud)
	for need in ["快存", "快读", "菜单"]:
		if not tops.has(need):
			_fail("顶栏缺少按钮「%s」，实际：%s" % [need, tops])
			return
	for gone in ["保存", "读取", "资源", "音效", "音乐", "统计", "科技"]:
		if tops.has(gone):
			_fail("顶栏还留着已移走的按钮「%s」" % gone)
			return

	# 2b. 左侧圆钮列：资源 / 人口 / 财政 / 科技，竖排小地图下方
	var nav := hud.get_parent().get_node_or_null("NavCol")
	if nav == null:
		nav = hud.find_child("NavCol", true, false)
	if nav == null:
		_fail("找不到左侧圆钮列 NavCol")
		return
	var nav_btns: Array = []
	for c in nav.get_children():
		if c is Button:
			nav_btns.append(c)
	# 圆钮列的**个数与 HUD 的 NAV_ITEMS 对齐**（别在这里硬编码数字：加一个圆钮
	# 就要回来改这一条 —— 2026-10 加「任务」、2026-10 底加「预言」都是这么红的）。
	# 这里仍然要判断表本身是"资源 / 人口 / 财政 / 科技 / 任务 / 预言"这六个。
	if nav_btns.size() != hud.NAV_ITEMS.size():
		_fail("圆钮列应有 %d 个按钮（%s），实际 %d" % [hud.NAV_ITEMS.size(),
			" / ".join((hud.NAV_ITEMS as Array).map(func(it): return String(it[0]))),
			nav_btns.size()])
		return
	if nav_btns.size() != 8:
		_fail("圆钮列现在是 8 个（资源/人口/财政/科技/任务/预言/贸易/外交），实际 %d" % nav_btns.size())
		return
	for b in nav_btns:
		if (b as Button).icon == null:
			_fail("圆钮「%s」没有图标" % (b as Button).tooltip_text)
			return
	# 必须在小地图下方（小地图圆环直径 128，加飘带到 ~140）
	if (nav as Control).position.y < 130.0:
		_fail("圆钮列 y=%.0f 压在小地图上了（应 ≥ 130）" % (nav as Control).position.y)
		return
	# 必须贴着左侧（留白不超过 ~14px），别被挪回中间
	if (nav as Control).position.x > 14.0:
		_fail("圆钮列 x=%.0f 没贴着左边缘（留白应 ≤ 14）" % (nav as Control).position.x)
		return

	# 第 6 个「预言」圆钮要真的接上：点它 → 全屏预言页（anchors 0..1）
	#
	# ⚠️ 用户 2026-10：**第一章收尾之前这个按钮是藏着的**（瑟拉菲娜那时才登场），
	# 而藏着的时候 `activate_nav()` 也返回 false（不然 F6 会凭空弹面板）。
	# 所以这里要先把她"解锁"（= 第一章记过完成），再验接通。
	var sim0 = node.get("runner").sim
	if not sim0.prophet_unlocked():
		if hud.activate_nav(5):
			_fail("第一章还没收尾，F6 就把预言面板弹出来了（她会提前现身）")
			return
		sim0.s["quests"]["chapters"]["1"] = int(sim0.s["day"])
		hud.refresh_nav_buttons()
		await process_frame
	if not hud.activate_nav(5):
		_fail("activate_nav(5) 应当打到「预言」那个圆钮（第一章收尾之后）")
		return
	await process_frame
	var ai_panel = node.get_node_or_null("UI/Root/AiPanel")
	if ai_panel == null or not (ai_panel as CanvasItem).visible:
		_fail("点第 6 个圆钮没有打开预言面板")
		return
	if not is_equal_approx((ai_panel as Control).anchor_right, 1.0) \
			or not is_equal_approx((ai_panel as Control).anchor_bottom, 1.0):
		_fail("预言面板应当是**全屏**（anchors 0..1），实际 right=%.2f bottom=%.2f"
			% [(ai_panel as Control).anchor_right, (ai_panel as Control).anchor_bottom])
		return
	(ai_panel as CanvasItem).visible = false
	await process_frame

	# 3. 菜单六项齐全
	menu.open()
	await process_frame
	var items: Array = _labels(menu)
	for need in ["保存…", "读取…", "设置资源…", "退出游戏"]:
		if not items.has(need):
			_fail("菜单缺少「%s」，实际：%s" % [need, items])
			return
	var has_sfx := false
	var has_music := false
	for s in items:
		if String(s).begins_with("音效："):
			has_sfx = true
		if String(s).begins_with("音乐："):
			has_music = true
	if not has_sfx or not has_music:
		_fail("菜单缺少音效/音乐开关，实际：%s" % items)
		return
	# 统计面板只在左侧圆钮列，菜单里不许再有一份
	for s in items:
		if String(s).begins_with("统计"):
			_fail("统计面板应该只在左侧圆钮列，菜单里不该有：%s" % items)
			return

	# 3b. 每一行都要有**图标**（用户 2026-10："为了统一风格，我这边给了所有选项一个图标，
	#     图标固定在按钮最左侧，但是文字居中"）。
	#     图标是按钮的子节点 `Icon`（`UIKit.icon_left_button()`），锚在左边、不参与文字排版 ——
	#     所以文字能在整条按钮里真居中。这里量三件事：在、靠左、没跟文字挤在一起。
	var need_icons := ["新游戏…", "保存…", "读取…", "设置资源…", "AI 辅助设置…",
		"调试功能：关", "退出游戏"]
	for b in menu.find_children("*", "Button", true, false):
		var btn := b as Button
		var want := need_icons.has(btn.text) or btn.text.begins_with("音效：") \
			or btn.text.begins_with("音乐：")
		if not want:
			continue
		var ico := btn.get_node_or_null("Icon") as TextureRect
		if ico == null or ico.texture == null:
			_fail("菜单项「%s」没有贴图标" % btn.text)
			return
		if ico.position.x > 14.0 or ico.position.x < 1.0:
			_fail("「%s」的图标没贴在左侧（x=%.0f）" % [btn.text, ico.position.x])
			return
		# 文字居中：图标只占左边一小条，按钮宽度远大于它
		if ico.size.x > float(btn.size.x) * 0.4:
			_fail("「%s」的图标太大，挤到文字了（图标 %.0f / 按钮 %.0f）" % [
				btn.text, ico.size.x, btn.size.x])
			return
		if btn.alignment != HORIZONTAL_ALIGNMENT_CENTER:
			_fail("「%s」的文字没有居中（alignment=%d）" % [btn.text, btn.alignment])
			return

	# 4. 保存 / 读取 必须开**自绘的存档对话框**，不能是 Godot 的 FileDialog。
	#    FileDialog 自带一整套默认皮肤（标题栏、路径栏、列表、滚动条、下拉框），
	#    项目主题覆盖不到 —— 用户反馈的就是"一半游戏风、一半默认风"。
	var dlg = node.get_node_or_null("DialogLayer/SaveDialog")
	if dlg == null:
		_fail("找不到 DialogLayer/SaveDialog（main 没注入存档对话框）")
		return
	menu._save_dialog()
	await process_frame
	if not dlg.visible:
		_fail("点「保存…」没有打开存档对话框")
		return
	if int(dlg._mode) != int(dlg.Mode.SAVE):
		_fail("「保存…」打开的不是保存模式")
		return
	if not (dlg._name_box as Control).visible:
		_fail("保存模式没有显示存档名输入框")
		return
	dlg.close()
	menu._load_dialog()
	await process_frame
	if not dlg.visible:
		_fail("点「读取…」没有打开存档对话框")
		return
	if int(dlg._mode) != int(dlg.Mode.LOAD):
		_fail("「读取…」打开的不是读取模式")
		return
	if (dlg._name_box as Control).visible:
		_fail("读取模式不该显示存档名输入框")
		return
	dlg.close()

	# 4b. 整棵树里不许再有 FileDialog / 窗口式对话框（它们就是默认皮肤的来源）
	var strays: Array = []
	for w in node.find_children("*", "FileDialog", true, false):
		strays.append(w.name)
	if strays.size() > 0:
		_fail("场景里还挂着 FileDialog：%s" % str(strays))
		return

	print("ESC TEST 菜单=%s 顶栏=%s" % [items, tops])
	print("ESC TEST RESULT: PASS")
	quit(0)

func _esc() -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	return e
