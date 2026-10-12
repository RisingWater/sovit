extends PanelContainer

# 统计面板：资源 / 人口 / 财务 三个 Tab。
#
# 取数全部是仿真层的**权威记录**，面板不重算任何公式：
#   GameStats 每过一个游戏日采样，数值取自 DaySnapshot.ledger（当日实际流量）
#   与 resident.account（逐人账目）。
#   只有"工坊数 / 工位 / 工人"是结构性数据，由 shops 现算。

var runner: SimRunner
var world: Node
var stats: GameStats

const TABS := ["资源", "人口", "财务"]

## 表头颜色：必须用深色。UIKit.FG_LABEL 是浅米色，那是给深色 section 条用的，
## 印在米黄面板上完全看不见。
const HEAD_COL := Color(0.52, 0.31, 0.16)

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
const CFG_PATH := "user://hud.cfg"
## 拖动时至少留这么多像素在屏幕内，避免把面板拖没了
const KEEP_VISIBLE := 80.0

var _dragging := false
var _drag_off := Vector2.ZERO
var _dragbar: Control

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	# 用左上角锚点 + position 定位：拖动时直接改 position，比改 offset 直观得多
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 9, 8, 9, 8))

	var vp := get_viewport_rect().size
	var saved := _load_pos()
	if saved == Vector2.INF:
		position = ((vp - Vector2(PANEL_W, PANEL_H)) * 0.5).round()
	else:
		position = _clamp_pos(saved)

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
	# Tab 右边整条都是拖动把手
	_dragbar = Control.new()
	_dragbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dragbar.mouse_filter = Control.MOUSE_FILTER_STOP
	_dragbar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_dragbar.tooltip_text = "按住拖动面板"
	var hint := UIKit.label("拖动此处移动面板", Color(0.66, 0.52, 0.36))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dragbar.add_child(hint)
	_dragbar.gui_input.connect(_on_drag_input)
	head.add_child(_dragbar)
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
	UIKit.play_switch()
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == i else UIKit.T_BTN))
	refresh()

## 面板范围内的鼠标事件一律吃掉。
##
## ScrollContainer 只在自己**真的滚动了**的时候才 accept_event()；滚到顶/底之后
## 它不再接受，事件就会漏到 _unhandled_input，于是滚列表把外面的地图也缩放了。
## 这里兜底：任何落到面板上的鼠标事件都标记为已处理。
## （world_view 那边还有一层"悬停在 UI 上就不碰镜头"的守卫。）
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()

# ---------------------------------------------------------------------------
# 拖动：按在标题栏（Tab 右边那条）上拖，位置存 user://hud.cfg
# ---------------------------------------------------------------------------
func _on_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_off = get_global_mouse_position() - global_position
			# 拖到最前，避免被其它面板挡住
			move_to_front()
		else:
			position = _clamp_pos(position)
			_save_pos()
	elif event is InputEventMouseMotion and _dragging:
		position = _clamp_pos(get_global_mouse_position() - _drag_off)

## 至少留 KEEP_VISIBLE 像素在屏幕内，别拖出去找不回来
func _clamp_pos(p: Vector2) -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(
		clampf(p.x, -(PANEL_W - KEEP_VISIBLE), vp.x - KEEP_VISIBLE),
		clampf(p.y, 0.0, vp.y - KEEP_VISIBLE))

func _load_pos() -> Vector2:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return Vector2.INF
	if not cf.has_section_key("panel", "stats_pos"):
		return Vector2.INF
	var v = cf.get_value("panel", "stats_pos")
	if v is Vector2:
		return v
	return Vector2.INF

func _save_pos() -> void:
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)   # 保留其它段（顶栏资源选择、音乐设置都在同一个文件里）
	cf.set_value("panel", "stats_pos", position)
	cf.save(CFG_PATH)

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
	# 默认选中第一个，打开就有内容可看，不用先点一下
	if _sel_good == "" and not pack.is_empty():
		_sel_good = String(pack[0])

	_section("全局产出")
	_chart("人口 / 就业", [
		{"name": "人口", "color": Color(0.45, 0.72, 0.95), "values": stats.population, "fill": true},
		{"name": "就业", "color": Color(0.55, 0.85, 0.55), "values": stats.employed},
	])
	_note("全部为[实际]：库存读状态；产量、工业消耗、居民购买、工资/税收/租金/消费回款都读当天台账（DaySnapshot.ledger）。"
		+ "工坊数 / 工位 / 工人是结构性数据，由 shops 现算。")

	# 主从布局：左列表 + 右详情。不做一览表 —— 一屏 9 列挤在一起既难读也看不清重点。
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 10)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(split)

	# ---- 左：资源列表
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(296, 0)
	left.add_theme_constant_override("separation", 4)
	split.add_child(left)
	var lhead := UIKit.panel(true)
	var lh := UIKit.label("资源", UIKit.FG_LABEL)
	lh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lhead.add_child(lh)
	left.add_child(lhead)
	var lscroll := ScrollContainer.new()
	lscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lscroll.custom_minimum_size = Vector2(0, 470)
	lscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(lscroll)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.add_theme_constant_override("separation", 2)
	lscroll.add_child(lv)
	for gid in pack:
		var gid2 := String(gid)
		if not runner.db.goods.has(gid2):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		var ic := TextureRect.new()
		ic.texture = load("res://assets/goods/%s.png" % gid2)
		ic.custom_minimum_size = Vector2(16, 16)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		row.add_child(ic)
		var nb := UIKit.button(_good_name(gid2), true)
		nb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		nb.tooltip_text = "点击查看「%s」的详细数据" % _good_name(gid2)
		if gid2 == _sel_good:
			nb.add_theme_stylebox_override("normal", UIKit.box(UIKit.T_BTN_ACTIVE))
			nb.add_theme_color_override("font_color", UIKit.FG_LIGHT)
		nb.pressed.connect(_on_pick_good.bind(gid2))
		row.add_child(nb)
		var st := UIKit.label("%.0f" % float(stats.good_row(gid2)["stock"]), Color(0.62, 0.48, 0.34))
		st.custom_minimum_size = Vector2(40, 0)
		st.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(st)
		var pad := Control.new()          # 给纵向滚动条留位置，否则数字被压住
		pad.custom_minimum_size = Vector2(12, 0)
		row.add_child(pad)
		lv.add_child(row)

	# ---- 右：详情
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)
	_good_detail(right)

## 右侧详情：图标 + 名称 + 大字数据 + 曲线
func _good_detail(right: VBoxContainer) -> void:
	if _sel_good == "":
		var hint := UIKit.label("← 从左边选一个资源", UIKit.FG_HEAD)
		right.add_child(hint)
		return
	var gd: Dictionary = runner.db.goods.get(_sel_good, {})
	var r := stats.good_row(_sel_good)
	var net := float(r["produced"]) - float(r["consumed_ind"]) - float(r["consumed_pop"])

	# 图标 + 名称 + 净额
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var ic := TextureRect.new()
	ic.texture = load("res://assets/goods/%s.png" % _sel_good)
	ic.custom_minimum_size = Vector2(48, 48)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(ic)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	var nm := _big(_good_name(_sel_good))
	col.add_child(nm)
	var sub := UIKit.label(String(gd.get("category", "")), Color(0.62, 0.48, 0.34))
	col.add_child(sub)
	head.add_child(col)
	head.add_child(UIKit.spacer())
	var netcol := VBoxContainer.new()
	netcol.add_theme_constant_override("separation", 0)
	var nl := UIKit.label("净变化 / 日", HEAD_COL)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	netcol.add_child(nl)
	var nv := _big("%+.1f" % net,
		Color(0.18, 0.45, 0.20) if net >= 0.0 else Color(0.65, 0.22, 0.18))
	nv.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	netcol.add_child(nv)
	head.add_child(netcol)
	right.add_child(head)
	right.add_child(UIKit.hsep())

	# 大字数据
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 4)
	right.add_child(g)
	var rows := [
		["库存", "%.0f" % float(r["stock"]), UIKit.FG_DARK],
		["日产量", "%.1f" % float(r["produced"]), Color(0.18, 0.42, 0.24)],
		["工业消耗 / 日", "%.1f" % float(r["consumed_ind"]), Color(0.55, 0.30, 0.18)],
		["居民消耗 / 日", "%.1f" % float(r["consumed_pop"]), Color(0.55, 0.30, 0.18)],
		["工坊数", "%d" % int(r["shops"]), UIKit.FG_DARK],
		["工位总数", "%d" % int(r["slots"]), UIKit.FG_DARK],
		["在岗工人", "%d" % int(r["workers"]), UIKit.FG_DARK],
	]
	for row in rows:
		var kl := UIKit.label(String(row[0]), HEAD_COL)
		kl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		g.add_child(kl)
		var vl := _big(String(row[1]), row[2])
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(vl)

	# 曲线
	var cv := Chart.new()
	cv.custom_minimum_size = Vector2(0, 110)
	cv.set_data("库存", [{"name": "库存", "color": Color(0.85, 0.72, 0.35),
		"values": stats.series(stats.stock, _sel_good), "fill": true}], false, "%.0f")
	right.add_child(cv)
	var cp := Chart.new()
	cp.custom_minimum_size = Vector2(0, 110)
	cp.set_data("日产 / 工业耗", [
		{"name": "日产", "color": Color(0.40, 0.75, 0.45),
			"values": stats.series(stats.produced, _sel_good), "fill": true},
		{"name": "工业耗", "color": Color(0.85, 0.45, 0.35),
			"values": stats.series(stats.consumed_ind, _sel_good)},
	], false, "%.1f")
	right.add_child(cp)

## 大字（12px 像素字体的整数 2 倍）
func _big(t: String, col: Color = UIKit.FG_DARK) -> Label:
	var l := UIKit.label(t, col)
	l.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	return l

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
		_cell(g, h, HEAD_COL, 90.0)
	_cell(g, "人口", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % (s["residents"] as Array).size(), UIKit.FG_DARK, 60.0, true)
	_cell(g, "就业", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % employed, UIKit.FG_DARK, 60.0, true)
	_cell(g, "岗位总量", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % total_slots, UIKit.FG_DARK, 60.0, true)
	_cell(g, "用工目标", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % total_workers, UIKit.FG_DARK, 60.0, true)

	_section("居民（点名字看详情）")
	var gg := _grid(6)
	for h in ["姓名", "阶层", "住房", "工作", "熟练", "满意"]:
		_cell(gg, h, HEAD_COL, 70.0)
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
	_note("个人饥饿与个人每日消耗已逐人记录（resident.account）。目前按阶层平均分配，所以同阶层人人相同；结构已分开，将来可做差异化。")

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
	# 以下全部读仿真层记录的**个人账目**（resident.account），不是面板重算的
	var acc: Dictionary = r.get("account", {})
	if acc.is_empty():
		_note("该居民尚无账目（账目在每个游戏日夜间结算时写入）。")
		return
	var is_hungry := bool(acc.get("hungry", false))
	_cell(g, "今日饥饿", UIKit.FG_HEAD, 90.0)
	_cell(g, "是" if is_hungry else "否",
		Color(0.72, 0.22, 0.18) if is_hungry else Color(0.18, 0.45, 0.20), 70.0)
	_cell(g, "食物满足", UIKit.FG_HEAD, 90.0)
	_cell(g, "%.0f%%" % (float(acc.get("foodScore", 1.0)) * 100.0),
		Color(0.72, 0.22, 0.18) if is_hungry else UIKit.FG_DARK, 70.0)
	_cell(g, "舒适满足", UIKit.FG_HEAD, 90.0)
	_cell(g, "%.0f%%" % (float(acc.get("comfortScore", 1.0)) * 100.0), UIKit.FG_DARK, 70.0)
	_cell(g, "价格满意", UIKit.FG_HEAD, 90.0)
	_cell(g, "%.0f%%" % (float(acc.get("priceScore", 1.0)) * 100.0), UIKit.FG_DARK, 70.0)
	_cell(g, "今日工资", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % float(acc.get("wage", 0.0)), UIKit.FG_DARK, 70.0)
	_cell(g, "今日所得税", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % float(acc.get("tax", 0.0)), UIKit.FG_DARK, 70.0)
	_cell(g, "今日租金", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % float(acc.get("rent", 0.0)), UIKit.FG_DARK, 70.0)
	_cell(g, "今日消费", UIKit.FG_HEAD, 90.0); _cell(g, "¥%.2f" % float(acc.get("spent", 0.0)), UIKit.FG_DARK, 70.0)
	var net := float(acc.get("wage", 0.0)) - float(acc.get("tax", 0.0)) - float(acc.get("rent", 0.0)) - float(acc.get("spent", 0.0))
	_cell(g, "今日净额", UIKit.FG_HEAD, 90.0)
	_cell(g, "¥%+.2f" % net,
		Color(0.18, 0.45, 0.20) if net >= 0.0 else Color(0.65, 0.22, 0.18), 70.0)

	# 逐人每日消耗（bought）：目前按阶层均分，所以同阶层人人相同
	var bought: Dictionary = acc.get("bought", {})
	_body.add_child(UIKit.hsep())
	_body.add_child(UIKit.label("今日消耗（逐人记录）", UIKit.FG_HEAD))
	if bought.is_empty():
		_note("今日未购买任何商品。")
	else:
		var gb := _grid(6)
		for hh in ["商品", "数量", "商品", "数量", "商品", "数量"]:
			_cell(gb, hh, HEAD_COL, 76.0)
		var keys: Array = bought.keys()
		keys.sort()
		var i := 0
		while i < keys.size():
			for c in 3:
				if i < keys.size():
					var gid := String(keys[i])
					_cell(gb, _good_name(gid), UIKit.FG_HEAD, 76.0)
					_cell(gb, "%.2f" % float(bought[gid]), UIKit.FG_DARK, 60.0, true)
				else:
					_cell(gb, "", UIKit.FG_DARK, 76.0)
					_cell(gb, "", UIKit.FG_DARK, 60.0)
				i += 1

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
		_cell(g2, h, HEAD_COL, 80.0)
	var items := [
		["工资支出", stats.avg(stats.wages), "公式", "∑ 居民 gross（工资×技能系数，封顶）"],
		["所得税", stats.avg(stats.tax), "公式", "累进税表套在 gross 上"],
		["租金收入", stats.avg(stats.rent), "公式", "国有租户实缴 + 私租抽税"],
		["消费收入", stats.avg(stats.sales), "实际", "居民购买回款（读台账）"],
		["建造支出", stats.avg(stats.build_cost), "实际", "在建项目的建造成本合计"],
	]
	for it in items:
		_cell(g2, String(it[0]), UIKit.FG_HEAD, 80.0)
		_cell(g2, "¥%.1f" % float(it[1]), UIKit.FG_DARK, 80.0, true)
		_cell(g2, String(it[2]), Color(0.55, 0.42, 0.30), 60.0)
		_cell(g2, String(it[3]), Color(0.55, 0.42, 0.30), 0.0)
	_note("全部为[实际]：工资/税收/租金/消费回款都读当天台账（DaySnapshot.ledger），不再由面板重算公式。")

	_section("税收结构")
	var g3 := _grid(3)
	for h in ["档位", "上限", "税率"]:
		_cell(g3, h, HEAD_COL, 90.0)
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
			_cell(g4, h, HEAD_COL, 70.0)
		var n := stats.days.size()
		for k in range(maxi(0, n - 12), n):
			_cell(g4, "D%d" % stats.days[k], UIKit.FG_HEAD, 70.0)
			_cell(g4, "%.0f" % stats.money[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%+.0f" % stats.money_flow[k],
				Color(0.18, 0.45, 0.20) if stats.money_flow[k] >= 0.0 else Color(0.65, 0.22, 0.18), 70.0, true)
			_cell(g4, "%.0f" % stats.wages[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%.0f" % stats.tax[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%.0f" % stats.rent[k], UIKit.FG_DARK, 70.0, true)
