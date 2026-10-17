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

## 当前往哪个容器里加行：默认 `_body`；`_section()` 会把它切到该段的内容容器。
## 这样"分段"只是换一个 add_child 的目标，`_kv` / `_label` / 滑块 都不用各写一遍。
var _host: VBoxContainer
## 每一段的内容容器（段名 → VBox），重建时刷新。折叠就是把它 visible 掉。
var _sections := {}
## 每一段的折叠按钮（段名 → Button），切换时只改字形，不重建面板。
var _fold_btns := {}
## 每一段的折叠状态（段名 → bool）。**要跨重建保留** —— `_rebuild()` 每个游戏小时都跑一次，
## 不记着的话玩家一折叠、下一小时又自己弹开了。
var _folded := {}

## 页签行（滚动区外面）：普通建筑没有第二页，整行收起来；建筑工坊 / 研究所各多一页
## 队列（见 `_tabs_of()`）。当前页记在 `_tab`，跨"每小时重建"保留。
var _tab_row: HBoxContainer
var _tab_btns: Array = []
var _tabs: Array = []
var _tab := 0
## 队列页里那个共用控件的二次确认状态（记在面板上才能跨重建；见 queue_box.gd）
var _qstate := {"confirm": ""}

## 每种内容一套尺寸：普通建筑分「基础 / 员工 / 操作」三段（员工可能多行，里面是
## ScrollContainer，所以给个够放三段标题的高度）
const SIZE_BUILDING := Vector2(560, 520)
const SIZE_RESIDENT := Vector2(560, 380)
const SIZE_HOUSING := Vector2(560, 330)
const KEEP_VISIBLE := 80.0
## 对话框离窗口边缘至少留这么多（`_clamp_pos()` 用它，自适应高度也算它）
const MARGIN := 16.0
## 面板里行内图标（商品 / 金币）的边长。与科技 tooltip 的 24 一致。
const ROW_ICON := 24
## **每一行的高度**。带图标的行与不带图标的行必须一样高 —— 否则 24px 的图标会把那一行
## 撑高，行距一跳一跳的（用户原话："没有图标的行和有图标的行上下间隔不一样…很丑"）。
## 图标与文字都用 `SIZE_SHRINK_CENTER` / `VERTICAL_ALIGNMENT_CENTER` 在这条基准线上居中。
const ROW_H := 26

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
	# 页签行：只有**产能建筑**才显示第二页（建筑工坊 → 建造队列 / 研究所 → 研究队列）。
	# 放在滚动区**外面** —— 滚内容时页签不该跟着滚走（与城镇中心面板同一形式）。
	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 4)
	_tab_row.visible = false
	root.add_child(_tab_row)
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

## 标题行 + 分隔线 + 副标题 + 面板内边距的高度（即滚动区之外的那些）。
##
## 为什么不用 `reset_size()` 量：里面的 `ScrollContainer` 最小高**不是**内容高，
## 先试过那条路 —— 量出来 366px，面板反而被压得更小、内容被截（见 _open_with 的注释）。
func _chrome_height() -> float:
	var h := 0.0
	var root := get_child(0)
	if root == null:
		return h
	for c in root.get_children():
		if c is ScrollContainer or not (c as Control).visible:
			continue
		h += (c as Control).get_combined_minimum_size().y
		h += 6.0                                   # root 的 separation
	return h + 22.0                                # UIKit.pad(...) 的上下内边距 10 + 10（+2 余量）

## 面板高度的算法（`fit_h` 与折叠后重算共用一处，别写两遍）。
##
## 下限只挡"三段全折叠时面板缩成一条"（那时内容 ≈ 3 个标题条 ≈ 150px）；
## 别把下限设大 —— 下限一大，折叠后就留出一片空白，正是要避免的东西。
func _fit_height() -> float:
	var vp_max := get_viewport_rect().size.y - 2.0 * MARGIN
	return clampf(_chrome_height() + _body.get_combined_minimum_size().y,
		SIZE_BUILDING.y * 0.35, minf(SIZE_BUILDING.y * 1.6, vp_max))

## 折叠 / 展开某一段之后**重新贴合高度**（面板高度是按内容算的，见 `_open_with`）。
## 位置保持不变（只夹回可视区），免得点一下折叠面板就跳走。
func _refit_height() -> void:
	if _kind != "building":
		return
	custom_minimum_size.y = _fit_height()
	reset_size()
	position = _clamp_pos(position)

## 摆好尺寸并居中（每次切换目标都重新居中，免得从上一个位置"跳"出来）。
##
## `fit_h` = **高度跟着内容走**（建筑面板专用）：员工 0 个和 12 个差很多，写死高度不是
## 留一大片空白就是被截掉。高度 = 滚动区外的高度 + 内容自身的最小高，再夹在
## `want.y × 0.7` 与 `min(want.y × 1.6, 窗口高 − 2×MARGIN)` 之间 ——
## 员工特别多时就不再长高，交给 ScrollContainer 滚。
func _open_with(title: String, sub: String, want: Vector2, fit_h: bool = false) -> void:
	_title_lb.text = title
	_sub_lb.text = sub
	# 副标题为空就整行收起来（建筑面板不再写「运营」——段标题已经说明一切）
	_sub_lb.visible = sub != ""
	var h := _fit_height() if fit_h else want.y
	custom_minimum_size = Vector2(want.x, h)
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	visible = true
	move_to_front()

func show_building(id: String) -> void:
	_kind = "building"
	_id = id
	_tab = 0                 # 换一座建筑从「运营」页看起
	_qstate["confirm"] = ""
	_rebuild()
	if _kind == "building":
		# 不写副标题：段标题（基础 / 员工 / 操作）已经把内容说清了
		_open_with(String(_title_lb.text), "", SIZE_BUILDING, true)

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
	# ⚠️ 必须**先 `remove_child` 再 `queue_free`**：`queue_free()` 是延迟的，节点要到帧末
	# 才真的离开树。而面板高度是按 `_body` 的内容算的（`_fit_height()`）—— 同一帧里去量，
	# 量到的是"旧内容 + 新内容"，面板会一路顶到上限、底下留一大片空白（切页签时最明显：
	# 「运营」那页还在树上，加上队列页的一起算，实测 832px 上限、底下 200px 空的）。
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()

# ---------------------------------------------------------------------------
# 排版小件
# ---------------------------------------------------------------------------
func _title(text: String, big: bool = false) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(text, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	_host.add_child(p)
	if big:
		_host.add_child(UIKit.hsep())

## **可折叠段落**：标题条右侧一个 ＋/− 按钮，返回这一段的**内容容器** ——
## 之后的 `_kv` / `_label` / 滑块 / 按钮都会自动加进它里面（靠 `_host` 切换），
## 直到下一个 `_section()` / `_title()`。
##
## ＋ = 现在是折叠的（点一下展开），− = 现在是展开的（点一下折叠）。
## 折叠状态记在 `_folded` 里，跨重建保留（面板每游戏小时重建一次）。
func _section(name: String) -> VBoxContainer:
	var bar := UIKit.panel(true)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	var l := UIKit.label(name, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(l)
	var folded := bool(_folded.get(name, false))
	var btn := UIKit.button("+" if folded else "–", true)
	# 只放一个字形：压到 22×18，别把标题条撑得比数据行还高。
	# ⚠️ 字号**不能改**（UIKit.FS = 像素字体原生尺寸，改了会糊）
	# ⚠️ 字形必须是**字体里真有的**：以前写的是 U+2212 "−"，fusion-pixel 没有它，
	#    展开状态下按钮上**一个字都没有**（空按钮）。改用 U+2013 "–"（门槛 `glyph` 盯着）。
	btn.custom_minimum_size = Vector2(22, 18)
	btn.tooltip_text = ("展开「%s」" % name) if folded else ("折叠「%s」" % name)
	btn.pressed.connect(_toggle_section.bind(name))
	hb.add_child(btn)
	_fold_btns[name] = btn
	bar.add_child(hb)
	# ⚠️ 标题条与内容容器加到 `_body`（不是 `_host`）—— 否则第二段会被塞进第一段里面
	_body.add_child(bar)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.visible = not folded
	_body.add_child(box)
	_sections[name] = box
	_host = box
	return box

## 折叠 / 展开一段。按钮字形跟着状态变（＋ = 折叠中，− = 展开中），
## 然后重新贴合面板高度 —— 位置不动，免得点一下折叠面板就跳走。
func _toggle_section(name: String) -> void:
	var now := not bool(_folded.get(name, false))
	_folded[name] = now
	var box: VBoxContainer = _sections.get(name, null)
	if box != null:
		box.visible = not now
	var btn: Button = _fold_btns.get(name, null)
	if btn != null:
		btn.text = "+" if now else "–"
		btn.tooltip_text = ("展开「%s」" % name) if now else ("折叠「%s」" % name)
	_refit_height()

## 画一行「键 —— 值」。返回那个**值标签**，方便调用方（用工拖动条）原地改它。
func _kv(key: String, value: String, color: Color = UIKit.FG_DARK, tip: String = "") -> Label:
	return _kv_icon(key, value, null, color, tip)

## 一行「键 —— 值」，值左边可以带一个图标（商品图标 / 金币）。
## 图标 24×24、按比例居中 —— 与科技 tooltip 里那套 `_tip_icon_row` 同一口径。
##
## `tip` 非空时整行挂 tooltip（拆解算式之类）。要挂 tip 就得让这一行自己收鼠标事件，
## 否则事件会穿到面板背景上（`_gui_input` 只吃面板范围内的）。
func _kv_icon(key: String, value: String, tex: Texture2D = null,
		color: Color = UIKit.FG_DARK, tip: String = "") -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0, ROW_H)   # 所有行同高（见 ROW_H 的说明）
	if tip != "":
		row.tooltip_text = tip
		row.mouse_filter = Control.MOUSE_FILTER_STOP
	var k := UIKit.label(key, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(k)
	if tex != null:
		var t := TextureRect.new()
		t.texture = tex
		t.custom_minimum_size = Vector2(ROW_ICON, ROW_ICON)
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# 只占 24px 并在行内垂直居中 —— 别让它跟着 26px 的行高拉伸（图标会糊）
		t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(t)
	var v := UIKit.label(value, color)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(v)
	_host.add_child(row)
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
	_host.add_child(pb)

func _gap(h: int = 4) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	_host.add_child(c)

## 「日产量」：每个产出商品一行（`[图标] 数量`），第一行挂 tooltip 写清拆解。
##
## 数量 = 今日计划批数 × 每批产出 × **制造加成** —— 也就是"今天实际能出多少件"；
## 加成单独列在下一行（制造加成 N%），所以看一眼就知道其中多少是加成带来的。
## 批数（`shop.planned`，就是那个会问"1.78 批是什么意思"的数）放在 tooltip 里：
## 它是"跑几遍配方"，玩家要看的是件数，但排查"为什么产量低"时又要看它。
func _daily_output_rows(recipe: Dictionary, planned: float, boost: float) -> void:
	var out: Dictionary = recipe.get("output", {})
	var first := true
	for gid in out.keys():
		var per_batch := float(out[gid])
		if per_batch <= 0.0:
			continue
		var per_day := per_batch * planned * boost
		var tip := ""
		if first:
			tip = "%s：今日计划 %.2f 批 × 每批 %s = %s；再 × 制造加成 %.2f = %s（每天）" % [
				_good_name(String(gid)), planned, _num_text(per_batch),
				_num_text(per_batch * planned), boost, _num_text(per_day)]
		_kv_icon("日产量" if first else "", _num_text(per_day),
			GoodIcons.tex(String(gid)), UIKit.FG_DARK, tip)
		first = false

## 「员工」一行：`姓名 —— 熟练度 62 —— [金币] ¥2.74`。
##
## 工资**不是**本店工资那个标称值：实际发的是 `工资 × (0.5 + 熟练度/100)`（再夹工资上限），
## 所以同一座建筑里熟练度不同的人拿的钱不一样 —— 这也是这一列存在的意义。
## 数值由 `sim.shop_workers()` 给（与 `_pay_wages` 共用同一个函数），面板不自己算。
func _worker_row(rid: String, skill: float, wage: float, wage_cap: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0, ROW_H)   # 与「基础」段的行同高
	var tip := "编号 %s · 工资 = 本店工资 × (0.5 + 熟练度/100)" % rid
	if wage_cap > 0.0:
		tip += "，封顶 ¥%.1f" % wage_cap
	row.tooltip_text = tip
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	var nm := UIKit.label(Names.for_id(rid), UIKit.FG_DARK)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(nm)
	var sk := UIKit.label("熟练度 %d" % int(round(skill)), UIKit.FG_HEAD)
	sk.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sk.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(sk)
	var t := TextureRect.new()
	t.texture = UIKit.stat_icon("money")
	t.custom_minimum_size = Vector2(ROW_ICON, ROW_ICON)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(t)
	var pay := UIKit.label("¥%.2f" % wage)
	pay.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(pay)
	_host.add_child(row)

## 数字文案：整数不带小数点，否则 1 位小数（面板里的产量不需要 2 位）。
func _num_text(v: float) -> String:
	if is_equal_approx(v, round(v)):
		return str(int(round(v)))
	return "%.1f" % v

## 本店配方的产出商品名（查不到就退回 id）。
func _good_name(gid: String) -> String:
	if runner.db.goods.has(gid):
		return String(runner.db.goods[gid].get("nameZh", gid))
	return gid

## 本店的配方（产能建筑没有配方 → 空字典）。
func _recipe_of(def: Dictionary) -> Dictionary:
	var rid := String(def.get("recipe", ""))
	if rid == "":
		return {}
	return runner.db.recipes.get(rid, {})

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
	_host.add_child(row)

## 说明性文字。`wrap=false` 用于**定宽之前就会被量高**的行（建筑面板要按内容自适应高度，
## 而自动换行的 Label 在宽度还是 0 的时候会按"每行一个字"报最小高 —— 面板因此被顶到上限，
## 底部留一大片空白。这几条提示都短，一行放得下，所以直接不换行。
func _label(t: String, size: int = 10, wrap: bool = true) -> Label:
	var l := UIKit.label(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
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
	# 段容器与折叠按钮每次重建都重来一遍（折叠**状态**记在 `_folded` 里，跨重建保留）
	_sections.clear()
	_fold_btns.clear()
	_host = _body
	var tabs := _tabs_of()
	_sync_tabs(tabs["names"])
	match _kind:
		"building":
			if _tab == 1 and int(tabs["kind"]) >= 0:
				_building_queue_panel(int(tabs["kind"]))
			else:
				_building_panel()
		"resident": _resident_panel()
		"housing": _housing_panel()
		_:
			# 没选中任何东西 → 面板整个收起来（见文件头注释：
			# 全局数字顶栏已经全有，不该再占一屏）。
			visible = false
			return
	visible = true

# ---------------------------------------------------------------------------
# 页签（只有产能建筑有第二页）
#
# 用户："点击**建筑工坊**的面板也加这一个 tab"、"在**研究所**的面板加一个 tab，
# 里面是研究队列"。所以这一页不是"另一套面板"，而是同一个共用控件 `queue_box.gd`：
# 建筑工坊看建造队列（`QueueBox.Kind.BUILD`）、研究所看研究队列（`RESEARCH`）。
# ---------------------------------------------------------------------------

## 这一座要不要多一个队列页。返回 `{"names": ["运营", ...], "kind": QueueBox.Kind 或 -1}`。
## 别给普通建筑留一条空页签行 —— 只有一座的页签行整行收起来（见 `_sync_tabs`）。
func _tabs_of() -> Dictionary:
	var plain := {"names": ["运营"], "kind": -1}
	if _kind != "building" or _id == "" or runner == null or runner.sim == null:
		return plain
	var def = null
	for sh in (runner.sim.s["shops"] as Array):
		if String(sh["id"]) == _id:
			def = runner.db.buildings.get(String(sh["defId"]), null)
			break
	if def == null or not (def as Dictionary).has("capacity"):
		return plain
	var k := String((def as Dictionary)["capacity"]["kind"])
	if k == "build":
		return {"names": ["运营", "建造队列"], "kind": QueueBox.Kind.BUILD}
	if k == "research":
		return {"names": ["运营", "研究队列"], "kind": QueueBox.Kind.RESEARCH}
	return plain

## 重画页签行。每次都重建按钮（数量少，不值得做增量），并把当前页的选中态刷上。
func _sync_tabs(names: Array) -> void:
	_tabs = names
	if _tab >= names.size():
		_tab = 0
	for b in _tab_btns:
		if is_instance_valid(b):
			(b as Button).queue_free()
	_tab_btns.clear()
	_tab_row.visible = names.size() > 1
	if not _tab_row.visible:
		return
	for i in names.size():
		var b := UIKit.button(String(names[i]), true)
		b.pressed.connect(_select_tab.bind(i))
		_tab_row.add_child(b)
		_tab_btns.append(b)
	_mark_tabs()

func _mark_tabs() -> void:
	for k in _tab_btns.size():
		(_tab_btns[k] as Button).add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == _tab else UIKit.T_BTN))

## 切页：重画内容 + 重新贴合高度（两页内容高度差很多）。
## 重建会经 `_sync_tabs()` 重画按钮，所以选中态的刷法只有一处。
func _select_tab(i: int) -> void:
	_tab = clampi(i, 0, maxi(0, _tabs.size() - 1))
	_qstate["confirm"] = ""
	UIKit.play_switch()
	_rebuild()
	_refit_height()

## 「建造队列」/「研究队列」页：标题栏还是这座建筑的名字，正文交给共用控件。
func _building_queue_panel(kind: int) -> void:
	var shop = null
	for s in (runner.sim.s["shops"] as Array):
		if String(s["id"]) == _id:
			shop = s
	if shop == null:
		_kind = ""
		visible = false
		return
	var def: Dictionary = runner.db.buildings[String(shop["defId"])]
	_demolish_def_id = String(shop["defId"])
	_title_lb.text = String(def["nameZh"])
	_title("建造队列" if kind == QueueBox.Kind.BUILD else "研究队列")
	var box := QueueBox.new()
	_body.add_child(box)
	box.setup(runner, world, kind, _qstate)

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
	var recipe := _recipe_of(def)
	var planned := float(shop["planned"])
	var boost: Dictionary = runner.sim.shop_output_boost(_id)
	var boost_total := float(boost["total"])

	# ---- 基础：这栋建筑现在是什么状态、今天能出多少 ----
	_section("基础")
	if exp_queued:
		_kv("等级", "Lv%d（升级已排队）" % int(shop["level"]), Color(0.72, 0.35, 0.15))
	else:
		_kv("等级", "Lv%d" % int(shop["level"]))
	var status := "生产中" if active else "已停产"
	var status_color := Color(0.18, 0.45, 0.20) if active else Color(0.60, 0.20, 0.18)
	# 开着工、也有人，却排不出任何批次 → 只可能是上游没料（原料系数被压到 0）。
	# 这条提示是用户问"1.78 批是什么意思"时最需要的那个答案：产量低先看原料。
	if active and not recipe.is_empty() and planned <= 0.0 and assigned > 0:
		status = "生产中（原料不足）"
		status_color = Color(0.72, 0.45, 0.18)
	_kv("状态", status, status_color)
	var worker_hint := _kv("用工", _worker_hint_text(assigned, eff_workers, queued_workers),
		Color(0.72, 0.35, 0.15) if queued_workers else UIKit.FG_DARK)
	if recipe.is_empty():
		# 建筑工坊 / 研究所这类产能建筑：没有配方，日产量与加成都无从谈起
		_kv("产出", "不产商品 · 只提供每日产能")
	else:
		_daily_output_rows(recipe, planned, boost_total)
		_kv("制造加成", "%d%%" % int(round(boost_total * 100.0)), UIKit.FG_DARK,
			"工具 ×%.2f · 本产业科技 ×%.2f（两者相乘，只放大产出、不放大投入）" % [
				float(boost["tool"]), float(boost["tech"])])
		var profit := float(shop["profit"])
		_kv_icon("利润", "¥%.2f" % profit, UIKit.stat_icon("money"),
			Color(0.18, 0.45, 0.20) if profit >= 0.0 else Color(0.60, 0.20, 0.18),
			"按基准价的当日估算：产出 － 投入 － 工资（不含制造加成）")

	# ---- 员工：谁在岗、多熟练、这一天拿多少钱 ----
	_section("员工")
	var workers: Array = runner.sim.shop_workers(_id)
	var wage_cap := float(shop["wageCap"])
	if workers.is_empty():
		_host.add_child(_label("没有工人在岗 → 今日不生产" if not recipe.is_empty()
			else "没有工人在岗", 10, false))
	else:
		for w in workers:
			_worker_row(String(w["id"]), float(w["skill"]), float(w["wage"]), wage_cap)

	# ---- 操作：用工 / 升级 / 移动 / 拆除（都次日 06:00 生效）----
	_section("操作")
	_host.add_child(_label("用工（0 = 停产 · 最多 %d 人）" % slots, 10, false))
	_build_worker_slider(slots, eff_workers, worker_hint, assigned)
	_gap()
	_buttons([["升级" if not exp_queued else "升级（已排队）", func(): _expand(), exp_queued],
		["移动", func(): _begin_move_shop()],
		["拆除", func(): _demolish()]])
	_gap(2)
	# 这一条也**不换行**：它在面板底部、又是自适应高度那次量高会读到的最后一行
	_host.add_child(_label("所有操作次日 06:00 生效" if not (queued_workers or exp_queued)
		else "已排队，次日 06:00 生效", 10, false))

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
	_host.add_child(s)
	# 下面这行让"拖到 0"这件事一眼可见。
	# ⚠️ 必须**不换行**：建筑面板的高度是"内容最小高"算出来的，而自动换行的 Label
	# 在定宽之前（宽度按 1px 算）会报 320px 高 —— 面板当场被顶到高度上限、底部一大片空白。
	_host.add_child(_label("0 = 停产　·　最大 = 满员 %d 个工位" % slots, 10, false))

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

func _upgrade_housing() -> void:
	# 已经排着改建就别再入队（按钮虽然会置灰，但别只靠 UI 拦）—— 和 `_expand()` 同一条规矩。
	var inst = world.housing_instance(_id) if world != null else null
	if inst == null:
		return
	if not world._housing_upgrade_state(inst).is_empty():
		return
	# ⚠️ 带上**这一栋的房号**（`unitId`）：引擎与地图都是按房号认"哪一栋在改建"的
	# （用户 2026-10："你是不是没有给他们 id？" —— 现在有了，就别再靠顺序猜）。
	runner.enqueue([{"type": "upgrade_housing", "goodId": String(inst["type"]),
		"unitId": String(inst["uid"])}])
	_rebuild()

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
	# 改建：茅屋 → 木屋 → 砖房（链由 content 的 `upgradeTo` 决定；别墅不在链里，
	# 所以它没有这一栏 —— 用户："别墅要单独建造"）。见 docs/spec.md §5.4。
	var to_id := String(def.get("upgradeTo", ""))
	if to_id == "" or not runner.db.housing.has(to_id):
		_buttons([["移动", func(): _begin_move_housing()]])
		return
	var to_def: Dictionary = runner.db.housing[to_id]
	var spec: Dictionary = runner.sim._housing_upgrade_spec(def, to_def)
	var parts := []
	for m in (spec["mats"] as Array):
		var gid := String(m[0])
		var nm = String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid
		parts.append("%s %.0f" % [nm, float(m[1])])
	var cost_txt := "不要材料" if parts.is_empty() else "，".join(parts)
	_kv("改建", "→ %s（%s · 建造力 %.0f）" % [String(to_def["nameZh"]), cost_txt, float(spec["work"])])
	var busy: bool = world != null and not world._housing_upgrade_state(inst).is_empty()
	# 目标房型没解锁时也置灰：不拦的话玩家点完只会等到次日黎明才收到一句拒绝
	# （`build_housing` 也是这条规矩，见 actions.ts）。
	var locked: bool = not runner.sim.is_housing_unlocked(to_id)
	if locked:
		var tname := to_id
		for tid in runner.db.tech_ids:
			if (runner.db.techs[tid]["unlocks"]["housing"] as Array).has(to_id):
				tname = String(runner.db.techs[tid]["nameZh"])
		_body.add_child(_label("需要先研究「%s」才能改建" % tname))
	elif bool(inst["private"]):
		_body.add_child(_label("私有住房不能改建（居民买下的私产）"))
	elif busy:
		_body.add_child(_label("已经在改建中（或已下单，次日 06:00 生效）"))
	_gap()
	_buttons([
		["移动", func(): _begin_move_housing()],
		["改建为%s" % String(to_def["nameZh"]), func(): _upgrade_housing(), locked or bool(inst["private"]) or busy],
	])

func _set_population_cap(value: int) -> void:
	runner.enqueue([{"type": "set_population_cap", "value": value}])
	# 必须立刻重建：命令排到次日 06:00 才生效，不重建的话点完屏幕上
	# 一点变化都没有，看起来就像按钮没反应。
	_rebuild()
