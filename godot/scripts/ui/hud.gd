extends PanelContainer

# 顶部栏：时钟 / 暂停变速 / 概览 / 操作提示。

var runner: SimRunner

var _time: Label
var _info: Label
var _notice: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = 76
	mouse_filter = Control.MOUSE_FILTER_PASS

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.11, 0.85)
	add_theme_stylebox_override("panel", bg)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var row := HBoxContainer.new()
	margin.add_child(row)

	_time = Label.new()
	_time.add_theme_font_size_override("font_size", 20)
	row.add_child(_time)

	row.add_child(_spacer())

	var col := VBoxContainer.new()
	row.add_child(col)
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 14)
	col.add_child(_info)
	_notice = Label.new()
	_notice.add_theme_font_size_override("font_size", 13)
	_notice.modulate = Color(1, 0.9, 0.6)
	col.add_child(_notice)

	row.add_child(_spacer())

	for cfg in [["暂停", true, 0.0], ["1x", false, 1.0], ["2x", false, 2.0], ["4x", false, 4.0]]:
		var b := Button.new()
		b.text = String(cfg[0])
		b.pressed.connect(_on_speed.bind(bool(cfg[1]), float(cfg[2])))
		row.add_child(b)

	if runner != null:
		runner.hour_ticked.connect(_refresh)
	_refresh()

func set_notice(text: String) -> void:
	_notice.text = text

func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c

func _on_speed(paused: bool, value: float) -> void:
	if runner == null:
		return
	runner.set_paused(paused)
	if not paused:
		runner.set_speed(value)

func _refresh() -> void:
	if runner == null or runner.sim == null:
		return
	var s: Dictionary = runner.sim.s
	_time.text = runner.time_string()
	var gov: Dictionary = s["government"]
	var residents: Array = s["residents"]
	var employed := 0
	var sat := 0.0
	for r in residents:
		if bool(r["employed"]):
			employed += 1
		sat += float(r["satisfaction"])
	sat = sat / float(residents.size()) if not residents.is_empty() else 0.0
	var pending: int = (s["pending"] as Array).size()
	_info.text = "人口 %d  就业 %d  满意度 %.1f  政府 ¥%.0f  想来 %d  待生效 %d" % [
		residents.size(), employed, sat, float(gov["money"]), int(s["arrivals"]), pending,
	]
