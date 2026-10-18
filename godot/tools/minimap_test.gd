extends SceneTree

# 左上角小地图挂件门槛。
#
# 重点查两件容易静默失效的事：
#   1. 圆环贴图必须在 _ready() 里加载好 —— 在 _draw() 里现 load() 会拿到
#      尚未完成的占位纹理，画出来是一整块白的，不报错。
#   2. 顶栏两行都要让开挂件宽度，否则资源条被压在小地图底下。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("MINIMAP TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	# 标题页会藏掉整个游戏 UI 并接管镜头，测游戏内 UI 前先关掉它
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var mm = node.get_node_or_null("UI/Root/Minimap")
	if mm == null:
		_fail("找不到 UI/Root/Minimap")
		return

	# 1. 圆环贴图必须已经加载好（4 张，都不能为 null）
	var tex: Array = mm._ring_tex
	if tex.size() != 4:
		_fail("圆环贴图应有 4 张，实际 %d" % tex.size())
		return
	for i in tex.size():
		if tex[i] == null:
			_fail("第 %d 张圆环贴图为 null —— _draw() 里会画成白块" % i)
			return

	# 2. 尺寸：圆环必须是 64 的整数倍，否则重采样糊掉
	var d: int = mm.RING_D
	if d % 64 != 0:
		_fail("RING_D=%d 不是 64 的整数倍，像素会被重采样" % d)
		return

	# 2b. 日期框与红巾必须叠在圆盘范围内（紧凑排布），不能把挂件撑高
	if mm.size.y > float(d) + 8.0:
		_fail("挂件高度 %.0f 超出圆盘 %d —— 日期框/红巾没有叠上去" % [mm.size.y, d])
		return

	# 3. 村名：默认 sovit、能改、长度受限
	if mm.village_name() != "sovit":
		_fail("默认村名应为 sovit，实际 %s" % mm.village_name())
		return
	mm.set_village_name("  新村  ")
	if mm.village_name() != "新村":
		_fail("改名没生效或没去空白：%s" % mm.village_name())
		return
	mm.set_village_name("")
	if mm.village_name() != "sovit":
		_fail("清空后应回落到 sovit，实际 %s" % mm.village_name())
		return
	mm.set_village_name("这是一个非常非常非常长的村庄名字超过十六个字")
	if mm.village_name().length() > 16:
		_fail("村名没有限制长度：%d" % mm.village_name().length())
		return
	# 存进仿真状态里（随存档保存）
	if String(node.get("runner").sim.s.get("villageName", "")) != mm.village_name():
		_fail("村名没有写进仿真状态，存档带不走")
		return
	mm.set_village_name("sovit")

	# 4. 顶栏两行都要让开挂件
	var hud = node.get_node_or_null("UI/Root/HUD")
	if hud == null:
		_fail("找不到 HUD")
		return
	# 顶栏第一行现在是"图标 + 数值"的 _stats_row（以前是个叫 _info 的标签）
	for pair in [["第一行", hud._stats_row.get_parent()], ["资源行", hud._res_row]]:
		var row = pair[1]
		var first = row.get_child(1)      # 0 是间距占位，1 才是第一个真控件
		if first == null:
			_fail("%s 是空的" % pair[0])
			return
		var pad = row.get_child(0)
		if pad == null or pad.custom_minimum_size.x < float(mm.RING_D):
			_fail("%s 没有给左上角小地图留出宽度" % pair[0])
			return

	# 5. 小地图跟随镜头：移动镜头，中心格必须跟着变
	var world = node.get_node_or_null("World")
	if world == null or world.camera == null:
		_fail("找不到 World.camera")
		return
	world.camera.position = Vector2(0, 0)
	await process_frame
	var c0: Vector2 = mm.center_cell()
	world.camera.position = Vector2(world.TILE * 40, world.TILE * 25)
	await process_frame
	var c1: Vector2 = mm.center_cell()
	if c1.distance_to(c0) < 30.0:
		_fail("镜头移动了 40/25 格，小地图中心却几乎没动：%s -> %s" % [c0, c1])
		return
	if absf(c1.x - 40.0) > 1.1 or absf(c1.y - 25.0) > 1.1:
		_fail("小地图中心没有对上镜头：期望约 (40,25)，实际 %s" % c1)
		return

	# 6. 缩放跟随：拉近镜头（zoom 变大）视野格数应变少
	var v_before: float = mm.view_cells()
	world.camera.zoom = Vector2(6.0, 6.0)
	await process_frame
	var v_in: float = mm.view_cells()
	world.camera.zoom = Vector2(1.5, 1.5)
	await process_frame
	var v_out: float = mm.view_cells()
	if not (v_in < v_before and v_out > v_before):
		_fail("视野没跟缩放走：zoom3->%.1f zoom6->%.1f zoom1.5->%.1f" % [v_before, v_in, v_out])
		return
	world.camera.zoom = Vector2(3.0, 3.0)

	# 7. 顶栏不能再显示日期时间 —— 已经移到小地图挂件上，两处重复是多余的
	var re := RegEx.new()
	# 用户 2026-10-20（B0）：日期改成 `AE 312年1月1日`（上面一行）+ `06:00`（下面一行），
	# 所以这里按 AE 日期认，不再按「第 N 天」。空格可有可无（`AE` 与年之间留一个）。
	re.compile("AE *[0-9]+ *年 *[0-9]+ *月 *[0-9]+ *日")
	for l in hud.find_children("*", "Label", true, false):
		if re.search((l as Label).text) != null:
			_fail("顶栏里还有日期时间：『%s』" % (l as Label).text)
			return
	# 但挂件上必须有
	var found_mm := false
	for l in mm.find_children("*", "Label", true, false):
		if re.search((l as Label).text) != null:
			found_mm = true
	if not found_mm:
		_fail("小地图挂件上没有日期时间")
		return

	print("MINIMAP TEST 圆环=%dpx 贴图=%d 村名=%s 跟随镜头 %s->%s 缩放 %.0f/%.0f/%.0f ✅" % [
		d, tex.size(), mm.village_name(), c0, c1, v_before, v_in, v_out])
	print("MINIMAP TEST RESULT: PASS")
	quit(0)
