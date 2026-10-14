extends PanelContainer

# 右侧详情面板：选中**普通建筑** → 运营；选中居民 → 个人；选中住房 → 产权。
#
# **没选中任何东西时整个面板收起来**（用户要求）：
# 原来这里画的是"全局面板"（日期/人口/国库/库存/日志），但那些全局数字
# 顶栏已经全有了（人口/满意度/钱/建造力/科研/移民），再占一屏纯属重复。
#
# ⚠️ 城镇中心与仓库**不在这里** —— 它们走浮动对话框（`panel_civic.gd`，
# 和点左侧圆钮出来的「统计」面板同一套形式：标题栏 + 拖动把手 + 关闭）。
# 分派在 `main._on_select_building()`。
#
# 排版规则（游戏化，不再堆 key: value 文本）：
#   区块标题 = 深色窄条；数据 = 左标签右数值；比例 = 进度条；商品 = 图标 + 名称 + 数量

var runner: SimRunner
var world: Node

var _kind := ""      # "" | "building" | "resident" | "housing"
var _id := ""
## 拆除确认弹窗（懒建，只建一次）
var _confirm: PopupPanel
var _confirm_text: Label
## 当前查看的建筑的 defId，供弹窗写文案（`_id` 是 shop 实例 id，不是 defId）
var _demolish_def_id := ""
var _body: VBoxContainer
## 标题栏（浮动框形式；见 `_ready()`）
var _title_lb: Label
var _sub_lb: Label
var _dragging := false
var _drag_off := Vector2.ZERO

## 拖动用工滑块期间置真。见 `_rebuild()` 里的说明。
var _dragging_slider := false

## 每种内容一套尺寸：普通建筑内容不多（等级/用工/滑块/三个按钮），别留一大片空白
const SIZE_BUILDING := Vector2(560, 440)
const SIZE_RESIDENT := Vector2(560, 380)
const SIZE_HOUSING := Vector2(560, 330)
const KEEP_VISIBLE := 80.0

func _ready() -> void:
	# **浮动对话框**，不再是右侧那条常驻面板（用户："我对右侧显示面板的这种界面形式
	# 不满意，不能是对话框吗"）。形式和 panel_civic / panel_stats 一致：
	# 标题 + 拖动把手 + 关闭，浮在画面中央，可以拖走。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 12, 10, 12, 10))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	_title_lb = UIKit.label("", UIKit.FG_HEAD)
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
	close.pressed.connect(func(): clear())
	head.add_child(close)
	root.add_child(UIKit.hsep())
	_sub_lb = UIKit.label("", UIKit.FG_DIM)
	root.add_child(_sub_lb)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 2)
	scroll.add_child(_body)

	visible = false
	if runner != null:
		runner.hour_ticked.connect(_rebuild)

## 拖动标题栏移动对话框；拖出屏幕会被 `_clamp_pos()` 拉回来。
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
		clampf(p.x, KEEP_VISIBLE - size.x, vp.x - KEEP_VISIBLE),
		clampf(p.y, 0.0, vp.y - KEEP_VISIBLE))

## 面板范围内的鼠标事件一律吃掉，别让滚内容把外面的地图也缩放了。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()

## 摆好尺寸并居中（每次切换目标都重新居中，免得从上一个位置"跳"出来）。
func _open_with(title: String, sub: String, want: Vector2) -> void:
	_title_lb.text = title
	_sub_lb.text = sub
	custom_minimum_size = want
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	visible = true
	move_to_front()

func show_building(id: String) -> void:
	_kind = "building"
	_id = id
	_rebuild()
	if _kind == "building":
		_open_with(String(_title_lb.text), "所有操作次日 06:00 生效", SIZE_BUILDING)

func show_resident(id: String) -> void:
	_kind = "resident"
	_id = id
	_rebuild()
	# 标题由 `_resident_panel()` 填（居民姓名），这里沿用
	_open_with(_title_lb.text, "个人状态", SIZE_RESIDENT)

func show_housing(uid: String) -> void:
	_kind = "housing"
	_id = uid
	_rebuild()
	_open_with(_title_lb.text, "产权与住户", SIZE_HOUSING)

func clear() -> void:
	_kind = ""
	_id = ""
	_rebuild()

func _clear() -> void:
	for c in _body.get_children():
		c.queue_free()

# ---------------------------------------------------------------------------
# 排版小件
# ---------------------------------------------------------------------------
func _title(text: String, big: bool = false) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(text, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	_body.add_child(p)
	if big:
		_body.add_child(UIKit.hsep())

## 画一行「键 —— 值」。返回那个**值标签**，方便调用方（用工拖动条）原地改它。
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

func _bar_row(key: String, value: float, maxv: float, color: Color, suffix: String = "") -> void:
	_kv(key, "%.1f%s" % [value, suffix], color)
	var pb := ProgressBar.new()
	pb.max_value = maxf(0.001, maxv)
	pb.value = clampf(value, 0.0, maxv)
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(0, 6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.24, 0.17, 0.12, 0.35)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	pb.add_theme_stylebox_override("background", bg)
	pb.add_theme_stylebox_override("fill", fg)
	_body.add_child(pb)

func _gap(h: int = 4) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	_body.add_child(c)

func _icon_row(gid: String, right: String, color: Color = UIKit.FG_DARK) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var tr := TextureRect.new()
	tr.texture = GoodIcons.tex(gid)
	tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(tr)
	var nm = String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid
	var k := UIKit.label(nm, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	row.add_child(UIKit.label(right, color))
	_body.add_child(row)

## 按钮行。每项是 `[文案, 回调]`，可选的第三项 `true` = 禁用
## （用于"命令已排队、再点没意义"的情况，比如已经排着升级）。
func _buttons(items: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	for it in items:
		var b := UIKit.button(String(it[0]), true)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if it.size() > 2 and bool(it[2]):
			b.disabled = true
		b.pressed.connect(it[1])
		row.add_child(b)
	_body.add_child(row)

func _label(t: String, size: int = 10) -> Label:
	var l := UIKit.label(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _button(t: String, cb: Callable) -> Button:
	return UIKit.button(t, true)

# ---------------------------------------------------------------------------
func _rebuild() -> void:
	if _body == null or runner == null or runner.sim == null:
		return
	# 拖动中**真的**不重建。
	#
	# 原来这里只有 `_build_worker_slider` 上方的一行注释声称"拖动中不能 _rebuild()"，
	# 但代码里并没有任何东西挡住它 —— 注释不等于事实。而 `runner.hour_ticked`
	# **每个游戏小时**都会触发本函数（sim_runner.gd:51），于是拖到一半滑块就被
	# `_clear()` 销毁重建，拖动当场断掉。
	if _dragging_slider:
		return
	_clear()
	match _kind:
		"building": _building_panel()
		"resident": _resident_panel()
		"housing": _housing_panel()
		_:
			# 没选中任何东西 → 面板整个收起来（见文件头注释：
			# 全局数字顶栏已经全有，不该再占一屏）。
			visible = false
			return
	visible = true

## 本店在 pending 队列里排着的 `set_workers`；-1 = 没排队。
##
## 为什么必须看 pending：命令是"次日 06:00 生效"的，在黎明之前
## `shop["targetWorkers"]` **不会变**。面板每小时都会 `_rebuild()`，
## 滑块初值若直接取 `targetWorkers`，用户拖完几秒就被打回原位
## —— 这就是"拖动之后会跳回去"那个 bug 的根。
##
## 与全局面板的人口上限（`_global_panel`）是同一套做法，那一格当初就修过这个问题。
## 引擎按 shopId 合并同名命令（`sim_core.gd` 的 `_dedup_key`），所以最多一条。
func _pending_workers() -> int:
	if runner == null or runner.sim == null:
		return -1
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_workers" and String(a.get("shopId", "")) == _id:
			return int(float(a["value"]))
	return -1

## 本店有没有排着「升级」（同样是次日生效，所以要标注出来）。
func _pending_expand() -> bool:
	if runner == null or runner.sim == null:
		return false
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "expand" and String(a.get("shopId", "")) == _id:
			return true
	return false

## 用工提示文案：`实际在岗 / 目标`（排着队就缀上「已排队」）。
##
## 拖动时也走这个函数，保证"滑块拖到 12"和"文字写 6"不会同时出现。
func _worker_hint_text(assigned: int, target: int, queued: bool) -> String:
	return "%d / %d%s" % [assigned, target, "（已排队）" if queued else ""]

func _building_panel() -> void:
	var shop = null
	for s in runner.sim.s["shops"]:
		if String(s["id"]) == _id:
			shop = s
			break
	if shop == null:
		_kind = ""
		visible = false
		return
	var def_id := String(shop["defId"])
	# 城镇中心 / 仓库由 main 分派到浮动对话框（panel_civic.gd），不该走到这里；
	# 真走到了就收起面板，别显示一份尴尬的通用建筑信息。
	if def_id == "town_center" or def_id == "warehouse":
		_kind = ""
		visible = false
		return
	var def: Dictionary = runner.db.buildings[def_id]
	_demolish_def_id = def_id
	var assigned := 0
	for r in runner.sim.s["residents"]:
		if r.get("jobShopId", null) == _id:
			assigned += 1
	# 上限是**有效工位数**（含升级带来的工位），不是 maxWorkers 那个常数 ——
	# 研究所这类产能建筑升一级会 +slotsPerLevel 个工位。
	# 与引擎共用同一个口径（TS effectiveSlots / GDScript effective_slots）。
	var slots := runner.sim.effective_slots(def, int(shop["level"]))
	var active := bool(shop["active"])
	# 排着队的命令次日才生效，所以显示值要优先取 pending（见 _pending_workers 的说明）
	var pend_workers := _pending_workers()
	var queued_workers := pend_workers >= 0
	var eff_workers: int = pend_workers if queued_workers else int(shop["targetWorkers"])
	var exp_queued := _pending_expand()

	_title_lb.text = String(def["nameZh"])   # 标题栏显示建筑名，正文里不再重复一遍
	if exp_queued:
		_kv("等级", "Lv%d（升级已排队）" % int(shop["level"]), Color(0.72, 0.35, 0.15))
	else:
		_kv("等级", "Lv%d" % int(shop["level"]))
	_kv("状态", "生产中" if active else "已停产",
		Color(0.18, 0.45, 0.20) if active else Color(0.60, 0.20, 0.18))
	var worker_hint := _kv("用工", _worker_hint_text(assigned, eff_workers, queued_workers),
		Color(0.72, 0.35, 0.15) if queued_workers else UIKit.FG_DARK)
	var pb := ProgressBar.new()
	pb.max_value = maxf(1.0, float(slots))
	pb.value = float(assigned)
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(0, 6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.24, 0.17, 0.12, 0.35)
	var fg := StyleBoxFlat.new()
	fg.bg_color = Color(0.35, 0.55, 0.72)
	pb.add_theme_stylebox_override("background", bg)
	pb.add_theme_stylebox_override("fill", fg)
	_body.add_child(pb)
	_kv("今日计划", "%.2f 批" % float(shop["planned"]))
	_kv("利润", "¥%.1f" % float(shop["profit"]),
		Color(0.18, 0.45, 0.20) if float(shop["profit"]) >= 0.0 else Color(0.60, 0.20, 0.18))
	_gap()
	_title("用工（0 = 停产）")
	_build_worker_slider(slots, eff_workers, worker_hint, assigned)
	_gap()
	_buttons([["升级" if not exp_queued else "升级（已排队）", func(): _expand(), exp_queued],
		["移动", func(): _begin_move_shop()],
		["拆除", func(): _demolish()]])
	_gap(2)
	_body.add_child(_label("所有操作次日 06:00 生效" if not (queued_workers or exp_queued)
		else "已排队，次日 06:00 生效"))

## 用工拖动条。
##
## 为什么不用那四个 ±按钮：拖动条一眼能看出"满员是多少、现在开了多少"，
## 而且拖到 0 就是停产 —— 原来那个「停产/复工」开关就多余了，已删掉。
##
## 拖动期间 `_dragging_slider = true`，`_rebuild()` 会让路（否则滑块被销毁重建、
## 拖动断掉）；松手后再补一次重建，让面板与队列一致。
## 拖动中只更新提示文字 + 入队（引擎按 shopId 合并同名命令，连发也只留最后一条）。
func _build_worker_slider(slots: int, current: int, hint: Label, assigned: int) -> void:
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = float(maxi(1, slots))
	s.step = 1
	s.value = float(clampi(current, 0, slots))
	s.custom_minimum_size = Vector2(0, 18)
	s.tooltip_text = "开多少工位。拖到 0 = 停产；最大 = 满员 %d" % slots
	# 像素风：默认 HSlider 的圆角渐变很出戏，这里全部换成硬边纯色
	# （把手是一张 8x12 的木/金属像素贴图，与左侧圆钮同一套配色）
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.24, 0.17, 0.12, 0.55)
	track.content_margin_top = 5
	track.content_margin_bottom = 5
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.55, 0.72)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var grab := UIKit.slider_grabber()
	if grab != null:
		s.add_theme_icon_override("grabber", grab)
		s.add_theme_icon_override("grabber_highlight", grab)
	# 拖动起止：挡住 _rebuild()，松手后补一次
	s.drag_started.connect(func(): _dragging_slider = true)
	s.drag_ended.connect(func(_changed: bool):
		_dragging_slider = false
		_rebuild())
	s.value_changed.connect(func(v: float):
		var w := int(round(v))
		# 文字跟着滑块走，并且立刻标「已排队」——
		# 否则会出现"滑块 12、文字写 6"这种自相矛盾（文案由 _worker_hint_text 统一生成）
		hint.text = _worker_hint_text(assigned, w, true)
		hint.add_theme_color_override("font_color", Color(0.72, 0.35, 0.15))
		runner.enqueue([{"type": "set_workers", "shopId": _id, "value": w}]))
	_body.add_child(s)
	# 下面这行让"拖到 0"这件事一眼可见
	_body.add_child(_label("0 = 停产　·　最大 = 满员 %d 个工位" % slots))

func _demolish() -> void:
	# 二次确认**弹窗**（不是按钮文案变一下）：拆除不可撤销，得让玩家看清要拆哪一座。
	# 用项目既有的弹窗做法（PopupPanel + UIKit 框体），别自己造一套。
	# 主题：main.gd 已经设了 `get_window().theme`，popup 挂在 window 下能拿到；
	# 只设 root_ui.theme 的话 popup 是拿不到的（这个坑项目里踩过）。
	if _confirm == null:
		_confirm = PopupPanel.new()
		_confirm.add_theme_stylebox_override("panel",
			UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 10, 10, 10, 10))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 8)
		_confirm_text = UIKit.label("", UIKit.FG_DARK)
		_confirm_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_confirm_text.custom_minimum_size = Vector2(280, 0)
		vb.add_child(_confirm_text)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(UIKit.spacer())
		var no := UIKit.button("取消", true)
		no.pressed.connect(func(): _confirm.hide())
		row.add_child(no)
		var yes := UIKit.button("确定拆除", true)
		yes.pressed.connect(func():
			_confirm.hide()
			runner.enqueue([{"type": "demolish", "shopId": _id}])
			clear())   # 建筑马上就没了，面板回到全局视图
		row.add_child(yes)
		vb.add_child(row)
		_confirm.add_child(vb)
		add_child(_confirm)
	var nm := _id
	if runner.db.buildings.has(_demolish_def_id):
		nm = String(runner.db.buildings[_demolish_def_id]["nameZh"])
	_confirm_text.text = "确定拆除「%s」？\n退回建造材料，不退建造力。此操作不可撤销。" % nm
	_confirm.popup_centered(Vector2i(340, 150))

func _expand() -> void:
	# 已经排着升级就别再入队（按钮虽然会置灰，但别只靠 UI 拦）
	if _pending_expand():
		return
	runner.enqueue([{"type": "expand", "shopId": _id}])
	_rebuild()

func _begin_move_shop() -> void:
	if world != null:
		world.begin_move_shop(_id)
	# 关掉对话框：它就在屏幕中间，不收起来会正好挡住要放的位置（用户反馈）
	clear()

func _begin_move_housing() -> void:
	if world != null:
		world.begin_move_housing(_id)
	clear()

func _resident_panel() -> void:
	var r = null
	for x in runner.sim.s["residents"]:
		if String(x["id"]) == _id:
			r = x
			break
	if r == null:
		_kind = ""
		visible = false
		return
	var cls := String(r["classId"])
	var hour = int(runner.sim.s["hour"])
	var activity := "在家休息"
	if hour >= 6 and hour < 18:
		activity = "在工作（或去仓库）"
	elif r.get("jobShopId", null) != null:
		activity = "下班回家"
	var work := "无业"
	if r.get("jobShopId", null) != null:
		var sid = String(r["jobShopId"])
		for s in runner.sim.s["shops"]:
			if String(s["id"]) == sid:
				work = String(runner.db.buildings[String(s["defId"])]["nameZh"])
				break

	# 头像：取该阶层精灵表的 S 向第 0 帧，放大 3 倍
	_title_lb.text = Names.for_id(_id)      # 标题栏显示名字，正文不再重复
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var av := TextureRect.new()
	var at := AtlasTexture.new()
	at.atlas = load("res://assets/actors/%s.png" % cls)
	at.region = Rect2(0, 0, 16, 16)
	av.texture = at
	av.custom_minimum_size = Vector2(48, 48)
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(av)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UIKit.label(Names.for_id(_id), UIKit.FG_DARK))
	col.add_child(UIKit.label("阶层 %s" % cls, UIKit.FG_HEAD))
	col.add_child(UIKit.label(activity, UIKit.FG_HEAD))
	head.add_child(col)
	_body.add_child(head)
	_body.add_child(UIKit.hsep())

	_bar_row("满意度", float(r["satisfaction"]), 100.0,
		Color(0.24, 0.55, 0.28) if float(r["satisfaction"]) >= 60.0 else Color(0.72, 0.45, 0.18), "")
	_bar_row("技能", float(r["skill"]), 100.0, Color(0.35, 0.50, 0.72))
	_kv("存款", "¥%.1f" % float(r["savings"]))
	var tenure := "国有"
	if bool(r.get("homeowner", false)):
		tenure = "自有"
	elif bool(r.get("privateTenant", false)):
		tenure = "私租"
	_kv("住宅", "%s·Lv%d" % [tenure, int(r.get("housingQuality", 0))])
	_kv("工作地点", work)
	_gap(2)
	_body.add_child(_label("编号 %s" % _id))

func _housing_panel() -> void:
	var inst = world.housing_instance(_id) if world != null else null
	if inst == null:
		_kind = ""
		visible = false
		return
	var def: Dictionary = runner.db.housing[inst["type"]]
	var occ: Array = inst["occupants"]
	_title_lb.text = String(def["nameZh"])   # 标题栏显示房型
	_kv("产权", "私有" if bool(inst["private"]) else "国有",
		Color(0.55, 0.35, 0.15) if bool(inst["private"]) else UIKit.FG_DARK)
	_kv("等级", "Lv%d" % int(def["quality"]))
	_bar_row("入住", float(occ.size()), float(def["capacity"]), Color(0.35, 0.50, 0.72))
	_gap()
	_title("住户 %d/%d" % [occ.size(), int(def["capacity"])])
	if occ.is_empty():
		_body.add_child(_label("（空置）"))
	for rid in occ:
		_kv(Names.for_id(String(rid)), String(rid))
	_gap()
	_buttons([["移动", func(): _begin_move_housing()]])

func _set_population_cap(value: int) -> void:
	runner.enqueue([{"type": "set_population_cap", "value": value}])
	# 必须立刻重建：命令排到次日 06:00 才生效，不重建的话点完屏幕上
	# 一点变化都没有，看起来就像按钮没反应。
	_rebuild()
