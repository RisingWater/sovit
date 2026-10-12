extends SceneTree

# ESC 菜单门槛。
#
# 查三件事：
#   1. ESC 能开关菜单（顶层入口）
#   2. 顶栏只剩 快存/快读/统计/菜单，被移走的那些按钮不能再出现
#   3. 保存 / 读取 走的是 FileDialog（文件系统对话框），不是直接写默认位

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

	# 2. 顶栏：必须有 快存/快读，不能有被移走的那些
	var tops: Array = _labels(hud)
	for need in ["快存", "快读", "统计", "菜单"]:
		if not tops.has(need):
			_fail("顶栏缺少按钮「%s」，实际：%s" % [need, tops])
			return
	for gone in ["保存", "读取", "资源", "音效", "音乐"]:
		if tops.has(gone):
			_fail("顶栏还留着已移走的按钮「%s」" % gone)
			return

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
	# 统计面板只在顶栏，菜单里不许再有一份
	for s in items:
		if String(s).begins_with("统计"):
			_fail("统计面板应该只在顶栏，菜单里不该有：%s" % items)
			return

	# 4. 保存 / 读取 必须开 FileDialog
	menu._save_dialog()
	await process_frame
	var save_dlg: FileDialog = _find_dialog(menu, FileDialog.FILE_MODE_SAVE_FILE)
	if save_dlg == null:
		_fail("点「保存…」没有打开保存用的 FileDialog")
		return
	save_dlg.hide()
	save_dlg.queue_free()
	menu._load_dialog()
	await process_frame
	var load_dlg: FileDialog = _find_dialog(menu, FileDialog.FILE_MODE_OPEN_FILE)
	if load_dlg == null:
		_fail("点「读取…」没有打开读取用的 FileDialog")
		return
	load_dlg.hide()
	load_dlg.queue_free()

	print("ESC TEST 菜单=%s 顶栏=%s" % [items, tops])
	print("ESC TEST RESULT: PASS")
	quit(0)

func _esc() -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	return e

func _find_dialog(root: Node, mode: int):
	for w in root.find_children("*", "FileDialog", true, false):
		if (w as FileDialog).file_mode == mode and (w as FileDialog).visible:
			return w
	return null
