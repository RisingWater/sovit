extends PanelContainer

# AI 辅助面板（浮动对话框，和「城镇中心」同一套形式：标题栏 + 拖动把手 + 关闭）。
#
# 两页：
#   · **建议** —— 上半是「本地分析」（引擎算出来的，不联网、永远有），
#                下半是「AI 建议」（点了才去问模型）。本地那一块是刻意的：
#                没配 key / 断网 / 模型抽风时，玩家至少还有程序算出来的下一步。
#   · **设置** —— base_url / model_name / api_key（用户点名要的三项）+ 超时、
#                回复上限、提问时自动暂停。key 存在 `user://ai.cfg`，**不进仓库**。
#
# 分层的接法：
#   · 算与拼提示词 → `scripts/sim/advisor.gd`（纯函数，headless 可测）
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
## 每页各自的框高：建议页要装下"本地分析 + AI 回答"两块（固定 620），
## 设置页只有几个输入框，用 620 底下会空一大片（截图量出来的：内容到 460 左右结束）。
const TAB_H := [620.0, 470.0]
const KEEP_VISIBLE := 80.0
const TABS := ["建议", "设置"]
const C_OK := Color(0.19, 0.45, 0.16)
const C_WARN := Color(0.62, 0.30, 0.12)

var _tab := 0
var _tab_btns: Array[Button] = []
var _title_lb: Label
var _body: VBoxContainer      # 页签内容容器（每次切页重建）
var _scroll: ScrollContainer
var _status: Label
var _ask_btn: Button
var _ai_head: Label
var _ai_body: VBoxContainer
var _local_body: VBoxContainer
var _ask_input: LineEdit

var _cfg: Dictionary = {}
var _client: AiClient
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
	custom_minimum_size = Vector2(PANEL_W, TAB_H[0])
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
	_title_lb = UIKit.label("AI 辅助", UIKit.FG_HEAD)
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

	# 页签
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	root.add_child(tab_row)
	for i in TABS.size():
		var b := UIKit.button(TABS[i], true)
		b.pressed.connect(select_tab.bind(i))
		tab_row.add_child(b)
		_tab_btns.append(b)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	_scroll.add_child(_body)

	visible = false
	# 每小时重算本地分析：局势变了，建议就该跟着变（不联网，很便宜）
	if runner != null:
		runner.hour_ticked.connect(_on_hour_ticked)

func _on_hour_ticked() -> void:
	if visible and _tab == 0 and not _client.is_busy():
		_refresh_local()

# ---------------------------------------------------------------------------
# 打开 / 关闭 / 拖动
# ---------------------------------------------------------------------------
## 打开面板但不问（ESC 菜单走这条：玩家多半是来配 key 的）。
func open() -> void:
	_cfg = AiConfig.load_cfg()
	visible = true
	select_tab(0)
	_place()

## 打开并**立刻问一次**（顶栏那个「AI 辅助」按钮走这条）。
func open_and_ask() -> void:
	open()
	if AiConfig.is_ready(_cfg):
		ask()
	else:
		_notice("AI 还没配置：在「设置」页填 base_url 与 model_name")
		select_tab(1)

func close_panel() -> void:
	visible = false
	if _client != null:
		_client.cancel()
	_resume_if_auto_paused()

func _place() -> void:
	# ⚠️ 顺序：**先**设 `custom_minimum_size`，**再** `reset_size()` ——
	# 反过来的话 `reset_size()` 用的是旧的最小尺寸，框高根本不变
	# （和 `panel_civic._apply_size()` 同一套写法）。
	custom_minimum_size = Vector2(PANEL_W, float(TAB_H[clampi(_tab, 0, TAB_H.size() - 1)]))
	reset_size()
	var vp := get_viewport_rect().size
	position = _clamp_pos(((vp - size) * 0.5).round())
	move_to_front()

func select_tab(i: int) -> void:
	_tab = clampi(i, 0, TABS.size() - 1)
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == _tab else UIKit.T_BTN))
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

func _build_advice_page() -> void:
	_status = UIKit.label("", UIKit.FG_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL_W - 46.0, 0)
	_body.add_child(_status)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_body.add_child(row)
	_ask_btn = UIKit.button("问 AI：现在该做什么", false)
	_ask_btn.pressed.connect(ask)
	row.add_child(_ask_btn)
	var again := UIKit.button("重算本地分析", true)
	again.tooltip_text = "本地分析是引擎现算的（不联网），每小时会自动跟着局势更新"
	again.pressed.connect(_refresh_local)
	row.add_child(again)
	_body.add_child(UIKit.hsep())

	_body.add_child(_head("本地分析（引擎计算，不联网）"))
	_local_body = _vbox()
	_body.add_child(_local_body)
	_body.add_child(UIKit.hsep())

	_ai_head = _head("预言家的进言")
	_body.add_child(_ai_head)
	_ai_body = _vbox()
	_body.add_child(_ai_body)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 5)
	_body.add_child(row2)
	_ask_input = UIKit.input("也可以追问一句（例如：先补粮还是先盖房？）", 200)
	_ask_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ask_input.text_submitted.connect(func(_t): ask())
	row2.add_child(_ask_input)
	var ask2 := UIKit.button("追问", true)
	ask2.pressed.connect(ask)
	row2.add_child(ask2)

	_refresh_status()
	_refresh_local()
	_show_ai_placeholder()

func _build_settings_page() -> void:
	_body.add_child(_wrapped("接入任何 OpenAI 兼容的 /chat/completions 服务（DeepSeek / OpenAI / 通义 / "
		+ "硅基流动 / ollama / llama.cpp / vLLM…）。只有 base_url 与 model_name 是必填的，"
		+ "api_key 可以留空（本地推理就不需要）。", UIKit.FG_DIM))
	_body.add_child(UIKit.hsep())

	_body.add_child(_head("base_url"))
	var e_url := UIKit.input(AiConfig.PLACEHOLDER_BASE_URL, 200)
	e_url.text = String(_cfg["base_url"])
	_body.add_child(e_url)
	_body.add_child(_wrapped("填到 /v1 为止就行，程序自己接 /chat/completions；"
		+ "已经填到 /chat/completions 也认。", UIKit.FG_DIM))

	_body.add_child(_head("model_name"))
	var e_model := UIKit.input(AiConfig.PLACEHOLDER_MODEL, 80)
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
	show.tooltip_text = "切换明文 / 圆点显示（只是显示，不改内容）"
	show.pressed.connect(func():
		e_key.secret = not e_key.secret
		show.text = "隐藏" if not e_key.secret else "显示")
	key_row.add_child(show)
	var clear := UIKit.button("清空", true)
	clear.pressed.connect(func(): e_key.text = "")
	key_row.add_child(clear)
	_body.add_child(_wrapped("key 只写在本机的 user://ai.cfg（和存档、音量设置放在一起），"
		+ "不会进仓库、不进存档、不进公告。界面上只显示头尾。", UIKit.FG_DIM))

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
	var e_mt := UIKit.input("800", 6)
	e_mt.text = str(int(_cfg["max_tokens"]))
	e_mt.custom_minimum_size = Vector2(72, UIKit.BTN_H_SM)
	adv.add_child(e_mt)

	var pause_btn := UIKit.button("", false)
	pause_btn.text = "提问时自动暂停：%s" % ("开" if bool(_cfg["pause_on_ask"]) else "关")
	pause_btn.tooltip_text = "问一次要几秒到几十秒；不暂停的话答案到手时局势已经往前跑了。" \
		+ "\n只冻时间，不改任何游戏状态。"
	pause_btn.pressed.connect(func():
		_cfg["pause_on_ask"] = not bool(_cfg["pause_on_ask"])
		pause_btn.text = "提问时自动暂停：%s" % ("开" if bool(_cfg["pause_on_ask"]) else "关"))
	_body.add_child(pause_btn)

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
	test.tooltip_text = "先保存设置，再发一句最短的话给模型；成功会显示模型的回话"
	test.pressed.connect(func():
		collect.call()
		_save_cfg("")
		_test_connection())
	btns.add_child(test)

	_body.add_child(_wrapped("配置文件：%s" % AiConfig.path, Color(0.66, 0.52, 0.36)))

# ---------------------------------------------------------------------------
# 本地分析 / AI 回答的渲染
# ---------------------------------------------------------------------------
## 造一个 Advisor：注入建造栏页签名（拿不到就不写页签，不编）。
func make_advisor() -> Advisor:
	var ad := Advisor.new(runner.sim if runner != null else null)
	if build_bar != null and build_bar.has_method("_category_of"):
		ad.cat_of = Callable(build_bar, "_category_of")
	if _ask_input != null:
		ad.question = _ask_input.text
	return ad

func _refresh_local() -> void:
	if _local_body == null or runner == null or runner.sim == null:
		return
	for c in _local_body.get_children():
		_local_body.remove_child(c)
		c.queue_free()
	var ad := make_advisor()
	# 面板上直接画结构化的建议（比一整块文本好读：标题深色、理由暗、做法缩进）
	var pl := ad.plan()
	if pl.is_empty():
		_local_body.add_child(_wrapped("程序没算出明显的短板：村子运转正常。"))
		return
	for i in pl.size():
		var s: Dictionary = pl[i]
		var t := "%d. ［%s］%s" % [i + 1, String(s["tag"]), String(s["title"])]
		_local_body.add_child(_wrapped(t, UIKit.FG_HEAD))
		_local_body.add_child(_wrapped("为什么：" + String(s["why"]), UIKit.FG_DARK))
		for h in (s["how"] as Array):
			var txt := String(h).strip_edges()
			if txt != "":
				_local_body.add_child(_wrapped("   " + txt, UIKit.FG_DIM))

func _refresh_status() -> void:
	if _status == null:
		return
	if AiConfig.is_ready(_cfg):
		_status.text = "模型 %s · %s · key %s" % [String(_cfg["model"]),
			String(_cfg["base_url"]), AiConfig.masked_key(_cfg)]
		_status.add_theme_color_override("font_color", UIKit.FG_DIM)
	else:
		_status.text = "还没配置：到「设置」页填 base_url 与 model_name。现在显示的是本地计算的结果。"
		_status.add_theme_color_override("font_color", C_WARN)

func _show_ai_placeholder() -> void:
	_clear_ai()
	if not AiConfig.is_ready(_cfg):
		_ai_body.add_child(_wrapped("（未配置 —— 点上面的按钮会提示去设置）", UIKit.FG_DIM))
	else:
		_ai_body.add_child(_wrapped("（点「问 AI：现在该做什么」，上山去问那位预言家；"
			+ "他看的是上面那份账，说的却是人话）", UIKit.FG_DIM))

func _clear_ai() -> void:
	for c in _ai_body.get_children():
		_ai_body.remove_child(c)
		c.queue_free()

## 模型的回答：逐行画。标题行深色，`征兆：`/`应对：` 行暗色，其余原样。
## 判断前先 `strip_edges()` —— 模型很爱给这几行缩进，按原样比对会漏掉一半。
## 前缀表里同时留着 `为什么`/`怎么做`/`总结`：旧格式的答案（或模型没照格式写时）
## 也能画得对，不会因为换了口吻就把整段回话变成一坨。
func _render_reply(text: String) -> void:
	_clear_ai()
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if line == "":
			continue
		var color := UIKit.FG_DARK
		for pre in ["征兆", "应对", "预言", "为什么", "怎么做", "总结"]:
			if line.begins_with(pre):
				color = UIKit.FG_DIM
				break
		if color == UIKit.FG_DARK and line.substr(0, 1).is_valid_int():
			color = UIKit.FG_HEAD
		_ai_body.add_child(_wrapped(line, color))

# ---------------------------------------------------------------------------
# 提问
# ---------------------------------------------------------------------------
func ask() -> void:
	if runner == null or runner.sim == null or _client == null:
		return
	if _client.is_busy():
		return
	if not AiConfig.is_ready(_cfg):
		_notice("还没配置 base_url 与 model_name（在「设置」页填）")
		select_tab(1)
		return
	_testing = false
	_start_request(make_advisor().messages(), "正在等预言家开口…（%s）" % String(_cfg["model"]))

func _test_connection() -> void:
	if _client.is_busy():
		return
	if not AiConfig.is_ready(_cfg):
		_notice("base_url 与 model_name 都不能空")
		return
	_testing = true
	# 回答要画在「建议」页上（那一页才有回答区），所以先切过去。
	# 顺序很要紧：**先切页再发请求** —— 切页会重建控件，发请求会往回答区塞「正在测试…」。
	select_tab(0)
	_start_request([
		{"role": "system", "content": "你是连通性测试。只回复两个字：收到"},
		{"role": "user", "content": "在吗"},
	], "正在测试连接…")

func _start_request(messages: Array, busy_text: String) -> void:
	# 提问时自动暂停：查询要几秒到几十秒，不冻住时间的话答案到手时局势已经变了。
	# 这是**纯表现层**动作（只动 SimRunner.paused，不进仿真状态、不影响确定性）。
	_auto_paused = false
	if bool(_cfg.get("pause_on_ask", true)) and runner != null and not runner.paused:
		if hud != null and hud.has_method("set_paused_external"):
			hud.set_paused_external(true)
		else:
			runner.set_paused(true)
		_auto_paused = true
	_set_ask_enabled(false)
	if _ai_head != null:
		_ai_head.text = "预言家的进言" + ("（测试连接）" if _testing else "")
	if _ai_body != null:
		_clear_ai()
		_ai_body.add_child(_wrapped(busy_text, UIKit.FG_HEAD))
	if not _client.ask(_cfg, messages):
		_set_ask_enabled(true)

## ⚠️ `_ask_btn` 只在「建议」页存在（设置页没有它）—— 一律走这个守卫，
## 否则在设置页点「测试连接」会空引用。
func _set_ask_enabled(v: bool) -> void:
	if _ask_btn != null:
		_ask_btn.disabled = not v

func _on_replied(text: String) -> void:
	_set_ask_enabled(true)
	_resume_if_auto_paused()
	var clean := AiClient.clean_reply(text)
	if _testing:
		_notice("连接成功：模型回话「%s」" % clean.replace("\n", " ").substr(0, 40))
		_clear_ai()
		_ai_body.add_child(_wrapped("连接成功，模型回话：" + clean, C_OK))
		_testing = false
		return
	_render_reply(clean)

func _on_failed(message: String) -> void:
	_set_ask_enabled(true)
	_resume_if_auto_paused()
	_testing = false
	if _ai_body != null:
		_clear_ai()
		_ai_body.add_child(_wrapped("问不到模型：" + message, C_WARN))
		_ai_body.add_child(_wrapped("（下面那块「本地分析」是引擎自己算的，照样能用；"
			+ "要改接入地址就去「设置」页）", UIKit.FG_DIM))
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
