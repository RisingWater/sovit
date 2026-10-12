extends SceneTree
func _init() -> void: call_deferred("_run")
func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var bar = node.get_node_or_null("UI/Root/BuildBar")
	if bar == null:
		print("BARTAB FAIL: 找不到 BuildBar"); quit(1); return
	var total := 0
	for i in bar.TABS.size():
		var cat: String = bar.TABS[i]
		if cat == "其它":
			print("BARTAB [%s] 道路 / 地板" % cat)
			continue
		var ids = bar._ids_of(cat)
		total += ids.size()
		var names := []
		for id in ids:
			names.append(bar._name_of(String(id)))
		print("BARTAB [%s] %d 座: %s" % [cat, ids.size(), ", ".join(names)])
	# 笔刷尺寸只在最后一个 Tab（其它）显示
	for i in bar.TABS.size():
		bar._select_tab(i)
		await process_frame
		var last: bool = bar.TABS[i] == "其它"
		if bar._size_box.visible != last:
			print("BARTAB FAIL: Tab「%s」的笔刷尺寸可见性应为 %s" % [bar.TABS[i], last])
			quit(1); return
	# 只有一页的 Tab 不该出现翻页控件
	for i in bar.TABS.size():
		bar._select_tab(i)
		await process_frame
		var cat: String = bar.TABS[i]
		var n: int = 2 if cat == "其它" else bar._ids_of(cat).size()
		var avail: float = (bar.size.x - 130.0) if bar.size.x > 300.0 else 1100.0
		var per: int = maxi(1, int(avail / float(UIKit.CARD_W + UIKit.GAP)))
		var pages: int = int(ceil(float(n) / float(per)))
		if pages <= 1 and bar._prev_btn.visible:
			print("BARTAB FAIL: Tab「%s」只有 %d 页却还显示翻页按钮" % [cat, pages])
			quit(1); return
	bar._select_tab(0)

	print("BARTAB 建筑总数=%d" % total)
	# 每座建筑只能出现在一个 tab
	var seen := {}
	var dup := 0
	for i in bar.TABS.size():
		var cat: String = bar.TABS[i]
		if cat == "其它": continue
		for id in bar._ids_of(cat):
			if seen.has(id): dup += 1
			seen[String(id)] = cat
	# 期望值从内容包推导，不硬编码（各 pack 的建筑数量不同）
	var pack: Dictionary = bar.runner.db.packs[String(bar.runner.sim.s["pack"])]
	var expect: int = (pack["buildings"] as Array).size() + (pack["housing"] as Array).size()
	print("BARTAB 去重后=%d 重复=%d 期望=%d" % [seen.size(), dup, expect])
	var ok: bool = dup == 0 and total == expect and seen.size() == expect
	print("BARTAB RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
