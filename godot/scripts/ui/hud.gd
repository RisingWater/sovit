extends Control

# HUD：只读仿真状态并显示；速度/暂停按钮把命令交给 SimRunner。
# 所有命令都是「次日生效」，与 docs/spec.md 一致。

var runner: SimRunner

var _time_label: Label
var _info_label: Label
var _goods_label: Label
var _log_label: RichTextLabel

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	if runner != null:
		runner.hour_ticked.connect(_refresh)
	_refresh()

func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var root := VBoxContainer.new()
	margin.add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)

	_time_label = Label.new()
	_time_label.add_theme_font_size_override("font_size", 22)
	top.add_child(_time_label)

	top.add_child(_spacer())

	for cfg in [["暂停", true, 0.0], ["1x", false, 1.0], ["2x", false, 2.0], ["4x", false, 4.0]]:
		var b := Button.new()
		b.text = String(cfg[0])
		b.pressed.connect(_on_speed.bind(bool(cfg[1]), float(cfg[2])))
		top.add_child(b)

	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 16)
	root.add_child(_info_label)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	_goods_label = Label.new()
	_goods_label.custom_minimum_size = Vector2(320, 0)
	_goods_label.add_theme_font_size_override("font_size", 14)
	split.add_child(_goods_label)

	_log_label = RichTextLabel.new()
	_log_label.scroll_following = true
	_log_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(_log_label)

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
	_time_label.text = runner.time_string()

	var gov: Dictionary = s["government"]
	var residents: Array = s["residents"]
	var employed := 0
	var sat := 0.0
	for r in residents:
		if bool(r["employed"]):
			employed += 1
		sat += float(r["satisfaction"])
	sat = sat / float(residents.size()) if not residents.is_empty() else 0.0
	_info_label.text = "人口 %d   就业 %d   满意度 %.1f   政府 ¥%.0f   想来 %d" % [
		residents.size(), employed, sat, float(gov["money"]), int(s["arrivals"]),
	]

	var lines := PackedStringArray()
	lines.append("— 库存 —")
	var goods: Dictionary = s["goods"]
	for gid in goods.keys():
		var qty = float(goods[gid])
		if qty < 0.01:
			continue
		var name: String = gid
		if runner.db.goods.has(gid):
			name = String(runner.db.goods[gid]["nameZh"])
		lines.append("%-8s %8.1f" % [name, qty])
	lines.append("")
	lines.append("— 建筑 %d —" % (s["shops"] as Array).size())
	_goods_label.text = "\n".join(lines)

	var text := ""
	var logs: Array = runner.recent_logs
	var start := maxi(0, logs.size() - 12)
	for i in range(start, logs.size()):
		var e: Dictionary = logs[i]
		text += "[%d] %s\n" % [int(e.get("day", 0)), String(e.get("text", ""))]
	_log_label.text = text
