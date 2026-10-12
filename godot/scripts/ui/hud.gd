extends PanelContainer

# 顶栏（两行）：
#   第一行：时钟 / 人口概览 / 通知 / 暂停变速 / 存读档 / 资源设置
#   第二行：资源数量（图标 + 数字），显示哪些由弹窗里的勾选决定（存 user://hud.cfg）

var runner: SimRunner
var world: Node
var stats_panel: Control = null      # 统计面板（由 main 注入）

const CFG_PATH := "user://hud.cfg"
const DEFAULT_VISIBLE := ["wood", "stone", "brick", "clay", "firewood",
	"coarse_bread", "vegetable", "build_power"]

var _time: Label
var _info: Label
var _notice: Label
var _speed_btns: Array[Button] = []

var _res_row: HBoxContainer
var _chip_labels: Dictionary = {}
var _visible: Array = []
var _picker: PopupPanel
var _checks: Dictionary = {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = UIKit.BAR_H
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.hud_box(), 8, 3, 8, 3))

	_load_cfg()

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 2)
	add_child(root)

	# ---------------- 第一行
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	root.add_child(row)

	_time = UIKit.label("第 0 天  00:00", UIKit.FG_LABEL)
	row.add_child(_time)

	_info = UIKit.label("", Color(0.89, 0.91, 0.94))
	row.add_child(_info)

	row.add_child(UIKit.spacer())

	_notice = UIKit.label("", Color(1.0, 0.9, 0.6))
	row.add_child(_notice)

	var speeds := [["pause", "暂停", true, 0.0], ["1x", "1x 速度", false, 1.0],
		["2x", "2x 速度", false, 2.0], ["4x", "4x 速度", false, 4.0]]
	for cfg in speeds:
		var b := UIKit.icon_button("res://assets/ui/speed_%s.png" % cfg[0], String(cfg[1]))
		b.pressed.connect(_on_speed.bind(bool(cfg[2]), float(cfg[3])))
		row.add_child(b)
		_speed_btns.append(b)
	_mark_speed(0)

	for pair in [["保存", "_on_save"], ["读取", "_on_load"]]:
		var b := UIKit.button(String(pair[0]), true)
		b.pressed.connect(Callable(self, String(pair[1])))
		row.add_child(b)
	var pick := UIKit.button("资源", true)
	pick.tooltip_text = "选择顶栏显示哪些资源"
	pick.pressed.connect(_open_picker)
	row.add_child(pick)
	var st := UIKit.button("统计", true)
	st.tooltip_text = "资源 / 人口 / 财务 明细与曲线"
	st.pressed.connect(_open_stats)
	row.add_child(st)

	# ---------------- 第二行：资源
	_res_row = HBoxContainer.new()
	_res_row.add_theme_constant_override("separation", 9)
	root.add_child(_res_row)
	_rebuild_chips()

	_build_picker()

	if runner != null:
		runner.hour_ticked.connect(_refresh)
	_refresh()

func _open_stats() -> void:
	if stats_panel != null:
		stats_panel.open()

# ---------------------------------------------------------------------------
# 资源栏
# ---------------------------------------------------------------------------
func _chip(gid: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 3)
	var tr := TextureRect.new()
	tr.texture = load("res://assets/goods/%s.png" % gid)
	tr.custom_minimum_size = Vector2(16, 16)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	h.add_child(tr)
	var l := UIKit.label("0", Color(0.95, 0.93, 0.86))
	l.custom_minimum_size = Vector2(38, 0)
	h.add_child(l)
	_chip_labels[gid] = l
	return h

func _rebuild_chips() -> void:
	if _res_row == null:
		return
	for c in _res_row.get_children():
		c.queue_free()
	_chip_labels.clear()
	for gid in _visible:
		if runner != null and runner.db != null and not runner.db.goods.has(gid):
			continue
		_res_row.add_child(_chip(String(gid)))
	_refresh()

func _load_cfg() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) == OK:
		_visible = (cf.get_value("hud", "goods", DEFAULT_VISIBLE) as Array).duplicate()
	else:
		_visible = DEFAULT_VISIBLE.duplicate()

func _save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.set_value("hud", "goods", _visible)
	cf.save(CFG_PATH)

func _build_picker() -> void:
	_picker = PopupPanel.new()
	_picker.add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 10, 10, 10, 10))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	vb.add_child(UIKit.label("顶栏显示哪些资源", UIKit.FG_HEAD))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 1)
	vb.add_child(grid)

	var ids: Array = []
	if runner != null and runner.db != null:
		ids = runner.db.goods.keys()
		ids.sort()
	for gid in ids:
		var cb := CheckBox.new()
		cb.text = String(runner.db.goods[gid]["nameZh"])
		cb.add_theme_font_override("font", UIKit.pixel_font())
		cb.add_theme_font_size_override("font_size", UIKit.FS)
		cb.button_pressed = _visible.has(gid)
		cb.toggled.connect(_on_toggle.bind(String(gid)))
		grid.add_child(cb)
		_checks[String(gid)] = cb

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var allb := UIKit.button("全选", true)
	allb.pressed.connect(_set_all.bind(true))
	row.add_child(allb)
	var noneb := UIKit.button("清空", true)
	noneb.pressed.connect(_set_all.bind(false))
	row.add_child(noneb)
	row.add_child(UIKit.spacer())
	var closeb := UIKit.button("关闭", true)
	closeb.pressed.connect(func(): _picker.hide())
	row.add_child(closeb)
	vb.add_child(row)

	_picker.add_child(vb)

func _open_picker() -> void:
	add_child(_picker)
	# 每次打开时同步勾选状态
	for gid in _checks.keys():
		(_checks[gid] as CheckBox).set_pressed_no_signal(_visible.has(gid))
	_picker.popup_centered(Vector2i(478, 316))

func _on_toggle(pressed: bool, gid: String) -> void:
	if pressed and not _visible.has(gid):
		_visible.append(gid)
	elif not pressed and _visible.has(gid):
		_visible.erase(gid)
	_save_cfg()
	_rebuild_chips()

func _set_all(on: bool) -> void:
	_visible.clear()
	if on and runner != null and runner.db != null:
		_visible = runner.db.goods.keys()
	for gid in _checks.keys():
		(_checks[gid] as CheckBox).set_pressed_no_signal(on)
	_save_cfg()
	_rebuild_chips()

# ---------------------------------------------------------------------------
func _mark_speed(idx: int) -> void:
	for i in _speed_btns.size():
		_speed_btns[i].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if i == idx else UIKit.T_BTN))

func _on_save() -> void:
	if world == null:
		return
	var err = world.save_to(SaveManager.DEFAULT_PATH)
	set_notice("已保存" if err == OK else "保存失败")

func _on_load() -> void:
	if world == null:
		return
	if world.load_from(SaveManager.DEFAULT_PATH):
		set_notice("已读取存档")
	else:
		set_notice("没有可用存档")

func set_notice(text: String) -> void:
	if _notice != null:
		_notice.text = text

func _on_speed(paused: bool, value: float) -> void:
	if runner == null:
		return
	runner.set_paused(paused)
	if not paused:
		runner.set_speed(value)
	var idx := 0
	if not paused:
		idx = 1 if value == 1.0 else (2 if value == 2.0 else 3)
	_mark_speed(idx)

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
	_info.text = "人口%d  就业%d  满意%.1f  ¥%.0f  待生效%d" % [
		residents.size(), employed, sat, float(gov["money"]), pending,
	]
	# 资源数字
	var goods: Dictionary = s["goods"]
	var reserved: Dictionary = s.get("reserved", {})
	for gid in _chip_labels.keys():
		var amt := float(goods.get(gid, 0.0))
		var rsv := float(reserved.get(gid, 0.0))
		var l: Label = _chip_labels[gid]
		l.text = "%.0f" % amt
		if rsv > 0.01:
			l.add_theme_color_override("font_color", Color(0.75, 0.79, 0.62))
		else:
			l.add_theme_color_override("font_color", Color(0.95, 0.93, 0.86))
