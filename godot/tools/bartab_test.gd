extends SceneTree
func _init() -> void: call_deferred("_run")
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
		# 「其它」= 道路 / 地板 / 清除 三张笔刷卡
		var n: int = 3 if cat == "其它" else bar._ids_of(cat).size()
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
	# 期望值从内容包推导，不硬编码（各 pack 的建筑数量不同）。
	# 减去 `ContentDB.MAP_FIXED`：地图上**固定存在**的建筑（城镇中心）不进建造列表 ——
	# 地图中央那一座是 `_build_town_center()` 画的，再"建"一座只会得到
	# 材料照扣、精灵不画的隐形建筑。
	# ⚠️ 2026-10：这份名单从 `build_bar` 搬到了 `ContentDB`（AI 辅助的"可建清单"也要
	#    用同一份，见 docs/ai-assist.md），所以这里跟着改问内容层。
	var pack: Dictionary = bar.runner.db.packs[String(bar.runner.sim.s["pack"])]
	var expect: int = (pack["buildings"] as Array).size() + (pack["housing"] as Array).size() \
		- (ContentDB.MAP_FIXED as Array).size()
	print("BARTAB 去重后=%d 重复=%d 期望=%d" % [seen.size(), dup, expect])

	# 每座建筑的分类都必须是**一个真实存在的 Tab**。
	# 2026-10 用户把「工业」拆成「民生工业」+「重工业」：分类名改了而 `TABS` 没跟上，
	# 那几座建筑不会报错，只会**在建造栏里静默消失**（"这座建筑没了"）。这条就是防这个。
	for bid in pack["buildings"]:
		var cat: String = bar._category_of(String(bid))
		if not bar.TABS.has(cat):
			print("BARTAB FAIL: 建筑 %s 的分类「%s」不是一个 Tab（会在建造栏里静默消失）"
				% [String(bid), cat])
			quit(1); return
	for hid in pack["housing"]:
		var hcat: String = bar._category_of(String(hid))
		if not bar.TABS.has(hcat):
			print("BARTAB FAIL: 住房 %s 的分类「%s」不是一个 Tab" % [String(hid), hcat])
			quit(1); return
	print("BARTAB 分类自检：%d 个 Tab，每座的分类都能落到一个 Tab 上 ✅" % bar.TABS.size())

	var ok: bool = dup == 0 and total == expect and seen.size() == expect
	print("BARTAB RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
