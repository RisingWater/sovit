extends PanelContainer

# 统计面板：资源 / 人口 / 财务 三个 Tab。
#
# 取数全部是仿真层的**权威记录**，面板不重算任何公式：
#   GameStats 每过一个游戏日采样，数值取自 DaySnapshot.ledger（当日实际流量）
#   与 resident.account（逐人账目）。
#   只有"工坊数 / 工位 / 工人"是结构性数据，由 shops 现算。

var runner: SimRunner
var world: Node
var stats: GameStats

const TABS := ["资源", "人口", "财务"]
## 页签 -> 图标 id（assets/ui/panel/）
const TAB_ICONS := {"资源": "resource", "人口": "population", "财务": "finance"}
## 页签 -> 右下角那张立绘（七人顾问团：资源=老臣、人口=露娜、财务=薇拉）
const TAB_PORTRAIT := ["sebastian", "luna", "vera"]
## 立绘占的宽度：高 = 面板高的一半，宽按 2:3 的原图比例 —— 900 高的窗口下约 280。
## 内容侧要在这条线之前收住，否则数字会跑到脸上去。
const PORTRAIT_GAP := 292.0

## 表头颜色：必须用深色。UIKit.FG_LABEL 是浅米色，那是给深色 section 条用的，
## 印在米黄面板上完全看不见。
const HEAD_COL := Color(0.52, 0.31, 0.16)

var _tab := 0
var _tab_btns: Array[Button] = []
var _body: VBoxContainer
var _scroll_root: ScrollContainer
var _portrait: PanelPortrait
var _sel_good := ""
var _sel_resident := ""
## 布局还没算完时最多推迟几帧再取高度（见 `_sync_body_height()`）
var _height_retry := 0

func setup(r: SimRunner, w: Node, st: GameStats) -> void:
	runner = r
	world = w
	stats = st

func _ready() -> void:
	# **全屏最大化**（用户要求）：顶栏保留，其余全被盖住 —— 地图、左侧圆钮、
	# 底部建造栏都看不见了。**不可拖动**（原来是浮框 + 拖动把手 + 记住位置）。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_right = 0.0
	offset_top = float(UIKit.BAR_H)
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 14, 10, 14, 10))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 5)
	add_child(root)

	# 标题行：标题 + 页签 + 撑开 + 关闭。不再有拖动把手。
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	root.add_child(head)
	var title := UIKit.label("统计", UIKit.FG_HEAD)
	title.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(title)
	for i in TABS.size():
		var b := UIKit.button(TABS[i], true)
		# 三个页签都给图标（作者 workbuddy，MIT）。只给一个的话，
		# 三个并排的页签里只有一个带图，看着像漏做了。
		var ico := UIKit.panel_icon(TAB_ICONS.get(TABS[i], ""))
		if ico != null:
			b.icon = ico
			b.add_theme_constant_override("icon_max_width", UIKit.PANEL_ICON_BTN)
			# ⚠️ 这里**不能**设 icon_alignment。带文字的按钮里，icon_alignment=CENTER
			# 会让图标自己居中、直接压在文字上（"资源/人口/财务"就是这么重叠的）。
			# 默认的左对齐才是"图标在左、文字在右"。
			# （左侧圆钮那四个**没有文字**，那边设 CENTER 是对的。）
		b.pressed.connect(_select_tab.bind(i))
		head.add_child(b)
		_tab_btns.append(b)
	# Tab 右边撑开，把「关闭」推到最右（原来那条是拖动把手，已删）
	head.add_child(UIKit.spacer())
	var close := UIKit.button("关闭", true)
	close.tooltip_text = "回到地图（Esc 也行）"
	close.pressed.connect(func(): visible = false)
	head.add_child(close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_scroll_root = scroll
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	scroll.add_child(_body)
	# 窗口缩放 / 面板重排之后也要重新量一次（否则下限还是旧视口的高度）
	scroll.resized.connect(_sync_body_height)

	# 右下角的顾问立绘（用户 2026-10）。**最后加** = 画在最上层 —— 见 panel_portrait.gd。
	_portrait = PanelPortrait.new()
	_portrait.name = "Portrait"
	add_child(_portrait)

	visible = false
	visibility_changed.connect(_on_visibility_changed)
	_select_tab(0)

func open() -> void:
	# 全屏面板必须**盖住小地图和左侧圆钮**：它们是 root_ui 里更晚加进去的兄弟节点，
	# 不 move_to_front 的话会浮在面板上面、把标题栏压住（实测就是这样）。
	move_to_front()
	visible = true
	refresh()
	_say_hi()

## 打开并直接切到某个页签（顶栏左侧的圆钮用：资源 / 人口 / 财政）。
func open_tab(i: int) -> void:
	move_to_front()
	visible = true
	# `_select_tab` 里会说话（visible 已经是 true），不用再补一次
	_select_tab(clampi(i, 0, TABS.size() - 1))

## 右下角那位冒一句话（用户 2026-10）。每次**打开**才说，切页签 / 刷新数据都不重说。
func _say_hi() -> void:
	if _portrait != null:
		_portrait.speak()

# ---------------------------------------------------------------------------
# 打开时**隐藏地图那一侧**的常驻件（小地图 + 左侧圆钮）
#
# 用户："你没有隐藏地图，所以全屏的 panel 出来的时候左上角很奇怪"。
# 光靠面板盖住不够：小地图本来就压在顶栏下沿（它的上沿在 y≈40），面板从 y=58
# 铺下来，于是小地图被**切成半个**卡在左上角 —— 上面一截露在顶栏里，
# 下面一截被面板挡住。真隐藏掉才干净。
#
# 用 `visibility_changed` 而不是在每个 open()/close 里手写：任何地方改 visible
# （包括 main 里 Esc 关面板、按钮回调）都会走到这里。
# ---------------------------------------------------------------------------
func _on_visibility_changed() -> void:
	UIKit.show_map_chrome(self, not UIKit.any_panel_open(self, visible))
	# 刚变可见时容器还没排版，`_scroll_root.size` 还是 0 —— 推迟一帧再量高度
	# （否则页面下半截会空着，见 `_sync_body_height()`）
	if visible:
		call_deferred("_sync_body_height")

func _select_tab(i: int) -> void:
	_tab = i
	UIKit.play_switch()
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == i else UIKit.T_BTN))
	if _portrait != null:
		_portrait.setup(String(TAB_PORTRAIT[clampi(i, 0, TAB_PORTRAIT.size() - 1)]), runner.sim)
	refresh()
	# 切页签 = 换人，让新的那位也说一句（`_ready` 里那次 visible 还是 false，不会说）。
	if visible:
		_say_hi()

## 面板范围内的鼠标事件一律吃掉。
##
## ScrollContainer 只在自己**真的滚动了**的时候才 accept_event()；滚到顶/底之后
## 它不再接受，事件就会漏到 _unhandled_input，于是滚列表把外面的地图也缩放了。
## 这里兜底：任何落到面板上的鼠标事件都标记为已处理。
## （world_view 那边还有一层"悬停在 UI 上就不碰镜头"的守卫。）
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()

# 面板是**全屏、不可移动**的（用户要求），所以原来那套"拖动把手 + 位置夹取 +
# 存到 user://hud.cfg"的代码整段删掉了 —— 留着只会有个永远读不到的配置项。

func refresh() -> void:
	if _body == null or runner == null or runner.sim == null or stats == null:
		return
	for c in _body.get_children():
		c.queue_free()
	match _tab:
		0: _resources_tab()
		1: _people_tab()
		_: _finance_tab()
	_sync_body_height()

## `ScrollContainer` 只按**最小高度**摆子节点 —— 不给 `_body` 一个下限，内容就停在
## 面板上半截，下面空一大片（用户 2026-10 在资源页 / 人口页各圈出一块，之后**又犯一次**）。
##
## ⚠️ 这个下限必须**等布局算完**再取 `_scroll_root.size`：面板刚 `visible = true` 的那一帧，
## 容器还没排（size 还是 0），照旧写法取到 0 → 高度根本没设上 → 下面空一片；而且只有
## "下次有人刷新"才会自己好 —— 新开一局、面板开着、又没在跑时间的时候就一直空着
## （用户圈出来的就是这张：工坊数 0 / 在岗 0 的新局）。
## 所以：拿不到有效高度就 `call_deferred` 等下一帧再来；另外窗口缩放（`resized`）
## 与面板重新可见时也各补一次。
func _sync_body_height() -> void:
	if _body == null or _scroll_root == null:
		return
	var h := _scroll_root.size.y
	if h <= 4.0:
		# 还没排过版：下一帧再来（只有可见时才有意义；隐藏着等 open() 那次刷新）
		if visible and _height_retry < 60:
			_height_retry += 1
			call_deferred("_sync_body_height")
		return
	_height_retry = 0
	_body.custom_minimum_size.y = h - 2.0

# ---------------------------------------------------------------------------
# 通用小件
# ---------------------------------------------------------------------------
func _section(t: String) -> void:
	_section_in(_body, t)

func _note(t: String) -> void:
	_note_in(_body, t)

## 这两个 `*_in` 版本是给"右栏详情"用的：内容和左栏共用一个 `_body` 之外的容器
## （居民详情现在固定在右侧一栏里，不再 append 到整页最后）。
func _section_in(parent: Control, t: String) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(t, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	parent.add_child(p)

func _note_in(parent: Control, t: String) -> void:
	var l := UIKit.label(t, Color(0.55, 0.42, 0.30))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)

func _chart(title: String, s: Array, zero := false, fmt := "%.0f", h := 84) -> void:
	var c := Chart.new()
	c.custom_minimum_size = Vector2(0, h)
	c.set_data(title, s, zero, fmt)
	_body.add_child(c)

func _grid(cols: int) -> GridContainer:
	return _grid_in(_body, cols)

func _grid_in(parent: Control, cols: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 1)
	parent.add_child(g)
	return g

## 表格单元格。
## 数值和正文**同字号**（12）—— 2026-10 试过给数字单独放大到 18，用户看完否了
## （"算了，数字改回来吧，不好看"），见 `UIKit.label()` 上面的注释。
##
## `right = true` 表示这一格是**值**：右对齐。
## ⚠️ 别给它加 `SIZE_EXPAND_FILL`：`GridContainer` 会把多余宽度全分给带 EXPAND 的列，
##    标签和值之间就会被拉开半个屏幕（2026-10 试过，很丑）。列宽按内容定、
##    值在自己的列里右对齐，两个值列的右边缘各自对齐，就够了。
func _cell(g: GridContainer, text: String, color: Color, min_w := 0.0, right := false) -> Label:
	var l := UIKit.label(text, color)
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, 0)
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	g.add_child(l)
	return l

func _good_name(gid: String) -> String:
	return String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid

# ---------------------------------------------------------------------------
# 资源
# ---------------------------------------------------------------------------
func _resources_tab() -> void:
	var s: Dictionary = runner.sim.s
	var pack: Array = runner.db.packs[String(s["pack"])]["goods"]
	# 默认选中第一个，打开就有内容可看，不用先点一下
	if _sel_good == "" and not pack.is_empty():
		_sel_good = String(pack[0])

	# 用户 2026-10：这一页**不要**「全局统计」那一段（人口/就业折线 + 口径说明），
	# 也不要在详情里放「库存 / 日产」两张折线 —— 一页只要"资源清单 + 单项数据"。
	# 主从布局：左列表 + 右详情。不做一览表 —— 一屏 9 列挤在一起既难读也看不清重点。
	# 高度靠 `refresh()` 里给 `_body` 的下限撑满（见那里的注释），这里不用再算。
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 10)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.custom_minimum_size = Vector2(0, 360)
	_body.add_child(split)

	# ---- 左：资源列表
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(296, 0)
	left.add_theme_constant_override("separation", 4)
	split.add_child(left)
	var lhead := UIKit.panel(true)
	var lh := UIKit.label("资源", UIKit.FG_LABEL)
	lh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lhead.add_child(lh)
	left.add_child(lhead)
	var lscroll := ScrollContainer.new()
	lscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lscroll.custom_minimum_size = Vector2(0, 470)
	lscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(lscroll)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.add_theme_constant_override("separation", 2)
	lscroll.add_child(lv)
	for gid in pack:
		var gid2 := String(gid)
		if not runner.db.goods.has(gid2):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		var ic := TextureRect.new()
		ic.texture = GoodIcons.tex(gid2)
		ic.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		# 手绘图标是 64×64（v7），这里是 32 的位子 → 必须按比例缩，不能 KEEP_CENTERED
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(ic)
		var nb := UIKit.button(_good_name(gid2), true)
		nb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		nb.tooltip_text = "点击查看「%s」的详细数据" % _good_name(gid2)
		if gid2 == _sel_good:
			nb.add_theme_stylebox_override("normal", UIKit.box(UIKit.T_BTN_ACTIVE))
			nb.add_theme_color_override("font_color", UIKit.FG_LIGHT)
		nb.pressed.connect(_on_pick_good.bind(gid2))
		row.add_child(nb)
		var st := UIKit.label("%.0f" % float(stats.good_row(gid2)["stock"]),
			Color(0.62, 0.48, 0.34))
		st.custom_minimum_size = Vector2(44, 0)
		st.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(st)
		var pad := Control.new()          # 给纵向滚动条留位置，否则数字被压住
		pad.custom_minimum_size = Vector2(12, 0)
		row.add_child(pad)
		lv.add_child(row)

	# ---- 右：详情
	# 详情列**撑开**，右边缘停在立绘的左边（用户 2026-10："净变化/日那列，为什么在中间
	# 没有靠右侧？"）—— 所以是 `EXPAND_FILL` + 右边一个**固定宽度**的空隙，
	# 不是"详情固定 640、空隙去撑开"（那样数字会停在屏幕中间）。
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)
	_good_detail(right)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(PORTRAIT_GAP, 0)
	split.add_child(gap)

## 右侧详情：图标 + 名称 + 大字数据 + 曲线
func _good_detail(right: VBoxContainer) -> void:
	if _sel_good == "":
		var hint := UIKit.label("← 从左边选一个资源", UIKit.FG_HEAD)
		right.add_child(hint)
		return
	var gd: Dictionary = runner.db.goods.get(_sel_good, {})
	var r := stats.good_row(_sel_good)
	var net := float(r["produced"]) - float(r["consumed_ind"]) - float(r["consumed_pop"])

	# 图标 + 名称 + 净额
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var ic := TextureRect.new()
	ic.texture = GoodIcons.tex(_sel_good)
	ic.custom_minimum_size = Vector2(48, 48)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(ic)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	var nm := _big(_good_name(_sel_good))
	col.add_child(nm)
	# 中文类别（内部键是英文，直接印出来会变成「raw」这种）
	var sub := UIKit.label(runner.db.category_zh(String(gd.get("category", ""))), Color(0.62, 0.48, 0.34))
	col.add_child(sub)
	head.add_child(col)
	head.add_child(UIKit.spacer())
	var netcol := VBoxContainer.new()
	netcol.add_theme_constant_override("separation", 0)
	var nl := UIKit.label("净变化 / 日", HEAD_COL)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	netcol.add_child(nl)
	var nv := _big("%+.1f" % net,
		Color(0.18, 0.45, 0.20) if net >= 0.0 else Color(0.65, 0.22, 0.18))
	nv.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	netcol.add_child(nv)
	head.add_child(netcol)
	right.add_child(head)
	right.add_child(UIKit.hsep())

	# 大字数据
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 16)
	g.add_theme_constant_override("v_separation", 4)
	right.add_child(g)
	var rows := [
		["库存", "%.0f" % float(r["stock"]), UIKit.FG_DARK],
		["日产量", "%.1f" % float(r["produced"]), Color(0.18, 0.42, 0.24)],
		["工业消耗 / 日", "%.1f" % float(r["consumed_ind"]), Color(0.55, 0.30, 0.18)],
		["居民消耗 / 日", "%.1f" % float(r["consumed_pop"]), Color(0.55, 0.30, 0.18)],
		["工坊数", "%d" % int(r["shops"]), UIKit.FG_DARK],
		["工位总数", "%d" % int(r["slots"]), UIKit.FG_DARK],
		["在岗工人", "%d" % int(r["workers"]), UIKit.FG_DARK],
	]
	# 「工业消耗 / 居民消耗」两行带悬停明细（用户 2026-10）：
	#   工业消耗 → 哪类建筑各吃掉多少（面包房 ×3　12.0）
	#   居民消耗 → 哪一等居民各买走多少（中产 ×11　8.0）
	# 数字来自台账的拆分表，`GameStats` 只排序拼字，不重算公式。
	for i in rows.size():
		var row: Array = rows[i]
		var tip := ""
		if i == 2:
			tip = stats.industrial_tip(_sel_good)
		elif i == 3:
			tip = stats.resident_tip(_sel_good)
		var kl := UIKit.label(String(row[0]), HEAD_COL)
		kl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		if tip != "":
			kl.tooltip_text = tip
			# ⚠️ `Label` 默认 `mouse_filter = IGNORE`（实测：Label=2 / Button=0）——
			# 光设 `tooltip_text` 是**永远不会弹**的：鼠标根本落不到这个控件上。
			# 用户 2026-10："鼠标移上去没有反应" 就是这个。
			# 这里这两行本来就是只读的，吞掉鼠标没有副作用；顺带把光标换成"可查看"。
			kl.mouse_filter = Control.MOUSE_FILTER_STOP
			kl.mouse_default_cursor_shape = Control.CURSOR_HELP
		g.add_child(kl)
		var vl := _big(String(row[1]), row[2])
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if tip != "":
			vl.tooltip_text = tip
			vl.mouse_filter = Control.MOUSE_FILTER_STOP
			vl.mouse_default_cursor_shape = Control.CURSOR_HELP
		g.add_child(vl)

## 大字（12px 像素字体的整数 2 倍）
func _big(t: String, col: Color = UIKit.FG_DARK) -> Label:
	var l := UIKit.label(t, col)
	l.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	return l

func _on_pick_good(gid: String) -> void:
	_sel_good = gid
	refresh()

# ---------------------------------------------------------------------------
# 人口
# ---------------------------------------------------------------------------
## 两张折线**并排、各占一半宽**（用户 2026-10）。
## Chart 是自绘控件（`_draw()` 按自己的 size 画），所以放进 HBox 里给
## `SIZE_EXPAND_FILL` 就各分一半 —— 不能再用 `_chart()` 那种直接塞进 `_body` 的写法。
func _chart_pair(a: Array, b: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_body.add_child(row)
	for spec in [a, b]:
		var c := Chart.new()
		c.custom_minimum_size = Vector2(120, 96)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.set_data(String(spec[0]), spec[1], bool(spec[2]), String(spec[3]))
		row.add_child(c)

func _people_tab() -> void:
	var s: Dictionary = runner.sim.s
	_section("人口 / 满意度 / 饥饿")
	_chart_pair(
		["人口", [{"name": "人口", "color": Color(0.45, 0.72, 0.95),
			"values": stats.population, "fill": true}], false, "%.0f"],
		["满意度 / 饥饿", [
			{"name": "满意", "color": Color(0.40, 0.75, 0.45), "values": stats.satisfaction},
			{"name": "饥饿", "color": Color(0.85, 0.45, 0.35), "values": stats.hungry},
		], false, "%.1f"])

	_section("就业与岗位")
	var employed := 0
	var total_slots := 0
	var total_workers := 0
	for shop in s["shops"]:
		var did := String(shop["defId"])
		if runner.db.buildings.has(did):
			total_slots += int(runner.db.buildings[did]["maxWorkers"])
			total_workers += int(shop["targetWorkers"])
	for r in s["residents"]:
		if bool(r["employed"]):
			employed += 1
	var g := _grid(4)
	# ⚠️ 表头也要**右对齐**、并且和数值同宽 —— 原来表头左对齐、数字右对齐，
	# 于是数字永远缩在列的另一头（用户："数值和实际数字没有对齐"）。
	for h in ["口径", "数值", "口径", "数值"]:
		var i := g.get_child_count()
		var right := i % 2 == 1
		_cell(g, h, HEAD_COL, 90.0 if not right else 60.0, right)
	_cell(g, "人口", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % (s["residents"] as Array).size(), UIKit.FG_DARK, 60.0, true)
	_cell(g, "就业", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % employed, UIKit.FG_DARK, 60.0, true)
	_cell(g, "岗位总量", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % total_slots, UIKit.FG_DARK, 60.0, true)
	_cell(g, "用工目标", UIKit.FG_HEAD, 90.0); _cell(g, "%d" % total_workers, UIKit.FG_DARK, 60.0, true)

	# 教育（用户 2026-10 · A3）：满足率 → 熟练度成长倍率 → 在校人数。
	# 三个数都从引擎读，面板**不自己算**（倍率的唯一实现是
	# `SimCore.education_growth_multiplier()`，与 TS `labor.ts` 同一条公式）。
	_section("教育")
	var ge := _grid(4)
	for h in ["口径", "数值", "口径", "数值"]:
		var ie := ge.get_child_count()
		var righte: bool = ie % 2 == 1
		_cell(ge, h, HEAD_COL, 90.0 if not righte else 60.0, righte)
	var sim = runner.sim
	var schools := 0
	for shop2 in s["shops"]:
		if String(shop2["defId"]) == "school":
			schools += 1
	_cell(ge, "教育满足率", UIKit.FG_HEAD, 90.0)
	_cell(ge, "%.0f%%" % (sim.education_score() * 100.0), UIKit.FG_DARK, 60.0, true)
	_cell(ge, "熟练度成长", UIKit.FG_HEAD, 90.0)
	_cell(ge, "×%.2f" % sim.education_growth_multiplier(), UIKit.FG_DARK, 60.0, true)
	_cell(ge, "在校人数", UIKit.FG_HEAD, 90.0)
	_cell(ge, "%d" % sim.covered_people("education"), UIKit.FG_DARK, 60.0, true)
	_cell(ge, "学校", UIKit.FG_HEAD, 90.0)
	_cell(ge, "%d 座" % schools, UIKit.FG_DARK, 60.0, true)
	# ⚠️ 这里原本还有一句提示"还没有学校 —— 教育满足率会一直是 0…"，
	# 用户 2026-10 让删掉（"学校的话删掉"）：上面那两个 0 已经把话说完了，再补一句是噪音。

	# 左：名单；右：详情。
	# 用户 2026-10："点名字看详情好像并没有实现，是不是弹到后面去了？"
	# —— 就是弹到后面去了：原来那段是 append 在**整页最后**的，人多的时候
	# 点了名字什么也看不见。现在固定占右边一栏，永远在同一屏里。
	_section("居民（点名字看详情）")
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 10)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(split)

	var lscroll := ScrollContainer.new()
	# 名单给个固定宽度（六列加起来 ~480），剩下的位置让给右边的详情 ——
	# 不然列表撑满之后，详情被推到屏幕中间，中间空出一大片。
	lscroll.size_flags_horizontal = Control.SIZE_FILL
	lscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lscroll.custom_minimum_size = Vector2(560, 420)
	lscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(lscroll)
	var gg := GridContainer.new()
	gg.columns = 6
	gg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gg.add_theme_constant_override("h_separation", 10)
	gg.add_theme_constant_override("v_separation", 1)
	lscroll.add_child(gg)
	for h in ["姓名", "阶层", "住房", "工作", "熟练", "满意"]:
		# 用户 2026-10："中文也右对齐，现在中文左对齐、数字右对齐很丑" ——
		# 六列**全部右对齐**（表头跟着一起），整张表只有一个右边线。
		var numeric: bool = h == "熟练" or h == "满意"
		_cell(gg, h, HEAD_COL, 56.0 if numeric else 76.0, true)
	var shops_by_id := {}
	for shop in s["shops"]:
		shops_by_id[String(shop["id"])] = shop
	var rows := 0
	for r in s["residents"]:
		rows += 1
		if rows > 60:
			break
		var rid := String(r["id"])
		var job := "无业"
		var js = r.get("jobShopId", null)
		if js != null and shops_by_id.has(String(js)):
			job = String(runner.db.buildings.get(String(shops_by_id[String(js)]["defId"]), {}).get("nameZh", "?"))
		var tenure := "国有"
		if bool(r.get("homeowner", false)):
			tenure = "自有"
		elif bool(r.get("privateTenant", false)):
			tenure = "私租"
		var b := UIKit.button(Names.for_id(rid), true)
		b.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.custom_minimum_size = Vector2(76, 0)
		if rid == _sel_resident:
			b.add_theme_stylebox_override("normal", UIKit.box(UIKit.T_BTN_ACTIVE))
			b.add_theme_color_override("font_color", UIKit.FG_LIGHT)
		b.pressed.connect(_on_pick_resident.bind(rid))
		gg.add_child(b)
		_cell(gg, _class_name_zh(String(r["classId"])), UIKit.FG_DARK, 76.0, true)
		_cell(gg, "%s·%s" % [tenure, _house_name(int(r.get("housingQuality", 0)))],
			UIKit.FG_DARK, 76.0, true)
		_cell(gg, job, UIKit.FG_DARK, 76.0, true)
		_cell(gg, "%.0f" % float(r["skill"]), UIKit.FG_DARK, 56.0, true)
		_cell(gg, "%.0f" % float(r["satisfaction"]), UIKit.FG_DARK, 56.0, true)
	if rows >= 60:
		_note("（只列出前 60 位）")

	var dscroll := ScrollContainer.new()
	dscroll.custom_minimum_size = Vector2(420, 420)
	dscroll.size_flags_horizontal = Control.SIZE_FILL
	dscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(dscroll)
	# 右下角要让位给立绘
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.custom_minimum_size = Vector2(PORTRAIT_GAP - 120.0, 0)
	split.add_child(gap)
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 4)
	dscroll.add_child(detail)
	if _sel_resident == "":
		_note_in(detail, "← 点左边的名字，这里显示他的账目。")
	else:
		_resident_detail(detail, _sel_resident, s)

## 阶层的中文名（内容里就叫「穷人 / 中产 / 富人 / 老板」）。
## 用户 2026-10："阶层、不要用英文" —— 面板上原来直接印的是 classId（poor/rich…）。
func _class_name_zh(cid: String) -> String:
	if runner.db.classes.has(cid):
		return String((runner.db.classes[cid] as Dictionary).get("nameZh", cid))
	return cid

## 住房等级 -> 名字。
## 用户 2026-10："住房不要用 Lv1（茅屋、木屋、砖房、别墅）"。
## 名字从 `content/housing.json` 的 `quality` 反查（加一座新房不用改这里）；
## 查不到的（比如还没实装的别墅）退回一张写死的表。
func _house_name(q: int) -> String:
	if q <= 0:
		return "无房"
	for id in runner.db.housing:
		var hd: Dictionary = runner.db.housing[id]
		if int(hd.get("quality", -1)) == q:
			return String(hd.get("nameZh", id))
	return String({1: "茅屋", 2: "木屋", 3: "砖房", 4: "别墅"}.get(q, "住房 %d" % q))

func _on_pick_resident(rid: String) -> void:
	_sel_resident = rid
	refresh()

func _resident_detail(pane: VBoxContainer, rid: String, s: Dictionary) -> void:
	var r = null
	for x in s["residents"]:
		if String(x["id"]) == rid:
			r = x
			break
	if r == null:
		return
	# ⚠️ **不画「居民 XXX」那行标题**（用户 2026-10："选择人之后，居民xx这一行去掉"）——
	# 名字在左边那张表里已经高亮着了，右栏直接从数据开始。
	var job := "无业"
	var js = r.get("jobShopId", null)
	if js != null:
		for shop in s["shops"]:
			if String(shop["id"]) == String(js):
				job = String(runner.db.buildings.get(String(shop["defId"]), {}).get("nameZh", "?"))
				break
	var tenure := "国有租住"
	if bool(r.get("homeowner", false)):
		tenure = "自有住房"
	elif bool(r.get("privateTenant", false)):
		tenure = "私租"
	var g := _grid_in(pane, 4)
	# ⚠️ **每一格的值都要右对齐**（用户 2026-10 圈出：阶层 / 住房 / 工作 / 今日饥饿 那几个值
	# 是左对齐的，跟旁边的数字参差不齐）。标签列左对齐、值列右对齐 + EXPAND，两列值的右边缘
	# 才各自对得齐。
	_cell(g, "阶层", UIKit.FG_HEAD, 82.0)
	_cell(g, _class_name_zh(String(r["classId"])), UIKit.FG_DARK, 82.0, true)
	_cell(g, "熟练度", UIKit.FG_HEAD, 82.0)
	_cell(g, "%.1f" % float(r["skill"]), UIKit.FG_DARK, 82.0, true)
	_cell(g, "满意度", UIKit.FG_HEAD, 82.0)
	_cell(g, "%.1f" % float(r["satisfaction"]), UIKit.FG_DARK, 82.0, true)
	_cell(g, "存款", UIKit.FG_HEAD, 82.0)
	_cell(g, "¥%.1f" % float(r["savings"]), UIKit.FG_DARK, 82.0, true)
	_cell(g, "住房", UIKit.FG_HEAD, 82.0)
	_cell(g, "%s·%s" % [tenure, _house_name(int(r.get("housingQuality", 0)))], UIKit.FG_DARK, 82.0, true)
	_cell(g, "工作", UIKit.FG_HEAD, 82.0)
	_cell(g, job, UIKit.FG_DARK, 82.0, true)
	# 以下全部读仿真层记录的**个人账目**（resident.account），不是面板重算的
	var acc: Dictionary = r.get("account", {})
	if acc.is_empty():
		_note_in(pane, "该居民尚无账目（账目在每个游戏日夜间结算时写入）。")
		return
	var is_hungry := bool(acc.get("hungry", false))
	_cell(g, "今日饥饿", UIKit.FG_HEAD, 82.0)
	_cell(g, "是" if is_hungry else "否",
		Color(0.72, 0.22, 0.18) if is_hungry else Color(0.18, 0.45, 0.20), 82.0, true)
	_cell(g, "食物满足", UIKit.FG_HEAD, 82.0)
	_cell(g, "%.0f%%" % (float(acc.get("foodScore", 1.0)) * 100.0),
		Color(0.72, 0.22, 0.18) if is_hungry else UIKit.FG_DARK, 82.0, true)
	_cell(g, "舒适满足", UIKit.FG_HEAD, 82.0)
	_cell(g, "%.0f%%" % (float(acc.get("comfortScore", 1.0)) * 100.0), UIKit.FG_DARK, 82.0, true)
	_cell(g, "价格满意", UIKit.FG_HEAD, 82.0)
	_cell(g, "%.0f%%" % (float(acc.get("priceScore", 1.0)) * 100.0), UIKit.FG_DARK, 82.0, true)
	_cell(g, "今日工资", UIKit.FG_HEAD, 82.0)
	_cell(g, "¥%.2f" % float(acc.get("wage", 0.0)), UIKit.FG_DARK, 82.0, true)
	_cell(g, "今日所得税", UIKit.FG_HEAD, 82.0)
	_cell(g, "¥%.2f" % float(acc.get("tax", 0.0)), UIKit.FG_DARK, 82.0, true)
	_cell(g, "今日租金", UIKit.FG_HEAD, 82.0)
	_cell(g, "¥%.2f" % float(acc.get("rent", 0.0)), UIKit.FG_DARK, 82.0, true)
	_cell(g, "今日消费", UIKit.FG_HEAD, 82.0)
	_cell(g, "¥%.2f" % float(acc.get("spent", 0.0)), UIKit.FG_DARK, 82.0, true)
	var net := float(acc.get("wage", 0.0)) - float(acc.get("tax", 0.0)) - float(acc.get("rent", 0.0)) - float(acc.get("spent", 0.0))
	_cell(g, "今日净额", UIKit.FG_HEAD, 82.0)
	_cell(g, "¥%+.2f" % net,
		Color(0.18, 0.45, 0.20) if net >= 0.0 else Color(0.65, 0.22, 0.18), 82.0, true)

	# 逐人每日消耗（bought）：目前按阶层均分，所以同阶层人人相同
	var bought: Dictionary = acc.get("bought", {})
	pane.add_child(UIKit.hsep())
	pane.add_child(UIKit.label("今日消耗（逐人记录）", UIKit.FG_HEAD))
	if bought.is_empty():
		_note_in(pane, "今日未购买任何商品。")
	else:
		var gb := _grid_in(pane, 4)
		# 表头 4 格，**对齐方式与下面数据行一致**（数量右对齐）——
		# 用户 2026-10 圈出的"数量 → 数量"就是这里：第一组"数量"是左对齐、第二组是右对齐，
		# 一行表头自己先歪了。
		_cell(gb, "商品", HEAD_COL, 96.0)
		_cell(gb, "数量", HEAD_COL, 60.0, true)
		_cell(gb, "商品", HEAD_COL, 96.0)
		_cell(gb, "数量", HEAD_COL, 60.0, true)
		var keys: Array = bought.keys()
		keys.sort()
		for k in keys:
			var gid := String(k)
			_cell(gb, _good_name(gid), UIKit.FG_HEAD, 96.0)
			_cell(gb, "%.2f" % float(bought[gid]), UIKit.FG_DARK, 60.0, true)

# ---------------------------------------------------------------------------
# 财务
# ---------------------------------------------------------------------------
func _finance_tab() -> void:
	var s: Dictionary = runner.sim.s
	_section("国库")
	var g := _grid(4)
	_cell(g, "当前余额", UIKit.FG_HEAD, 90.0)
	_cell(g, "¥%.0f" % float(s["government"]["money"]), UIKit.FG_DARK, 90.0, true)
	_cell(g, "7 日均净收支", UIKit.FG_HEAD, 90.0)
	var net7 := stats.avg(stats.money_flow, 7)
	_cell(g, "¥%+.0f / 日" % net7,
		Color(0.18, 0.45, 0.20) if net7 >= 0.0 else Color(0.65, 0.22, 0.18), 90.0, true)
	_chart("国库余额", [{"name": "国库", "color": Color(0.90, 0.78, 0.40),
		"values": stats.money, "fill": true}])
	_chart("日净收支", [{"name": "净额", "color": Color(0.55, 0.80, 0.95),
		"values": stats.money_flow}], true)

	_section("收支分项（7 日均值）")
	var g2 := _grid(4)
	# 数字列的表头**也右对齐**（和值同宽）—— 用户 2026-10："有数字的都没有和表头对齐"。
	_cell(g2, "项目", HEAD_COL, 80.0)
	_cell(g2, "7 日均", HEAD_COL, 80.0, true)
	_cell(g2, "口径", HEAD_COL, 60.0)
	_cell(g2, "说明", HEAD_COL, 0.0)
	var items := [
		["工资支出", stats.avg(stats.wages), "公式", "Σ 居民 gross（工资×技能系数，封顶）"],
		["所得税", stats.avg(stats.tax), "公式", "累进税表套在 gross 上"],
		["租金收入", stats.avg(stats.rent), "公式", "国有租户实缴 + 私租抽税"],
		["消费收入", stats.avg(stats.sales), "实际", "居民购买回款（读台账）"],
		["建造支出", stats.avg(stats.build_cost), "实际", "在建项目的建造成本合计"],
	]
	for it in items:
		_cell(g2, String(it[0]), UIKit.FG_HEAD, 80.0)
		_cell(g2, "¥%.1f" % float(it[1]), UIKit.FG_DARK, 80.0, true)
		_cell(g2, String(it[2]), Color(0.55, 0.42, 0.30), 60.0)
		_cell(g2, String(it[3]), Color(0.55, 0.42, 0.30), 0.0)

	# 公共事业补贴（2026-10）：公共建筑当晚的工资支出，台账口径（国库本来就付了这笔钱）
	var subsidy := float((s.get("ledgerToday", {}) as Dictionary).get("publicSubsidy", 0.0))
	_section("公共事业（今日台账）")
	var gs := _grid(3)
	_cell(gs, "项目", HEAD_COL, 110.0)
	_cell(gs, "今日", HEAD_COL, 90.0, true)
	_cell(gs, "说明", HEAD_COL, 0.0)
	_cell(gs, "补贴", UIKit.FG_HEAD, 110.0)
	_cell(gs, "¥%.1f" % subsidy, UIKit.FG_DARK, 90.0, true)
	_cell(gs, "研究所/建筑工坊/医院/学校/治安所的工资", Color(0.55, 0.42, 0.30), 0.0)
	# 三项服务**分开**显示（用户 2026-10："这个还是要分开算的"）
	var produced: Dictionary = (s.get("ledgerToday", {}) as Dictionary).get("produced", {})
	var bought: Dictionary = (s.get("ledgerToday", {}) as Dictionary).get("bought", {})
	for row in [["治安", "safety"], ["医疗", "medical_service"], ["教育", "education"]]:
		_cell(gs, String(row[0]), UIKit.FG_HEAD, 110.0)
		_cell(gs, "产 %.1f / 买 %.1f" % [float(produced.get(String(row[1]), 0.0)),
			float(bought.get(String(row[1]), 0.0))], UIKit.FG_DARK, 90.0, true)
		_cell(gs, "点数商品（当日归零）", Color(0.55, 0.42, 0.30), 0.0)

	_section("税收结构")
	var g3 := _grid(3)
	_cell(g3, "档位", HEAD_COL, 90.0)
	_cell(g3, "上限", HEAD_COL, 90.0, true)
	_cell(g3, "税率", HEAD_COL, 90.0, true)
	var i := 0
	for b in (s["government"]["taxBrackets"] as Array):
		i += 1
		_cell(g3, "第 %d 档" % i, UIKit.FG_HEAD, 90.0)
		_cell(g3, "不限" if b["upTo"] == null else "¥%.0f" % float(b["upTo"]), UIKit.FG_DARK, 90.0, true)
		_cell(g3, "%.0f%%" % (float(b["rate"]) * 100.0), UIKit.FG_DARK, 90.0, true)
	_cell(g3, "国有住房租金", UIKit.FG_HEAD, 90.0)
	_cell(g3, "¥%.1f / 人/日" % float(s["government"]["rent"]), UIKit.FG_DARK, 90.0, true)
	_cell(g3, "", UIKit.FG_DARK, 90.0)

	if stats.has_data():
		_section("最近 12 天")
		var g4 := _grid(6)
		_cell(g4, "天", HEAD_COL, 70.0)
		for h in ["国库", "净额", "工资", "税收", "租金"]:
			_cell(g4, h, HEAD_COL, 70.0, true)
		var n := stats.days.size()
		for k in range(maxi(0, n - 12), n):
			_cell(g4, "D%d" % stats.days[k], UIKit.FG_HEAD, 70.0)
			_cell(g4, "%.0f" % stats.money[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%+.0f" % stats.money_flow[k],
				Color(0.18, 0.45, 0.20) if stats.money_flow[k] >= 0.0 else Color(0.65, 0.22, 0.18), 70.0, true)
			_cell(g4, "%.0f" % stats.wages[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%.0f" % stats.tax[k], UIKit.FG_DARK, 70.0, true)
			_cell(g4, "%.0f" % stats.rent[k], UIKit.FG_DARK, 70.0, true)
