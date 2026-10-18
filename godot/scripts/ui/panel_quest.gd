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
#   · 描述 = 内容里的 `brief`，用**老臣（塞巴斯蒂安）**的口吻说明"为什么要做这一条"
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

## 左树宽度。右栏是"剩下的全部"（全屏了，所以宽度不是常量）。
const TREE_W := 258.0
const C_OK := Color(0.19, 0.45, 0.16)

## 章节收起 / 展开的箭头。两个字形都有（`glyph_test` 会拦缺字）。
const ARROW_OPEN := "▼"
const ARROW_SHUT := "▶"

var _title_lb: Label
var _body: HBoxContainer
var _tree: VBoxContainer
var _portrait: PanelPortrait
var _detail: VBoxContainer
## 展开的章（章节 id 的字符串 -> true；`ms` = 里程碑那一组）。默认只展开"选中那条"所在的组。
var _open: Dictionary = {}
## 当前选中的任务 id（"" = 还没选）。
var _sel := ""
## 当前页签：0 = 任务（分章 + 里程碑组），1 = 支线（只列 `kind: "side"`）。
## 用户 2026-10："任务面板要有两页：任务、支线"。
var _tab := 0
const TAB_NAMES := ["任务", "支线"]
var _tab_btns: Array[Button] = []
## 里程碑那一组的键（它不属于任何一章，单独一组 —— 见 docs/quests.md §五）。
const MS_KEY := "ms"

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	# **全屏**（用户 2026-10："右边圆形按钮的任务面板没有全屏，和其它圆形按钮一样，需要全屏"）。
	# 和「统计」「科技」两个圆钮面板同一个口径：anchors 0..1 铺满，不拖动、不跟着内容改高度。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 16, 13, 16, 13))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# 标题行：图标 + 名字 + （空） + 关闭
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
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)
	var close := UIKit.button("关闭", true)
	close.pressed.connect(close_panel)
	head.add_child(close)

	root.add_child(UIKit.hsep())

	# 页签：任务 / 支线（用户 2026-10）。和统计面板同一套做法：一排按钮 + 选中态换底纹。
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	root.add_child(tab_row)
	for i in TAB_NAMES.size():
		var tb := UIKit.button(String(TAB_NAMES[i]), true)
		tb.pressed.connect(_switch_tab.bind(i))
		tab_row.add_child(tb)
		_tab_btns.append(tb)
	tab_row.add_child(UIKit.spacer())

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

	# 右下角的顾问立绘（雷纳德 —— 任务是他带来的）。**最后加** = 画在最上层。
	_portrait = PanelPortrait.new()
	_portrait.name = "Portrait"
	add_child(_portrait)
	_portrait.setup("reynard", runner.sim if runner != null else null)

	visible = false
	if runner != null:
		runner.hour_ticked.connect(_on_hour)

# ---------------------------------------------------------------------------
# 打开 / 关闭
# ---------------------------------------------------------------------------
## 打开：**默认选中第一个未完成的任务**（用户要求："进入显示当前未完成的第一个任务"）。
## 全屏（anchors 0..1），所以不摆位置、不量高度 —— 高度就是窗口高度。
func open() -> void:
	_sel = _default_sel()
	_open.clear()
	if _sel != "":
		_open[_group_key(_sel)] = true
	visible = true
	_refresh()
	# 右下角那位冒一句话（用户 2026-10）
	_face_owner()
	if _portrait != null:
		_portrait.speak()
	move_to_front()

## 右下角立绘 = **面板主人**（用户 2026-10）：前五章是雷纳德（差事由朝廷转来），
## 章 5 之后换伊莎贝拉（她接手了这堆差事）。判据在引擎里（`quest_chapter_done`）。
func _face_owner() -> void:
	if _portrait == null or runner == null or runner.sim == null:
		return
	_portrait.setup("isabella" if runner.sim.quest_chapter_done(5) else "reynard", runner.sim)

## 换页签：重选一条（每个页签只看自己那一类的任务）。
func _switch_tab(i: int) -> void:
	if _tab == i:
		return
	_tab = i
	_sel = _default_sel()
	_open.clear()
	if _sel != "":
		_open[_group_key(_sel)] = true
	UIKit.play_switch()
	_refresh()

func close_panel() -> void:
	visible = false

func _on_hour() -> void:
	if visible:
		_refresh()

# ---------------------------------------------------------------------------
# 数据（都从引擎读，这一层不判定任何东西）
# ---------------------------------------------------------------------------
func _journal() -> Array:
	return [] if runner == null or runner.sim == null else runner.sim.quest_journal()

## 这条任务在左树里属于哪一组：主线 = 章节号，里程碑 = `ms`。
## （支线有自己的页签，不参与分组。）
func _group_key(qid: String) -> String:
	for q in _journal():
		if String(q["id"]) != qid:
			continue
		if String(q.get("kind", "main")) == "milestone":
			return MS_KEY
		return str(int(q["chapter"]))
	return "1"

func _default_sel() -> String:
	var j := _journal()
	for q in j:
		if bool(q["done"]):
			continue
		var kind := String(q.get("kind", "main"))
		if _tab == 1 and kind != "side":
			continue
		if _tab == 0 and kind == "side":
			continue
		return String(q["id"])
	# 这一页全做完了：选最后一条（也就是最新完成的那条）
	for i in range(j.size() - 1, -1, -1):
		var q2: Dictionary = j[i]
		var kind2 := String(q2.get("kind", "main"))
		if _tab == 1 and kind2 != "side":
			continue
		if _tab == 0 and kind2 == "side":
			continue
		return String(q2["id"])
	return ""

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

## 一章的 `{total, done, reward_got}`。**只数主线**（`kind: "main"`）——
## 支线有自己的页签、里程碑有自己的一组，都不参与"本章全绿"的判定。
## 而且**只数"玩家已经知道"的任务** —— 锁着的那些连总数都不该暴露。
func _chapter_stat(cid: int) -> Dictionary:
	var j := _journal()
	var total := 0
	var done := 0
	for q in j:
		if int(q["chapter"]) != cid:
			continue
		if String(q.get("kind", "main")) != "main":
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

func _build_tree(j: Array) -> void:
	_style_tabs()
	if _tab == 1:
		_build_side_list(j)
		return
	# 章节顺序 = 内容里的 `chapters` 顺序；没有"已知主线"的章整章不画
	for ch in runner.db.chapters:
		var cid := int(ch["id"])
		var stat := _chapter_stat(cid)
		if int(stat["total"]) <= 0:
			continue
		var is_open := bool(_open.get(str(cid), false))
		_tree.add_child(_group_head(cid, String(ch["title"]), stat, is_open))
		if not is_open:
			continue
		for q in j:
			if String(q.get("kind", "main")) != "main":
				continue
			if int(q["chapter"]) != cid:
				continue
			_tree.add_child(_quest_row(q))
	# 里程碑：单独一组（用户 2026-10 · B2）—— 不进「支线」页、不参与章节奖励
	var ms: Array = []
	for q in j:
		if String(q.get("kind", "main")) == "milestone":
			ms.append(q)
	if not ms.is_empty():
		var done_n := 0
		for q in ms:
			if bool(q["done"]):
				done_n += 1
		var open_ms := bool(_open.get(MS_KEY, false))
		var head := UIKit.button("", true)
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		head.text = "%s 里程碑  %d/%d" % [ARROW_OPEN if open_ms else ARROW_SHUT, done_n, ms.size()]
		head.tooltip_text = "里程碑不发钱、也不挡剧情 —— 它们只是替你把追踪条填住。"
		head.pressed.connect(_toggle_group.bind(MS_KEY))
		_tree.add_child(head)
		if open_ms:
			for q in ms:
				_tree.add_child(_quest_row(q))

## 一章的组头（点击展开 / 收起）。
func _group_head(cid: int, title: String, stat: Dictionary, is_open: bool) -> Control:
	var head := UIKit.button("", true)
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.text = "%s 第 %d 章 %s  %d/%d%s" % [
		ARROW_OPEN if is_open else ARROW_SHUT, cid, title,
		int(stat["done"]), int(stat["total"]),
		"  ★" if bool(stat["reward_got"]) else ""]
	head.tooltip_text = "章节奖励 %d 金%s" % [int(_chapter_def(cid).get("reward", 0)),
		"（已领）" if bool(stat["reward_got"]) else "（本章主线全绿时自动发放，支线与里程碑不算）"]
	head.pressed.connect(_toggle_chapter.bind(cid))
	return head

## 「支线」页：**平铺**列出所有 `kind: "side"` 的任务（不分章 —— 它们本来就不挂章节）。
## 17 条送物资、石制工具、自己的房子、一盏像样的灯都在这一页。
func _build_side_list(j: Array) -> void:
	var rows := 0
	for q in j:
		if String(q.get("kind", "main")) != "side":
			continue
		_tree.add_child(_quest_row(q))
		rows += 1
	if rows == 0:
		_tree.add_child(UIKit.label("（这一页还没有支线）", UIKit.FG_DIM))

## 页签的选中态（与统计面板同一套做法：换底纹）。
func _style_tabs() -> void:
	for i in _tab_btns.size():
		_tab_btns[i].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if i == _tab else UIKit.T_BTN))

func _quest_row(q: Dictionary) -> Control:
	var qid := String(q["id"])
	var row := UIKit.button("", true)
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var kind := String(q.get("kind", "main"))
	var tag := ""
	if kind == "side":
		tag = "支线 · "
	elif kind == "milestone":
		tag = "里程碑 · "
	row.text = "   %s%s   %s" % [tag, String(q["title"]), _status_short(q)]
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
	if String(q.get("kind", "main")) == "milestone":
		# 里程碑不发钱（用户 2026-10 · B2）—— 别在面板上写「奖励 0 金」
		_detail.add_child(_wrapped("里程碑：不发钱、也不挡剧情 —— 只为把追踪条填住。", UIKit.FG_DIM))
	else:
		_detail.add_child(_wrapped("奖励 %d 金%s" % [int(q["reward"]),
			"（已入国库）" if bool(q["done"]) else "（黎明结算时入国库）"], UIKit.FG_DIM))

## 右栏文字宽度：窗口宽 - 左树 - 右边的立绘 - 两边的边距与滚动条。
## 全屏之后窗口宽是运行时才知道的（1280/1600/1920 都可能），所以现算。
## ⚠️ 那个 `PORTRAIT_GAP` 是右下角雷诺德那张立绘占的宽度：不给它留位，
## 文字会一直排到脸上（立绘画在最上层）。
const PORTRAIT_GAP := 300.0

func _detail_w() -> float:
	var vp := get_viewport_rect().size.x
	return clampf(vp - TREE_W - 92.0 - PORTRAIT_GAP, 320.0, 1200.0)

func _wrapped(text: String, color: Color = UIKit.FG_DARK) -> Label:
	var l := UIKit.label(text, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(_detail_w(), 0)
	return l

func _section(text: String) -> Label:
	return _wrapped(text, UIKit.FG_HEAD)

## 标题下面那一行：第几章 · 种类 · 完成情况 · **完成日期**（AE 纪元，用户 2026-10 · B0）。
func _summary_line(q: Dictionary, ch: Dictionary) -> String:
	var goals: Array = q["goals"]
	var met := 0
	for g in goals:
		if bool(g["met"]):
			met += 1
	var parts := PackedStringArray()
	parts.append("第 %d 章 %s" % [int(q["chapter"]), String(ch.get("title", ""))])
	var kind := String(q.get("kind", "main"))
	if kind == "side":
		parts.append("支线")
	elif kind == "milestone":
		parts.append("里程碑（不发钱）")
	parts.append("要求 %d/%d 项" % [met, goals.size()])
	if bool(q["done"]):
		parts.append("%s 完成" % _date(int(q["day"])))
	elif bool(q["met"]):
		parts.append("已达成 · 次日 06:00 结算")
	else:
		parts.append("尚未完成")
	return " · ".join(parts)

## 日期（用户 2026-10 · B0）：`AE 312 年 1 月 1 日`。
## ⚠️ 历法一个字都不在这里拼：唯一实现是 `sim_core.gd::date_label()`。
func _date(d: int) -> String:
	if runner == null or runner.sim == null:
		return "第 %d 天" % d
	return runner.sim.date_label(d)

func _detail_lines(q: Dictionary) -> Dictionary:
	var brief := String(q.get("brief", "")).strip_edges()
	if brief == "":
		brief = "（这条任务还没有写描述 —— 内容里的 `brief` 是空的）"
	var progress := ""
	if bool(q["done"]):
		progress = "已完成，%s 结算。" % _date(int(q["day"]))
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
	_toggle_group(str(cid))

## 收起 / 展开一组（章节或「里程碑」那一组）。
func _toggle_group(key: String) -> void:
	_open[key] = not bool(_open.get(key, false))
	UIKit.play_switch()
	_refresh()

func _select(qid: String) -> void:
	_sel = qid
	_open[_group_key(qid)] = true
	UIKit.play_switch()
	_refresh()
