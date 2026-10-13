extends SceneTree

# 顶栏资源 chip 的 tooltip 门槛。
#
# 锁两件事：
#   1. 每条 chip 都有非空的、内容讲得清的 tooltip
#   2. 图标与数字都让开鼠标事件（mouse_filter = IGNORE）
#      —— 否则鼠标落在图标上时 Godot 找不到带 tooltip 的控件，tip 根本不弹。
#      这是"tip 不显示"最常见的原因，而它**看不出来**：代码里 tooltip 明明设了。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("CHIPTIP TEST FAIL: ", msg)
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

	var hud = node.get_node_or_null("UI/Root/HUD")
	if hud == null:
		_fail("找不到 UI/Root/HUD")
		return

	# 跑一天，让库存/预留/价格都有值，tooltip 才有内容可讲
	for h in 26:
		node.runner.sim.tick_hour([])
	hud._refresh()
	await process_frame

	var nodes: Dictionary = hud.get("_chip_nodes")
	var labels: Dictionary = hud.get("_chip_labels")
	if nodes == null or nodes.is_empty():
		_fail("顶栏一条资源 chip 都没有（_chip_nodes 为空）")
		return
	if nodes.size() != labels.size():
		_fail("_chip_nodes(%d) 与 _chip_labels(%d) 数量不一致" % [nodes.size(), labels.size()])
		return

	var checked := 0
	var sample := ""
	for gid in nodes.keys():
		var chip: Control = nodes[gid]
		var tip := String(chip.tooltip_text)
		if tip.strip_edges() == "":
			_fail("「%s」的 chip 没有 tooltip" % gid)
			return
		if not tip.contains(String(gid)) and not tip.contains("库存"):
			_fail("「%s」的 tooltip 内容不像资源说明：%s" % [gid, tip])
			return
		if not tip.contains("库存"):
			_fail("「%s」的 tooltip 缺「库存」行：%s" % [gid, tip])
			return
		if chip.mouse_filter != Control.MOUSE_FILTER_STOP:
			_fail("「%s」的 chip 没接鼠标（mouse_filter=%d），tip 不会弹" % [gid, chip.mouse_filter])
			return
		# 子节点必须让开，否则悬停在图标/数字上时 tip 被吞掉
		for c in chip.get_children():
			if (c as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
				_fail("「%s」的子节点 %s 没让开鼠标（mouse_filter=%d），悬停在它上面 tip 不弹"
					% [gid, c.get_class(), (c as Control).mouse_filter])
				return
		if sample == "":
			sample = tip
		checked += 1

	# 工具类商品应该多讲一句加成
	var tools_chip = nodes.get("stone_tools", null)
	if tools_chip != null:
		var t := String((tools_chip as Control).tooltip_text)
		if not t.contains("工具"):
			_fail("石制工具的 tooltip 没说明它的产出加成：%s" % t)
			return

	print("CHIPTIP TEST 检查了 %d 条 chip；样例：\n---\n%s\n---" % [checked, sample])
	print("CHIPTIP TEST RESULT: PASS")
	quit(0)
