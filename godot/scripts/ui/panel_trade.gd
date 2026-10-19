extends PanelContainer

# 贸易市场（M4，2026-10）
#
# 用户 2026-10 的原话："这就是你的游商界面？……贸易界面应该是也是全屏面板的，游商只是一个
# tab，薇拉立绘在右下角。" —— 所以这里从"深色浮动小窗"改成了和「统计 / 科技 / 任务」同一套
# **全屏米黄面板**：
#
#   ┌ 标题行：通商图标 + 「贸易市场」 + （空） + 关闭 ───────────────────────┐
#   │ 页签：游商 / 商路（商路是下一版的系统，先摆一句占位）                 │
#   │ 正文：游商卡片（他收购 / 他出售）· 可滚动                             │
#   │                                                  薇拉立绘（右下角）  │
#   └──────────────────────────────────────────────────────────────────────┘
#
# 数据来自 `SimCore.trade_snapshot()`（引擎算好的只读快照），面板只负责画 + 发命令：
#   · 他收购（玩家卖给他）→ `{"type": "sell_to_caravan", ...}`
#   · 他出售（玩家买）    → `{"type": "buy_from_caravan", ...}`
#
# ⚠️ 命令走 `runner.enqueue()`（次日黎明生效），与建造/调序同一套口径 —— 这一点写在副标题里，
#    否则玩家会以为点了没反应。

var runner: SimRunner
var world: Node

var _title_lb: Label
var _sub: Label
var _body: VBoxContainer
var _scroll: ScrollContainer
var _portrait: PanelPortrait

## 页签：0 = 游商（M4 已做），1 = 商路（B3 的系统，只有占位）
const TAB_NAMES := ["游商", "商路"]
var _tab := 0
var _tab_btns: Array[Button] = []
var _page_box: VBoxContainer
var _road_box: VBoxContainer

const C_HINT := Color(0.42, 0.32, 0.22)

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	# **全屏**（anchors 0..1），和统计 / 科技 / 任务同一个口径：不拖动、不跟内容改高度，
	# 顶栏留着（它们都从 BAR_H 往下铺）。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_right = 0.0
	offset_top = float(UIKit.BAR_H)
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 16, 12, 16, 12))
	visible = false

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# ---- 标题行
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	var ico := UIKit.tech_icon("trade")
	if ico == null:
		ico = UIKit.panel_icon("resource")
	if ico != null:
		var tr := TextureRect.new()
		tr.texture = ico
		tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tr)
	_title_lb = UIKit.label("贸易市场", UIKit.FG_HEAD)
	_title_lb.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(_title_lb)
	head.add_child(UIKit.spacer())
	_sub = UIKit.label("")
	_sub.add_theme_color_override("font_color", C_HINT)
	head.add_child(_sub)
	head.add_child(UIKit.spacer())
	var close := UIKit.button("关闭", true)
	close.tooltip_text = "回到地图（Esc 也行）"
	close.pressed.connect(close_panel)
	head.add_child(close)

	root.add_child(UIKit.hsep())

	# ---- 页签
	var tabrow := HBoxContainer.new()
	tabrow.name = "TabRow"
	tabrow.add_theme_constant_override("separation", 5)
	root.add_child(tabrow)
	for i in TAB_NAMES.size():
		var b := UIKit.button(String(TAB_NAMES[i]), true)
		b.pressed.connect(_select_tab.bind(i))
		tabrow.add_child(b)
		_tab_btns.append(b)
	tabrow.add_child(UIKit.spacer())
	root.add_child(UIKit.hsep())

	# ---- 「游商」页：可滚动
	_page_box = VBoxContainer.new()
	_page_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_page_box)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page_box.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	_scroll.add_child(_body)

	# ---- 「商路」页：占位（B3 的系统，见 docs/todo.md §1.10）
	_road_box = VBoxContainer.new()
	_road_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_road_box.add_theme_constant_override("separation", 6)
	_road_box.visible = false
	root.add_child(_road_box)
	_road_box.add_child(UIKit.label("商路：还没开通", UIKit.FG_HEAD))
	_road_box.add_child(UIKit.label(
		"常驻商路要等「米拉」带来的那套系统（车队、关税、跨城价）。现在能做生意的地方是"
		+ "「游商」这一页 —— 他们每周来一批、停七天，带的货和手里的钱都有限。"))
	_road_box.add_child(UIKit.label("（建造栏 → 市政 → 贸易市场 建好之后，这个面板才能打开。）"))

	# ---- 右下角顾问立绘：薇拉（兼管贸易，见 docs/town.md）
	_portrait = PanelPortrait.new()
	_portrait.name = "Portrait"
	add_child(_portrait)
	_portrait.setup("vera", runner.sim if runner != null else null)

	visibility_changed.connect(_on_visibility_changed)
	if runner != null and runner.has_signal("hour_ticked"):
		runner.hour_ticked.connect(_on_hour)
	_select_tab(0)


# ---------------------------------------------------------------------------
# 打开 / 关闭
# ---------------------------------------------------------------------------
func close_panel() -> void:
	visible = false

func open_trade() -> void:
	visible = true
	move_to_front()
	_last_hour = int(runner.sim.s["hour"]) if runner != null and runner.sim != null else -1
	_select_tab(_tab)
	_refresh()
	if _portrait != null:
		_portrait.speak()

## 打开时把地图那一侧的常驻件（小地图 + 左侧圆钮）藏起来 —— 和统计 / 科技同一套。
func _on_visibility_changed() -> void:
	UIKit.show_map_chrome(self, not UIKit.any_panel_open(self, visible))

func _on_hour() -> void:
	if not visible:
		return
	var h := int(runner.sim.s["hour"])
	# 面板一直开着也只在**整点**刷一次，别每小时刷好几遍
	if h == _last_hour:
		return
	_last_hour = h
	_refresh()

var _last_hour := -1


# ---------------------------------------------------------------------------
# 页签
# ---------------------------------------------------------------------------
func _select_tab(i: int) -> void:
	_tab = clampi(i, 0, TAB_NAMES.size() - 1)
	UIKit.play_switch()
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == _tab else UIKit.T_BTN))
	if _page_box != null:
		_page_box.visible = _tab == 0
	if _road_box != null:
		_road_box.visible = _tab == 1
	if _sub != null:
		_sub.text = ("买卖次日 06:00 生效；他带的货有限，钱也有限" if _tab == 0
			else "常驻商路还没做（下一版）")


# ---------------------------------------------------------------------------
# 正文
# ---------------------------------------------------------------------------
func _clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()

func _refresh() -> void:
	if not visible or runner == null or runner.sim == null:
		return
	_clear(_body)
	var snap: Dictionary = runner.sim.trade_snapshot()
	var caravans: Array = snap.get("caravans", [])
	if caravans.is_empty():
		var left := int(snap.get("daysToNext", 0))
		var hint := "还没有游商。"
		if int(snap.get("waveSize", 0)) == 0:
			hint = "完成第 3 章之后，游商会开始上门（每周一批、停留 7 天）。"
		elif left > 0:
			hint = "下一位游商还有 %d 天到达。" % left
		_body.add_child(UIKit.label(hint))
	else:
		for cv in caravans:
			_body.add_child(_caravan_block(cv))

	_body.add_child(_sep())
	_body.add_child(UIKit.label("国库 ¥%.2f" % float(snap.get("money", 0.0)), UIKit.FG_HEAD))

func _sep() -> Control:
	var s := ColorRect.new()
	s.color = Color(0.62, 0.54, 0.40)
	s.custom_minimum_size = Vector2(0, 1)
	return s

func _caravan_block(cv: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var head := UIKit.label(
		"%s · 还能待 %d 天 · 他手里还有 ¥%.0f 可以收你的货"
		% [String(cv.get("id", "")), int(cv.get("daysLeft", 0)), float(cv.get("cash", 0.0))],
		14,
	)
	head.add_theme_color_override("font_color", UIKit.FG_HEAD)
	box.add_child(head)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(cols)

	cols.add_child(_offer_column(cv, "buy", "他可收购（你卖给他）"))
	cols.add_child(_offer_column(cv, "sell", "他可出售（你买）"))
	box.add_child(_sep())
	return box

func _offer_column(cv: Dictionary, key: String, title: String) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 2)
	var tl := UIKit.label(title, UIKit.FG_HEAD)
	tl.add_theme_color_override("font_color", UIKit.FG_HEAD)
	col.add_child(tl)
	var offers: Array = cv.get(key, [])
	if offers.is_empty():
		col.add_child(UIKit.label("（这次没有）", UIKit.FG_DIM))
		return col
	for o in offers:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var gid := String(o.get("good", ""))
		var name: String = runner.sim.good_name(gid)
		var line: String = "%s ×%.0f @%.2f" % [name, float(o.get("qty", 0.0)), float(o.get("price", 0.0))]
		var lb := UIKit.label(line)
		lb.custom_minimum_size = Vector2(200, 0)
		row.add_child(lb)
		var action := "sell_to_caravan" if key == "buy" else "buy_from_caravan"
		for q in [1, 5]:
			var b := UIKit.button(str(q), true)
			b.custom_minimum_size = Vector2(34, 0)
			b.pressed.connect(_send.bind(action, String(cv.get("id", "")), gid, q))
			row.add_child(b)
		col.add_child(row)
	return col

func _send(action: String, caravan_id: String, good_id: String, qty: int) -> void:
	runner.enqueue([{"type": action, "caravanId": caravan_id, "goodId": good_id, "qty": qty}])
	_refresh()

## 面板范围内的鼠标事件一律吃掉（全屏面板，别让点击穿到地图上）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()
