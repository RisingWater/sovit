extends SceneTree

# 统计 / 科技面板：**全屏最大化、不可移动**（用户要求）。
#
# 用户原话："左侧圆形按钮弹出的面板不能是对话框了，我希望弹出来的面板是全屏
# （最大化）的。保留顶栏显示（隐藏地图），遮住下面建筑列表，同时无法移动。"
#
# 所以这个门槛测四件事：
#   1. 铺满顶栏以下的整个屏幕（顶栏那 58px 露着）；
#   2. 盖住底部建造栏 —— 几何上包住它，**而且**兄弟顺序在它之后（真的画在上面）；
#   3. 不可移动：拖动把手 / 拖动函数 / 位置夹取都该消失；
#   4. 面板吃掉滚轮，关闭后地图滚轮照常生效（别把正常功能一起锁死）。
#
# 后半段（页签选中、无新数据不重建）是原来就有的，保留。
# ⚠️ 2026-10 用户把资源页的「全局产出」整段和详情里的两张折线删了，
#    所以"选中商品后出曲线"这条**反过来了**：现在要求一个 Chart 都没有。

const CFG := "user://hud.cfg"

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("PANEL TEST FAIL: ", msg)
	quit(1)

## 在面板里找"关闭"按钮
func _find_close(root: Node) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if (c as Button).text == "关闭":
			return c
	return null

## 全屏断言：面板必须铺满 [BAR_H, 视口底] 这块矩形。
func _check_fullscreen(tag: String, panel: Control, vp: Vector2, bar: Control) -> bool:
	var r := panel.get_global_rect()
	if absf(r.position.y - float(UIKit.BAR_H)) > 1.0:
		_fail("%s 顶边 %.0f 不在顶栏下沿（应 %d）" % [tag, r.position.y, UIKit.BAR_H])
		return false
	if absf(r.position.x) > 1.0 or absf(r.position.x + r.size.x - vp.x) > 1.0:
		_fail("%s 没有横向铺满：x=%.0f..%.0f（视口宽 %.0f）" % [tag, r.position.x, r.position.x + r.size.x, vp.x])
		return false
	if absf(r.position.y + r.size.y - vp.y) > 1.0:
		_fail("%s 没有铺到底：底边 %.0f（视口高 %.0f）" % [tag, r.position.y + r.size.y, vp.y])
		return false
	# 顶栏必须露着 —— 用同一个常量核对，别让面板顶边跑到顶栏中间去
	if r.position.y < float(UIKit.BAR_H) - 1.0:
		_fail("%s 把顶栏盖住了一截（顶边 %.0f < %d）" % [tag, r.position.y, UIKit.BAR_H])
		return false
	# 建造栏：既要被包住，又要真的画在它上面
	if not r.encloses(bar.get_global_rect()):
		_fail("%s 没有盖住底部建造栏（面板 %s vs 建造栏 %s）" % [tag, r, bar.get_global_rect()])
		return false
	if panel.get_index() < bar.get_index():
		_fail("%s 画在建造栏下面（顺序 %d < %d），会被挡住" % [tag, panel.get_index(), bar.get_index()])
		return false
	# 不可移动：拖动链路必须整段消失
	if panel.get("_dragbar") != null:
		_fail("%s 还留着 _dragbar 拖动把手（应全屏不可移动）" % tag)
		return false
	if panel.has_method("_on_drag_input") or panel.has_method("_clamp_pos"):
		_fail("%s 还留着拖动/夹取函数（应全屏不可移动）" % tag)
		return false
	var close_btn := _find_close(panel)
	if close_btn == null:
		_fail("%s 找不到「关闭」按钮" % tag)
		return false
	if close_btn.global_position.x + close_btn.size.x > vp.x + 1.0:
		_fail("%s 的关闭按钮被挤出屏幕" % tag)
		return false
	return true

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var panel = node.get_node_or_null("UI/Root/Stats")
	var tech = node.get_node_or_null("UI/Root/Tech")
	var bar = node.get_node_or_null("UI/Root/BuildBar")
	if panel == null or tech == null or bar == null:
		_fail("找不到 UI/Root/Stats | Tech | BuildBar")
		return
	var vp := root.get_visible_rect().size

	# 面板初始是隐藏的，隐藏时容器不做布局 —— 必须先打开再量尺寸
	panel.open()
	for i in 3:
		await process_frame
	if not _check_fullscreen("统计面板", panel, vp, bar):
		return
	print("PANEL TEST 统计面板 = %s" % panel.get_global_rect())

	tech.open()
	for i in 3:
		await process_frame
	if not _check_fullscreen("科技面板", tech, vp, bar):
		return
	print("PANEL TEST 科技面板 = %s" % tech.get_global_rect())
	tech.visible = false

	# ---- 地图那一侧：整块藏掉（含日期框）
	# 小地图上沿本来就压在顶栏里（日期框坐在那一行），只靠"面板盖住"会把它
	# 切成半个卡在左上角 —— 用户就是这么发现"你没有隐藏地图"的。
	# 后来只藏地图本体、把日期留在原地，用户又说"日期框不要留，留着很奇怪"，
	# 所以现在是**整块可见性开关**。
	var mm = node.get_node_or_null("UI/Root/Minimap")
	var nav = node.get_node_or_null("UI/Root/NavCol")
	if mm == null:
		_fail("找不到 UI/Root/Minimap")
		return
	panel.open()
	for i in 2:
		await process_frame
	if (mm as CanvasItem).visible:
		_fail("全屏面板开着时小地图仍然显示（左上角会露出半个小地图/孤零零的日期框）")
		return
	if nav != null and (nav as CanvasItem).visible:
		_fail("全屏面板开着时左侧圆钮列仍然显示")
		return
	panel.visible = false
	await process_frame
	if not (mm as CanvasItem).visible:
		_fail("关掉面板后小地图没有还原")
		return
	if nav != null and not (nav as CanvasItem).visible:
		_fail("关掉面板后左侧圆钮列没有还原")
		return
	print("PANEL TEST 地图挂件 开着→整块隐藏 关掉→还原 ✅")
	panel.open()
	for i in 2:
		await process_frame

	# ---- 面板内滚轮不该动镜头；关掉面板后地图滚轮照常生效
	var world = node.get_node_or_null("World")
	if world == null:
		_fail("找不到 World")
		return
	var camera: Camera2D = world.camera
	var z0: float = camera.zoom.x
	# 面板中间一点（全屏之后没有"面板外"的地图可点了 —— 那正是用户要的效果）
	var probe: Vector2 = Vector2(vp.x * 0.5, float(UIKit.BAR_H) + (vp.y - float(UIKit.BAR_H)) * 0.5)
	_wheel(root, probe, true)
	await process_frame
	if absf(camera.zoom.x - z0) > 0.0001:
		_fail("面板内滚轮影响了地图缩放：%.4f -> %.4f" % [z0, camera.zoom.x])
		return
	panel.visible = false
	await process_frame
	_wheel(root, Vector2(120, 430), true)
	await process_frame
	if absf(camera.zoom.x - z0) < 0.0001:
		_fail("关掉面板后地图滚轮不缩放，正常功能被误伤：%.4f" % camera.zoom.x)
		return
	print("PANEL TEST 缩放 面板内%.3f(不动) 面板关掉后%.3f(生效)" % [z0, camera.zoom.x])
	panel.open()
	for i in 3:
		await process_frame

	# ---- 资源 Tab：直接在列表里点商品名选中（不再有底部那排选择按钮），
	#      而且详情里**不再画折线图**（用户 2026-10："库存+日产两个折线图删掉"）。
	#      所以这里反过来断言：选中之后一个 Chart 都不该有。
	panel._select_tab(0)
	await process_frame
	var pick_buttons := 0
	for b in panel.find_children("*", "Button", true, false):
		if (b as Button).tooltip_text.begins_with("点击查看"):
			pick_buttons += 1
	if pick_buttons < 10:
		_fail("列表里可点的商品名太少（%d 个），选中交互没接上" % pick_buttons)
		return
	panel._sel_good = ""
	panel._on_pick_good("coarse_bread")
	await process_frame
	if panel._sel_good != "coarse_bread":
		_fail("选中没有生效：_sel_good=%s" % panel._sel_good)
		return
	var charts := 0
	for c in panel.find_children("*", "Chart", true, false):
		charts += 1
	if charts != 0:
		_fail("资源详情里不该再有折线图（用户要求删掉），实际找到 %d 个" % charts)
		return
	print("PANEL TEST 列表可选商品=%d 选中=%s 折线=%d（应为 0）"
		% [pick_buttons, panel._sel_good, charts])

	# ---- 数值和正文**同字号**（12）
	#     2026-10 试过给数字单独放大到 18，用户看完否了（"算了，数字改回来吧，不好看"）。
	#     这条反过来锁住：统计面板里不许出现比 FS 更大的普通标签
	#     （`_big()` 那几格是 BIG_FS，它们是真标题，所以只查"非 BIG_FS 却大于 FS"的）。
	var odd := 0
	for l in panel.find_children("*", "Label", true, false):
		var fs: int = (l as Label).get_theme_font_size("font_size")
		if fs > UIKit.FS and fs != UIKit.BIG_FS:
			odd += 1
	if odd > 0:
		_fail("统计面板里出现了 %d 个非 12 / 非 24 的字号（数字不要单独放大）" % odd)
		return

	# ---- 没有新数据时不能重建面板
	#    曾经 main.gd 写成"只要面板可见就 refresh()"，于是每帧把所有子节点
	#    （含按钮）销毁重建 —— 面板看着正常，但按钮永远点不动。
	var before_ids := []
	for c in panel._body.get_children():
		before_ids.append(c.get_instance_id())
	for i in 12:
		await process_frame
	var after_ids := []
	for c in panel._body.get_children():
		after_ids.append(c.get_instance_id())
	if before_ids != after_ids:
		_fail("面板在无新数据时被重建（%d -> %d 个子节点），按钮会点不动" % [
			before_ids.size(), after_ids.size()])
		return
	print("PANEL TEST 空转 12 帧后面板子节点数=%d 未被重建 ✅" % after_ids.size())

	print("PANEL TEST RESULT: PASS")
	quit(0)

## 往指定位置推一个滚轮事件（走真实的 GUI 派发路径）。
## 先推一个鼠标移动 —— gui_get_hovered_control() 靠移动事件更新，
## 只推滚轮的话悬停状态还是旧的，测不出"悬停 UI 就不碰镜头"这条守卫。
func _wheel(win: Window, pos: Vector2, up: bool) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = pos
	mv.global_position = pos
	win.push_input(mv, true)

	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = pos
	ev.global_position = pos
	win.push_input(ev, true)
