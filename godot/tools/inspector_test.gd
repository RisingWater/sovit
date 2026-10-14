extends SceneTree

# 右侧检视面板门槛。
#
# 用户要求的三件事，逐条锁住：
#   1. **没选中任何东西时整个面板收起来** —— 全局数字顶栏已经全有
#      （人口/满意度/钱/建造力/科研/移民），不该再占一屏。
#   2. 选中**城镇中心** → 人口（移民 / 上限 / 空房 / 次日会来）。
#   3. 选中**仓库** → 资源列表：每种货的数量 + **上限就在这里设**，
#      填完立刻进 pending（次日 06:00 生效），而不是等面板下次刷新被打回旧值。
#
# 顺带锁住"上限不在「设置资源」里了"：那个面板现在只管顶栏显示哪些资源，
# 里面不该再有任何输入框。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("INSPECTOR TEST FAIL: ", msg)
	quit(1)

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
	if ins == null or runner == null:
		_fail("找不到 Inspector / runner")
		return

	# ---- 1. 未选中 → 收起来
	ins.clear()
	await process_frame
	if ins.visible:
		_fail("没选中任何东西时面板仍然显示（应整个收起来）")
		return
	if ins.find_children("*", "Label", true, false).size() > 0:
		_fail("未选中时面板里还留着内容")
		return

	# ---- 2. 城镇中心 → 人口
	var tc_id := ""
	var wh_id := ""
	for sh in runner.sim.s["shops"]:
		if String(sh["defId"]) == "town_center":
			tc_id = String(sh["id"])
	ins.show_building(tc_id)
	await process_frame
	if not ins.visible:
		_fail("选中城镇中心后面板没显示")
		return
	var keys: Array = []
	for l in ins.find_children("*", "Label", true, false):
		keys.append((l as Label).text)
	for need in ["城镇中心 · 人口", "人口上限", "当前人口", "空房", "次日会来", "公告"]:
		if not keys.has(need) and not _has_prefix(keys, need):
			_fail("城镇中心面板缺少「%s」，实际：%s" % [need, keys])
			return
	# 通用建筑面板那套（用工拖动条 / 拆除）不该出现在村中心
	if ins.find_children("*", "HSlider", true, false).size() > 0:
		_fail("城镇中心面板里不该有通用建筑的用工拖动条")
		return

	# ---- 3. 仓库 → 资源（数量 / 上限）
	#    开局没有仓库，先塞一座并让世界摆出来
	var s: Dictionary = runner.sim.s
	(s["shops"] as Array).append({
		"id": "warehouse#t", "defId": "warehouse", "owner": "state",
		"targetWorkers": 1, "wage": 3.0, "wageCap": 6.0, "level": 1,
		"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	wh_id = "warehouse#t"
	ins.show_building(wh_id)
	await process_frame
	keys = []
	for l in ins.find_children("*", "Label", true, false):
		keys.append((l as Label).text)
	for need in ["仓库 · 仓储", "本座容量", "全村仓储", "资源（数量 / 上限）"]:
		if not keys.has(need):
			_fail("仓库面板缺少「%s」，实际：%s" % [need, keys])
			return
	# 每种货一行输入框（数量是只读 Label，上限是 LineEdit）
	var edits := ins.find_children("*", "LineEdit", true, false)
	var goods_n: int = (runner.db.packs[String(s["pack"])]["goods"] as Array).size()
	if edits.size() != goods_n:
		_fail("仓库面板的上限输入框应有 %d 个（每种货一个），实际 %d" % [goods_n, edits.size()])
		return
	for e in edits:
		if (e as LineEdit).placeholder_text != "不限":
			_fail("上限输入框的提示语应是「不限」")
			return

	# 上限真的进队列：往其中一个输入框填 120。
	#
	# ⚠️ 这里必须"先改控件文本、再直接调处理器"：Godot 4.7 的 `LineEdit.text = x`
	# **不会**发 `text_changed`（只有真实键盘/GUI 输入才发，实测确认过），
	# 所以没法靠赋值走信号；直接调处理器等价于玩家打字那一下。
	var gid0 := String((runner.db.packs[String(s["pack"])]["goods"] as Array)[0])
	var le0: LineEdit = ins._cap_inputs.get(gid0, null)
	if le0 == null:
		_fail("仓库面板里找不到「%s」的上限输入框" % gid0)
		return
	le0.text = "120"
	ins._on_cap_text("120", gid0)
	var pending_caps := _pending_caps(runner)
	if int(pending_caps.get(gid0, 0)) != 120:
		_fail("填了 120 之后 pending 里没有 set_storage_caps[%s]=120（实际 %s）" % [gid0, pending_caps])
		return
	# 非数字要被过滤掉（12a3 → 123）
	le0.text = "12a3"
	ins._on_cap_text("12a3", gid0)
	if le0.text != "123":
		_fail("非数字没有被过滤：输入 12a3，输入框里是「%s」（应 123）" % le0.text)
		return
	pending_caps = _pending_caps(runner)
	if int(pending_caps.get(gid0, 0)) != 123:
		_fail("过滤后 pending 里的值是 %s（应 123）" % str(pending_caps.get(gid0, 0)))
		return
	# 清空 = 不限：这一项应从表里消失
	le0.text = ""
	ins._on_cap_text("", gid0)
	pending_caps = _pending_caps(runner)
	if pending_caps.has(gid0):
		_fail("清空输入框后该项仍在上限表里（留空应 = 不限）")
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
		_fail("「设置资源」里还有输入框 —— 上限应只在仓库面板里设")
		return
	picker.hide()

	print("INSPECTOR TEST 商品=%d 上限框=%d" % [goods_n, edits.size()])
	print("INSPECTOR TEST RESULT: PASS")
	quit(0)

func _has_prefix(arr: Array, prefix: String) -> bool:
	for a in arr:
		if String(a).begins_with(prefix):
			return true
	return false

## pending 里那条 set_storage_caps 的 caps（没有就是空表）。
func _pending_caps(runner) -> Dictionary:
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_storage_caps":
			return (a.get("caps", {}) as Dictionary)
	return {}
