extends PanelContainer

# 城镇中心 / 仓库的**浮动对话框**（和「统计」面板同一套形式：标题栏 + 拖动把手 + 关闭）。
#
# 为什么不是右侧常驻条：右侧那条是"选中就占着屏幕右边一整条"的形式，
# 用户不喜欢 —— 他要的是"点一下弹出来、能拖、能关"的对话框，
# 也就是点左侧圆钮（资源/人口/财政）出来的那种（`panel_stats.gd`）。
#
# 两种内容：
#   - 城镇中心 → 人口（本回合想来 / 上限 / 当前人口 / 空房 / 次日会来）+ 公告
#   - 仓库     → 等级·用工·本座容量 / 全村仓储余量 / **每种资源（数量 / 上限）**
#               上限就在这里设（留空 = 不限），命令次日 06:00 生效。
#
# 顶部那条"全局"（日期/就业/满意度/国库）**不放这儿** —— 顶栏已经全有。

var runner: SimRunner
var world: Node
var inspector: Node = null      # 拆除确认等交给它？不，本面板自带两段式确认（见下）

const PANEL_W := 620.0
const PANEL_H := 660.0
## 人口那一页内容少，对话框跟着矮一截（不然底下空一大片）
const POP_W := 620.0
const POP_H := 430.0
const KEEP_VISIBLE := 80.0

enum Mode { NONE, TOWN_CENTER, WAREHOUSE }

var _mode := Mode.NONE
var _id := ""
var _title_lb: Label
var _body: VBoxContainer
var _sub: Label
## 每种货的上限输入框（每次重建时重置）
var _cap_inputs: Dictionary = {}
## 二次确认标记（"拆除"要点两次）
var _confirm := ""

var _dragging := false
var _drag_off := Vector2.ZERO

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 12, 10, 12, 10))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# 标题行：名字 + 拖动把手 + 关闭（和「统计」面板一致）
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	_title_lb = UIKit.label("城镇中心", UIKit.FG_HEAD)
	_title_lb.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(_title_lb)
	var dragbar := Control.new()
	dragbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dragbar.mouse_filter = Control.MOUSE_FILTER_STOP
	dragbar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	dragbar.tooltip_text = "按住拖动对话框"
	var hint := UIKit.label("拖动此处移动", Color(0.66, 0.52, 0.36))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dragbar.add_child(hint)
	dragbar.gui_input.connect(_on_drag_input)
	head.add_child(dragbar)
	var close := UIKit.button("关闭", true)
	close.pressed.connect(close_panel)
	head.add_child(close)
	root.add_child(UIKit.hsep())

	_sub = UIKit.label("", UIKit.FG_DIM)
	root.add_child(_sub)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	scroll.add_child(_body)

	visible = false
	if runner != null:
		runner.hour_ticked.connect(_on_hour)

# ---------------------------------------------------------------------------
# 打开 / 关闭 / 拖动
# ---------------------------------------------------------------------------
func open_town_center() -> void:
	_mode = Mode.TOWN_CENTER
	_title_lb.text = "城镇中心"
	_sub.text = "人口与公告 —— 全局数字（日期/就业/满意度/国库）在顶栏"
	_show()

## `shop_id`：仓库的 shop 实例 id（只能同时看一座的容量构成）
func open_warehouse(shop_id: String) -> void:
	_mode = Mode.WAREHOUSE
	_id = shop_id
	_title_lb.text = "仓库 · 仓储"
	_sub.text = "上限留空 = 不限；命令次日 06:00 生效"
	_show()

func _show() -> void:
	_confirm = ""
	visible = true
	_refresh()
	# 高度按内容分档：人口那一页内容少，用矮一点的框（不然底下空一大片）
	var want := Vector2(POP_W, POP_H) if _mode == Mode.TOWN_CENTER else Vector2(PANEL_W, PANEL_H)
	custom_minimum_size = want
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	move_to_front()

func close_panel() -> void:
	visible = false
	_mode = Mode.NONE

func _on_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if _dragging:
				_drag_off = get_global_mouse_position() - position
	elif event is InputEventMouseMotion and _dragging:
		position = _clamp_pos(get_global_mouse_position() - _drag_off)

func _clamp_pos(p: Vector2) -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(
		clampf(p.x, KEEP_VISIBLE - PANEL_W, vp.x - KEEP_VISIBLE),
		clampf(p.y, 0.0, vp.y - KEEP_VISIBLE))

## 面板范围内的鼠标事件一律吃掉（滚列表时别把外面的地图也缩放了）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()

# ---------------------------------------------------------------------------
# 刷新
# ---------------------------------------------------------------------------
func _on_hour() -> void:
	if not visible:
		return
	# 正在填上限时**别重建** —— 重建会把输入框销毁，打字打到一半就断
	# （和右侧面板的用工拖动条是同一个坑）。
	if _cap_input_focused():
		return
	_refresh()

func _cap_input_focused() -> bool:
	for c in _body.find_children("*", "LineEdit", true, false):
		if (c as LineEdit).is_visible_in_tree() and (c as LineEdit).has_focus():
			return true
	return false

func _refresh() -> void:
	for c in _body.get_children():
		c.queue_free()
	_cap_inputs.clear()
	match _mode:
		Mode.TOWN_CENTER: _build_population()
		Mode.WAREHOUSE: _build_storage()
		_: pass

# ---------------------------------------------------------------------------
# 排版小件（和 inspector 同款：区块标题 + 左标签右数值 + 进度条）
# ---------------------------------------------------------------------------
func _title(text: String) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(text, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	_body.add_child(p)

func _kv(key: String, value: String, color: Color = UIKit.FG_DARK) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var k := UIKit.label(key, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := UIKit.label(value, color)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	_body.add_child(row)
	return v

func _bar(key: String, value: float, maxv: float, color: Color, suffix: String = "") -> void:
	_kv(key, "%.0f%s" % [value, suffix], color)
	var pb := ProgressBar.new()
	pb.max_value = maxf(0.001, maxv)
	pb.value = clampf(value, 0.0, maxv)
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(0, 8)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.24, 0.17, 0.12, 0.35)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	pb.add_theme_stylebox_override("background", bg)
	pb.add_theme_stylebox_override("fill", fg)
	_body.add_child(pb)

func _note(t: String) -> Label:
	var l := UIKit.label(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(l)
	return l

func _gap(h: int = 6) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	_body.add_child(c)

func _buttons(items: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for it in items:
		var b := UIKit.button(String(it[0]), true)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if it.size() > 2 and bool(it[2]):
			b.disabled = true
		b.pressed.connect(it[1])
		row.add_child(b)
	_body.add_child(row)

# ---------------------------------------------------------------------------
# 城镇中心：人口 + 公告
# ---------------------------------------------------------------------------
func _build_population() -> void:
	var s: Dictionary = runner.sim.s
	var residents: Array = s["residents"]
	var arrivals = int(s["arrivals"])
	var cap = int(float(s["government"]["populationCap"]))
	# 命令次日 06:00 生效，所以显示值要先看 pending（否则点完按钮屏幕没反应）
	var pending_cap := -1
	for a in (s["pending"] as Array):
		if String(a.get("type", "")) == "set_population_cap":
			pending_cap = int(float(a["value"]))
	var eff_cap: int = pending_cap if pending_cap >= 0 else cap
	var popn = residents.size()
	var hcap := 0
	for gid in (s["housing"] as Dictionary).keys():
		if runner.db.housing.has(gid):
			hcap += int(runner.db.housing[gid]["capacity"]) * int(floor(float(s["housing"][gid])))
	var cap_room: int = (eff_cap - popn) if eff_cap < 100000000 else arrivals
	var will_come: int = mini(arrivals, mini(cap_room, maxi(0, hcap - popn)))

	_kv("人口上限" + ("（已排队）" if pending_cap >= 0 else ""),
		"不限" if eff_cap >= 100000000 else str(eff_cap),
		Color(0.72, 0.35, 0.15) if pending_cap >= 0 else UIKit.FG_DARK)
	_kv("当前人口", "%d 人" % popn)
	_kv("空房", "%d" % maxi(0, hcap - popn))
	_kv("本回合想来", "%d 人" % arrivals, Color(0.55, 0.35, 0.15) if arrivals > 0 else UIKit.FG_DARK)
	_kv("次日会来", "%d 人" % will_come,
		Color(0.18, 0.45, 0.20) if will_come > 0 else UIKit.FG_DARK)
	_buttons([["不限", func(): _set_population_cap(1000000000)],
		["停", func(): _set_population_cap(popn)],
		["+10", func(): _set_population_cap(popn + 10)]])
	_gap(2)
	if will_come <= 0 and arrivals > 0:
		var why = "空房不足" if (hcap - popn) <= 0 else ("已到人口上限" if eff_cap < 100000000 else "名额不足")
		_note("想来 %d 人，但%s，一个也进不来。" % [arrivals, why])
	else:
		_note("次日 06:00 生效。没人来通常是空房不足或已到人口上限；"
			+ "空房靠多盖住房，上限就是上面那三个按钮。")

	# 仓储容量也报一句（明细在仓库对话框里）
	_gap()
	_title("仓储容量")
	_bar("已用", runner.sim.stored_total(), maxf(1.0, runner.sim.storage_capacity()),
		Color(0.72, 0.45, 0.18) if runner.sim.stored_total() >= runner.sim.storage_capacity() * 0.9
		else Color(0.24, 0.55, 0.28),
		" / %d" % int(round(runner.sim.storage_capacity())))
	_note("容量来自城镇中心与仓库；点任意一座仓库可以看到每种资源还剩多少额度。")

	_gap()
	_title("公告")
	var logs: Array = runner.recent_logs
	if logs.is_empty():
		_note("（暂无）")
	for i in range(maxi(0, logs.size() - 12), logs.size()):
		var e: Dictionary = logs[i]
		_note("[D%d] %s" % [int(e.get("day", 0)), String(e.get("text", ""))])

func _set_population_cap(value: int) -> void:
	runner.enqueue([{"type": "set_population_cap", "value": value}])
	# 立刻重建：命令次日才生效，不重建的话点完屏幕上一点变化都没有
	_refresh()

# ---------------------------------------------------------------------------
# 仓库：容量 + 每种资源（数量 / 上限）
# ---------------------------------------------------------------------------
func _build_storage() -> void:
	var sim = runner.sim
	var s: Dictionary = sim.s
	var shop = null
	for sh in s["shops"]:
		if String(sh["id"]) == _id:
			shop = sh
	if shop == null:
		_note("这座仓库已经不在了。")
		return
	var def: Dictionary = runner.db.buildings["warehouse"]
	var level := int(shop["level"])
	var st: Dictionary = def.get("storage", {})
	var own: float = float(st.get("storage", 0.0)) + float(st.get("storagePerLevel", 0.0)) * float(level - 1)
	var assigned := sim._assigned_workers(_id)
	var exp_queued := false
	for a in (s["pending"] as Array):
		if String(a.get("type", "")) == "expand" and String(a.get("shopId", "")) == _id:
			exp_queued = true

	_kv("等级", "Lv%d（升级已排队）" % level if exp_queued else "Lv%d" % level,
		Color(0.72, 0.35, 0.15) if exp_queued else UIKit.FG_DARK)
	_kv("用工", "%d / %d（在右侧建筑面板里调）" % [assigned, int(shop["targetWorkers"])],
		Color(0.72, 0.35, 0.15) if assigned < 1 else UIKit.FG_DARK)
	_kv("本座容量", "%d" % int(round(own)),
		UIKit.FG_DARK if assigned >= 1 else Color(0.60, 0.20, 0.18))
	if assigned < 1:
		_note("没有工人在岗 → 这座仓库的容量不计入（docs/town.md §3.2）。")
	_buttons([["升级" if not exp_queued else "升级（已排队）", func(): _expand(), exp_queued],
		["移动", func(): _begin_move()],
		["拆除", func(): _demolish()]])

	_gap()
	_title("全村仓储" + ("（上限已排队）" if _caps_pending() else ""))
	var used := sim.stored_total()
	var total := sim.storage_capacity()
	_bar("已用", used, maxf(1.0, total),
		Color(0.72, 0.45, 0.18) if used >= total * 0.9 else Color(0.24, 0.55, 0.28),
		" / %d" % int(round(total)))
	if used >= total:
		_note("已经满了：当晚超出上限的部分会被丢掉。再建/升级仓库可以扩容。")

	_gap()
	# 资源列表：数量 ＋ 上限。顺序用 pack 的固定顺序（数量每小时都变，按它排行会跳）
	var caps: Dictionary = _effective_caps()
	var goods: Dictionary = s["goods"]
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	_body.add_child(grid)
	for gid in (runner.db.packs[String(s["pack"])]["goods"] as Array):
		_cap_cell(grid, String(gid), int(caps.get(String(gid), 0)), float(goods.get(String(gid), 0.0)))
	_gap(2)
	_note("数量 = 当前库存；上限留空 = 不限。超过上限的部分当天夜里按价值从低到高丢掉，"
		+ "价值并列时按商品 id 排（docs/spec.md §2.4）。数量标红＝这一项已经超了自己的上限。")

func _cap_cell(grid: GridContainer, gid: String, cap: int, amount: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var ic: Texture2D = GoodIcons.tex(gid)
	if ic != null:
		var tr := TextureRect.new()
		tr.texture = ic
		tr.custom_minimum_size = Vector2(22, 22)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(tr)
	var nm := UIKit.label(String(runner.db.goods[gid]["nameZh"]))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ⚠️ `clip_text = true` 会让 Label 的最小宽度变成 0 —— 在 3 列网格里名字会被
	# 挤成 0 宽（实测：整列只剩图标和数字）。必须自己给个最小宽度。
	nm.clip_text = true
	nm.custom_minimum_size = Vector2(58, 0)
	row.add_child(nm)
	var over := cap > 0 and amount > float(cap)
	var amt := UIKit.label("%.0f" % amount, Color(0.72, 0.25, 0.15) if over else UIKit.FG_DARK)
	amt.custom_minimum_size = Vector2(46, 0)
	amt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(amt)
	var le := UIKit.input("不限", 6)
	le.custom_minimum_size = Vector2(62, 0)
	le.text = "" if cap <= 0 else str(cap)
	le.tooltip_text = "「%s」最多存多少（留空 = 不限）" % String(runner.db.goods[gid]["nameZh"])
	le.text_changed.connect(_on_cap_text.bind(gid))
	row.add_child(le)
	grid.add_child(row)
	_cap_inputs[gid] = le

## 上限输入框改了 → 整张表作为一条命令入队（次日 06:00 生效）。
##
## ⚠️ 过滤完**必须接着推一次**：Godot 4.7 里 `LineEdit.text = x` 不会发
## `text_changed`（实测），所以"抹掉非数字"这一步不会自己再触发本函数。
func _on_cap_text(text: String, gid: String) -> void:
	var le: LineEdit = _cap_inputs.get(gid, null)
	if le == null:
		return
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != text:
		le.text = digits
	var caps := {}
	for g in _cap_inputs.keys():
		var v := int((_cap_inputs[g] as LineEdit).text)
		if v > 0:
			caps[g] = v
	runner.enqueue([{"type": "set_storage_caps", "caps": caps}])

func _effective_caps() -> Dictionary:
	var caps: Dictionary = (runner.sim.s["government"] as Dictionary).get("storageCaps", {})
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_storage_caps":
			return (a.get("caps", {}) as Dictionary)
	return caps

func _caps_pending() -> bool:
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_storage_caps":
			return true
	return false

func _expand() -> void:
	runner.enqueue([{"type": "expand", "shopId": _id}])
	_refresh()

func _begin_move() -> void:
	if world != null and world.has_method("begin_move_shop"):
		close_panel()
		world.begin_move_shop(_id)

## 拆除要**点两次**（第一次只提示），不弹二级对话框。
func _demolish() -> void:
	if _confirm != "del":
		_confirm = "del"
		_note("确认拆除这座仓库？再点一次「拆除」就拆（材料会退回）。")
		return
	_confirm = ""
	runner.enqueue([{"type": "demolish", "shopId": _id}])
	close_panel()
