extends PanelContainer

# 顶栏（两行）：
#   第一行：时钟 / 人口概览 / 通知 / 暂停变速 / 存读档 / 资源设置
#   第二行：资源数量（图标 + 数字），显示哪些由弹窗里的勾选决定（存 user://hud.cfg）

var runner: SimRunner
var world: Node
var stats_panel: Control = null      # 统计面板（由 main 注入）
var tech_panel: Control = null       # 科技面板（由 main 注入）
var music: Node = null               # 背景音乐（由 main 注入）
var sfx: Node = null                 # 菜单音效（由 main 注入）
var _sfx_btn: Button = null
var _music_btn: Button = null
## ESC 菜单（由 main 注入）。顶栏的「菜单」按钮要能打开它。
var esc_menu: Node = null
## 左上角小地图占掉的宽度。顶栏整体右移，文字从小地图右侧开始。
var left_inset := 0.0

const CFG_PATH := "user://hud.cfg"
const DEFAULT_VISIBLE := ["wood", "stone", "brick", "clay", "firewood",
	"coarse_bread", "vegetable"]

var _info: Label
var _notice: Label
var _speed_btns: Array[Button] = []

var _res_row: HBoxContainer
var _chip_labels: Dictionary = {}
## gid -> 整条 chip（图标 + 数字）。tooltip 挂在这上面，
## 所以图标和数字都要 mouse_filter=IGNORE，否则鼠标落在它们身上就不冒泡到 chip。
var _chip_nodes: Dictionary = {}
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
	# 小地图压在顶栏左上角，这一行从它右侧开始排
	if left_inset > 0.0:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(left_inset, 0)
		row.add_child(pad)

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

	# 只保留"快存 / 快读"（直接写默认存档位），其余进 ESC 菜单
	var qs := UIKit.button("快存", true)
	qs.tooltip_text = "快速保存到默认存档位（F5）"
	qs.pressed.connect(_on_save)
	row.add_child(qs)
	var ql := UIKit.button("快读", true)
	ql.tooltip_text = "从默认存档位快速读取（F9）"
	ql.pressed.connect(_on_load)
	row.add_child(ql)
	var st := UIKit.button("统计", true)
	st.tooltip_text = "资源 / 人口 / 财务 明细与曲线"
	st.pressed.connect(_open_stats)
	row.add_child(st)
	var tech := UIKit.button("科技", true)
	tech.tooltip_text = "研究科技解锁新的建筑与商品（科研力由研究所提供）"
	tech.pressed.connect(_open_tech)
	row.add_child(tech)
	var menu := UIKit.button("菜单", true)
	menu.tooltip_text = "保存 / 读取 / 音效 / 音乐 / 资源 / 退出（ESC）"
	menu.pressed.connect(func():
		if esc_menu != null:
			esc_menu.toggle())
	row.add_child(menu)
	_refresh_music_btn()
	_refresh_sfx_btn()

	# ---------------- 第二行：资源
	_res_row = HBoxContainer.new()
	_res_row.add_theme_constant_override("separation", 9)
	root.add_child(_res_row)
	_rebuild_chips()
	# 第二行同样要让开左上角的小地图（挂件高 266，会压到这一行）。
	# 必须放在 _rebuild_chips() 之后 —— 那个函数会清空 _res_row 的所有子节点。
	if left_inset > 0.0:
		var pad2 := Control.new()
		pad2.custom_minimum_size = Vector2(left_inset, 0)
		_res_row.add_child(pad2)
		_res_row.move_child(pad2, 0)

	_build_picker()

	if runner != null:
		runner.hour_ticked.connect(_refresh)
	_refresh()

func _open_stats() -> void:
	if stats_panel != null:
		stats_panel.open()

func _open_tech() -> void:
	if tech_panel != null:
		tech_panel.open()

func _toggle_music() -> void:
	if music == null:
		return
	music.toggle_mute()
	_refresh_music_btn()

func _toggle_sfx() -> void:
	if sfx == null:
		return
	sfx.toggle_mute()
	_refresh_sfx_btn()

func _refresh_sfx_btn() -> void:
	# 顶栏不再有音效按钮，状态显示在 ESC 菜单里
	pass

func _refresh_music_btn() -> void:
	# 顶栏不再有音乐按钮，状态显示在 ESC 菜单里
	pass

# ---------------------------------------------------------------------------
# 资源栏
# ---------------------------------------------------------------------------
func _chip(gid: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 3)
	# tooltip 挂在整条 chip 上；子节点让开鼠标事件，否则悬停在图标上时
	# Godot 找不到带 tooltip 的控件，tip 就不弹（这是最常见的"tip 不显示"原因）
	h.mouse_filter = Control.MOUSE_FILTER_STOP
	var tr := TextureRect.new()
	# 走单点加载器：手绘 icons/ 优先，回落程序化 goods/
	tr.texture = GoodIcons.tex(gid)
	tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(tr)
	var l := UIKit.label("0", Color(0.95, 0.93, 0.86))
	l.custom_minimum_size = Vector2(38, 0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	_chip_labels[gid] = l
	_chip_nodes[gid] = h
	return h

func _rebuild_chips() -> void:
	if _res_row == null:
		return
	for c in _res_row.get_children():
		c.queue_free()
	_chip_labels.clear()
	_chip_nodes.clear()
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
		# 选项也带上图标，一眼能认出是哪种资源
		var ic: Texture2D = GoodIcons.tex(String(gid))
		if ic != null:
			cb.icon = ic
			cb.add_theme_constant_override("icon_max_width", UIKit.CHIP_ICON)
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
	# 建造力与科研力都是**速率**（人·天/日），不是库存 —— 见 docs/construction.md / docs/technology.md
	var build_rate := runner.sim.construction_rate()
	var research_rate := runner.sim.research_rate()
	_info.text = "人口%d  就业%d  满意%.1f  ¥%.0f  建造%.0f/天  科研%.1f/天  待生效%d" % [
		residents.size(), employed, sat, float(gov["money"]), build_rate, research_rate, pending,
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
		# tooltip：悬停看得到这项资源的全貌，不用去开统计面板
		if _chip_nodes.has(gid):
			(_chip_nodes[gid] as Control).tooltip_text = _chip_tip(String(gid), amt, rsv, s)

## 顶栏资源 chip 的悬停提示。
func _chip_tip(gid: String, amt: float, rsv: float, s: Dictionary) -> String:
	var db = runner.db if runner != null else null
	var nm := gid
	var lines: Array[String] = []
	if db != null and db.goods.has(gid):
		var gdef: Dictionary = db.goods[gid]
		nm = String(gdef["nameZh"])
		lines.append("%s　（%s）" % [nm, String(gdef.get("category", ""))])
	else:
		lines.append(nm)
	lines.append("库存 %s" % _amt(amt))
	if rsv > 0.01:
		lines.append("已预留 %s　（今天计划要花掉的）" % _amt(rsv))
	var price := float((s["prices"] as Dictionary).get(gid, 0.0))
	if price > 0.0:
		lines.append("市场价 ¥%.2f" % price)
	if db != null and db.goods.has(gid):
		var gd: Dictionary = db.goods[gid]
		# 工具类：说明它给工坊带来什么
		var tb := float(gd.get("toolBonus", 0.0))
		if tb > 0.0:
			lines.append("工具：已装配的工坊产出 ×%.2f（投入不变）" % (1.0 + tb))
		# 住房：说明能住多少人
		if db.housing.has(gid):
			lines.append("住房：可住 %d 人/座" % int(db.housing[gid]["capacity"]))
		if bool(gd.get("luxury", false)):
			lines.append("奢侈品：低价格弹性（对富人提价更好赚）")
	return "\n".join(lines)

## 数量显示：小的带一位小数（0.5 个蔬菜这种），大的取整
func _amt(v: float) -> String:
	if absf(v) < 100.0 and absf(v - round(v)) > 0.005:
		return "%.1f" % v
	return "%.0f" % v
