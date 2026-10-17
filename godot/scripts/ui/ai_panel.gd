extends PanelContainer

# 瑟拉菲娜（AI 辅助 / 预言家）。两个**形式完全不同**的页面：
#
#   · **预言**（`open()` / `open_for_question()`）—— **全屏**（用户 2026-10）：
#       左栏 = 历史预言（点一条看那一回的原话），左下角 = 问话栏 +「获取瑟拉菲娜的新预言」；
#       右栏 = 这一次的内容（正在拨球 / 她的回答）。
#       入口两个：**左侧圆钮第 6 个**、**顶栏那个水晶球**，都是进这里。
#   · **设置**（`open_settings()`，ESC 菜单那一行）—— 还是原来那个居中的浮动对话框，
#       高度跟着内容走。**不放进全屏页**：那是"机器设置"，玩家一年动一次。
#
# 分层的接法：
#   · 算与拼提示词 → `scripts/sim/advisor.gd`（纯函数，headless 可测）
#   · 沙盘试方案   → `scripts/sim/trial.gd` + `scripts/sim/prophet_agent.gd`（纯的）
#   · 发 HTTP      → `scripts/ui/ai_client.gd`（Node + HTTPRequest）
#   · 本文件只负责画、接信号、把玩家的输入写回 `user://ai.cfg`
#
# 历史预言存在**仿真状态**里（`s["prophet"]["log"]`，读 `SimCore.prophecy_log()`）：
# 于是退出重进、读档都还在。面板不自己攒副本 —— 和"公告日志唯一真源是 sim.s"同一条规矩。
#
# ⚠️ 沙盘（本地引擎跑的）**一条都不画**（用户 2026-10："全部去掉，破坏沉浸"）。
#    账房算出来的候选仍然会写进提示词给模型看 —— 那是"先算再问"，不是面板内容。

var runner: SimRunner
var world: Node
var hud: Node = null
var build_bar: Node = null

const MODE_PROPHECY := 0
const MODE_SETTINGS := 1

## 设置页（浮动对话框）的尺寸口径
const PANEL_W := 560.0
const H_MIN := 250.0
const H_MAX := 620.0
const CHROME_H := 72.0
const KEEP_VISIBLE := 80.0

## 预言页（全屏）的尺寸口径
const HIST_W := 300.0
## 左栏问话栏那一块的最小高度
const ASK_MIN_H := 96.0
## 右下角立绘占的宽度（内容要在这之前收住，否则数字会跑到脸上去）
const PORTRAIT_GAP := 316.0

const C_OK := Color(0.19, 0.45, 0.16)
const C_WARN := Color(0.62, 0.30, 0.12)
## 问话栏的默认文字（用户 2026-10 定：默认这行是「我下一步要做什么」）。
## 每次打开面板都会重新填成它 —— 上一次问过的问题不该粘在框里。
const DEFAULT_QUESTION := "我下一步要做什么"
## 「测试连接」发的那两条消息（最小请求，不带工具）。
const TEST_MESSAGES := [
	{"role": "system", "content": "你是连通性测试。只回复两个字：收到"},
	{"role": "user", "content": "在吗"},
]

var _mode := MODE_PROPHECY
var _title_lb: Label
## 设置页的滚动内容容器（每次打开重建）
var _body: VBoxContainer
var _scroll: ScrollContainer
var _status: Label
var _ask_btn: Button
var _ai_head: Label
var _ai_body: VBoxContainer
var _ask_input: LineEdit
## 预言页左栏：历史条目的容器 + 当前选中哪一条（-1 = 没选）
var _hist: VBoxContainer
var _sel_entry := -1
var _portrait: PanelPortrait
## 设置页底部那行"测试连接"的结果
var _test_lb: Label = null

var _cfg: Dictionary = {}
var _client: AiClient
## 设置页上一次量出来的高度（下次打开先按它摆，避免"先撑满再缩"的跳动）
var _fitted := H_MIN
## 一场"问话"= 多轮试方案（见 ProphetAgent）。会话进行中它非空。
var _agent: ProphetAgent = null
var _session := false
## 上一次的结论（重建界面时重画用）
var _last_final := ""
var _dragging := false
var _drag_off := Vector2.ZERO
## 本次提问是不是"测试连接"（回答的处理方式不同）
var _testing := false
## 本次提问是不是**免费**的（第一章收尾她主动送的那次）：答完不记冷却
var _free := false
## 我们自己暂停的吗？是的话答完就恢复（玩家本来按着暂停就别动它）
var _auto_paused := false

func setup(r: SimRunner, w: Node, bar: Node = null) -> void:
	runner = r
	world = w
	build_bar = bar

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_cfg = AiConfig.load_cfg()
	_client = AiClient.new()
	_client.name = "AiClient"
	add_child(_client)
	_client.replied.connect(_on_replied)
	_client.failed.connect(_on_failed)
	visible = false
	visibility_changed.connect(_on_visibility_changed)
	if runner != null:
		runner.hour_ticked.connect(_on_hour_ticked)
	_build()

func _on_visibility_changed() -> void:
	# 全屏（预言页）才需要藏小地图/左侧圆钮（它们是小地图那侧常驻的兄弟节点）
	UIKit.show_map_chrome(self, not (_mode == MODE_PROPHECY
		and UIKit.any_panel_open(self, visible)))

func _on_hour_ticked() -> void:
	if not visible or _mode != MODE_PROPHECY:
		return
	# 冷却按"天"算，所以每小时都要重算一次（跨过黎明就少一天）
	_sync_ask_button()

# ---------------------------------------------------------------------------
# 打开 / 关闭
#
# ⚠️ **两个入口各开一页**（用户 2026-10 定）：
#   · 顶栏水晶球 / 左侧圆钮「预言」（`open_for_question()`）→ 预言页（全屏）
#   · ESC 菜单（`open_settings()`）                        → 设置页（浮动对话框）
# ---------------------------------------------------------------------------
## 打开**预言**页（全屏）。历史里挑最新那条显示。
func open() -> void:
	_cfg = AiConfig.load_cfg()
	_mode = MODE_PROPHECY
	visible = true
	_build()
	_place()
	_select_latest_entry()
	# 右下角那位冒一句话（用户 2026-10）
	if _portrait != null:
		_portrait.speak()

## 打开并**把光标放进问话栏**（顶栏那个水晶球走这条）。
##
## 用户："点了以后可以输入一行字。默认这行字是「我下一步要做什么」" ——
## 所以这里**不自动发问**：默认那句已经填好并选中，直接打字就换掉，回车/点按钮才发。
func open_for_question() -> void:
	open()
	if _ask_input != null:
		_ask_input.grab_focus()
		_ask_input.select_all()

## 打开**设置**页（ESC 菜单 →「AI 辅助设置…」）。
func open_settings() -> void:
	_cfg = AiConfig.load_cfg()
	_mode = MODE_SETTINGS
	visible = true
	_build()
	_place()

## 第一章收尾选「……说下去」之后的那次**免费预言**（用户 2026-10）。
##
## 剧情里她自己送上来的，所以：
##   · 不占 5 天冷却（`ask(true)`）—— 玩家没挑时机，不该被罚等 5 天
##   · 问话栏预填一句默认问句（玩家还可以改），因为这时候没什么可打字的
func open_free_prophecy() -> void:
	_cfg = AiConfig.load_cfg()
	open()
	if _ask_input != null:
		_ask_input.text = "我下一步要做什么"
	ask(true)

## 关面板 = **把这一场问话结束掉**。
##
## ⚠️ 这里必须清 `_session`：玩家在"正在问"的时候按关闭（或 ESC）时，`_client.cancel()`
## 只会取消 HTTP、**不发任何信号** —— 于是 `_on_replied` / `_on_failed` 都不会跑，
## `_session` 就永远是 true，问话按钮一辈子是灰的（用户报的"问预言家点不动"就是这个）。
func close_panel() -> void:
	visible = false
	_session = false
	_testing = false
	_free = false
	if _client != null:
		_client.cancel()
	_sync_ask_button()
	_resume_if_auto_paused()

func _place() -> void:
	if _mode == MODE_PROPHECY:
		# 全屏：和统计/科技/任务面板同一个口径 —— 顶栏留着，其余全铺满
		anchor_left = 0.0
		anchor_top = 0.0
		anchor_right = 1.0
		anchor_bottom = 1.0
		offset_left = 0.0
		offset_right = 0.0
		offset_top = float(UIKit.BAR_H)
		offset_bottom = 0.0
		add_theme_stylebox_override("panel",
			UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 14, 10, 14, 10))
		move_to_front()
		return
	# 设置页：居中的浮动框，高度跟内容走
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 12, 10, 12, 10))
	# ⚠️ 顺序：**先**设 `custom_minimum_size`，**再** `reset_size()` ——
	# 反过来的话 `reset_size()` 用的是旧的最小尺寸，框高根本不变。
	custom_minimum_size = Vector2(PANEL_W, float(_fitted))
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	move_to_front()
	_fit()

## 框高跟着内容走（只有设置页要）。⚠️ `autowrap` 的 Label 必须先拿到宽度才知道自己多高，
## 所以必须**等一帧**再量（刚加进去时量出来是错的）。
func _fit() -> void:
	if _mode != MODE_SETTINGS:
		return
	await get_tree().process_frame
	if not is_inside_tree() or _body == null:
		return
	_fitted = clampf(CHROME_H + _body.get_combined_minimum_size().y + 10.0, H_MIN, H_MAX)
	custom_minimum_size = Vector2(PANEL_W, float(_fitted))
	reset_size()

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
# 建界面
# ---------------------------------------------------------------------------
func _build() -> void:
	# 只留 HTTP 客户端（它挂着信号），其余全重建 —— 两种形式的骨架差得太远，
	# 就地改节点比重建更容易出"上一个模式的残留"。
	for c in get_children():
		if c == _client:
			continue
		remove_child(c)
		c.queue_free()
	_title_lb = null
	_body = null
	_scroll = null
	_status = null
	_ask_btn = null
	_ask_input = null
	_ai_head = null
	_ai_body = null
	_hist = null
	_test_lb = null

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	if _mode == MODE_PROPHECY:
		_build_prophecy(root)
	else:
		_build_settings(root)

## 标题行：图标 + 名字 +（撑开）+ 关闭。设置页多一个拖动把手。
func _head_row(root: VBoxContainer, with_drag: bool) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	# 图标**原生 32px**（和科技面板标题同一个口径）：整数倍、不重采样。
	var ico := UIKit.panel_icon("ai_assist")
	if ico != null:
		var tr := TextureRect.new()
		tr.texture = ico
		tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tr)
	_title_lb = UIKit.label("瑟拉菲娜", UIKit.FG_HEAD)
	_title_lb.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(_title_lb)
	if with_drag:
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
	else:
		head.add_child(UIKit.spacer())
	var close := UIKit.button("关闭", true)
	close.tooltip_text = "回到地图（Esc 也行）"
	close.pressed.connect(close_panel)
	head.add_child(close)

## 小标题条（米黄面板里的深色 section 条，和统计面板同一套）
func _section(parent: Control, text: String) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(text, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	parent.add_child(p)

func _vbox(sep: int = 4) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return v

func _wrapped(text: String, color: Color = UIKit.FG_DARK, width: float = 0.0) -> Label:
	var l := UIKit.label(text, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if width > 0.0:
		l.custom_minimum_size = Vector2(width, 0)
	return l

# ---------------------------------------------------------------------------
# 预言页（全屏）
# ---------------------------------------------------------------------------
func _build_prophecy(root: VBoxContainer) -> void:
	_head_row(root, false)
	root.add_child(UIKit.hsep())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	# ---- 左栏：历史预言 + 问话
	var left := _vbox(4)
	left.custom_minimum_size = Vector2(HIST_W, 0)
	# ⚠️ 不能跟着撑开：`_vbox()` 给的是 EXPAND_FILL，两栏都会去分多出来的宽度，
	# 左栏会被拉到面板的一半（第一版就是这样：问话栏横了一整条）。
	left.size_flags_horizontal = Control.SIZE_FILL
	body.add_child(left)
	_section(left, "历史预言")
	var hscroll := ScrollContainer.new()
	hscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(hscroll)
	_hist = _vbox(2)
	hscroll.add_child(_hist)

	left.add_child(UIKit.hsep())
	var ask_row := HBoxContainer.new()
	ask_row.add_theme_constant_override("separation", 5)
	left.add_child(ask_row)
	_ask_input = UIKit.input(DEFAULT_QUESTION, 120)
	_ask_input.text = DEFAULT_QUESTION
	_ask_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ask_input.tooltip_text = "想问什么就写一行 —— 例如「我的食物不够了怎么办」「为什么人口一直上不去」"
	_ask_input.text_submitted.connect(func(_t): ask())
	ask_row.add_child(_ask_input)
	_ask_btn = UIKit.button("获取新的预言", false)
	_ask_btn.custom_minimum_size = Vector2(0, UIKit.BTN_H)
	_ask_btn.tooltip_text = "让瑟拉菲娜拨一次水晶球"
	_ask_btn.pressed.connect(ask)
	left.add_child(_ask_btn)

	# ---- 右栏：状态 + 内容
	# 右边给立绘留出 PORTRAIT_GAP：立绘画在最上层，不给它让位的话数字会跑到脸上。
	var right_wrap := HBoxContainer.new()
	right_wrap.add_theme_constant_override("separation", 0)
	right_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(right_wrap)
	var right := _vbox(4)
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_wrap.add_child(right)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(PORTRAIT_GAP, 0)
	right_wrap.add_child(gap)

	_status = _wrapped("", UIKit.FG_DIM)
	right.add_child(_status)
	_ai_head = _wrapped("", UIKit.FG_HEAD)
	right.add_child(_ai_head)
	var cscroll := ScrollContainer.new()
	cscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(cscroll)
	_scroll = cscroll
	_ai_body = _vbox(4)
	cscroll.add_child(_ai_body)

	# 立绘：**最后加** = 画在最上层（见 panel_portrait.gd 的注释）
	_portrait = PanelPortrait.new()
	_portrait.name = "Portrait"
	add_child(_portrait)
	_portrait.setup("serafina", runner.sim if runner != null else null)

	_rebuild_history()
	_refresh_status()
	_sync_ask_button()
	_select_latest_entry()

## 历史列表：一条一个按钮（第 N 天 + 问的那句话）。选中的那条换底纹。
func _rebuild_history() -> void:
	if _hist == null:
		return
	for c in _hist.get_children():
		_hist.remove_child(c)
		c.queue_free()
	var log: Array = runner.sim.prophecy_log() if runner != null and runner.sim != null else []
	if log.is_empty():
		_hist.add_child(_wrapped("（还没有过预言）", UIKit.FG_DIM))
		return
	for i in log.size():
		var it: Dictionary = log[i]
		var q := String(it.get("q", "")).strip_edges()
		var label := "第 %d 天" % int(it.get("d", 0))
		if q != "":
			label += "  " + (q if q.length() <= 8 else q.substr(0, 8) + "…")
		var b := UIKit.button(label, true)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = "第 %d 天 · %s" % [int(it.get("d", 0)), q if q != "" else "（没写问话）"]
		if i == _sel_entry:
			b.add_theme_stylebox_override("normal", UIKit.box(UIKit.T_BTN_ACTIVE))
			b.add_theme_color_override("font_color", UIKit.FG_LIGHT)
		b.pressed.connect(_select_entry.bind(i))
		_hist.add_child(b)

func _select_latest_entry() -> void:
	var log: Array = runner.sim.prophecy_log() if runner != null and runner.sim != null else []
	_sel_entry = log.size() - 1
	_rebuild_history()
	_show_entry(_sel_entry)

func _select_entry(i: int) -> void:
	_sel_entry = i
	UIKit.play_switch()
	_rebuild_history()
	_show_entry(i)

## 把某一条历史画到右栏。
func _show_entry(i: int) -> void:
	if _ai_body == null:
		return
	_clear_body()
	var log: Array = runner.sim.prophecy_log() if runner != null and runner.sim != null else []
	if i < 0 or i >= log.size():
		_show_placeholder()
		return
	var it: Dictionary = log[i]
	var q := String(it.get("q", "")).strip_edges()
	if _ai_head != null:
		_ai_head.text = "第 %d 天 · 你问的是「%s」" % [int(it.get("d", 0)),
			q if q != "" else DEFAULT_QUESTION]
	_render_reply(String(it.get("t", "")))
	_scroll_to_top()

func _scroll_to_top() -> void:
	if _scroll != null:
		_scroll.scroll_vertical = 0

func _clear_body() -> void:
	if _ai_body == null:
		return
	for c in _ai_body.get_children():
		_ai_body.remove_child(c)
		c.queue_free()

## 右栏没有内容时的占位（按"没配好 / 冷却中 / 还没问过"三种情况说不同的话）。
func _show_placeholder() -> void:
	if _ai_body == null:
		return
	if _ai_head != null:
		_ai_head.text = ""
	if not _has_key_for_gateway():
		# 没配好时给一个能按的入口
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_ai_body.add_child(row)
		var lb := UIKit.label("（还没接上预言家）", UIKit.FG_DIM)
		lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lb)
		var go := UIKit.button("去设置", true)
		go.pressed.connect(open_settings)
		row.add_child(go)
	elif _cooldown_left() > 0:
		_ai_body.add_child(_wrapped("（她在闭门静修：还有 %d 天才能再问一次）"
			% _cooldown_left(), UIKit.FG_DIM))
	else:
		_ai_body.add_child(_wrapped("（还没有过预言。左边写好问话，点「获取新的预言」——"
			+ "她会拨开水晶球，回来告诉你哪条路走得通）", UIKit.FG_DIM))

# ---------------------------------------------------------------------------
# 设置页（ESC 菜单 →「AI 辅助设置…」）
#
# 用户 2026-10 的原话："过于啰嗦。第一句，只要写『支持设置接入任何 OpenAI 兼容的大语言模型
# 端点』就好了。必填项加 * 表示，要有输入框 placeholder。那些说明……删掉。这是游戏，
# 用户不是来学习的。" 所以这一页只有：一句引言 + 三个输入框（必填带 *）+ 两个按钮。
# ⚠️ 别再往回加说明文字 —— 细节在 docs/ai-assist.md 里，不在这里。
# ---------------------------------------------------------------------------
func _build_settings(root: VBoxContainer) -> void:
	_head_row(root, true)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)
	_body = _vbox(3)
	_scroll.add_child(_body)

	_body.add_child(_wrapped("支持设置接入任何 OpenAI 兼容的大语言模型端点。", UIKit.FG_DARK,
		PANEL_W - 46.0))
	_body.add_child(UIKit.hsep())

	_body.add_child(_wrapped("base_url *", UIKit.FG_HEAD, PANEL_W - 46.0))
	var e_url := UIKit.input("https://api.deepseek.com/v1", 200)
	e_url.text = String(_cfg["base_url"])
	_body.add_child(e_url)

	_body.add_child(_wrapped("model_name *", UIKit.FG_HEAD, PANEL_W - 46.0))
	var e_model := UIKit.input("deepseek-flash", 80)
	e_model.text = String(_cfg["model"])
	_body.add_child(e_model)

	_body.add_child(_wrapped("api_key", UIKit.FG_HEAD, PANEL_W - 46.0))
	var key_row := HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 5)
	_body.add_child(key_row)
	var e_key := UIKit.input("sk-…（本地推理可留空）", 200)
	e_key.text = String(_cfg["api_key"])
	e_key.secret = true
	e_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key_row.add_child(e_key)
	var show := UIKit.button("显示", true)
	show.pressed.connect(func():
		e_key.secret = not e_key.secret
		show.text = "隐藏" if not e_key.secret else "显示")
	key_row.add_child(show)

	_body.add_child(UIKit.hsep())
	var adv := HBoxContainer.new()
	adv.add_theme_constant_override("separation", 8)
	_body.add_child(adv)
	adv.add_child(UIKit.label("超时(秒)"))
	var e_to := UIKit.input("60", 6)
	e_to.text = str(int(_cfg["timeout"]))
	e_to.custom_minimum_size = Vector2(64, UIKit.BTN_H_SM)
	adv.add_child(e_to)
	adv.add_child(UIKit.label("回复上限(tokens)"))
	var e_mt := UIKit.input("4000", 6)
	e_mt.text = str(int(_cfg["max_tokens"]))
	e_mt.custom_minimum_size = Vector2(72, UIKit.BTN_H_SM)
	adv.add_child(e_mt)

	_body.add_child(UIKit.hsep())
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 5)
	_body.add_child(btns)
	# 把输入框收进 `_cfg` 的动作只写一份：「保存」和「测试连接」都要它，
	# 写两份迟早只改一处（比如以后加个字段，忘了在"测试连接"里也带上）。
	var collect := func() -> void:
		_cfg["base_url"] = e_url.text
		_cfg["model"] = e_model.text
		_cfg["api_key"] = e_key.text
		_cfg["timeout"] = clampf(e_to.text.to_float(), 5.0, 300.0)
		_cfg["max_tokens"] = int(clampf(e_mt.text.to_float(), 64.0, 8192.0))
	var save := UIKit.button("保存", false)
	save.pressed.connect(func():
		collect.call()
		_save_cfg("设置已保存"))
	btns.add_child(save)
	var test := UIKit.button("测试连接", false)
	test.tooltip_text = "发一句最短的话给模型，看看通不通"
	test.pressed.connect(func():
		collect.call()
		_save_cfg("")
		_test_connection())
	btns.add_child(test)

	_test_lb = _wrapped("", UIKit.FG_DIM, PANEL_W - 46.0)
	_test_lb.visible = false     # 没测过就不占那一行（面板里不许留空白）
	_body.add_child(_test_lb)

# ---------------------------------------------------------------------------
# 状态行 / 渲染
# ---------------------------------------------------------------------------
## 状态行：只说**玩家人关心的事** —— 预言家能不能问、还要等几天。
## ⚠️ 这里**不写 base_url / model / key**（用户 2026-10："删掉，太出戏了"）。
func _refresh_status() -> void:
	if _status == null:
		return
	var cool := _cooldown_left()
	if not _has_key_for_gateway():
		_status.text = "还没配置（在 ESC 菜单 →「AI 辅助设置」里填）"
		_status.add_theme_color_override("font_color", C_WARN)
	elif cool > 0:
		_status.text = "预言家在闭门静修 —— 第 %d 天（还有 %d 天）才回得来" % [
			int(runner.sim.s["day"]) + cool, cool]
		_status.add_theme_color_override("font_color", C_WARN)
	else:
		_status.text = "现在可以询问瑟拉菲娜"
		_status.add_theme_color_override("font_color", C_OK)

## "没配好"到底指什么：远程端点必须有 key（本地推理不用）。
func _has_key_for_gateway() -> bool:
	if not AiConfig.is_ready(_cfg):
		return false
	if AiConfig.has_key(_cfg):
		return true
	var url := String(_cfg.get("base_url", "")).to_lower()
	return url.contains("127.0.0.1") or url.contains("localhost") or url.contains("0.0.0.0")

## 还要等几天才能问（0 = 现在就能问）。规则在引擎里（`SimCore.prophet_days_left`）——
## 表现层只读它，不自己算冷却。
func _cooldown_left() -> int:
	if runner == null or runner.sim == null:
		return 0
	return runner.sim.prophet_days_left()

## 逐行着色（用户 2026-10 定的新格式，**没有编号、没有「征兆/应对/预言」标签**）：
##   「我明白了，你想要知道…」→ 暗色（开场，复述问题）
##   「我看见了，你应该…」    → 深色（这句是**结论**，原先在最后，现在提前）
##   措施（一条一句）         → 原样
## 前缀表里还留着旧的 `征兆`/`应对`/`预言`/`为什么`/`怎么做`/`总结`：模型偶尔不照新格式写，
## 画出来也不该变成一坨（旧前缀按暗色处理，无副作用）。
## ⚠️ 这个函数**不清空**内容区（调用方负责）。
func _render_reply(text: String) -> void:
	if _ai_body == null:
		return
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if line == "":
			continue
		var color := UIKit.FG_DARK
		if line.begins_with("我看见了"):
			color = UIKit.FG_HEAD
		else:
			for pre in ["我明白了", "征兆", "应对", "预言", "为什么", "怎么做", "总结"]:
				if line.begins_with(pre):
					color = UIKit.FG_DIM
					break
		if color == UIKit.FG_DARK and line.substr(0, 1).is_valid_int():
			color = UIKit.FG_HEAD
		_ai_body.add_child(_wrapped(line, color))

# ---------------------------------------------------------------------------
# 提问：一场**多轮试方案**的会话（见 docs/ai-assist.md §四·五）
# ---------------------------------------------------------------------------
## `free` = 这一次**不占冷却**（第一章收尾她主动送的那次，见 `open_free_prophecy()`）。
func ask(free: bool = false) -> void:
	if runner == null or runner.sim == null or _client == null:
		return
	if _client.is_busy() or _session:
		return
	if not _has_key_for_gateway():
		_notice("还没配置（ESC 菜单 →「AI 辅助设置」）")
		return
	_free = free
	# 冷却（用户："预言家 5 天才能问一次"）。规则在引擎里，这里只读。
	var left := 0 if free else _cooldown_left()
	if left > 0:
		_notice("预言家在闭门静修：还有 %d 天（第 %d 天）才能再问"
			% [left, int(runner.sim.s["day"]) + left])
		_free = false
		return
	# 免费的那次不算"问过" —— 冷却、按钮文案都要按没问过算
	if free:
		if _ask_btn != null:
			_ask_btn.disabled = false
	_testing = false
	_begin_session()

## 开场：建一个 agent（它自己会把问话与局势包拼好），暂停时间，清空内容区。
func _begin_session() -> void:
	_agent = ProphetAgent.new(runner.sim, _ask_input.text if _ask_input != null else "",
		_cat_of())
	_session = true
	_last_final = ""
	_auto_pause_once()
	if _ai_head != null:
		_ai_head.text = "她拨开了球上的雾"
	if _ai_body != null:
		_clear_body()
		_ai_body.add_child(_wrapped("（她把水晶球挪过来，指腹在球面上抹了一下）", UIKit.FG_HEAD))
		_scroll_to_top()
	call_deferred("_step")

## 建造栏页签名（"在哪一页建"）：sim 层不该知道页签叫什么，所以由表现层注入。
func _cat_of() -> Callable:
	if build_bar != null and build_bar.has_method("_category_of"):
		return Callable(build_bar, "_category_of")
	return Callable()

## 发下一发。`tools` 由 agent 决定（收尾轮给空数组 = 关掉工具，逼它说话）。
func _step() -> void:
	if not _session or _agent == null or _client == null:
		return
	var req := _agent.next_request()
	if req["stage"] == "done":
		_finish_session()
		return
	if not _client.ask(_cfg, req["messages"], req["tools"]):
		_sync_ask_button()

## 测试连接：发一句最短的话给模型。结果画在设置页自己那一行上。
func _test_connection() -> void:
	if _client.is_busy() or _session:
		return
	if not AiConfig.is_ready(_cfg):
		_test_note("base_url 与 model_name 都不能空", C_WARN)
		return
	_testing = true
	_test_note("正在测试…", UIKit.FG_DIM)
	if not _client.ask(_cfg, TEST_MESSAGES, []):
		_testing = false
		_sync_ask_button()

func _test_note(text: String, color: Color) -> void:
	if _test_lb == null:
		_notice(text)
		return
	_test_lb.text = text
	_test_lb.visible = text != ""
	_test_lb.add_theme_color_override("font_color", color)
	_fit()

## 问话期间暂停：一场会话要跑几轮沙盘、还要等几轮 HTTP，不冻住时间的话
## 答案到手时局势已经往前跑了好几天。用户 2026-10："问的时候游戏暂停" —— **无条件**。
## 这是**纯表现层**动作（只动 SimRunner.paused，不进仿真状态、不影响确定性）。
func _auto_pause_once() -> void:
	_auto_paused = false
	if runner == null or runner.paused:
		return
	if hud != null and hud.has_method("set_paused_external"):
		hud.set_paused_external(true)
	else:
		runner.set_paused(true)
	_auto_paused = true

## 问话按钮的两个"不能按"的理由：正在问 / 会话在多轮里 / 冷却。
## ⚠️ `_session` 必须算进去：两轮之间 `_client.is_busy()` 是 false，只看它按钮会闪一下。
## ⚠️ 顺手让**顶栏那个水晶球**也跟着换图标：冷却从"问到了"那一刻开始，
## 那时并没有跨天、不会触发 `hour_ticked` —— 只靠 HUD 自己的每小时刷新，顶栏会一直亮着。
func _sync_ask_button() -> void:
	if hud != null and hud.has_method("refresh_ai_btn"):
		hud.refresh_ai_btn()
	if _ask_btn == null:
		return
	var busy := (_client != null and _client.is_busy()) or _session
	var left := _cooldown_left()
	_ask_btn.disabled = busy or left > 0
	if left > 0:
		_ask_btn.text = "获取新的预言（还有 %d 天）" % left
		_ask_btn.tooltip_text = "预言家一次问话要隔 %d 天（问到了才算）。" % \
			int(SimCore.PROPHET_COOLDOWN_DAYS)
	else:
		_ask_btn.text = "获取瑟拉菲娜的新预言"
		# ⚠️ 这里原来分成「前半段 % 轮数」+「后半段 % [轮数, 天数]」两段拼，
		# 后半段只有一个 %d 却给了两个参数 —— 每次建面板都报
		# "String formatting error: not all arguments converted"（而且不红、只是日志里刷）。
		_ask_btn.tooltip_text = "让瑟拉菲娜拨一次水晶球（一场问话最多 %d 轮，一次问话要隔 %d 天）" % [
			ProphetAgent.MAX_ROUNDS, int(SimCore.PROPHET_COOLDOWN_DAYS)]
	_refresh_status()

func _on_replied(reply: Dictionary) -> void:
	var text := String(reply.get("text", ""))
	var clean := AiClient.clean_reply(text)
	if _testing:
		# 测试连接**不算问过**（不能白白吃掉 5 天冷却）
		_testing = false
		_sync_ask_button()
		_resume_if_auto_paused()
		var one_line := clean.replace("\n", " ").substr(0, 40)
		_test_note("连接成功：模型回话「%s」" % one_line, C_OK)
		return
	if _agent == null:
		_sync_ask_button()
		return
	# 交给 agent：它会决定「这是方案」还是「这是结论」
	var res := _agent.accept(reply)
	match String(res["kind"]):
		"final":
			_last_final = AiClient.clean_reply(_agent.final_text)
			_clear_body()
			_render_reply(_last_final)
			_scroll_to_top()
			_finish_session()
		"trials", "refused":
			# ⚠️ **不画任何沙盘结果**。玩家只该看见她在拨球 —— 一行换一句，
			# 别让人盯着空白等十几秒。
			_show_orb_whisper()
			_sync_ask_button()
			call_deferred("_step")
		"error":
			_session = false
			_sync_ask_button()
			_resume_if_auto_paused()
			_clear_body()
			var why := String(res["message"])
			_ai_body.add_child(_wrapped("她没应声（" + why + "）", C_WARN))
			var hint3 := _auth_hint(why)
			_ai_body.add_child(_wrapped(hint3 if hint3 != ""
				else "（连接的事在 ESC 菜单 →「AI 辅助设置…」里改）", UIKit.FG_DIM))
			_notice("AI：%s" % why)
		_:
			_finish_session()

## 会话正常结束：记冷却 + **把这回的问答存进历史**、放开按钮、恢复时间。
## ⚠️ **不清 `_agent`**：留着它，界面重建还能重画上一次的结论、截图工具/门槛也能
## 读"这一场试了几个方案"。它只是个数据袋，不会再发请求（`_session` 才是那个开关）。
func _finish_session() -> void:
	_session = false
	# 问到了才记冷却（用户："预言家 5 天才能问一次"）—— 失败/超时都不算；
	# 第一章收尾那次**免费**的也算"问到了"，但**不占冷却**（`_free`）：她在剧情里
	# 主动送上来的，不该让玩家一进游戏就被罚 5 天。历史照样记（`charge_cooldown=false`）。
	if runner != null and runner.sim != null:
		var q := _ask_input.text if _ask_input != null else ""
		runner.sim.mark_prophet_asked(q, _last_final, not _free)
	_free = false
	_sync_ask_button()
	_resume_if_auto_paused()
	if _mode == MODE_PROPHECY:
		# 新的一条在历史里排最后 —— 选中它，右栏就是刚拿到的这段
		_select_latest_entry()
	elif _ai_body != null and _ai_body.get_child_count() == 0:
		_show_placeholder()

## 拨球时显示的那一行（**不画数据**）。
## ⚠️ 这些字里**不许出现**沙盘/模拟/引擎/方案/轮次（那是给机器看的，不是给村里人看的）。
const ORB_LINES := [
	"（她拨开球上的雾，没回头看你）",
	"（水晶球里的光转了一下 —— 又暗下去）",
	"（她眯起紫眼睛，指尖在球面上停了一停）",
	"（球里浮起一片屋顶，转瞬又散）",
	"（她哼了一声，把球转了个方向）",
]

func _show_orb_whisper() -> void:
	if _ai_body == null:
		return
	_clear_body()
	var i := 0 if _agent == null else (_agent.rounds_done - 1)
	_ai_body.add_child(_wrapped(ORB_LINES[clampi(i, 0, ORB_LINES.size() - 1)], UIKit.FG_DIM))

## 401 / 403 单独认出来：默认 base_url 已经预填了 DeepSeek 官方地址（用户要求），
## 所以"没填 key 就点问话"会真发一次请求并换回 401 —— 这时候该说的是
## "key 没填或不对"，而不是把服务端那句话原样丢给玩家。
static func _auth_hint(message: String) -> String:
	var m := message.to_lower()
	if m.contains("401") or m.contains("403") or m.contains("authentication") \
			or m.contains("unauthorized") or m.contains("api key"):
		return "（像是 key 没填或不对：ESC 菜单 →「AI 辅助设置」里填 api_key）"
	return ""

func _on_failed(message: String) -> void:
	_session = false
	_testing = false
	_free = false
	_sync_ask_button()
	_resume_if_auto_paused()
	# 设置页：结果就写在那一行小字上（那边没有内容区）
	_test_note(message, C_WARN)
	if _ai_body != null:
		_clear_body()
		_ai_body.add_child(_wrapped("问不到模型：" + message, C_WARN))
		var hint := _auth_hint(message)
		_ai_body.add_child(_wrapped(hint if hint != ""
			else "（要改接入地址 / 模型名：ESC 菜单 →「AI 辅助设置」）", UIKit.FG_DIM))
	_notice("AI：%s" % message)

func _resume_if_auto_paused() -> void:
	if not _auto_paused:
		return
	_auto_paused = false
	if runner != null:
		if hud != null and hud.has_method("set_paused_external"):
			hud.set_paused_external(false)
		else:
			runner.set_paused(false)

# ---------------------------------------------------------------------------
func _save_cfg(note: String) -> void:
	var err := AiConfig.save_cfg(_cfg)
	if err != OK:
		_notice("设置写不进去（错误码 %d）：%s" % [err, AiConfig.PATH])
		return
	_refresh_status()
	_notice(note if note != "" else "设置已保存")

func _notice(msg: String) -> void:
	if hud != null and hud.has_method("set_notice"):
		hud.set_notice(msg)

## 这一场问话一共试了几个方案（截图工具与门槛读它；没有会话时 0）。
func trials_shown() -> int:
	return 0 if _agent == null else (_agent.trials as Array).size()

## 兼容旧调用（截图工具用过 `select_tab(0/1)`）：0 = 预言页，1 = 设置页。
func select_tab(i: int) -> void:
	if clampi(i, 0, 1) == 0:
		open()
	else:
		open_settings()
