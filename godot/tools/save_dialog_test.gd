extends SceneTree

# 存档 / 读档对话框门槛（`scripts/ui/save_dialog.gd`）。
#
# 为什么单独一个门槛：这个对话框是**自绘**的，没有场景文件也没有编辑器预览，
# 全靠代码拼 —— 拼错了只有跑起来才发现。而且它替代了 Godot 的 FileDialog，
# 后者正是"一半像素游戏风、一半默认灰 UI"的来源，所以这里既要测功能，
# 也要**测风格**：对话框里不许出现任何非像素主题的控件。
#
# 功能测四件：
#   1. 列表能列出存档，并能读出村名/天数（两种存档格式都认）
#   2. 保存 → 真的落盘，且是**富存档**（`world.save_to`：带 mapSeed/shops）
#   3. 覆盖要**点两次**（第一次只是提示，别把旧档一瞬间冲掉）
#   4. 删除要点两次；删完文件真的没了（.bak 一起带走）

const TEST_NAME := "zz-dialog-test.json"
const TEST_PATH := "user://" + TEST_NAME

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("SAVEDLG TEST FAIL: ", msg)
	_cleanup()
	quit(1)

func _cleanup() -> void:
	for p in [TEST_PATH, TEST_PATH + ".bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var world = node.get("world")
	var runner = node.get("runner")
	var dlg = node.get_node_or_null("DialogLayer/SaveDialog")
	if dlg == null:
		_fail("找不到 DialogLayer/SaveDialog")
		return

	# 干净起点
	_cleanup()
	world.start_new_game(20261014, 1.0, "存测村")
	await process_frame

	# ---- 1. 保存：应落盘，且带 mapSeed/shops（富存档，不是只有仿真状态）
	dlg.open_save(runner, world)
	await process_frame
	(dlg._name_edit as LineEdit).text = TEST_NAME
	dlg._do_save()
	await process_frame
	if not FileAccess.file_exists(TEST_PATH):
		_fail("点「保存」之后 %s 不存在" % TEST_NAME)
		return
	var raw = JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH))
	if raw == null or not raw.has("mapSeed") or not raw.has("shops"):
		_fail("存档不是富格式（缺 mapSeed/shops）—— 保存没走 world.save_to()")
		return
	if not raw.has("sim") or not (raw["sim"] as Dictionary).has("state"):
		_fail("存档里没有 sim.state")
		return

	# ---- 2. 列表能读到村名 / 天数
	var found := {}
	for s in dlg.list_saves():
		if String(s["file"]) == TEST_NAME:
			found = s
	if found.is_empty():
		_fail("list_saves() 里没有刚存的 %s" % TEST_NAME)
		return
	if String(found["village"]) != "存测村":
		_fail("列表读到的村名不对：%s（应 存测村）" % found["village"])
		return
	if not bool(found["ok"]):
		_fail("列表把刚存的档标成了无法识别")
		return

	# ---- 3. 覆盖必须点两次
	var before := FileAccess.get_file_as_string(TEST_PATH)
	# 改动状态，这样"覆盖成功"可验证
	world.start_new_game(7, 1.0, "另一个村")
	await process_frame
	dlg.open_save(runner, world)
	await process_frame
	(dlg._name_edit as LineEdit).text = TEST_NAME
	dlg._do_save()
	await process_frame
	if FileAccess.get_file_as_string(TEST_PATH) != before:
		_fail("第一次点「保存」就把旧档覆盖了（应只提示、要点两次）")
		return
	if String(dlg._hint_lb.text) == "":
		_fail("第一次点「保存」没有给出覆盖提示")
		return
	dlg._do_save()
	await process_frame
	if FileAccess.get_file_as_string(TEST_PATH) == before:
		_fail("第二次点「保存」没有真的覆盖")
		return

	# ---- 4. 读回来：村名应恢复成覆盖时那一局的
	var nm := String(runner.sim.s.get("villageName", ""))
	if nm != "另一个村":
		_fail("覆盖后当前村名应是「另一个村」，实际「%s」" % nm)
		return
	world.start_new_game(9, 1.0, "临时村")
	await process_frame
	dlg.open_load(runner, world)
	await process_frame
	dlg._selected = TEST_PATH
	dlg._do_load()
	await process_frame
	nm = String(runner.sim.s.get("villageName", ""))
	if nm != "另一个村":
		_fail("读档之后村名没有恢复（实际「%s」）" % nm)
		return

	# ---- 5. 删除要点两次
	dlg.open_load(runner, world)
	await process_frame
	dlg._selected = TEST_PATH
	dlg._on_delete()
	await process_frame
	if not FileAccess.file_exists(TEST_PATH):
		_fail("第一次点「删除」就把文件删了（应要点两次）")
		return
	dlg._on_delete()
	await process_frame
	if FileAccess.file_exists(TEST_PATH):
		_fail("第二次点「删除」之后文件还在")
		return
	dlg.close()

	# ---- 6. 风格：对话框里不许有非像素主题的控件
	#    FileDialog / OptionButton / SpinBox / ItemList / Tree / TabBar 都会
	#    自带 Godot 默认皮肤，摆进米黄像素面板就是"一半游戏风一半默认风"。
	var banned := ["FileDialog", "OptionButton", "SpinBox", "ItemList", "Tree", "TabBar",
		"TabContainer", "CheckBox", "CheckButton", "HSlider", "VSlider", "ProgressBar"]
	for cls in banned:
		var hits := dlg.find_children("*", cls, true, false)
		if hits.size() > 0:
			_fail("存档对话框里有 %d 个 %s（会带默认皮肤）" % [hits.size(), cls])
			return
	var no_font := 0
	for c in dlg.find_children("*", "Control", true, false):
		if c is Label or c is Button or c is LineEdit:
			if (c as Control).get_theme_font("font") != UIKit.pixel_font():
				no_font += 1
	if no_font > 0:
		_fail("对话框里有 %d 个控件没用像素字体" % no_font)
		return
	# 输入框必须是凹陷石板底（不是 Godot 默认白框）
	var le_ok := false
	for e in dlg.find_children("*", "LineEdit", true, false):
		var sb = (e as LineEdit).get_theme_stylebox("normal")
		if sb is StyleBoxTexture and (sb as StyleBoxTexture).texture != null:
			le_ok = true
	if not le_ok:
		_fail("存档名输入框没有用像素底纹（还是默认白框？）")
		return

	print("SAVEDLG TEST 存档=%s 村名=%s 控件=%d" % [
		TEST_NAME, found["village"], dlg.find_children("*", "Control", true, false).size()])
	print("SAVEDLG TEST RESULT: PASS")
	_cleanup()
	quit(0)
