extends SceneTree

# 统计面板拖动：把手存在、位置能存能读、越界能被夹住。
#
# 不模拟真实鼠标事件 —— _on_drag_input 内部读 get_global_mouse_position()，
# 合成事件改不动它。所以这里测的是拖动链路上可独立验证的三段：
# 把手配置、位置持久化、边界夹取。

const CFG := "user://hud.cfg"

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("PANEL TEST FAIL: ", msg)
	quit(1)

## 在标题行里找"关闭"按钮
func _find_close(root: Node) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if (c as Button).text == "关闭":
			return c
	return null

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	var panel = node.get_node_or_null("UI/Root/Stats")
	if panel == null:
		_fail("找不到 UI/Root/Stats")
		return

	# 面板初始是隐藏的，隐藏时容器不做布局 —— 必须先打开再量尺寸
	panel.open()
	for i in 3:
		await process_frame

	# 1. 拖动把手：必须能接鼠标、光标是移动样式
	var bar = panel.get("_dragbar")
	if bar == null:
		_fail("没有 _dragbar 拖动把手")
		return
	if bar.mouse_filter != Control.MOUSE_FILTER_STOP:
		_fail("拖动把手的 mouse_filter 不是 STOP，接不到鼠标")
		return
	if bar.mouse_default_cursor_shape != Control.CURSOR_MOVE:
		_fail("拖动把手的光标不是 CURSOR_MOVE")
		return
	# 把手必须真的占宽度（挤在 tab 与关闭按钮之间）
	if bar.size.x < 40.0:
		_fail("拖动把手太窄（%.0f px），拖不动" % bar.size.x)
		return

	var vp := root.get_visible_rect().size

	# 2. 面板不能被内容撑宽 —— 曾经商品曲线选择那行 36 个按钮把最小宽度顶到
	#    2500px，面板右半边连同关闭按钮被挤出屏幕外。
	var pw: float = panel.custom_minimum_size.x
	if panel.size.x > pw + 4.0:
		_fail("面板被内容撑宽：%.0f > 设定 %.0f" % [panel.size.x, pw])
		return
	var close_btn := _find_close(panel)
	if close_btn != null:
		var right := close_btn.global_position.x + close_btn.size.x
		if right > vp.x:
			_fail("关闭按钮被挤出屏幕：右边缘 %.0f > 视口 %.0f" % [right, vp.x])
			return

	# 3. 边界夹取：往四个方向拖出屏幕，都要留 KEEP_VISIBLE 在屏内
	var keep: float = panel.KEEP_VISIBLE
	var far_neg: Vector2 = panel._clamp_pos(Vector2(-99999, -99999))
	var far_pos: Vector2 = panel._clamp_pos(Vector2(99999, 99999))
	if far_neg.y < 0.0:
		_fail("向上拖出屏幕没有被夹住：%s" % far_neg)
		return
	if far_pos.x > vp.x - keep + 0.5 or far_pos.y > vp.y - keep + 0.5:
		_fail("向右下拖出屏幕没有被夹住：%s（视口 %s）" % [far_pos, vp])
		return

	# 3. 位置持久化：改位置 -> 存 -> 新建实例读回来
	#    门禁不能有副作用，所以整文件备份，测完原样还原（原本不存在就删掉）
	var had_cfg := FileAccess.file_exists(CFG)
	var backup := FileAccess.get_file_as_string(CFG) if had_cfg else ""

	var target := Vector2(137, 88)
	panel.position = target
	panel._save_pos()
	var again = load("res://scripts/ui/panel_stats.gd").new()
	root.add_child(again)
	await process_frame
	var restored_ok: bool = again.position.distance_to(target) <= 1.5

	if had_cfg:
		var fw := FileAccess.open(CFG, FileAccess.WRITE)
		fw.store_string(backup)
		fw.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CFG))

	if not restored_ok:
		_fail("位置没有持久化：存 %s，读回 %s" % [target, again.position])
		return

	print("PANEL TEST 把手宽=%.0f 夹取负向=%s 正向=%s 位置=%s" % [bar.size.x, far_neg, far_pos, again.position])
	print("PANEL TEST RESULT: PASS")
	quit(0)
