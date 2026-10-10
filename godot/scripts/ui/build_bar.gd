extends PanelContainer

# 底部建造栏：道路/地板笔刷 + 建筑目录（按 tier 分组）。

var runner: SimRunner
var world: Node

var _size_box: OptionButton

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -104
	mouse_filter = Control.MOUSE_FILTER_PASS

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.11, 0.9)
	add_theme_stylebox_override("panel", bg)

	var margin := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 8)
	add_child(margin)

	var root := VBoxContainer.new()
	margin.add_child(root)

	# 第一行：笔刷
	var row1 := HBoxContainer.new()
	root.add_child(row1)
	row1.add_child(_label("笔刷："))
	var road_btn := Button.new()
	road_btn.text = "道路（免费）"
	road_btn.pressed.connect(func(): world.set_brush("road", _brush_size()))
	row1.add_child(road_btn)
	var floor_btn := Button.new()
	floor_btn.text = "地板（1 石 = 100 格）"
	floor_btn.pressed.connect(func(): world.set_brush("floor", _brush_size()))
	row1.add_child(floor_btn)
	row1.add_child(_label("  尺寸："))
	_size_box = OptionButton.new()
	for i in range(1, 6):
		_size_box.add_item("%dx%d" % [i, i], i)
	_size_box.selected = 0
	row1.add_child(_size_box)

	# 第二行：建筑目录
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 44)
	root.add_child(scroll)
	var row2 := HBoxContainer.new()
	scroll.add_child(row2)

	if runner != null and runner.db != null:
		var pack: Dictionary = runner.db.packs[String(runner.sim.s["pack"])]
		var last_tier := -1
		for id in pack["buildings"]:
			if not runner.db.buildings.has(id):
				continue
			var b: Dictionary = runner.db.buildings[id]
			var tier = int(b["tier"])
			if tier != last_tier:
				row2.add_child(_label(" T%d " % tier))
				last_tier = tier
			var btn := Button.new()
			btn.text = String(b["nameZh"])
			btn.tooltip_text = _cost_text(id)
			btn.pressed.connect(func(): world.set_build(id))
			row2.add_child(btn)
		row2.add_child(_label(" 住房 "))
		for hid in pack["housing"]:
			var hb: Dictionary = runner.db.housing[hid]
			var hbtn := Button.new()
			hbtn.text = String(hb["nameZh"])
			hbtn.pressed.connect(func(): world.set_build(hid))
			row2.add_child(hbtn)

func _brush_size() -> int:
	if _size_box == null:
		return 1
	return int(_size_box.get_selected_id())

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _cost_text(id: String) -> String:
	var b: Dictionary = runner.db.buildings[id]
	var parts := PackedStringArray()
	if b.has("terrain"):
		parts.append("需地形：" + String(b["terrain"]))
	for k in (b.get("buildCost", {}) as Dictionary).keys():
		parts.append("%s×%s" % [k, str(b["buildCost"][k])])
	return "\n".join(parts)
