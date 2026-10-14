extends SceneTree

# 全局快捷键门槛。
#
# 锁这几条（都是用户点名的）：
#   · 空格 = 暂停 / 恢复（恢复时保持当前速度档）
#   · `+` / `-` = 加速 / 减速，**最快 4x、最慢 1x**，到顶到底就不动
#   · F1..F8 = 左侧圆钮列（现在 4 个 → F1..F4；F5..F8 落空，**不吃键**，
#     所以 F5 仍然是"快存"）
#   · 1..9 = 建造栏当前页的第 N 张卡片（锁着的卡给出"需要科技"提示、不落位）
#   · Tab / Shift+Tab = 循环换建造栏分类
#   · H = 镜头回到城镇中心
#   · 文本框在打字时（LineEdit 有焦点）以上全部让路
#   · 模态对话框（ESC 菜单 / 新游戏 / 存读档）开着时也让路
#
# ⚠️ 事件必须走**真实的引擎分发链**（`root.push_input` → GUI → `_shortcut_input`
# → `_unhandled_input`）。直接调 `main._shortcut_input(ev)` 是假的：
# 它测不出"这个键在 GUI 那层就被吃掉了"（比如焦点落在 OptionButton 上）。
# 所以下面统一用 `_key()`，**没有**任何一处直接调 `_shortcut_input`。
#
# ⚠️ 老规矩：内容/节点都从**真跑起来的 main.tscn** 取，并带"检查数为 0 就判红"。

var _main = null
var _checks := 0
var _notice := ""

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("KEYS TEST FAIL: ", msg)
	print("KEYS TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

## 按一下某个键（发 press + release 两个事件），走真实分发链。
func _key(keycode: int, shift: bool = false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.pressed = pressed
		ev.shift_pressed = shift
		root.push_input(ev)
	await process_frame

## 只造事件、不派发 —— 给 `Input.parse_input_event()` 用（它会更新按键状态，
## 也就是"**按住**某个键"这种持续状态，`root.push_input()` 做不到）。
func _raw_key(keycode: int, pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = pressed
	return ev

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		_fail("加载不了 main.tscn")
		return
	_main = ps.instantiate()
	root.add_child(_main)
	await process_frame
	await process_frame
	if _main.has_method("_end_title"):
		_main._end_title()
		await process_frame
	await process_frame

	var runner = _main.runner
	var hud = _main.get_node_or_null("UI/Root/HUD")
	var bar = _main.get_node_or_null("UI/Root/BuildBar")
	var world = _main.world
	if runner == null or hud == null or bar == null or world == null:
		_fail("main 没建出 runner / HUD / BuildBar / World（检查 0 个）")
		return
	world.notice.connect(func(t): _notice = String(t))

	# 一切从已知状态开始：运行中、1x（标题页展示期间可能动过速度 / 暂停）
	hud._on_speed(false, 1.0)
	await process_frame
	if runner.paused or runner.speed != 1.0:
		_fail("初始状态没设成（运行中 / 1x）：paused=%s speed=%s" % [str(runner.paused), str(runner.speed)])
		return

	# ---- 1. 空格：暂停 / 恢复 -----------------------------------------------
	await _key(KEY_SPACE)
	if not runner.paused:
		_fail("按空格没有暂停（空格没接到 _shortcut_input？）")
		return
	await _key(KEY_SPACE)
	if runner.paused:
		_fail("再按一次空格没有恢复（还是暂停）")
		return
	_ok("空格：暂停 / 恢复来回切")

	# ---- 2. `+` / `-`：最快 4x、最慢 1x --------------------------------------
	hud._on_speed(false, 1.0)
	await process_frame
	await _key(KEY_EQUAL)
	if runner.speed != 2.0:
		_fail("1x 按 `+` 应该到 2x，实际 %s" % str(runner.speed))
		return
	await _key(KEY_EQUAL)
	if runner.speed != 4.0:
		_fail("2x 按 `+` 应该到 4x，实际 %s" % str(runner.speed))
		return
	await _key(KEY_EQUAL)
	if runner.speed != 4.0:
		_fail("4x 是上限，再按 `+` 不该变，实际 %s" % str(runner.speed))
		return
	await _key(KEY_MINUS)
	if runner.speed != 2.0:
		_fail("4x 按 `-` 应该回 2x，实际 %s" % str(runner.speed))
		return
	await _key(KEY_MINUS)
	await _key(KEY_MINUS)
	if runner.speed != 1.0:
		_fail("1x 是下限，再按 `-` 不该变，实际 %s" % str(runner.speed))
		return
	_ok("`+` / `-`：1x → 2x → 4x 封顶；4x → 2x → 1x 到底（4x/1x 都不越界）")

	# 暂停时按 `+`：以新档恢复（跟点顶栏按钮一致），不能"暂停就不理人"
	hud._on_speed(true, 1.0)
	await process_frame
	await _key(KEY_EQUAL)
	if runner.paused or runner.speed != 2.0:
		_fail("暂停中按 `+` 应该恢复并到 2x，实际 paused=%s speed=%s"
			% [str(runner.paused), str(runner.speed)])
		return
	_ok("暂停中按 `+`：恢复到下一档（不是干等着）")
	hud._on_speed(false, 1.0)
	await process_frame

	# ---- 3. F1..F8 左侧圆钮 --------------------------------------------------
	var nav_n: int = hud.nav_count()
	if nav_n < 1:
		_fail("左侧一个圆钮都没有（检查 0 个）")
		return
	for i in nav_n:
		var tip := String((hud._nav_btns[i] as Button).tooltip_text)
		if not tip.contains("F%d" % (i + 1)):
			_fail("第 %d 个圆钮的 tooltip 没写 F%d 键：%s" % [i + 1, i + 1, tip])
			return
	await _key(KEY_F1)
	var stats_panel = _main.get_node_or_null("UI/Root/Stats")
	var tech_panel = _main.get_node_or_null("UI/Root/Tech")
	if stats_panel == null or not stats_panel.visible:
		_fail("按 F1 没有打开统计面板（圆钮第 1 个 = 资源）")
		return
	stats_panel.visible = false
	await process_frame
	await _key(KEY_F4)
	if tech_panel == null or not tech_panel.visible:
		_fail("按 F4 没有打开科技面板（圆钮第 4 个 = 科技）")
		return
	tech_panel.visible = false
	await process_frame
	_ok("F1..F%d 对上左侧圆钮（tooltip 里也写了键位）" % nav_n)

	# F5..F8 没有对应按钮时**不能吃掉这个键** —— F5 还是"快存"
	if nav_n < 8 and hud.activate_nav(nav_n):
		_fail("第 %d 个圆钮不存在，activate_nav 却返回了 true" % (nav_n + 1))
		return
	_ok("F%d..F8 落空时不吃键（F5 仍然是快存）" % (nav_n + 1))

	# ---- 4. 1..9 建造栏卡片 --------------------------------------------------
	bar._select_tab(0)                 # 住宅
	await process_frame
	var ids: Array = bar._ids_of("住宅")
	if ids.is_empty():
		_fail("「住宅」分类一张卡都没有（检查 0 个）")
		return
	var first_id := String(ids[0])
	world.set_build("")
	await process_frame
	await _key(KEY_1)
	if bar._locked(first_id):
		if world.build_mode == first_id:
			_fail("「%s」科技没解锁，按 1 却落位了" % first_id)
			return
		if _notice == "":
			_fail("按 1 撞到锁着的卡片，却没有给玩家任何提示")
			return
		_ok("按 1 = 锁着的「%s」：不落位，只给提示「%s」" % [first_id, _notice])
	else:
		if world.build_mode != first_id:
			_fail("按 1 应该选中「%s」，实际 build_mode=%s" % [first_id, String(world.build_mode)])
			return
		_ok("按 1 = 当前页第 1 张卡「%s」（与鼠标点它同一条路）" % first_id)

	# 越界：给一个肯定没有的槽位（第 9 张），应当只提示、不崩
	_notice = ""
	world.set_build("")
	await process_frame
	await _key(KEY_9)
	if bar.card_count() < 9:
		if _notice == "":
			_fail("按 9 超出本页卡片数（%d），却没有提示" % bar.card_count())
			return
		if world.build_mode != "":
			_fail("按 9 越界却把 build_mode 设成了「%s」" % String(world.build_mode))
			return
		_ok("按 9 越界：只提示「%s」，不落位" % _notice)

	# ---- 5. Tab / Shift+Tab 循环换分类 --------------------------------------
	bar._select_tab(0)
	await process_frame
	await _key(KEY_TAB)
	if bar._tab != 1:
		_fail("按 Tab 应该到第 2 个分类，实际 _tab=%d" % bar._tab)
		return
	await _key(KEY_TAB, true)
	if bar._tab != 0:
		_fail("Shift+Tab 应该回到第 1 个分类，实际 _tab=%d" % bar._tab)
		return
	# 末尾绕回开头
	bar._select_tab(bar.TABS.size() - 1)
	await process_frame
	await _key(KEY_TAB)
	if bar._tab != 0:
		_fail("最后一个分类按 Tab 应该绕回第 1 个，实际 _tab=%d" % bar._tab)
		return
	_ok("Tab / Shift+Tab 循环换分类（%d 个，末尾绕回开头）" % bar.TABS.size())

	# 笔刷 Tab（其它）：数字键选的是道路 / 地板 / 清除
	bar._select_tab(bar.TABS.size() - 1)
	await process_frame
	if bar.card_count() < 2:
		_fail("「其它」分类没有道路 / 地板两张卡（检查 0 个）")
		return
	world.set_brush("", 1)
	await process_frame
	await _key(KEY_2)
	if world.brush_mode != "floor":
		_fail("在「其它」里按 2 应该切到地板笔刷，实际 brush_mode=%s" % String(world.brush_mode))
		return
	world.set_brush("", 1)
	_ok("「其它」分类里 1 / 2 / 3 = 道路 / 地板 / 清除")

	# ---- 6. H：镜头回城镇中心 ------------------------------------------------
	var tc: Rect2i = world.map.town_center
	var want := Vector2(tc.get_center().x * world.TILE, tc.get_center().y * world.TILE)
	world.camera.position = want + Vector2(5000, 5000)
	await process_frame
	await _key(KEY_H)
	if not world.camera.position.is_equal_approx(want):
		_fail("按 H 之后镜头在 %s，不在城镇中心 %s" % [str(world.camera.position), str(want)])
		return
	_ok("H：镜头回到城镇中心 %s（不动缩放）" % str(want))

	# ---- 6.4 WASD / 方向键平移镜头 ------------------------------------------
	#
	# ⚠️ 平移是**每帧轮询** `Input.is_key_pressed()`（不是吃事件），所以这里必须用
	# `Input.parse_input_event()`（它会更新 Input 单例的按键状态）；
	# `root.push_input()` 不会更新，用它按住 W 是测不出来的。
	var cam0: Vector2 = world.camera.position
	Input.parse_input_event(_raw_key(KEY_W, true))
	for _f in 4:
		await process_frame
	Input.parse_input_event(_raw_key(KEY_W, false))
	await process_frame
	if world.camera.position.y >= cam0.y - 0.01:
		_fail("按住 W 镜头没往上走：%s → %s" % [str(cam0), str(world.camera.position)])
		return
	_ok("W（= 方向键 ↑）平移镜头：%.0f px" % (cam0.y - world.camera.position.y))

	# ---- 6.5 全屏面板开着时，建造栏的快捷键让路（但时间控制照常）-----------
	bar._select_tab(0)
	world.set_build("")
	await process_frame
	var tab_before: int = bar._tab
	# 面板就用 F1 打开（顺带再验一次 F 键）
	await _key(KEY_F1)
	if not stats_panel.visible:
		_fail("F1 没打开统计面板（这一段的守卫就测不到了）")
		return
	await _key(KEY_1)
	if world.build_mode != "":
		_fail("全屏面板开着时按 1 不该在背后选中建筑，实际 build_mode=%s" % String(world.build_mode))
		return
	await _key(KEY_TAB)
	if bar._tab != tab_before:
		_fail("全屏面板开着时按 Tab 不该换分类，实际 _tab=%d" % bar._tab)
		return
	hud._on_speed(false, 1.0)
	await process_frame
	await _key(KEY_SPACE)
	if not runner.paused:
		_fail("全屏面板开着时空格仍应能暂停（顶栏一直露着）")
		return
	stats_panel.visible = false
	hud._on_speed(false, 1.0)
	await process_frame
	_ok("全屏面板（统计 / 科技）开着：数字键 / Tab 让路，空格照常管时间")

	# ---- 7. 文本框有焦点时全部让路 -------------------------------------------
	var le := LineEdit.new()
	le.custom_minimum_size = Vector2(80, 24)
	_main.root_ui.add_child(le)
	await process_frame
	le.grab_focus()
	await process_frame
	if get_root().gui_get_focus_owner() != le:
		_fail("测试用的 LineEdit 没拿到焦点，这条断言测不出来")
		return
	hud._on_speed(false, 1.0)
	await process_frame
	await _key(KEY_SPACE)
	if runner.paused:
		_fail("焦点在输入框里时按空格不该暂停（打字会被打断）")
		return
	bar._select_tab(0)
	await process_frame
	await _key(KEY_TAB)
	if bar._tab != 0:
		_fail("焦点在输入框里时按 Tab 不该换分类，实际 _tab=%d" % bar._tab)
		return
	await _key(KEY_F1)
	if stats_panel.visible:
		_fail("焦点在输入框里时按 F1 不该弹统计面板")
		return
	# 打字时也不能平移镜头：村名 / 存档名里就有 w、a、s、d
	var cam_le: Vector2 = world.camera.position
	Input.parse_input_event(_raw_key(KEY_W, true))
	for _f in 4:
		await process_frame
	Input.parse_input_event(_raw_key(KEY_W, false))
	await process_frame
	if world.camera.position.y < cam_le.y - 0.01:
		_fail("输入框有焦点时按住 W，镜头还是被带走了：%s → %s"
			% [str(cam_le), str(world.camera.position)])
		return
	le.queue_free()
	await process_frame
	await _key(KEY_SPACE)
	if not runner.paused:
		_fail("输入框没了之后空格应该恢复生效（说明守卫是「看焦点」，不是「开关一次就坏」）")
		return
	await _key(KEY_SPACE)
	_ok("输入框有焦点：空格 / Tab / F 键 / WASD 全部让路；焦点一放开立刻恢复")

	# ---- 8. 模态对话框开着时让路 ---------------------------------------------
	var esc = _main.get_node_or_null("UI/Root/EscMenu")
	if esc == null:
		_fail("找不到 ESC 菜单（检查 0 个）")
		return
	esc.open()
	await process_frame
	await _key(KEY_SPACE)
	if runner.paused:
		_fail("ESC 菜单开着时按空格不该暂停")
		return
	esc.close()
	await process_frame
	_ok("ESC 菜单开着时快捷键让路")

	# ---- 收尾 ---------------------------------------------------------------
	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("KEYS TEST 检查了 %d 条断言" % _checks)
	print("KEYS TEST RESULT: PASS")
	quit(0)
