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
	if not is_equal_approx((panel as Control).offset_top, 0.0):
		_fail("地图面板应当**连顶栏一起盖**（offset_top = 0），实际 %.0f" % (panel as Control).offset_top)
		return
	_ok("点小地图打开地图面板：真·全屏（顶栏也盖住）")

	# ---- 3. 据点都在图内 ---------------------------------------------------
	var marks: Array = panel._marks
	if marks.size() != 12:
		_fail("据点数应当是 12（王都 + 10 座别人的 + 我们那一座），实际 %d" % marks.size())
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
	_ok("12 个据点全摆在底图内（%d×%d 的图）" % [int(map_rect.size.x), int(map_rect.size.y)])

	# 区域名都在
	var region_txt := _texts(panel._host)
	for need in ["WALDEN", "CHURCH STATE", "IRONPEAK DUCHY", "KHANATE", "JADE SEA", "GREYROCK RANGE"]:
		if not region_txt.contains(String(need)):
			_fail("地图上缺区域名「%s」：%s" % [need, region_txt])
			return
	_ok("地图上的字：区域名（英文）都在；城名**不画**（只在 hover 卡片里）")
	# 地图上不许出现城名（用户："所有城镇地图上不显示名字，城镇名字放在 tip 里显示"）
	var on_map := _texts(panel._host)
	for s in ["王都", "铁王城", "铁鸦堡", "圣火城", "曙光城", "金穗城", "黑石堡", "铁峰城", "翡翠城", "圣都", "汗庭"]:
		if on_map.contains(String(s)):
			_fail("地图上不该画城名「%s」：%s" % [s, on_map])
			return

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
	if String((crown["data"] as Dictionary)["name"]) != "王都":
		_fail("第一条应当是王都，实际 %s" % String((crown["data"] as Dictionary)["name"]))
		return
	var crown_btn: TextureButton = crown["node"]
	# 橙色（点亮版）图标必须挂在 `texture_hover` 上 —— TextureButton 悬停时优先用它
	if not String(crown_btn.texture_hover.resource_path).contains("_hover"):
		_fail("hover 那张图应当是橙色版（*_hover.png），实际 %s" % crown_btn.texture_hover.resource_path)
		return
	if String(crown_btn.texture_normal.resource_path).contains("_hover"):
		_fail("常态那张图不该是橙色版")
		return
	panel._on_mark_enter(0)
	await process_frame
	if not (crown_btn.scale.x > 1.0):
		_fail("hover 之后应当放大一点")
		return
	if not panel._card.visible:
		_fail("hover 之后没有弹出卡片")
		return
	var card := String(panel._card_title.text) + " / " + String(panel._card_body.text)
	if not card.contains("王都") or not card.contains("领主：") or not card.contains("特产："):
		_fail("卡片里该写「城名 / 领主 / 特产」，实际：%s" % card)
		return
	panel._on_mark_exit(0)
	await process_frame
	if not is_equal_approx(crown_btn.scale.x, 1.0):
		_fail("移开之后不该还放大着")
		return
	if panel._card.visible:
		_fail("移开之后卡片还挂着")
		return
	_ok("hover：橙色图标 + 放大 + 卡片写着「%s」" % card.replace("\n", " "))

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

	# ---- 7. 布置模式：自己拖点位 + 存盘 / 读盘 / 恢复默认 -----------------
	# 用户 2026-10-20："你能不能让我自己调整城镇的位置，有修改坐标什么的，
	# 这样我就不用叫你改了"
	var layout_path: String = ProjectSettings.globalize_path("res://data/map_layout.json")
	# ⚠️ 先备份：这份文件是**用户自己调好的坐标**，测试不能把它删了
	var had_layout := FileAccess.file_exists("res://data/map_layout.json")
	var orig_layout := FileAccess.get_file_as_string("res://data/map_layout.json") if had_layout else ""
	DirAccess.remove_absolute(layout_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://map_layout.json"))
	panel.open()
	await process_frame
	await process_frame
	if not FileAccess.file_exists("res://data/map_layout.json"):
		_fail("第一次打开应当导出一份坐标模板到 res://data/map_layout.json")
		return
	var j0 = JSON.parse_string(FileAccess.get_file_as_string("res://data/map_layout.json"))
	if typeof(j0) != TYPE_DICTIONARY or not (j0 as Dictionary).has("marks"):
		_fail("导出的 map_layout.json 结构不对：%s" % str(j0))
		return
	_ok("布置模式的存档：第一次打开就导出一份坐标模板（marks + regions）")

	# 换算一致性：图标**脚底中点**必须正好是它的 fx/fy
	for e in panel._marks:
		var d: Dictionary = e["data"]
		var b: TextureButton = e["node"]
		var f: Vector2 = panel._to_frac(b, Vector2(b.size.x * 0.5, b.size.y))
		if absf(f.x - float(d["fx"])) > 0.004 or absf(f.y - float(d["fy"])) > 0.004:
			_fail("拖拽换算和摆放不一致：%s 摆放 (%.4f, %.4f) 换算 (%.4f, %.4f)" % [
				String(d["name"]), float(d["fx"]), float(d["fy"]), f.x, f.y])
			return
	_ok("拖拽换算和摆放同口径（脚底中点 = fx/fy）")

	# 开布置模式：地名要变成可拖（STOP），按钮文案要变
	panel._on_edit_toggled(true)
	await process_frame
	if not panel._edit or not String(panel._edit_btn.text).contains("布置中"):
		_fail("点「布置城市」之后应当进布置模式")
		return
	for r in panel._labels:
		if (r["node"] as Label).mouse_filter != Control.MOUSE_FILTER_STOP:
			_fail("布置模式下地名应当可以拖（mouse_filter = STOP）")
			return
	# 拖动第 0 座：按下 → 移动 +120px → 松手
	var target: Dictionary = panel._marks[0]["data"]
	var tbtn: TextureButton = panel._marks[0]["node"]
	var fx0 := float(target["fx"])
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(tbtn.size.x * 0.5, tbtn.size.y)
	panel._on_mark_gui_input(press, 0)
	var mv := InputEventMouseMotion.new()
	mv.position = press.position + Vector2(120, 0)
	panel._on_mark_gui_input(mv, 0)
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = mv.position
	panel._on_mark_gui_input(rel, 0)
	await process_frame
	if float(target["fx"]) <= fx0 + 0.01:
		_fail("鼠标右移之后 fx 应当变大（%.4f → %.4f）" % [fx0, float(target["fx"])])
		return
	var moved := float(target["fx"])
	# 松手应当已经写盘：重新读一遍文件
	var j1 = JSON.parse_string(FileAccess.get_file_as_string("res://data/map_layout.json"))
	var saved_fx := float((j1 as Dictionary)["marks"][String(target["id"])]["fx"])
	if absf(saved_fx - moved) > 0.0002:
		_fail("松手应当自动存盘：文件里 %.4f，内存里 %.4f" % [saved_fx, moved])
		return
	_ok("拖动图标 → fx 变 → 松手自动存盘（%.4f）" % moved)

	# 「重新读入」：把内存改脏，再读回来
	target["fx"] = 0.01
	panel._load_layout()
	await process_frame
	if absf(float(target["fx"]) - moved) > 0.0002:
		_fail("「重新读入」没把文件里的坐标读回来")
		return
	_ok("「重新读入」能把文件里的坐标读回面板")

	# 「恢复默认」：删文件 + 回到内置坐标
	panel._reset_layout()
	await process_frame
	if absf(float(target["fx"]) - fx0) > 0.0004:
		_fail("「恢复默认」没回到内置坐标（%.4f，应当 %.4f）" % [float(target["fx"]), fx0])
		return
	_ok("「恢复默认」把坐标还原成代码里的内置值")

	panel._on_edit_toggled(false)
	await process_frame
	for r in panel._labels:
		if (r["node"] as Label).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			_fail("退出布置模式后地名不该再吃鼠标")
			return
	# 收尾：把用户原来的坐标原样还回去（本来没有就删掉）
	if had_layout:
		var fr := FileAccess.open("res://data/map_layout.json", FileAccess.WRITE)
		if fr != null:
			fr.store_string(orig_layout)
			fr.close()
	else:
		DirAccess.remove_absolute(layout_path)
	_ok("退出布置模式后地名恢复不吃鼠标（收尾把存档还原，不影响用户的坐标）")

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("MAP TEST 检查了 %d 条断言" % _checks)
	print("MAP TEST RESULT: PASS")
	quit(0)
