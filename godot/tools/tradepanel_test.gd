extends SceneTree

# 贸易市场面板门槛（M4，2026-10）。
#
# red 的含义：① 点不开（open_trade 之后不可见）② 有游商却画不出行
#              ③ 点按钮不发命令（玩家会以为"点了没反应"）④ 快照里的剩余天数不对
#              ⑤ 建造栏里找不到「贸易市场」/ 圆钮不出现（用户："市场这个建筑没了，
#                 这样游商系统的入口在哪里？"）

const SEED := 20261025

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("TRADEPANEL TEST FAIL: ", msg)
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
	var world = node.get("world")
	world.start_new_game(SEED, 1.0, "贸易测试")
	await process_frame
	var runner = node.get("runner")
	var sim = runner.sim

	# 让游商到货（第 3 章 + 当天到）
	sim.s["quests"]["chapters"]["3"] = 3
	sim.s["trade"]["nextWaveDay"] = int(sim.s["day"])
	sim._update_caravans(int(sim.s["day"]))
	if (sim.s["trade"]["caravans"] as Array).is_empty():
		_fail("第 3 章了却没有游商到货（引擎侧没生成）")
		return

	var panel = node.get("_panel_trade")
	if panel == null:
		_fail("main.tscn 里没有创建贸易市场面板（_panel_trade）")
		return
	panel.open_trade()
	await process_frame
	if not panel.visible:
		_fail("open_trade() 之后面板不可见")
		return

	# 版式：**全屏**（用户 2026-10："贸易界面应该是也是全屏面板的"），和统计 / 科技同口径
	if absf(panel.anchor_right - 1.0) > 0.001 or absf(panel.anchor_bottom - 1.0) > 0.001:
		_fail("贸易面板不是全屏（anchors = %.2f..%.2f / %.2f..%.2f）" % [
			panel.anchor_left, panel.anchor_right, panel.anchor_top, panel.anchor_bottom])
		return
	if absf(panel.offset_top - float(UIKit.BAR_H)) > 0.001:
		_fail("贸易面板的 offset_top 是 %.0f，应当留出顶栏 %.0f" % [panel.offset_top, UIKit.BAR_H])
		return
	# 页签：游商 只是其中一个（用户："游商只是一个tab"）
	var tabs: Array = panel.get("_tab_btns")
	if tabs.size() < 2:
		_fail("贸易面板只有 %d 个页签（至少要「游商」+「商路」）" % tabs.size())
		return
	if String((tabs[0] as Button).text) != "游商":
		_fail("第一个页签是「%s」，应当是「游商」" % String((tabs[0] as Button).text))
		return
	# 右下角顾问立绘：薇拉（兼管贸易）
	var portrait = panel.find_child("Portrait", true, false)
	if portrait == null:
		_fail("贸易面板右下角没有顾问立绘（PanelPortrait）")
		return
	if String(portrait.get("id")) != "vera":
		_fail("贸易面板的立绘是「%s」，应当是薇拉（vera）" % String(portrait.get("id")))
		return
	if portrait.get("tex") == null:
		_fail("薇拉的立绘贴图没载进来（assets/portraits/vera.png）")
		return
	print("TRADEPANEL TEST 版式：全屏 + %d 个页签（游商 / 商路）+ 薇拉立绘 ✅" % tabs.size())

	var body: VBoxContainer = panel.get("_body")
	if body == null or body.get_child_count() == 0:
		_fail("有游商时面板一行都没画出来")
		return
	print("TRADEPANEL TEST 打开：面板可见，%d 个内容块 ✅" % body.get_child_count())

	# 物资图标必须是 **32×32**（用户 2026-10："贸易面板里的图标被放大到了 64x64，
	# 你要保持 32x32"）。这条防的是 `TextureRect` 的经典坑：只写 `custom_minimum_size`
	# 而不写 `expand_mode = EXPAND_IGNORE_SIZE` 时，最小尺寸会取**贴图本身**（v7 那批是 64），
	# 于是"设了 32 却画成 64"。所以这里看 `get_combined_minimum_size()`，不是 `size`。
	var too_big := 0
	for tr in body.find_children("*", "TextureRect", true, false):
		var t := (tr as TextureRect)
		if t.texture == null:
			continue
		if t.get_combined_minimum_size().x > 32.0:
			too_big += 1
	if too_big > 0:
		_fail("有 %d 个图标被放到 64（物资图标应当固定 32×32，检查 expand_mode）" % too_big)
		return
	print("TRADEPANEL TEST 图标：物资 32×32 / 金币 16（没有被贴图 64 撑大）✅")

	# 快照：剩余天数 = leaveDay - day + 1
	var snap: Dictionary = sim.trade_snapshot()
	var cv: Dictionary = (snap["caravans"] as Array)[0]
	var want := int(sim.s["trade"]["caravans"][0]["leaveDay"]) - int(sim.s["day"]) + 1
	if int(cv["daysLeft"]) != want:
		_fail("剩余天数 %d，应当 %d" % [int(cv["daysLeft"]), want])
		return
	if (cv["buy"] as Array).size() != 4 or (cv["sell"] as Array).size() != 4:
		_fail("快照里的收/卖报价不是 4/4")
		return
	print("TRADEPANEL TEST 快照：剩余 %d 天、收 4 卖 4 ✅" % want)

	# 名字 / 来历（用户 2026-10："cv#2-1 是啥"）：
	# 表现层按 id 哈希取，同一个 id 必须永远同一个名字。
	var nm1 := String(panel.caravan_name(String(cv["id"])))
	var or1 := String(panel.caravan_origin(String(cv["id"])))
	if nm1 == "" or or1 == "":
		_fail("游商没有名字或来历（name=%s origin=%s）" % [nm1, or1])
		return
	if nm1 != String(panel.caravan_name(String(cv["id"]))):
		_fail("同一个游商两次取到的名字不一样（不稳定）")
		return
	# 抬头**不许放大**（用户 2026-10："xx 来自 xxxx这个字不要放大"）。
	# 之前这里错用了 `BIG_FS`(24) —— 比表头、价格、正文全都大一圈，看着像个标题。
	# 判据直接问主题解析出来的字号，不看代码里写没写 override（改了字号来源也照样能抓）。
	var head_lb: Label = null
	for lb in body.find_children("*", "Label", true, false):
		if String((lb as Label).text).contains("来自"):
			head_lb = lb
			break
	if head_lb == null:
		_fail("面板上找不到抬头那一句「名字 来自 地方」")
		return
	var fs_head := head_lb.get_theme_font_size("font_size")
	if fs_head != UIKit.FS:
		_fail("游商抬头「%s」的字号是 %d，应当和正文一样是 %d（用户：这个字不要放大）"
			% [String(head_lb.text), fs_head, UIKit.FS])
		return
	print("TRADEPANEL TEST 抬头：「%s 来自 %s」（字号 %d，与正文一致）✅" % [nm1, or1, fs_head])

	# ---- 收购侧的数量列 = 「可出售」= **我们没被预定的货**（用户 2026-10）-----
	#
	# 用户原话："他可收购的列表里面要显示，我们当前未锁定的货物数量，表头叫做 可出售"。
	# 所以这一列回答的是"我还能卖多少"，而不是"他这趟收了多少"（后者挪进按钮 tooltip）。
	# 造一个"有货但一部分被预定"的局面才测得出差别：库存 200、预定 30 → 可出售 170。
	var buy0: Array = cv["buy"] as Array
	if buy0.is_empty():
		_fail("这位游商一条收购报价都没有，测不出「可出售」")
		return
	var gid0 := String((buy0[0] as Dictionary)["good"])
	var good0_name := String(runner.sim.good_name(gid0))
	(sim.s["goods"] as Dictionary)[gid0] = 200.0
	(sim.s["reserved"] as Dictionary)[gid0] = 30.0
	panel._refresh()
	await process_frame
	if body.get_child_count() == 0:
		_fail("刷新之后面板一个块都没有")
		return
	# 结构：body → 游商块(VBox) → [抬头, 两列(HBox), 分隔线]；列(VBox) → [标题, 表头, 行...]
	var cols: Node = body.get_child(0).get_child(1)
	var buy_col: Node = cols.get_child(0)
	var qty_head := String(((buy_col.get_child(1) as Node).get_child(1) as Label).text)
	if qty_head != "可出售":
		_fail("收购侧数量列的表头是「%s」，应当叫「可出售」" % qty_head)
		return
	# 找那件货自己的行（不按下标猜：过滤掉"存不住"的报价之后顺序可能变）
	var shown := ""
	var shown_ok := false
	var row_btn: Button = null
	for i in range(2, buy_col.get_child_count()):
		var r: Node = buy_col.get_child(i)
		var nm_row: Node = r.get_child(0)
		var nm_lb := nm_row.get_child(nm_row.get_child_count() - 1) as Label
		if nm_lb == null or String(nm_lb.text) != good0_name:
			continue
		shown = String((r.get_child(1) as Label).text)
		row_btn = r.get_child(3) as Button
		shown_ok = true
		break
	if not shown_ok:
		_fail("收购侧的表里找不到「%s」这一行" % good0_name)
		return
	if shown != "170":
		_fail("「可出售」显示的是 %s，应当是未锁定库存 170（goods 200 − reserved 30）" % shown)
		return
	# tooltip 里不许再出现"他还能收 x / 20"这种配额说法 —— 唯一的坎是他的现金
	if row_btn == null or not row_btn.tooltip_text.contains("他手里还有"):
		_fail("「出售」按钮的 tooltip 是「%s」，应当说明他手里还有多少钱（配额已经删了）"
			% ("" if row_btn == null else row_btn.tooltip_text))
		return
	if row_btn.tooltip_text.contains("/") or row_btn.tooltip_text.contains("还收"):
		_fail("「出售」按钮的 tooltip 还在提配额：%s" % row_btn.tooltip_text)
		return
	# 旧列「已收购 x/20」不许再出现（"每种 20 件"的配额已按用户要求整体删除）
	for lb in body.find_children("*", "Label", true, false):
		if String((lb as Label).text).contains("已收购"):
			_fail("收购侧还在画旧表头/旧数值：%s" % String((lb as Label).text))
			return
	print("TRADEPANEL TEST 数量列：收购侧表头「可出售」= 未锁定库存 170（200 − 30），旧「已收购」已撤 ✅")

	# ---- 数量对话框（2026-10：1 / 5 两个按钮换成滑块）
	#
	# 收购侧：上限 = min(未锁定库存, 他现金买得起) —— **没有每种配额**
	# （用户 2026-10："游商本来就为了收购这个货物来的，所以是多多益善，阻止他收购这个货物的
	# 唯一就是自己钱不够了"）。
	var offer: Dictionary = (cv["buy"] as Array)[0]
	var gid := String(offer["good"])
	var price := float(offer["price"])
	if offer.has("qty"):
		_fail("他收的报价里还有 qty（每种配额）—— 已经按用户要求删了，别再生成")
		return
	# 开局头几天"预定量 > 库存"是正常的（黎明排产会先占住），所以这里给足货再测，
	# 免得断言被"未锁定 = 0"挡住（那不是 bug，是开局状态）。
	(sim.s["goods"] as Dictionary)[gid] = 200.0
	(sim.s["reserved"] as Dictionary)[gid] = 0.0
	var have := float((sim.s["goods"] as Dictionary).get(gid, 0.0))
	var reserved := float((sim.s["reserved"] as Dictionary).get(gid, 0.0))
	var unlocked := maxi(0, int(floor(have - reserved)))
	var cap_want := mini(unlocked, int(floor(float(cv["cash"]) / maxf(0.01, price))))
	if cap_want <= 0:
		_fail("这个报价一个都卖不了（unlocked=%d cash=%.2f），测不出对话框"
			% [unlocked, float(cv["cash"])])
		return
	panel._open_dialog("buy", String(cv["id"]), offer, "出售")
	await process_frame
	var dlg = panel.get("_dlg")
	if dlg == null or not (dlg as Window).visible:
		_fail("点「出售」没有弹出数量对话框")
		return
	var slider: HSlider = panel.get("_dlg_slider")
	if int(slider.max_value) != cap_want:
		_fail("滑块上限是 %d，应当是 %d（未锁定 / 他的现金 两者取小；没有配额这一项）"
			% [int(slider.max_value), cap_want])
		return
	slider.value = 2
	await process_frame
	var total_txt := String((panel.get("_dlg_total") as Label).text) \
		+ String((panel.get("_dlg_money") as Label).text)
	var want_money := "%.2f" % (price * 2.0)
	if not total_txt.contains(want_money):
		_fail("滑块拖到 2 个时总价显示「%s」，应当包含 %s（实时算钱）" % [total_txt, want_money])
		return
	# 确定 → 真的排一条命令出去（数量 = 滑块那个数）
	var before2: int = (sim.s["pending"] as Array).size()
	panel._confirm_dialog()
	var after2: int = (sim.s["pending"] as Array).size()
	if after2 <= before2:
		_fail("点了「确定出售」没有发命令")
		return
	var last2: Dictionary = (sim.s["pending"] as Array)[after2 - 1]
	if String(last2["type"]) != "sell_to_caravan" or int(last2["qty"]) != 2:
		_fail("发出去的命令是 %s × %s，应当是 sell_to_caravan × 2"
			% [String(last2["type"]), str(last2["qty"])])
		return
	print("TRADEPANEL TEST 数量对话框：上限 %d、拖到 2 个显示共 %s、确定后发命令 ✅"
		% [cap_want, want_money])

	# 购买侧：上限 = min(他的存货, 国库买得起)
	var sell_offer: Dictionary = (cv["sell"] as Array)[0]
	var price2 := float(sell_offer["price"])
	var cap_buy := mini(int(ceil(float(sell_offer["qty"]))),
		int(floor(float(sim.s["government"]["money"]) / maxf(0.01, price2))))
	if cap_buy > 0:
		panel._open_dialog("sell", String(cv["id"]), sell_offer, "购买")
		await process_frame
		var slider2: HSlider = panel.get("_dlg_slider")
		if int(slider2.max_value) != cap_buy:
			_fail("购买滑块上限是 %d，应当是 %d（存货 / 国库 取小）"
				% [int(slider2.max_value), cap_buy])
			return
		(dlg as Window).hide()
		print("TRADEPANEL TEST 购买对话框：上限 %d（存货 / 国库取小）✅" % cap_buy)

	# 关闭
	panel.close_panel()
	await process_frame
	if panel.visible:
		_fail("close_panel() 之后还可见")
		return

	# ---- 入口：建造栏里找得到 + 圆钮不依赖那座建筑 -------------------------
	# 用户 2026-10："市场这个建筑没了，这样游商系统的入口在哪里？"
	# ① 贸易市场必须在建造栏「市政」页（以前埋在「工业」页第 2 页里，等于没有）
	var bar = node.get_node_or_null("UI/Root/BuildBar")
	if bar == null:
		_fail("找不到建造栏（UI/Root/BuildBar）")
		return
	if not (bar._ids_of("市政") as Array).has("trade_market"):
		_fail("贸易市场不在建造栏「市政」页（现在在：%s）" % str(bar._ids_of("市政")))
		return
	for cat in ["民生工业", "重工业"]:
		if (bar._ids_of(cat) as Array).has("trade_market"):
			_fail("贸易市场跑到「%s」页去了（那两页是工坊，市场属于市政）" % cat)
			return
	print("TRADEPANEL TEST 建造栏：「市政」页里有贸易市场 ✅")

	# ② 圆钮：**村里有市场才出现**（用户 2026-10 明确："市场没有造好之前左侧贸易的圆形按钮隐藏"）
	var hud = node.get("_hud")
	if hud == null:
		_fail("找不到 HUD（main 的 _hud）")
		return
	var btn: Button = hud.get("_trade_nav_btn")
	if btn == null:
		_fail("HUD 里没有贸易圆钮（_trade_nav_btn）")
		return
	hud.refresh_nav_buttons()
	if btn.visible:
		_fail("还没有贸易市场，贸易圆钮就已经露出来了")
		return
	# 研究完「通商」也不该露头 —— 判据只看"村里有没有那座市场"
	var done: Array = sim.s["research"]["done"]
	if not done.has("trade"):
		done.append("trade")
	hud.refresh_nav_buttons()
	if btn.visible:
		_fail("只研究了「通商」、还没建市场，贸易圆钮就露出来了（用户要求建好之前隐藏）")
		return
	# 给它一座市场（判据只读 shops 里的 defId，所以直接补一条最小记录）
	(sim.s["shops"] as Array).append({"id": "sh_test_market", "defId": "trade_market"})
	hud.refresh_nav_buttons()
	if not btn.visible:
		_fail("建了贸易市场之后贸易圆钮还是不出现（游商系统就没有入口了）")
		return
	# 图标：用户 2026-10 专门给了 32×32 的通商图（`assets/ui/panel/trade.png`）。
	# 这条防的是"圆钮又变回一个空白木盘"（之前借的科技树图标是 111 字节的近空图）。
	if btn.icon == null:
		_fail("贸易圆钮没有图标（assets/ui/panel/trade.png 没被 stat_icon 取到）")
		return
	print("TRADEPANEL TEST 入口：市场建好之后贸易圆钮才出现（通商科技本身不算）+ 有图标 ✅")

	print("TRADEPANEL TEST RESULT: PASS")
	quit(0)
