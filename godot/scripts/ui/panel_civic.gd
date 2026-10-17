extends PanelContainer

# 城镇中心 / 仓库的**浮动对话框**（和「统计」面板同一套形式：标题栏 + 拖动把手 + 关闭）。
#
# 为什么不是右侧常驻条：右侧那条是"选中就占着屏幕右边一整条"的形式，
# 用户不喜欢 —— 他要的是"点一下弹出来、能拖、能关"的对话框，
# 也就是点左侧圆钮（资源/人口/财政）出来的那种（`panel_stats.gd`）。
#
# 两种内容：
#   - 城镇中心 → 四个页签：**基本信息**（城镇名字 / 人口上限 / 当前人口 / 空余房屋 /
#                想要迁入移民 / 本回合迁入移民 + 两个移民开关）、**资源**（全村仓储 +
#                每种资源数量与上限）、**建造队列**（谁先建 / 已用多少建造力 / 调序 / 撤单）、
#                **公告**（全部日志，自动滚到最新）
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

## 城镇中心的四个页签
const TABS := ["基本信息", "资源", "建造队列", "公告"]
## 每页各自的框高：基本信息矮（两段：6 行 + 2 个按钮）、资源中等（33 种货三列）、
## 建造队列按"能看到四五条工程"定、公告高（是个滚动列表，固定高合适）。
## 一页一个高度，免得"为了装下最长的那页，短的那页底下空一大片"。
## 四个数是按实际截图量出来的（内容高 + 标题栏/页签 + 内边距），改内容就回来量一次。
const TAB_H := [360.0, 480.0, 460.0, 520.0]
## 队列一行的高度（缩略图 34 + 上下留白）
const QUEUE_ROW_H := 40.0

enum Mode { NONE, TOWN_CENTER, WAREHOUSE }

var _mode := Mode.NONE
var _id := ""
var _title_lb: Label
var _body: VBoxContainer
var _sub: Label
## 内容滚动区（公告页要"自动滚到最新一天"，得留着引用）
var _scroll: ScrollContainer
## 上次画公告时的日志条数：条数没变就不重建（公告最多 500 条，每小时重建一次太浪费，
## 而且会把玩家正在看的位置顶掉）
var _notice_size := -1
## 每种货的上限输入框（每次重建时重置）
var _cap_inputs: Dictionary = {}
## 二次确认标记（"拆除"要点两次）
var _confirm := ""
## 建造队列控件的二次确认状态（`queue_box.gd` 读它 —— 记在**面板**上才能跨"每小时重建"）
var _qstate := {"confirm": ""}

var _dragging := false
var _drag_off := Vector2.ZERO
## 页签控件（只有城镇中心模式显示）
var _tab_row: HBoxContainer
var _tab_btns: Array = []
var _tab := 0

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

	# 页签（只有城镇中心用）：人口 / 资源 / 公告。
	# 为什么要有「资源」这一页：**开局不一定有仓库**，而库存余量与每种货的上限
	# 得让玩家看得到、设得了（用户："因为初始不一定有仓库，要让人看到库存和设置库存上限"）。
	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 4)
	root.add_child(_tab_row)
	for i in TABS.size():
		var b := UIKit.button(TABS[i], true)
		b.pressed.connect(_select_tab.bind(i))
		_tab_row.add_child(b)
		_tab_btns.append(b)

	root.add_child(UIKit.hsep())

	_sub = UIKit.label("", UIKit.FG_DIM)
	root.add_child(_sub)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_scroll = scroll
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
	# 不再写"人口 / 资源 / 公告 —— 全局数字在顶栏"那行（页签本身就是目录，顶栏也一眼能看到）
	_set_sub("")
	_tab = 0                      # 每次打开回到「基本信息」
	_tab_row.visible = true
	_show()

## `shop_id`：仓库的 shop 实例 id（只能同时看一座的容量构成）
func open_warehouse(shop_id: String) -> void:
	_mode = Mode.WAREHOUSE
	_id = shop_id
	_title_lb.text = "仓库 · 仓储"
	_set_sub("上限留空 = 不限；命令次日 06:00 生效")
	_tab_row.visible = false      # 仓库没有页签（它的内容本来就只有一屏）
	_show()

## 副标题：空字符串就整行收起（不然留一条空行 + 分隔线）
func _set_sub(t: String) -> void:
	_sub.text = t
	_sub.visible = t != ""

func _show() -> void:
	_confirm = ""
	_qstate["confirm"] = ""
	visible = true
	_mark_tabs()
	_refresh()
	_apply_size()
	move_to_front()

## 切页签：重画内容 + 换框高（每页内容多少差很多，一页一个高度）
func _select_tab(i: int) -> void:
	_tab = clampi(i, 0, TABS.size() - 1)
	_confirm = ""           # 换页就把"等二次确认"的状态收掉（撤单是两步的）
	_qstate["confirm"] = ""
	UIKit.play_switch()
	_mark_tabs()
	_refresh()
	_apply_size()

func _mark_tabs() -> void:
	for k in _tab_btns.size():
		(_tab_btns[k] as Button).add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == _tab else UIKit.T_BTN))

func _apply_size() -> void:
	var want := Vector2(PANEL_W, PANEL_H)
	if _mode == Mode.TOWN_CENTER:
		want = Vector2(PANEL_W, _tab_height())
	custom_minimum_size = want
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())

## 本页该多高。前三页内容多少是**固定**的，所以用 `TAB_H` 里量好的数；
## 「建造队列」不行：行高 56、条数不定 —— 空队列时留一大片空白，排了 12 条又挤得只剩
## 五行要滚。那一页改成**跟着内容走**（与建筑面板的 `_fit_height()` 同一套办法），
## 上限 620：再长也不让对话框铺满整屏（其余条目滚动看）。
func _tab_height() -> float:
	if _tab != 2:
		return float(TAB_H[clampi(_tab, 0, TAB_H.size() - 1)])
	return clampf(_chrome_height() + _body.get_combined_minimum_size().y,
		260.0, minf(620.0, get_viewport_rect().size.y - 2.0 * KEEP_VISIBLE))

## 滚动区之外那些东西的高度（标题行 / 页签行 / 副标题 / 分隔线 / 面板内边距）。
## 与 inspector 的 `_chrome_height()` 同一套算法，两处都别写死数字。
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
	# 公告页：日志条数没变就不重建（500 条 Label 每小时重建一次太浪费，
	# 而且会把玩家正在看的滚动位置顶到最新）
	if _mode == Mode.TOWN_CENTER and _tab == 3 and runner.sim.log_size() == _notice_size:
		return
	_refresh()

func _cap_input_focused() -> bool:
	for c in _body.find_children("*", "LineEdit", true, false):
		if (c as LineEdit).is_visible_in_tree() and (c as LineEdit).has_focus():
			return true
	return false

func _refresh() -> void:
	# ⚠️ 先 `remove_child` 再 `queue_free`：`queue_free()` 是**延迟**的，节点要到帧末才离开
	# 树。而「建造队列」页的高度是按 `_body` 的内容算的（`_tab_height()`）—— 同一帧里去量，
	# 量到的是"旧内容 + 新内容"（建筑面板就是这么被顶到上限、底下留空白的）。
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_cap_inputs.clear()
	match _mode:
		Mode.TOWN_CENTER:
			match _tab:
				0:
					# 修缮放在**最上面**：破旧时这是玩家第一件该做的事，
					# 塞在「基础」下面就得滚动才看得见（实测就是这样）。
					_build_repair()
					_build_basic()
				1: _build_resources()
				2: _build_queue()
				_: _build_notice()
		Mode.WAREHOUSE: _build_storage()
		_: pass

# ---------------------------------------------------------------------------
# 修缮城镇中心（用户 2026-10：一开局那座是废墟，修好才换回好图）
#
# 只在「破旧」时出现；命令进 `runner.enqueue()`，和别的建造一样**次日黎明生效**。
# 材料不够就当场说明白（不排队、不扣东西）—— 免得玩家排了单又白等一天。
#
# ⚠️ 价格与"破旧/修好"的判据**都不在这儿**：
#   · 价格 = `SimCore.TOWN_CENTER_REPAIR_COST`（`sim.town_center_repair_cost()`）
#   · 换图 = 任务 `q10f_townhall_repair` 结算（`sim.town_center_ruined_visual()`）
# 这里只画。别在 UI 里再抄一份数字 —— 抄一份就等于两处会漂。
# ---------------------------------------------------------------------------

func _build_repair() -> void:
	var tc: Dictionary = runner.sim.s.get("townCenter", {})
	if not bool(tc.get("ruined", false)):
		# 已经下过单（或本来就好的）：说清楚现在是什么状态，别留一片空
		if bool(runner.sim.town_center_ruined_visual()):
			_body.add_child(UIKit.hsep())
			_title("修缮城镇中心")
			_body.add_child(UIKit.label("已下令修缮 —— 等任务「修复城镇中心」结算后才换新貌",
				UIKit.FG_DIM))
		return
	_body.add_child(UIKit.hsep())
	_title("修缮城镇中心")
	var cost: Dictionary = runner.sim.town_center_repair_cost()
	var parts := PackedStringArray()
	for gid in ["wood", "stone", "brick"]:
		if not cost.has(gid):
			continue
		parts.append("%s %d" % [_cost_name(gid), int(cost[gid])])
	var need := " · ".join(parts)
	_kv("用料", need)
	_body.add_child(UIKit.label("明日 06:00 完工，之后城镇中心就修好了", UIKit.FG_DIM))
	var b := UIKit.button("修缮", false)
	b.tooltip_text = "花 %s，次日黎明完工" % need
	b.pressed.connect(func():
		var ok := true
		for gid in cost.keys():
			if float(runner.sim.s["goods"].get(gid, 0.0)) < float(cost[gid]):
				ok = false
		if not ok:
			_set_sub("材料不够：还差一些" + need)
			return
		runner.enqueue([{"type": "repair_town_center"}])
		_set_sub("已下令修缮 —— 次日 06:00 完工")
		_refresh())
	_body.add_child(b)

## 材料的显示名（木 / 石 / 砖）。内容表里是 `wood` / `stone` / `brick`。
func _cost_name(gid: String) -> String:
	var zh := String((runner.sim.db.goods.get(gid, {}) as Dictionary).get("nameZh", gid))
	return zh

# ---------------------------------------------------------------------------
# 排版小件（和 inspector 同款：区块标题 + 左标签右数值 + 进度条）# ---------------------------------------------------------------------------
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
# 城镇中心「基本信息」页：村子是谁 / 住了多少人 / 还能来多少人
# ---------------------------------------------------------------------------
func _build_basic() -> void:
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

	_title("基础")
	_kv("城镇名字", String(s.get("villageName", "sovit")))
	_kv("人口上限" + ("（已排队）" if pending_cap >= 0 else ""),
		"不限" if eff_cap >= 100000000 else str(eff_cap),
		Color(0.72, 0.35, 0.15) if pending_cap >= 0 else UIKit.FG_DARK)
	_kv("当前人口", "%d 人" % popn)
	_kv("空余房屋", "%d" % maxi(0, hcap - popn))
	_kv("想要迁入移民", "%d 人" % arrivals, Color(0.55, 0.35, 0.15) if arrivals > 0 else UIKit.FG_DARK)
	_kv("本回合迁入移民", "%d 人" % will_come,
		Color(0.18, 0.45, 0.20) if will_come > 0 else UIKit.FG_DARK)

	_title("操作")
	_buttons([["不限制移民迁入", func(): _set_population_cap(1000000000)],
		["停止移民迁入", func(): _set_population_cap(popn)]])
	_gap(2)
	# 想来却进不来时把原因写清楚（这行用户点名要留着）
	if will_come <= 0 and arrivals > 0:
		var why = "空房不足" if (hcap - popn) <= 0 else ("已到人口上限" if eff_cap < 100000000 else "名额不足")
		_note("想来 %d 人，但%s，一个也进不来。" % [arrivals, why])
	_gap(2)
	_note("命令次日 06:00 生效。没人来通常是空房不足或已到人口上限：空房靠多盖住房，上限就是上面两个按钮。")

	# 仓储容量与库存明细不在这一页 —— 它们是「资源」页的事
	# （开局不一定有仓库，所以那一页必须能独立看到库存与上限）。

func _set_population_cap(value: int) -> void:
	runner.enqueue([{"type": "set_population_cap", "value": value}])
	# 立刻重建：命令次日才生效，不重建的话点完屏幕上一点变化都没有
	_refresh()

## 城镇中心的「资源」页：全村仓储余量 + 每种货（数量 / 上限）。
##
## 这一页存在的理由：**开局不一定有仓库**，但玩家必须能看库存、能设上限
## （用户原话："因为初始不一定有仓库，要让人看到库存和设置库存上限"）。
func _build_resources() -> void:
	_build_capacity()
	_gap()
	_build_goods()

# ---------------------------------------------------------------------------
# 城镇中心「建造队列」页
#
# 行怎么画、调序怎么生效、撤单为什么是两步 —— 全在**共用控件** `queue_box.gd` 里
# （建筑工坊面板与研究所面板读的是同一个控件，施工 / 研究两条队列也共用一套行）。
# 这里只负责把它挂进本面板的正文。
# ---------------------------------------------------------------------------
func _build_queue() -> void:
	_title("建造队列")
	var box := QueueBox.new()
	_body.add_child(box)
	box.setup(runner, world, QueueBox.Kind.BUILD, _qstate)

## 城镇中心的「公告」页：**全部**日志（SimCore 自己封顶 500 条）。
##
## ⚠️ 日志读的是**仿真状态里的那一份**（`sim.s["log"]`，逐小时累积、上限 500，
## 随存档保存）—— 表现层不再自己攒一份副本。以前读的是 `SimRunner.recent_logs`
## （只在内存里的环形缓冲），**读档时被清空**，于是"退出再进来公告全没了"。
##
## 日期写「第 N 天」（日志里的 `day` 从 1 开始），不再写 `D37` 那种缩写。
func _build_notice() -> void:
	_title("公告")
	if runner == null or runner.sim == null:
		_note("（暂无）")
		return
	var total: int = runner.sim.log_size()
	_notice_size = total
	var logs: Array = runner.sim.log_tail(total)
	if logs.is_empty():
		_note("（暂无）")
		return
	for e in logs:
		var d := int((e as Dictionary).get("day", 0))
		_note("第%d天　%s" % [d, String((e as Dictionary).get("text", ""))])
	_scroll_to_bottom()

## 滚到最新一条（日志是"老的在上、新的在下"）。
## 必须等一帧：内容刚加进去时 ScrollContainer 还没算出行高，这时设 scroll_vertical 无效。
func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if _scroll != null and is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)

## 全村仓储余量（进度条）。城镇中心的「资源」页与仓库面板共用。
func _build_capacity() -> void:
	var sim = runner.sim
	var pending_caps := _caps_pending()
	_title("全村仓储" + ("（上限已排队）" if pending_caps else ""))
	var used := sim.stored_total()
	var total := sim.storage_capacity()
	_bar("已用", used, maxf(1.0, total),
		Color(0.72, 0.45, 0.18) if used >= total * 0.9 else Color(0.24, 0.55, 0.28),
		" / %d" % int(round(total)))
	if used >= total:
		_note("已经满了：当晚超出上限的部分会被丢掉。再建/升级仓库可以扩容。")

## 每种资源一行：数量 + 上限输入框（城镇中心的「资源」页与仓库面板共用）。
func _build_goods() -> void:
	var s: Dictionary = runner.sim.s
	# 顺序用 pack 里商品的**固定顺序**，不按数量排 —— 数量每小时都在变，
	# 按它排行会跳来跳去，数字根本没法填。
	_title("资源（数量 / 上限）")
	var caps: Dictionary = _effective_caps()
	var goods: Dictionary = s["goods"]
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	_body.add_child(grid)
	for gid in (runner.db.packs[String(s["pack"])]["goods"] as Array):
		_cap_cell(grid, String(gid), int(caps.get(String(gid), 0)), float(goods.get(String(gid), 0.0)))
	# 尾注删掉了（用户："数量= 当前库存；上限留空…"那一整段全部删掉）。
	# 仓库面板的副标题仍写着"上限留空 = 不限"，够了。

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
	# 容量与资源列表是**共用件**（城镇中心的「资源」页也要用同一份）
	_build_capacity()
	_gap()
	_build_goods()

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
