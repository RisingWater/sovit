extends PanelContainer

# 任务面板（浮动对话框，与「城镇中心」「AI 辅助」同一套形式：标题栏 + 拖动把手 + 关闭）。
#
# 由**左侧圆形按钮列**的第 5 个圆钮打开（图标 `quest_panel.png`，快捷键 F5）。
#
# 版式：
#   ┌ 标题行：图标 + 「任务」 + 拖动 + 关闭 ─────────────────────────┐
#   │ 左：任务树（分章，可展开收起）  │ 右：选中任务的详情           │
#   └────────────────────────────────────────────────────────────────┘
#
# 右侧按用户点名的四件事排：**描述 / 要求 / 完成情况 / 第几天完成**。
#   · 描述 = 内容里的 `brief`，用**镇长智囊**的口吻说明"为什么要做这一条"
#   · 要求 = 引擎拼好的 `goal.text`（达标变绿）
#   · 完成情况 = 已完成 k / n 项（+ 已达成未结算时提示次日 06:00 结算）
#   · 第几天完成 = `s["quests"]["done"][qid]`，写在标题下面那行
#
# ⚠️ 渐进显示这条契约在面板上**也要守**（见 docs/quests.md）：
#   数据源是 `SimCore.quest_journal()`，它跟 `quest_view()` 一样，
#   `requires` 没全完成、自己也没完成的任务**根本不返回** ——
#   所以左边的树里连"有个锁着的任务"都看不出来。
#
# ⚠️ 左树里**没有**"全部展开"这种选项：默认只展开"当前选中那条所在的章"。
#   二十多条一起铺开，玩家反而找不到自己该做的那条。

var runner: SimRunner
var world: Node

const PANEL_W := 780.0
## 框高**跟着内容走**（见 `_fit()`），这两个是上下限：再矮就只剩两行字，再高就顶到屏幕边。
const H_MIN := 380.0
const H_MAX := 620.0
## 一档的高度。量化到 40px：点左树逐条翻的时候，几十像素的抖很难受；
## 而"某几条特别长"本来也不需要每次都把框撑到最大。
const H_STEP := 40.0
## 标题行 + 分隔线 + 间距 + 内边距的总高（内容之外的那些）。
const CHROME_H := 67.0
const TREE_W := 258.0
## 标题栏那一行之外的东西（内边距），拖动时不至于把边框拖出屏幕外。
const KEEP_VISIBLE := 80.0
const C_OK := Color(0.19, 0.45, 0.16)

## 章节收起 / 展开的箭头。两个字形都有（`glyph_test` 会拦缺字）。
const ARROW_OPEN := "▼"
const ARROW_SHUT := "▶"

var _title_lb: Label
var _body: HBoxContainer
var _tree: VBoxContainer
var _detail: VBoxContainer
## 展开的章（章节 id 的字符串 -> true）。默认只有"选中那条所在的章"是展开的。
var _open: Dictionary = {}
## 当前选中的任务 id（"" = 还没选）。
var _sel := ""

var _dragging := false
var _drag_off := Vector2.ZERO

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_W, H_MIN)
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 12, 10, 12, 10))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# 标题行：图标 + 名字 + 拖动把手 + 关闭
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	var ico := UIKit.panel_icon("quest_panel")
	if ico != null:
		var tr := TextureRect.new()
		tr.texture = ico
		tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tr)
	_title_lb = UIKit.label("任务", UIKit.FG_HEAD)
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

	# 左右两栏
	_body = HBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)

	var left := ScrollContainer.new()
	left.custom_minimum_size = Vector2(TREE_W, 0)
	left.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(left)
	_tree = VBoxContainer.new()
	_tree.add_theme_constant_override("separation", 2)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(_tree)

	_body.add_child(UIKit.hsep())

	var right := ScrollContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(right)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 4)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_detail)

	visible = false
	if runner != null:
		runner.hour_ticked.connect(_on_hour)

# ---------------------------------------------------------------------------
# 打开 / 关闭 / 拖动
# ---------------------------------------------------------------------------
## 打开：**默认选中第一个未完成的任务**（用户要求："进入显示当前未完成的第一个任务"）。
func open() -> void:
	_sel = _default_sel()
	_open.clear()
	if _sel != "":
		_open[str(int(_chapter_of(_sel)))] = true
	visible = true
	_refresh()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	move_to_front()

## 框高跟着内容走（取左树与右栏里**更高**的那个）。
##
## 为什么不写死：一条任务的要求可能是 1 项，也可能 6 项；描述有长有短。
## 写死 470 的话，短的那些底下空一大片；跟着内容走又会让点左树时框高一直跳，
## 所以**量化到 40px 一档**。位置不动（往下长），免得玩家正看着的对话框整体跑掉。
func _fit() -> void:
	var inner := maxf(_tree.get_combined_minimum_size().y,
		_detail.get_combined_minimum_size().y)
	var want: float = ceilf((CHROME_H + inner) / H_STEP) * H_STEP
	var vp := get_viewport_rect().size
	custom_minimum_size = Vector2(PANEL_W,
		clampf(want, H_MIN, minf(H_MAX, vp.y - 2.0 * KEEP_VISIBLE)))
	reset_size()

func close_panel() -> void:
	visible = false

func _on_hour() -> void:
	if visible:
		_refresh()

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
	return Vector2(clampf(p.x, KEEP_VISIBLE - PANEL_W, vp.x - KEEP_VISIBLE),
		clampf(p.y, 0.0, vp.y - KEEP_VISIBLE))

# ---------------------------------------------------------------------------
# 数据（都从引擎读，这一层不判定任何东西）
# ---------------------------------------------------------------------------
func _journal() -> Array:
	return [] if runner == null or runner.sim == null else runner.sim.quest_journal()

func _default_sel() -> String:
	var j := _journal()
	for q in j:
		if not bool(q["done"]):
			return String(q["id"])
	# 全做完了：选最后一条（也就是最新完成的那条）
	return String((j[j.size() - 1] as Dictionary)["id"]) if not j.is_empty() else ""

func _chapter_of(qid: String) -> int:
	for q in _journal():
		if String(q["id"]) == qid:
			return int(q["chapter"])
	return 1

func _chapter_def(cid: int) -> Dictionary:
	for ch in runner.db.chapters:
		if int(ch["id"]) == cid:
			return ch
	return {}

## 一章的 `{total, done, reward_got}`。**只数"玩家已经知道"的任务** ——
## 锁着的那些连总数都不该暴露（否则 `0/6` 就泄露了后面还有几条）。
func _chapter_stat(cid: int) -> Dictionary:
	var j := _journal()
	var total := 0
	var done := 0
	for q in j:
		if int(q["chapter"]) != cid:
			continue
		total += 1
		if bool(q["done"]):
			done += 1
	return {"total": total, "done": done,
		"reward_got": (runner.sim.s["quests"]["chapters"] as Dictionary).has(str(cid))}

# ---------------------------------------------------------------------------
# 重画
# ---------------------------------------------------------------------------
func _refresh() -> void:
	for c in _tree.get_children():
		_tree.remove_child(c)
		c.queue_free()
	for c in _detail.get_children():
		_detail.remove_child(c)
		c.queue_free()
	var j := _journal()
	if j.is_empty():
		_tree.add_child(UIKit.label("（暂无任务）", UIKit.FG_DIM))
		_detail.add_child(UIKit.label("（暂无任务）", UIKit.FG_DIM))
		return
	_build_tree(j)
	_build_detail(j)
	_fit()

func _build_tree(j: Array) -> void:
	# 章节顺序 = 内容里的 `chapters` 顺序；没有"已知任务"的章整章不画
	for ch in runner.db.chapters:
		var cid := int(ch["id"])
		var stat := _chapter_stat(cid)
		if int(stat["total"]) <= 0:
			continue
		var is_open := bool(_open.get(str(cid), false))
		var head := UIKit.button("", true)
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		head.text = "%s 第 %d 章 %s  %d/%d%s" % [
			ARROW_OPEN if is_open else ARROW_SHUT, cid, String(ch["title"]),
			int(stat["done"]), int(stat["total"]),
			"  ★" if bool(stat["reward_got"]) else ""]
		head.tooltip_text = "章节奖励 %d 金%s" % [int(ch["reward"]),
			"（已领）" if bool(stat["reward_got"]) else "（本章主线全绿时自动发放，支线不算）"]
		head.pressed.connect(_toggle_chapter.bind(cid))
		_tree.add_child(head)
		if not is_open:
			continue
		for q in j:
			if int(q["chapter"]) != cid:
				continue
			_tree.add_child(_quest_row(q))

func _quest_row(q: Dictionary) -> Control:
	var qid := String(q["id"])
	var row := UIKit.button("", true)
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text = "   %s%s   %s" % ["支线 · " if bool(q["side"]) else "",
		String(q["title"]), _status_short(q)]
	row.add_theme_color_override("font_color", _status_color(q))
	if qid == _sel:
		# 选中态：换底纹（和面板页签同一套做法）
		row.add_theme_stylebox_override("normal", UIKit.box(UIKit.T_BTN_ACTIVE))
		row.add_theme_color_override("font_color", UIKit.FG_LIGHT)
	row.pressed.connect(_select.bind(qid))
	return row

func _status_short(q: Dictionary) -> String:
	if bool(q["done"]):
		return "已完成"
	if bool(q["met"]):
		return "待结算"
	return "进行中"

func _status_color(q: Dictionary) -> Color:
	if bool(q["done"]):
		return C_OK
	if bool(q["met"]):
		return UIKit.FG_HEAD
	return UIKit.FG_DARK

func _build_detail(j: Array) -> void:
	var q := {}
	for e in j:
		if String(e["id"]) == _sel:
			q = e
			break
	if q.is_empty():
		q = j[0]
		_sel = String(q["id"])
	var ch := _chapter_def(int(q["chapter"]))
	var lines := _detail_lines(q)

	# 标题 + 状态行
	var title := UIKit.label(String(q["title"]), _status_color(q))
	title.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(_detail_w(), 0)
	_detail.add_child(title)
	_detail.add_child(_wrapped(_summary_line(q, ch), _status_color(q)))
	_detail.add_child(UIKit.hsep())

	# 描述（智囊口吻）
	_detail.add_child(_section("描述"))
	_detail.add_child(_wrapped(String(lines["brief"]), UIKit.FG_DARK))

	# 要求
	_detail.add_child(_section("要求"))
	var goals: Array = q["goals"]
	if goals.is_empty():
		_detail.add_child(_wrapped("（没有列出要求）", UIKit.FG_DIM))
	for g in goals:
		var met := bool(g["met"])
		_detail.add_child(_wrapped("%s %s" % ["◆" if met else "◇", String(g["text"])],
			C_OK if met else UIKit.FG_DARK))
	# hint 放在要求下面：它是"怎么做"，常常是照做要求的具体步骤
	_detail.add_child(_wrapped("批示：" + String(q["hint"]), UIKit.FG_DIM))

	# 完成情况
	_detail.add_child(_section("完成情况"))
	_detail.add_child(_wrapped(String(lines["progress"]),
		C_OK if bool(q["done"]) else UIKit.FG_DARK))
	_detail.add_child(UIKit.hsep())
	_detail.add_child(_wrapped("奖励 %d 金%s" % [int(q["reward"]),
		"（已入国库）" if bool(q["done"]) else "（黎明结算时入国库）"], UIKit.FG_DIM))

func _detail_w() -> float:
	return PANEL_W - TREE_W - 62.0

func _wrapped(text: String, color: Color = UIKit.FG_DARK) -> Label:
	var l := UIKit.label(text, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(_detail_w(), 0)
	return l

func _section(text: String) -> Label:
	return _wrapped(text, UIKit.FG_HEAD)

## 标题下面那一行：第几章 · 完成情况 · **第几天完成**。
func _summary_line(q: Dictionary, ch: Dictionary) -> String:
	var goals: Array = q["goals"]
	var met := 0
	for g in goals:
		if bool(g["met"]):
			met += 1
	var parts := PackedStringArray()
	parts.append("第 %d 章 %s" % [int(q["chapter"]), String(ch.get("title", ""))])
	if bool(q["side"]):
		parts.append("支线")
	parts.append("要求 %d/%d 项" % [met, goals.size()])
	if bool(q["done"]):
		parts.append("第 %d 天完成" % int(q["day"]))
	elif bool(q["met"]):
		parts.append("已达成 · 次日 06:00 结算")
	else:
		parts.append("尚未完成")
	return " · ".join(parts)

func _detail_lines(q: Dictionary) -> Dictionary:
	var brief := String(q.get("brief", "")).strip_edges()
	if brief == "":
		brief = "（这条任务还没有写描述 —— 内容里的 `brief` 是空的）"
	var progress := ""
	if bool(q["done"]):
		progress = "已完成，第 %d 天结算。" % int(q["day"])
	elif bool(q["met"]):
		progress = "所有要求都已达成，等下一个黎明的 06:00 自动结算（不用提交）。"
	else:
		var miss := PackedStringArray()
		for g in (q["goals"] as Array):
			if not bool(g["met"]):
				miss.append(String(g["text"]))
		progress = "还差 %d 项：%s" % [miss.size(), "、".join(miss)]
	return {"brief": brief, "progress": progress}

# ---------------------------------------------------------------------------
func _toggle_chapter(cid: int) -> void:
	var k := str(cid)
	_open[k] = not bool(_open.get(k, false))
	UIKit.play_switch()
	_refresh()

func _select(qid: String) -> void:
	_sel = qid
	_open[str(_chapter_of(qid))] = true
	UIKit.play_switch()
	_refresh()
