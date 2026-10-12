extends PanelContainer

# 统计面板：资源 / 人口 / 财务 三个 Tab。
# 数据全部来自 GameStats（表现层统计），不改仿真层。
#
# 口径标注约定：
#   [实际] 直接读仿真状态
#   [计划] 工坊当日 planned × 配方
#   [公式] 用与仿真层相同的公式从可见状态重算
#   [估算] 受库存约束的推算

var runner: SimRunner
var world: Node
var stats: GameStats

const TABS := ["资源", "人口", "财务"]

var _tab := 0
var _tab_btns: Array[Button] = []
var _body: VBoxContainer
var _sel_good := ""
var _sel_resident := ""

func setup(r: SimRunner, w: Node, st: GameStats) -> void:
	runner = r
	world = w
	stats = st

const PANEL_W := 1100.0
const PANEL_H := 680.0

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	# 居中要显式设锚点与偏移：_ready() 里 get_combined_minimum_size() 还是 0，
	# 用 PRESET_CENTER + PRESET_MODE_MINSIZE 会得到零偏移，面板跑到屏幕右下角外面。
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -PANEL_W * 0.5
	offset_top = -PANEL_H * 0.5
	offset_right = PANEL_W * 0.5
	offset_bottom = PANEL_H * 0.5
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 9, 8, 9, 8))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 5)
	add_child(root)

	# 标题行
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	root.add_child(head)
	head.add_child(UIKit.label("统计", UIKit.FG_HEAD))
	for i in TABS.size():
		var b := UIKit.button(TABS[i], true)
		b.pressed.connect(_select_tab.bind(i))
		head.add_child(b)
		_tab_btns.append(b)
	head.add_child(UIKit.spacer())
	var close := UIKit.button("关闭", true)
	close.pressed.connect(func(): visible = false)
	head.add_child(close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	scroll.add_child(_body)

	visible = false
	_select_tab(0)

func open() -> void:
	visible = true
	refresh()

func _select_tab(i: int) -> void:
	_tab = i
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == i else UIKit.T_BTN))
	refresh()

func refresh() -> void:
	if _body == null or runner == null or runner.sim == null or stats == null:
		return
	for c in _body.get_children():
		c.queue_free()
	match _tab:
		0: _resources_tab()
		1: _people_tab()
		_: _finance_tab()

# ---------------------------------------------------------------------------
# 通用小件
# ---------------------------------------------------------------------------
func _section(t: String) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(t, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	_body.add_child(p)

func _note(t: String) -> void:
	var l := UIKit.label(t, Color(0.55, 0.42, 0.30))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(l)

func _chart(title: String, s: Array, zero := false, fmt := "%.0f", h := 84) -> void:
	var c := Chart.new()
	c.custom_minimum_size = Vector2(0, h)
	c.set_data(title, s, zero, fmt)
	_body.add_child(c)

func _grid(cols: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 1)
	_body.add_child(g)
	return g

func _cell(g: GridContainer, text: String, color: Color, min_w := 0.0, right := false) -> Label:
	var l := UIKit.label(text, color)
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, 0)
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	g.add_child(l)
	return l

func _good_name(gid: String) -> String:
	return String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid

# ---------------------------------------------------------------------------
# 资源
# ---------------------------------------------------------------------------
func _resources_tab() -> void:
	var s: Dictionary = runner.sim.s
	var pack: Array = runner.db.packs[String(s["pack"])]["goods"]

	_section("全局产出")
	_chart("人口 / 就业", [
		{"name": "人口", "color": Color(0.45, 0.72, 0.95), "values": stats.population, "fill": true},
		{"name": "就业", "color": Color(0.55, 0.85, 0.55), "values": stats.employed},
	])
	_note("产量与工业消耗为[计划]：工坊当日 planned 批次数 × 配方（planned 由黎明按在岗人数排出）。"
		+ "民用消耗为[公式]：阶层 needs.perCapita × 该阶层人数。库存为[实际]。")

	_section("商品明细")
	# 每列都给固定宽度，否则右对齐的数字会各占各的宽度、整表错位
	var widths := [92.0, 54.0, 54.0, 58.0, 58.0, 58.0, 44.0, 44.0, 44.0]
	var heads := ["商品", "库存", "日产", "工业耗", "民用耗", "净", "工坊", "工位", "工人"]
	var g := _grid(9)
	for i in heads.size():
		_cell(g, heads[i], UIKit.FG_LABEL, widths[i], i > 0)
	for gid in pack:
		var gid2 := String(gid)
		if not runner.db.goods.has(gid2):
			continue
		var r := stats.good_row(gid2)
		var net := float(r["produced"]) - float(r["consumed_ind"]) - float(r["consumed_pop"])
		var net_col := Color(0.18, 0.45, 0.20) if net >= 0.0 else Color(0.65, 0.22, 0.18)
		var is_sel := gid2 == _sel_good
		_cell(g, _good_name(gid2), Color(0.72, 0.35, 0.15) if is_sel else UIKit.FG_HEAD, widths[0])
		_cell(g, "%.0f" % float(r["stock"]), UIKit.FG_DARK, widths[1], true)
		_cell(g, "%.1f" % float(r["produced"]), Color(0.18, 0.42, 0.24), widths[2], true)
		_cell(g, "%.1f" % float(r["consumed_ind"]), Color(0.55, 0.30, 0.18), widths[3], true)
		_cell(g, "%.1f" % float(r["consumed_pop"]), Color(0.55, 0.30, 0.18), widths[4], true)
		_cell(g, "%+.1f" % net, net_col, widths[5], true)
		_cell(g, "%d" % int(r["shops"]), UIKit.FG_DARK, widths[6], true)
		_cell(g, "%d" % int(r["slots"]), UIKit.FG_DARK, widths[7], true)
		_cell(g, "%d" % int(r["workers"]), UIKit.FG_DARK, widths[8], true)

	# 单击选择商品（用按钮行覆盖在上面太重，这里给一个下拉）
	_body.add_child(UIKit.hsep())
	var pick := HBoxContainer.new()
	pick.add_theme_constant_override("separation", 4)
	pick.add_child(UIKit.label("查看曲线：", UIKit.FG_HEAD))
	for gid in pack:
		var gid2 := String(gid)
		if not runner.db.goods.has(gid2):
			continue
		var b := UIKit.button(_good_name(gid2), true)
		b.pressed.connect(_on_pick_good.bind(gid2))
		pick.add_child(b)
	_body.add_child(pick)

	if _sel_good != "":
		_section("%s 曲线" % _good_name(_sel_good))
		_chart("库存", [{"name": "库存", "color": Color(0.85, 0.72, 0.35),
			"values": stats.series(stats.stock, _sel_good), "fill": true}])
		_chart("日产 / 工业耗", [
			{"name": "日产", "color": Color(0.40, 0.75, 0.45),
				"values": stats.series(stats.produced, _sel_good), "fill": true},
			{"name": "工业耗", "color": Color(0.85, 0.45, 0.35),
				"values": stats.series(stats.consumed_ind, _sel_good)},
		], false, "%.1f")

func _on_pick_good(gid: String) -> void:
	_sel_good = gid
	refresh()

# ---------------------------------------------------------------------------
# 人口
# ---------------------------------------------------------------------------
func _people_tab() -> void:
	var s: Dictionary = runner.sim.s
	_section("人口 / 就业 / 饥饿")
	_chart("人口", [{"name": "人口", "color": Color(0.45, 0.72, 0.95),
		"values": stats.population, "fill": true}])
	_chart("满意度 / 饥饿", [
		{"name": "满意", "color": Color(0.40, 0.75, 0.45), "values": stats.satisfaction},
		{"name": "饥饿", "color": Color(0.85, 0.45, 0.35), "values": stats.hungry},
	], false, "%.1f")

	_section("就业与岗位")
	var employed := 0
	var total_slots := 0
	var total_workers := 0
	for shop in s["shops"]:
		var did := String(shop["defId"])
		if runner.db.buildings.has(did):
			total_slots += int(runner.db.buildings[did]["maxWorkers"])
			total_workers += int(shop["targetWorkers"])
	for r in s["residents"]:
		if bool(r["employed"]):
			employed += 1
	var g := _grid(4)
	for h in ["口径", "数值", "口径", "数值"]:
		_cell(g, h, UIKit.FG_LABEL, 90.0)
	_cell(g, "人口", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % (s["residents"] as Array).size(), UIKit.FG_DARK, 60.0, true)
	_cell(g, "就业", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % employed, UIKit.FG_DARK, 60.0, true)
	_cell(g, "岗位总量", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % total_slots, UIKit.FG_DARK, 60.0, true)
	_cell(g, "用工目标", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % total_workers, UIKit.FG_DARK, 60.0, true)

	_section("居民（点名字看详情）")
	var gg := _grid(6)
	for h in ["姓名", "阶层", "住房", "工作", "熟练", "满意"]:
		_cell(gg, h, UIKit.FG_LABEL, 70.0)
	var shops_by_id := {}
	for shop in s["shops"]:
		shops_by_id[String(shop["id"])] = shop
	var rows := 0
	for r in s["residents"]:
		rows += 1
		if rows > 60:
			break
		var rid := String(r["id"])
		var job := "无业"
		var js = r.get("jobShopId", null)
		if js != null and shops_by_id.has(String(js)):
			job = String(runner.db.buildings.get(String(shops_by_id[String(js)]["defId"]), {}).get("nameZh", "?"))
		var tenure := "国有"
		if bool(r.get("homeowner", false)):
			tenure = "自有"
		elif bool(r.get("privateTenant", false)):
			tenure = "私租"
		var b := UIKit.button(Names.for_id(rid), true)
		b.pressed.connect(_on_pick_resident.bind(rid))
		gg.add_child(b)
		_cell(gg, String(r["classId"]), UIKit.FG_DARK, 70.0)
		_cell(gg, "%s·Lv%d" % [tenure, int(r.get("housingQuality", 0))], UIKit.FG_DARK, 70.0)
		_cell(gg, job, UIKit.FG_DARK, 70.0)
		_cell(gg, "%.0f" % float(r["skill"]), UIKit.FG_DARK, 0.0, true)
		_cell(gg, "%.0f" % float(r["satisfaction"]), UIKit.FG_DARK, 0.0, true)
	if rows >= 60:
		_note("（只列出前 60 位）")
	_note("个人饥饿、个人每日消耗在仿真层没有逐人记录 —— 饥饿只有全城计数，消耗只按阶层汇总。")

	if _sel_resident != "":
		_body.add_child(UIKit.hsep())
		_resident_detail(_sel_resident, s)

func _on_pick_resident(rid: String) -> void:
	_sel_resident = rid
	refresh()

func _resident_detail(rid: String, s: Dictionary) -> void:
	var r = null
	for x in s["residents"]:
		if String(x["id"]) == rid:
			r = x
			break
	if r == null:
		return
	_section("居民 %s" % Names.for_id(rid))
	var job := "无业"
	var js = r.get("jobShopId", null)
	if js != null:
		for shop in s["shops"]:
			if String(shop["id"]) == String(js):
				job = String(runner.db.buildings.get(String(shop["defId"]), {}).get("nameZh", "?"))
				break
	var tenure := "国有租住"
	if bool(r.get("homeowner", false)):
		tenure = "自有住房"
	elif bool(r.get("privateTenant", false)):
		tenure = "私租"
	var g := _grid(4)
	_cell(g, "阶层", UIKit.FG_HEAD, 90.0); _cell(g, String(r["classId"]), UIKit.FG_DARK, 70.0)
	_cell(g, "熟练度", UIKit.FG_HEAD, 90.0); _cell(g, "%.1f" % float(r["skill"]), UIKit.FG_DARK, 70.0)
	_cell(g, "满意度", UIKit.FG_HEAD, 90.0); _cell(g, "%.1f" % float(r["satisfaction"]), UIKit.FG_DARK, 70.0)
	_cell(g, "存款", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.1f" % float(r["savings"]), UIKit.FG_DARK, 70.0)
	_cell(g, "住房", UIKit.FG_HEAD, 90.0); _cell(g, "%s Lv%d" % [tenure, int(r.get("housingQuality", 0))], UIKit.FG_DARK, 70.0)
	_cell(g, "工作", UIKit.FG_HEAD, 90.0); _cell(g, job, UIKit.FG_DARK, 70.0)
	# 日收支（用与仿真一致的工资公式）
	var eco: Dictionary = runner.db.economy
	var brackets: Array = s["government"]["taxBrackets"]
	var gross := 0.0
	if js != null:
		for shop in s["shops"]:
			if String(shop["id"]) == String(js):
				gross = float(shop["wage"]) * (float(eco["skillIncomeBase"]) + minf(float(eco["skillMax"]), float(r["skill"])) / 100.0)
				var cap := float(shop["wageCap"])
				if cap > 0.0:
					gross = minf(gross, cap)
				break
	else:
		gross = snappedf(float(eco["refWage"]) * float(eco["welfareRate"]), 0.01)
	var tax := stats.progressive_tax(gross, brackets)
	var rent := 0.0
	if not bool(r.get("homeowner", false)):
		rent = minf(float(s["government"]["rent"]), maxf(0.0, float(r["savings"]) + gross))
	_cell(g, "日工资", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % gross, UIKit.FG_DARK, 70.0)
	_cell(g, "日所得税", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % tax, UIKit.FG_DARK, 70.0)
	_cell(g, "日租金", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % rent, UIKit.FG_DARK, 70.0)
	_cell(g, "日净收入", UIKit.FG_HEAD, 90.0)
	_cell(g, "¥%+.2f" % (gross - tax - rent),
		Color(0.18, 0.45, 0.20) if gross - tax - rent >= 0.0 else Color(0.65, 0.22, 0.18), 70.0)

# ---------------------------------------------------------------------------
# 财务
# ---------------------------------------------------------------------------
func _finance_tab() -> void:
	var s: Dictionary = runner.sim.s
	_section("国库")
	var g := _grid(4)
	_cell(g, "当前余额", UIKit.FG_HEAD, 90.0)
	_cell(g, "¥%.0f" % float(s["government"]["money"]), UIKit.FG_DARK, 90.0, true)
	_cell(g, "7 日均净收支", UIKit.FG_HEAD, 90.0)
	var net7 := stats.avg(stats.money_flow, 7)
	_cell(g, "¥%+.0f / 日" % net7,
		Color(0.18, 0.45, 0.20) if net7 >= 0.0 else Color(0.65, 0.22, 0.18), 90.0, true)
	_chart("国库余额", [{"name": "国库", "color": Color(0.90, 0.78, 0.40),
		"values": stats.money, "fill": true}])
	_chart("日净收支", [{"name": "净额", "color": Color(0.55, 0.80, 0.95),
		"values": stats.money_flow}], true)

	_section("收支分项（7 日均值）")
	var g2 := _grid(4)
	for h in ["项目", "7 日均", "口径", "说明"]:
		_cell(g2, h, UIKit.FG_LABEL, 80.0)
	var items := [
		["工资支出", stats.avg(stats.wages), "公式", "∑ 居民 gross（工资×技能系数，封顶）"],
		["所得税", stats.avg(stats.tax), "公式", "累进税表套在 gross 上"],
		["租金收入", stats.avg(stats.rent), "公式", "国有租户实缴 + 私租抽税"],
		["消费收入", stats.avg(stats.sales), "估算", "阶层需求 × 售价，受库存上限约束"],
		["建造支出", stats.avg(stats.build_cost), "实际", "在建项目的建造成本合计"],
	]
	for it in items:
		_cell(g2, String(it[0]), UIKit.FG_HEAD, 80.0)
		_cell(g2, "¥%.1f" % float(it[1]), UIKit.FG_DARK, 80.0, true)
		_cell(g2, String(it[2]), Color(0.55, 0.42, 0.30), 60.0)
		_cell(g2, String(it[3]), Color(0.55, 0.42, 0.30), 0.0)
	_note("工资 / 税收 / 租金用与仿真层相同的公式从可见状态重算；"
		+ "消费收入受库存与购买顺序影响，只能估算；国库余额与日净收支为[实际]。")

	_section("税收结构")
	var g3 := _grid(3)
	for h in ["档位", "上限", "税率"]:
		_cell(g3, h, UIKit.FG_LABEL, 90.0)
	var i := 0
	for b in (s["government"]["taxBrackets"] as Array):
		i += 1
		_cell(g3, "第 %d 档" % i, UIKit.FG_HEAD, 90.0)
		_cell(g3, "不限" if b["upTo"] == null else "¥%.0f" % float(b["upTo"]), UIKit.FG_DARK, 90.0, true)
		_cell(g3, "%.0f%%" % (float(b["rate"]) * 100.0), UIKit.FG_DARK, 90.0)
	_cell(g3, "国有住房租金", UIKit.FG_HEAD, 90.0)
	_cell(g3, "¥%.1f / 人/日" % float(s["government"]["rent"]), UIKit.FG_DARK, 90.0, true)
	_cell(g3, "", UIKit.FG_DARK, 90.0)

	if stats.has_data():
		_section("最近 12 天")
		var g4 := _grid(6)
		for h in ["天", "国库", "净额", "工资", "税收", "租金"]:
			_cell(g4, h, UIKit.FG_LABEL, 70.0)
		var n := stats.days.size()
		for k in range(maxi(0, n - 12), n):
			_cell(g4, "D%d" % stats.days[k], UIKit.FG_HEAD, 70.0)
			_cell(g4, "%.0f" % stats.money[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%+.0f" % stats.money_flow[k],
				Color(0.18, 0.45, 0.20) if stats.money_flow[k] >= 0.0 else Color(0.65, 0.22, 0.18), 70.0, true)
			_cell(g4, "%.0f" % stats.wages[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%.0f" % stats.tax[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%.0f" % stats.rent[k], UIKit.FG_DARK, 70.0, true)
