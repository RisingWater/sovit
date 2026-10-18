extends SceneTree

# 王国地图门槛（2026-10-20）。
#
# 用户："地图面板，点击小地图的时候进入。……先实现地图打开，各个城镇显示，地图上的字，
# hover 效果，鼠标移上去显示基本信息（城镇名字，领主，特产）"
#
# 盯这几件事：
#   1. 点左上角小地图 → 地图面板打开（再点一下 / 点「关闭」收掉）
#   2. 底图与图标素材都在，且**据点全摆在图内**（比例坐标换算对不对）
#   3. 我们那一座**跟着城镇中心变**：废墟=村庄 → 初步修缮=小城镇 → 修好=中城镇
#   4. hover：换点亮图标、放大，并弹出「城名 / 领主 / 特产」卡片；移开收掉
#   5. 全屏（anchors 0..1，顶栏留着）—— 和统计 / 任务面板同一个口径
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/map_test.gd

var db = null
var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("MAP TEST FAIL: ", msg)
	print("MAP TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _texts(root: Node) -> String:
	var parts := PackedStringArray()
	for c in root.find_children("*", "Label", true, false):
		parts.append((c as Label).text)
	return " / ".join(parts)

func _run() -> void:
	root.size = Vector2i(1600, 900)
	await process_frame
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var panel = node.get_node_or_null("UI/Root/MapPanel")
	var minimap = node.get_node_or_null("UI/Root/Minimap")
	if panel == null or minimap == null:
		_fail("找不到 MapPanel / Minimap")
		return
	var sim = node.get("runner").sim

	# ---- 1. 素材在位 ------------------------------------------------------
	for kind in ["town_large", "town_medium", "town_small", "village", "camp", "temple"]:
		for suffix in ["", "_hover"]:
			var path := "res://assets/ui/map/%s%s.png" % [kind, suffix]
			if not ResourceLoader.exists(path):
				_fail("缺图标：%s" % path)
				return
	if not ResourceLoader.exists("res://assets/ui/map/kingdom_map_bare.jpg"):
		_fail("缺底图 res://assets/ui/map/kingdom_map_bare.jpg")
		return
	_ok("素材在位：底图 + 6 类据点 ×（默认 / hover）= 13 个文件")

	# ---- 2. 点小地图 → 打开 ----------------------------------------------
	if panel.visible:
		_fail("地图面板一开始不该是打开的")
		return
	var mc: Vector2 = (minimap as Control).get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = mc
		ev.global_position = mc
		root.push_input(ev)
		await process_frame
	await process_frame
	if not panel.visible:
		_fail("点小地图没有打开地图面板（%s）" % str(mc))
		return
	if not is_equal_approx((panel as Control).anchor_right, 1.0) \
			or not is_equal_approx((panel as Control).anchor_bottom, 1.0):
		_fail("地图面板应当全屏（anchors 0..1）")
		return
	if not is_equal_approx((panel as Control).offset_top, float(UIKit.BAR_H)):
		_fail("地图面板应当只留顶栏（offset_top = BAR_H），实际 %.0f" % (panel as Control).offset_top)
		return
	_ok("点小地图打开地图面板：全屏、只留顶栏")

	# ---- 3. 据点都在图内 ---------------------------------------------------
	var marks: Array = panel._marks
	if marks.size() != 11:
		_fail("据点数应当是 11（10 个别人的 + 我们那一座），实际 %d" % marks.size())
		return
	var map_rect := Rect2(panel._map.position, panel._map.size)
	if map_rect.size.x < 100.0 or map_rect.size.y < 100.0:
		_fail("底图没有量出尺寸：%s" % str(map_rect))
		return
	for e in marks:
		var btn: TextureButton = e["node"]
		var c := btn.position + btn.size * 0.5
		if c.x < map_rect.position.x - 1.0 or c.x > map_rect.end.x + 1.0 \
				or c.y < map_rect.position.y - 1.0 or c.y > map_rect.end.y + 1.0:
			_fail("据点「%s」跑到图外了：%s（图 %s）" % [
				String((e["data"] as Dictionary)["name"]), str(c), str(map_rect)])
			return
	_ok("11 个据点全摆在底图内（%d×%d 的图）" % [int(map_rect.size.x), int(map_rect.size.y)])

	# 区域名都在
	var region_txt := _texts(panel._host)
	for need in ["瓦尔登王国", "圣辉教国", "铁峰公国", "沙海汗国", "翡翠海", "灰岩山脉"]:
		if not region_txt.contains(String(need)):
			_fail("地图上缺区域名「%s」：%s" % [need, region_txt])
			return
	_ok("地图上的字：6 个区域名 + 11 个城名都在")

	# ---- 4. 我们那一座跟着城镇中心变 --------------------------------------
	var home_e: Dictionary = marks[marks.size() - 1]
	if String((home_e["data"] as Dictionary)["id"]) != "ashen_vale":
		_fail("最后一条应当是我们自己的据点（ashen_vale）")
		return
	var home_btn: TextureButton = home_e["node"]
	var ruined_path := home_btn.texture_normal.resource_path
	if not ruined_path.contains("village"):
		_fail("开局城镇中心是废墟，我们的据点应当是**村庄**图标，实际 %s" % ruined_path)
		return
	sim.s["townCenter"] = {"stage": "patched"}
	panel._refresh_home()
	if not String(home_btn.texture_normal.resource_path).contains("town_small"):
		_fail("初步修缮之后应当是小城镇，实际 %s" % home_btn.texture_normal.resource_path)
		return
	sim.s["townCenter"] = {"stage": "restored"}
	panel._refresh_home()
	if not String(home_btn.texture_normal.resource_path).contains("town_medium"):
		_fail("修好之后应当是中型城镇，实际 %s" % home_btn.texture_normal.resource_path)
		return
	sim.s["townCenter"] = {"stage": "ruined"}
	panel._refresh_home()
	_ok("我们的据点跟着城镇中心变：废墟=村庄 → 初步修缮=小城镇 → 修好=中型城镇")

	# ---- 5. hover：点亮图标 + 放大 + 卡片（城名 / 领主 / 特产）------------
	var crown: Dictionary = marks[0]
	if String((crown["data"] as Dictionary)["name"]) != "铁王城":
		_fail("第一条应当是铁王城，实际 %s" % String((crown["data"] as Dictionary)["name"]))
		return
	var crown_btn: TextureButton = crown["node"]
	panel._on_mark_enter(0)
	await process_frame
	if not String(crown_btn.texture_normal.resource_path).contains("_hover"):
		_fail("hover 之后应当换成点亮版图标，实际 %s" % crown_btn.texture_normal.resource_path)
		return
	if not (crown_btn.scale.x > 1.0):
		_fail("hover 之后应当放大一点")
		return
	if not panel._card.visible:
		_fail("hover 之后没有弹出卡片")
		return
	var card := String(panel._card_title.text) + " / " + String(panel._card_body.text)
	if not card.contains("铁王城") or not card.contains("领主：") or not card.contains("特产："):
		_fail("卡片里该写「城名 / 领主 / 特产」，实际：%s" % card)
		return
	panel._on_mark_exit(0)
	await process_frame
	if String(crown_btn.texture_normal.resource_path).contains("_hover"):
		_fail("移开之后图标没有还原")
		return
	if panel._card.visible:
		_fail("移开之后卡片还挂着")
		return
	_ok("hover：点亮图标 + 放大 + 卡片写着「%s」" % card.replace("\n", " "))

	# ---- 6. 关得掉 --------------------------------------------------------
	var close: Button = null
	for b in panel.find_children("*", "Button", true, false):
		if (b as Button).text == "关闭":
			close = b
	if close == null:
		_fail("没有「关闭」按钮")
		return
	close.pressed.emit()
	await process_frame
	if panel.visible:
		_fail("点「关闭」之后面板还开着")
		return
	_ok("「关闭」能收掉地图")

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("MAP TEST 检查了 %d 条断言" % _checks)
	print("MAP TEST RESULT: PASS")
	quit(0)
