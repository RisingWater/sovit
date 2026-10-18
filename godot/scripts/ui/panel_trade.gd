extends PanelContainer

# 贸易市场 · 游商（M4，2026-10）
#
# 只做「游商」这一页（「商路」是以后的系统，这里放一句占位）。
# 数据来自 `SimCore.trade_snapshot()`（引擎算好的只读快照），面板只负责画 + 发命令：
#   · 他收购（玩家卖给他）→ `{"type": "sell_to_caravan", ...}`
#   · 他出售（玩家买）    → `{"type": "buy_from_caravan", ...}`
#
# ⚠️ 命令走 `runner.enqueue()`（次日黎明生效），与建造/调序同一套口径 —— 这一点在副标题里写明，
#    否则玩家会以为点了没反应。

const W := 560.0
const H := 520.0

var runner
var _title_lb: Label
var _sub: Label
var _body: VBoxContainer
var _scroll: ScrollContainer
var _drag_from := Vector2.ZERO
var _dragging := false

func setup(r: SimRunner, _w: Node) -> void:
	runner = r

func _ready() -> void:
	visible = false
	size = Vector2(W, H)
	position = Vector2(360, 120)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.10, 0.09, 0.97)
	style.border_color = Color(0.45, 0.38, 0.28)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	root.add_child(head)
	_title_lb = UIKit.label("贸易市场 · 游商", 24)
	head.add_child(_title_lb)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var close := UIKit.button("关闭", true)
	close.pressed.connect(close_panel)
	head.add_child(close)

	_sub = UIKit.label("", 12)
	root.add_child(_sub)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	_scroll.add_child(_body)

	if runner != null and runner.has_signal("hour_ticked"):
		runner.hour_ticked.connect(_on_hour)

func close_panel() -> void:
	visible = false

func open_trade() -> void:
	_title_lb.text = "贸易市场 · 游商"
	_sub.text = "买卖次日 06:00 生效；他带的货有限，钱也有限"
	visible = true
	_refresh()
	_apply_size()
	move_to_front()

func _apply_size() -> void:
	size = Vector2(W, H)

func _on_hour() -> void:
	if visible:
		_refresh()

func _clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()

func _refresh() -> void:
	if not visible:
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
		_body.add_child(UIKit.label(hint, 14))
		return

	for cv in caravans:
		_body.add_child(_caravan_block(cv))

	_body.add_child(_sep())
	_body.add_child(UIKit.label("国库 ¥%.2f" % float(snap.get("money", 0.0)), 14))

func _sep() -> Control:
	var s := ColorRect.new()
	s.color = Color(0.35, 0.30, 0.22)
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
	col.add_child(UIKit.label(title, 14))
	var offers: Array = cv.get(key, [])
	if offers.is_empty():
		col.add_child(UIKit.label("（这次没有）", 12))
		return col
	for o in offers:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var gid := String(o.get("good", ""))
		var name: String = runner.sim.good_name(gid)
		var line: String = "%s ×%.0f @%.2f" % [name, float(o.get("qty", 0.0)), float(o.get("price", 0.0))]
		var lb := UIKit.label(line, 14)
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

# ---------------------------------------------------------------------------
# 拖动（和其它浮动面板一致）
# ---------------------------------------------------------------------------
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_from = event.global_position - position
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		position = event.global_position - _drag_from
