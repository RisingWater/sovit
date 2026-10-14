extends SceneTree

# 移民按钮的即时反馈。
#
# 用户的抱怨是"点了没反应"—— 因为 set_population_cap 是"次日 06:00 生效"的，
# 排进 pending 后状态里的旧值不变，面板照旧显示旧数字。
# 所以这里断言的是**显示出来的文本**，不是只查 pending 队列有没有入队。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("IMM TEST FAIL: ", msg)
	quit(1)

## 在面板里找 key 那一格，返回它同行右边的 value 文本
func _value_of(root: Node, key: String) -> String:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == key:
			var row := l.get_parent()
			if row != null and row.get_child_count() >= 2:
				return (row.get_child(1) as Label).text
	return "<未找到 %s>" % key

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var runner = node.get("runner")
	var ins = node.get_node_or_null("UI/Root/Inspector")
	if ins == null or runner == null:
		_fail("找不到 Inspector / runner")
		return

	for h in 24 * 4:
		runner.sim.tick_hour([])
		await process_frame

	# 人口面板现在在**城镇中心的浮动对话框**里（右侧常驻面板已按要求去掉，
	# 见 main._on_select_building 的分派），所以这里走真实的选中路径。
	var tc_id := ""
	for sh in runner.sim.s["shops"]:
		if String(sh["defId"]) == "town_center":
			tc_id = String(sh["id"])
	if tc_id == "":
		_fail("开局没有城镇中心，人口面板无处可看")
		return
	node._on_select_building(tc_id)
	await process_frame
	var panel = node.get_node_or_null("UI/Root/Civic")
	if panel == null or not panel.visible:
		_fail("选中城镇中心后没有弹出人口对话框")
		return
	if ins.visible:
		_fail("弹了对话框，右侧常驻面板却不该同时显示")
		return

	# 点"全收"：当前允许必须**立刻**变成不限并标注已排队
	panel._set_population_cap(1000000000)
	await process_frame
	var t_all := _value_of(panel, "人口上限（已排队）")
	if t_all != "不限":
		_fail("点全收后『人口上限（已排队）』应为 不限，实际 %s" % t_all)
		return

	# 点"暂停"：立刻变成 0
	panel._set_population_cap(0)
	await process_frame
	var t_pause := _value_of(panel, "人口上限（已排队）")
	if t_pause != "0":
		_fail("点暂停后『人口上限（已排队）』应为 0，实际 %s" % t_pause)
		return

	# 点"+10"：立刻变成 10
	panel._set_population_cap(10)
	await process_frame
	var t_add := _value_of(panel, "人口上限（已排队）")
	if t_add != "10":
		_fail("点+10后『人口上限（已排队）』应为 10，实际 %s" % t_add)
		return

	# 「次日会来」必须存在 —— 这才是真正会发生的事
	var will := _value_of(panel, "次日会来")
	if will.begins_with("<未找到"):
		_fail("面板没有『次日会来』这一行")
		return

	print("IMM TEST 全收->%s 暂停->%s +10->%s 次日会来=%s" % [t_all, t_pause, t_add, will])
	print("IMM TEST RESULT: PASS")
	quit(0)
