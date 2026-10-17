extends PanelContainer

# AI 辅助面板（浮动对话框，和「城镇中心」同一套形式：标题栏 + 拖动把手 + 关闭）。
#
# 两页：
#   · **建议** —— 上面是问话栏（默认「我下一步要做什么」）+「问预言家」；
#                下面是**她的进言**（沙盘数据一条都不画 —— 用户 2026-10："全部去掉，破坏沉浸"）。
#                ⚠️ 2026-10 用户定："不要本地分析" —— 原来那块「本地分析（引擎计算）」
#                已经拿掉了；沙盘本身也仍然在跑，只是**不进画面**（机制见 prophet_agent.gd）。
#                （引擎算的候选仍然会写进提示词给模型看，那是"先算再问"，不是面板内容。）
#   · **设置** —— base_url / model_name / api_key（用户点名要的三项）+ 超时、回复上限。
#                key 存在 `user://ai.cfg`，**不进仓库**。
#
# 分层的接法：
#   · 算与拼提示词 → `scripts/sim/advisor.gd`（纯函数，headless 可测）
#   · 沙盘试方案   → `scripts/sim/trial.gd` + `scripts/sim/prophet_agent.gd`（纯的）
#   · 发 HTTP      → `scripts/ui/ai_client.gd`（Node + HTTPRequest）
#   · 本文件只负责画、接信号、把玩家的输入写回 `user://ai.cfg`
#
# 建造栏页签名（「在建造栏哪一页建」）由 main 注入 `build_bar`，
# 再转给 `Advisor.cat_of` —— sim 层不该知道页签叫什么。

var runner: SimRunner
var world: Node
var hud: Node = null
var build_bar: Node = null

const PANEL_W := 560.0
## 高度：**跟着内容走**（"面板里不许有大片空白"）。
## 建议页只有一行问话时内容很矮，固定 620 会空出一大块；跑完一场问话
## （她的进言）又会顶到上限。设置页就那几行输入框，量出来更矮。
const H_MIN := 250.0
const H_MAX := 620.0
## 标题栏 + 内边距（页签行 2026-10 删掉了，所以比原来矮）。
const CHROME_H := 72.0
const KEEP_VISIBLE := 80.0
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

var _tab := 0
var _title_lb: Label
var _body: VBoxContainer      # 页签内容容器（每次切页重建）
var _scroll: ScrollContainer
var _status: Label
var _ask_btn: Button
var _ai_head: Label
var _ai_body: VBoxContainer
var _ask_input: LineEdit
## 设置页底部那行"测试连接"的结果（页签删了之后，结果只能画在设置页自己身上）。
var _test_lb: Label = null

var _cfg: Dictionary = {}
var _client: AiClient
## 每一页上一次量出来的高度（下次打开先按它摆，避免"先撑满再缩"的跳动）。
var _fitted := [H_MIN, H_MIN]
## 一场"问话"= 多轮试方案（见 ProphetAgent）。会话进行中它非空。
var _agent: ProphetAgent = null
var _session := false
## 上一次的结论（切去「设置」页再切回来时重画用）。
var _last_final := ""
var _dragging := false
var _drag_off := Vector2.ZERO
## 本次提问是不是"测试连接"（回答的处理方式不同）。
var _testing := false
## 我们自己暂停的吗？是的话答完就恢复（玩家本来按着暂停就别动它）。
var _auto_paused := false

func setup(r: SimRunner, w: Node, bar: Node = null) -> void:
	runner = r
	world = w
	build_bar = bar

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_W, H_MIN)
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 12, 10, 12, 10))

	_cfg = AiConfig.load_cfg()
	_client = AiClient.new()
	_client.name = "AiClient"
	add_child(_client)
	_client.replied.connect(_on_replied)
	_client.failed.connect(_on_failed)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# 标题行：图标 + 名字 + 拖动把手 + 关闭（与「城镇中心」一致）
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


	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	_scroll.add_child(_body)

	visible = false
	if runner != null:
		runner.hour_ticked.connect(_on_hour_ticked)

func _on_hour_ticked() -> void:
	if not visible or _tab != 0:
		return
	# 冷却按"天"算，所以每小时都要重算一次按钮上的天数（跨过黎明就少一天）
	_sync_ask_button()

# ---------------------------------------------------------------------------
# 打开 / 关闭 / 拖动
#
# ⚠️ **两个入口各开一页**（用户 2026-10 定）：
#   · 顶栏那个问号（`open_for_question()`）→ 只开**建议**页
#   · ESC 菜单（`open_settings()`）        → 只开**设置**页
#   所以页签行删掉了 —— 一个入口进去只看得到一摊东西，不会"点进来先看到一堆标签"。
# ---------------------------------------------------------------------------
## 打开面板的**建议**页（不自动发问）。
func open() -> void:
	_cfg = AiConfig.load_cfg()
	visible = true
	select_tab(0)
	_place()

## 打开面板的**设置**页（ESC 菜单 →「AI 辅助设置…」）。
func open_settings() -> void:
	_cfg = AiConfig.load_cfg()
	visible = true
	select_tab(1)
	_place()

## 打开并**把光标放进问话栏**（顶栏那个问号按钮走这条）。
##
## 用户："点了问号以后，可以输入一行字。默认这行字是「我下一步要做什么」" ——
## 所以这里**不自动发问**：默认那句已经填好并选中，直接打字就换掉，回车/点「问预言家」才发。
func open_for_question() -> void:
	open()
	if _ask_input != null:
		_ask_input.grab_focus()
		_ask_input.select_all()

## 关面板 = **把这一场问话结束掉**。
##
## ⚠️ 这里必须清 `_session`：玩家在"正在问"的时候按关闭（或 ESC）时，`_client.cancel()`
## 只会取消 HTTP、**不发任何信号** —— 于是 `_on_replied` / `_on_failed` 都不会跑，
## `_session` 就永远是 true，问话按钮一辈子是灰的（用户报的"问预言家点不动"就是这个）。
func close_panel() -> void:
	visible = false
	_session = false
	_testing = false
	if _client != null:
		_client.cancel()
	_sync_ask_button()
	_resume_if_auto_paused()

func _place() -> void:
	# ⚠️ 顺序：**先**设 `custom_minimum_size`，**再** `reset_size()` ——
	# 反过来的话 `reset_size()` 用的是旧的最小尺寸，框高根本不变
	# （和 `panel_civic._apply_size()` 同一套写法）。
	# 高度先用"上次量出来的"，`_fit()` 下一帧按真实内容校正。
	custom_minimum_size = Vector2(PANEL_W, float(_fitted[clampi(_tab, 0, 1)]))
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	move_to_front()
	_fit()

## 框高跟着内容走。⚠️ `autowrap` 的 Label 要先拿到宽度才知道自己多高，
## 所以必须**等一帧**再量（刚加进去时量出来是错的）。
func _fit() -> void:
	await get_tree().process_frame
	if not is_inside_tree() or _body == null:
		return
	var tab := clampi(_tab, 0, 1)
	_fitted[tab] = clampf(CHROME_H + _body.get_combined_minimum_size().y + 10.0, H_MIN, H_MAX)
	custom_minimum_size = Vector2(PANEL_W, float(_fitted[tab]))
	reset_size()

func select_tab(i: int) -> void:
	_tab = clampi(i, 0, 1)
	_title_lb.text = "瑟拉菲娜" if _tab == 0 else "AI 辅助设置"
	_rebuild()
	_place()

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
# 建页
# ---------------------------------------------------------------------------
func _rebuild() -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	if _tab == 0:
		_build_advice_page()
	else:
		_build_settings_page()

func _vbox(sep: int = 3) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return v

func _head(text: String) -> Label:
	var l := UIKit.label(text, UIKit.FG_HEAD)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W - 46.0, 0)
	return l

func _wrapped(text: String, color: Color = UIKit.FG_DARK) -> Label:
	var l := UIKit.label(text, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W - 46.0, 0)
	return l

## 「建议」页：问话栏 + 她的进言（**不画任何沙盘数据**）。
##
## ⚠️ **不显示 base_url / model / key**（用户 2026-10："删掉，太出戏了，破坏沉浸体验"）。
## 那三项是"机器设置"，在 ESC 菜单的「AI 辅助设置」里；这一页只该有村子里的东西。
func _build_advice_page() -> void:
	_status = UIKit.label("", UIKit.FG_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL_W - 46.0, 0)
	_body.add_child(_status)

	# 问话栏 + 问。
	# 用户："点了问号以后，可以输入一行字" —— 所以点那个问号按钮**不自动发问**，
	# 只把光标放进这一行（默认那句已经填好，选中，直接打字就换掉）。
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_body.add_child(row)
	_ask_input = UIKit.input(DEFAULT_QUESTION, 200)
	_ask_input.text = DEFAULT_QUESTION
	_ask_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ask_input.tooltip_text = "想问什么就写一行 —— 例如「我的食物不够了怎么办」「为什么人口一直上不去」"
	_ask_input.text_submitted.connect(func(_t): ask())
	row.add_child(_ask_input)
	_ask_btn = UIKit.button("问预言家", false)
	_ask_btn.pressed.connect(ask)
	row.add_child(_ask_btn)
	_body.add_child(UIKit.hsep())

	_ai_head = _head("预言家的进言")
	_body.add_child(_ai_head)
	_ai_body = _vbox()
	_body.add_child(_ai_body)

	_refresh_status()
	_show_ai_placeholder()
	_sync_ask_button()
	# 切走再切回来时，把上一次的结论补回来（拨球的中间过程不补）
	if _last_final != "":
		_clear_ai()
		_ai_body.add_child(UIKit.hsep())
		_render_reply(_last_final)

## 「设置」页（ESC 菜单 →「AI 辅助设置…」）。
##
## 用户 2026-10 的原话："过于啰嗦。第一句，只要写『支持设置接入任何 OpenAI 兼容的大语言模型
## 端点』就好了。必填项加 * 表示，要有输入框 placeholder。那些说明，什么『填到 v1 就好了』
## 删掉 /『保存到哪里，不进仓库存档』删掉。『问话游戏会暂停』删掉。这是游戏，用户不是来
## 学习的，很多东西用户没必要知道，没必要那么细节。"
##
## 所以这一页只有：一句引言 + 三个输入框（必填带 *）+ 两个按钮。
## ⚠️ 别再往回加说明文字 —— 那些细节在 docs/ai-assist.md 里，不在这里。
func _build_settings_page() -> void:
	_body.add_child(_wrapped("支持设置接入任何 OpenAI 兼容的大语言模型端点。", UIKit.FG_DARK))
	_body.add_child(UIKit.hsep())

	_body.add_child(_head("base_url *"))
	var e_url := UIKit.input("https://api.deepseek.com/v1", 200)
	e_url.text = String(_cfg["base_url"])
	_body.add_child(e_url)

	_body.add_child(_head("model_name *"))
	var e_model := UIKit.input("deepseek-flash", 80)
	e_model.text = String(_cfg["model"])
	_body.add_child(e_model)

	_body.add_child(_head("api_key"))
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

	_test_lb = _wrapped("", UIKit.FG_DIM)
	_test_lb.visible = false     # 没测过就不占那一行（面板里不许留空白）
	_body.add_child(_test_lb)

# ---------------------------------------------------------------------------
# 回答的渲染
# ---------------------------------------------------------------------------
## 状态行：只说**村民关心的事** —— 预言家能不能问、还要等几天。
##
## ⚠️ 这里**不写 base_url / model / key**（用户 2026-10："删掉，太出戏了"）。
## 没配好时才提一句"去设置"，因为那时候玩家确实得去动它。
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
## 默认地址已经预填成 DeepSeek 官方，所以"地址空着"这条基本不会触发 ——
## 真正会让玩家撞 401 的是没填 key。
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

# `_sync_ask_button()` 在下面"提问"那一节：判 busy / 会话进行中 / 冷却三件事，
# 并且顺带刷新状态行 —— 所有"能不能按"的地方都走它一个。

func _show_ai_placeholder() -> void:
	_clear_ai()
	if not _has_key_for_gateway():
		# 没配好时给一个能按的入口 —— 光写"去设置"在新版里没用了（两个入口各开一页）
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_ai_body.add_child(row)
		var lb := UIKit.label("（还没接上预言家）", UIKit.FG_DIM)
		lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lb)
		var go := UIKit.button("去设置", true)
		go.pressed.connect(func(): select_tab(1))
		row.add_child(go)
	elif _cooldown_left() > 0:
		_ai_body.add_child(_wrapped("（预言家在闭门静修：还有 %d 天才能再问一次）"
			% _cooldown_left(), UIKit.FG_DIM))
	else:
		_ai_body.add_child(_wrapped("（上面那一行就是你的问话 —— 写好点「问预言家」："
			+ "她会拨开水晶球，回来告诉你哪条路走得通）", UIKit.FG_DIM))

func _clear_ai() -> void:
	for c in _ai_body.get_children():
		_ai_body.remove_child(c)
		c.queue_free()

## 逐行着色（用户 2026-10 定的新格式，**没有编号、没有「征兆/应对/预言」标签**）：
##   「我明白了，你想要知道…」→ 暗色（开场，复述问题）
##   「我看见了，你应该…」    → 深色（这句是**结论**，原先在最后，现在提前）
##   措施（一条一句）         → 原样
## 前缀表里还留着旧的 `征兆`/`应对`/`预言`/`为什么`/`怎么做`/`总结`：模型偶尔不照新格式写，
## 画出来也不该变成一坨（旧前缀按暗色处理，无副作用）。
## ⚠️ 这个函数**不清空**回答区（调用方负责）：结论要独占一块，不能被上一轮的残影接着写。
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
#
# 这个函数只做三件事：把车开出去（`_begin_session`）、每一步问下一发该发什么
# （`_step`）、把回来的东西交给 `ProphetAgent` 并画出来（`_on_replied`）。
# 协议本身（几轮、什么时候关工具、方案怎么跑）全在 `ProphetAgent` 里 —— 那样能 headless 测。
# ---------------------------------------------------------------------------
func ask() -> void:
	if runner == null or runner.sim == null or _client == null:
		return
	if _client.is_busy() or _session:
		return
	if not _has_key_for_gateway():
		_notice("还没配置（ESC 菜单 →「AI 辅助设置」）")
		select_tab(1)
		return
	# 冷却（用户："预言家 5 天才能问一次"）。规则在引擎里，这里只读。
	var left := _cooldown_left()
	if left > 0:
		_notice("预言家在闭门静修：还有 %d 天（第 %d 天）才能再问"
			% [left, int(runner.sim.s["day"]) + left])
		return
	_testing = false
	_begin_session()

## 开场：建一个 agent（它自己会把问话与局势包拼好），暂停时间，清空回答区。
func _begin_session() -> void:
	_agent = ProphetAgent.new(runner.sim, _ask_input.text if _ask_input != null else "",
		_cat_of())
	_session = true
	_last_final = ""
	_auto_pause_once()
	if _ai_head != null:
		_ai_head.text = "预言家的进言"
	if _ai_body != null:
		_clear_ai()
		_ai_body.add_child(_wrapped("（她把水晶球挪过来，指腹在球面上抹了一下）", UIKit.FG_HEAD))
	call_deferred("_step")

## 建造栏页签名（"在哪一页建"）：sim 层不该知道页签叫什么，所以由表现层注入。
## 拿不到就返回空 Callable —— `Advisor` 那边会**不编页签名**，而不是猜一个。
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

## 测试连接：发一句最短的话给模型。
## ⚠️ 结果画在**设置页**自己那一行（`_test_lb`）上 —— 页签删掉之后没有"切到建议页去看结果"
## 这回事了，两个入口各开一页。
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

## 设置页那一行小字（测试连接的结果）。没有那一行（比如还没建页）就退回顶部提示。
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
## ⚠️ 一场会话只暂停一次、结束时才恢复 —— 多轮里每轮都恢复一次会让人以为没暂停。
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
## ⚠️ 顺手让**顶栏那个问号**也跟着换图标：冷却从"问到了"那一刻开始（`_finish_session`），
## 那时并没有跨天、不会触发 `hour_ticked` —— 只靠 HUD 自己的每小时刷新，
## 顶栏会一直亮着金问号（实测就是这么发现的）。
func _sync_ask_button() -> void:
	if hud != null and hud.has_method("refresh_ai_btn"):
		hud.refresh_ai_btn()
	if _ask_btn == null:
		return
	var busy := (_client != null and _client.is_busy()) or _session
	var left := _cooldown_left()
	_ask_btn.disabled = busy or left > 0
	if left > 0:
		_ask_btn.text = "问预言家（还有 %d 天）" % left
		_ask_btn.tooltip_text = "预言家一次问话要隔 %d 天（问到了才算）。" % \
			int(SimCore.PROPHET_COOLDOWN_DAYS)
	else:
		_ask_btn.text = "问预言家"
		_ask_btn.tooltip_text = "想让瑟拉菲娜拨一次水晶球（一场问话最多 %d 轮占卜，" % \
			ProphetAgent.MAX_ROUNDS + "一次问话要隔 %d 天）" % [
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
		_notice("连接成功：模型回话「%s」" % one_line)
		return
	if _agent == null:
		_sync_ask_button()
		return
	# 交给 agent：它会决定「这是方案」还是「这是结论」
	var res := _agent.accept(reply)
	match String(res["kind"]):
		"final":
			_last_final = AiClient.clean_reply(_agent.final_text)
			_clear_ai()
			if _ai_body != null:
				_render_reply(_last_final)
				_fit()
			_finish_session()
		"trials", "refused":
			# ⚠️ **不画任何沙盘结果**（用户 2026-10："全部去掉，破坏沉浸"）。
			# 玩家只该看见她在拨球 —— 一行换一句，别让人盯着空白等。
			_show_orb_whisper()
			_sync_ask_button()
			call_deferred("_step")
		"error":
			_session = false
			_sync_ask_button()
			_resume_if_auto_paused()
			_clear_ai()
			var why := String(res["message"])
			_ai_body.add_child(_wrapped("她没应声（" + why + "）", C_WARN))
			var hint3 := _auth_hint(why)
			_ai_body.add_child(_wrapped(hint3 if hint3 != ""
				else "（连接的事在 ESC 菜单 →「AI 辅助设置…」里改）", UIKit.FG_DIM))
			_notice("AI：%s" % why)
		_:
			_finish_session()

## 会话正常结束：记冷却、放开按钮、恢复时间。
## ⚠️ **不清 `_agent`**：留着它，面板切页回来还能重画上一次的结论、截图工具/门槛也能
## 读"这一场试了几个方案"。它只是个数据袋，不会再发请求（`_session` 才是那个开关）。
func _finish_session() -> void:
	_session = false
	# 问到了才记冷却（用户："预言家 5 天才能问一次"）—— 失败/超时都不算
	if runner != null and runner.sim != null:
		runner.sim.mark_prophet_asked()
	_sync_ask_button()
	_resume_if_auto_paused()
	if _ai_body != null and _ai_body.get_child_count() == 0:
		_show_ai_placeholder()

## 拨球时显示的那一行（**不画数据**）。
##
## 用户 2026-10："沙盘（本地引擎跑的）全部去掉，破坏沉浸" —— 所以等待期间只留一句
## 瑟拉菲娜那边的动静，换着说，别让人盯着一块空白等十几秒。
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
	_clear_ai()
	var i := 0 if _agent == null else (_agent.rounds_done - 1)
	_ai_body.add_child(_wrapped(ORB_LINES[clampi(i, 0, ORB_LINES.size() - 1)], UIKit.FG_DIM))
	_fit()

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
	_sync_ask_button()
	_resume_if_auto_paused()
	# 设置页：结果就写在那一行小字上（那边没有"进言"区）
	_test_note(message, C_WARN)
	if _ai_body != null:
		_clear_ai()
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
