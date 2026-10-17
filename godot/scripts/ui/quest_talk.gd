extends Control

# 剧情对话（galgame 形式）—— 任务触发 / 章节收尾都用这一个（用户 2026-10）。
#
# 数据由**引擎**给（`SimCore.quest_talks_pending()`），形状统一：
#   { key, kind, id, chapter, speaker, portrait, lines[], choices[]? }
# 这里只负责画：右侧立绘从边上滑进来、下中一个米黄文字框、说一句点一下翻页。
#
# 与 `intro.gd` 的分工：开场那五幕是**一次性硬编码剧本**（带黑屏旁白、村庄压暗、
# 第 5 幕露出 UI），这里只是"某个 NPC 说几句话"，所以是另一个更简单的脚本 ——
# 但视觉口径（立绘高度、框宽、▼ 闪动、点击翻页）刻意做成一样的。
#
# ⚠️ 台词里**不许出现像素字体没有的字**（见 godot/AGENTS.md 的缺字表）：
# 那个字会静默画成空白。门槛 `glyph_test` 扫的是 `content/quests.json` 全文。
# ⚠️ 剧情期间**时间暂停**由 `main` 负责（`hud.set_paused_external(true)`）。

## 全部台词说完（或玩家跳过）。`action` = 选项的 action（没有选项时空串）。
signal finished(action: String)

## 立绘占屏高多少（与开场剧情同一个数：0.78）
const PORTRAIT_H := 0.78
## 文字框宽度（与开场剧情同一个数：900）
const BOX_W := 900.0
## 一句话说完到能翻页之间不给"连点"，免得一次点击跳掉两页
const CLICK_LOCK := 0.08

var _lines: PackedStringArray = PackedStringArray()
var _choices: Array = []
var _page := 0
var _done := false
var _blink := 0.0
var _lock := 0.0
var _who := ""

var _dim: ColorRect
var _portrait: TextureRect
var _box: PanelContainer
var _name_lb: Label
var _text_lb: Label
var _arrow: Label
var _choice_row: HBoxContainer
var _skip: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	# 压暗（地图还在底下，但不该抢注意力）
	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.02, 0.03, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	# 立绘（右侧，底部贴屏幕底边）
	_portrait = TextureRect.new()
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_portrait)

	# 文字框（下中）
	_box = PanelContainer.new()
	_box.add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 20, 14, 20, 16))
	add_child(_box)
	var box_v := VBoxContainer.new()
	box_v.add_theme_constant_override("separation", 6)
	_box.add_child(box_v)
	_name_lb = UIKit.label("", UIKit.FG_HEAD)
	_name_lb.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	box_v.add_child(_name_lb)
	_text_lb = UIKit.label("", UIKit.FG_DARK)
	_text_lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_lb.custom_minimum_size = Vector2(BOX_W - 46.0, 0)
	box_v.add_child(_text_lb)
	# 右下角那个「▼」：闪动的"可以继续"
	_arrow = UIKit.label("▼", UIKit.FG_HEAD)
	_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box_v.add_child(_arrow)
	# 选项行（只有章节收尾那种带 choices 的才有）
	_choice_row = HBoxContainer.new()
	_choice_row.add_theme_constant_override("separation", 10)
	_choice_row.visible = false
	box_v.add_child(_choice_row)

	# 跳过（右上角）：玩家不该被一段话关住
	_skip = UIKit.button("跳过", true)
	_skip.tooltip_text = "直接关掉这段对话（Esc 也行）"
	_skip.pressed.connect(func(): _finish(""))
	add_child(_skip)

	_layout()
	get_viewport().size_changed.connect(_layout)

func _layout() -> void:
	var vp := get_viewport_rect().size
	if _skip != null:
		_skip.position = Vector2(vp.x - _skip.size.x - 16.0, 14.0)
	if _portrait != null:
		var ph := vp.y * PORTRAIT_H
		var pw := ph * 640.0 / 960.0
		_portrait.size = Vector2(pw, ph)
		_portrait.position = Vector2(vp.x - pw - 40.0, vp.y - ph)
	if _box != null:
		var h := _box.get_combined_minimum_size().y
		_box.size = Vector2(BOX_W, h)
		_box.position = Vector2(clampf((vp.x - BOX_W) * 0.5, 24.0, maxf(24.0, vp.x - BOX_W - 24.0)),
			vp.y - h - 56.0)

## 开始播一段对话。`talk` = 引擎给的字典（见文件头的形状说明）。
func play(talk: Dictionary) -> void:
	_lines = PackedStringArray()
	for l in (talk.get("lines", []) as Array):
		var t := String(l)
		if t != "":
			_lines.append(t)
	_choices = (talk.get("choices", []) as Array).duplicate()
	_page = 0
	_done = false
	_lock = 0.0
	_who = String(talk.get("speaker", ""))
	_name_lb.text = Cast.speaker_name(_who)
	_name_lb.visible = _who != ""
	# 台词为空（内容写漏了）时别卡住：直接算播完
	if _lines.is_empty():
		visible = true
		_finish("")
		return
	visible = true
	_set_portrait(String(talk.get("portrait", _who)))
	_render_page()

func _set_portrait(pid: String) -> void:
	var tex := Cast.portrait(pid)
	if tex == null:
		_portrait.visible = false
		return
	_portrait.texture = tex
	_portrait.visible = true
	_layout()
	# 从屏幕右侧滑进来（和开场剧情一个动作）
	var vp := get_viewport_rect().size
	var target := Vector2(vp.x - _portrait.size.x - 40.0, vp.y - _portrait.size.y)
	_portrait.position = Vector2(vp.x + 20.0, target.y)
	var tw := create_tween()
	tw.tween_property(_portrait, "position", target, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _is_last_page() -> bool:
	return _page >= _lines.size() - 1

func _render_page() -> void:
	_text_lb.text = _lines[clampi(_page, 0, _lines.size() - 1)]
	# 最后一页且带选项 → 出选项、收掉「▼」
	var show_choices := _is_last_page() and not _choices.is_empty()
	_arrow.visible = not show_choices
	_choice_row.visible = show_choices
	if show_choices and _choice_row.get_child_count() == 0:
		for c in _choices:
			var d: Dictionary = c
			var action := String(d.get("action", "close"))
			var b := UIKit.button(String(d.get("text", "（好）")), action == "free_prophecy")
			b.pressed.connect(func(): _pick(action))
			_choice_row.add_child(b)
	_layout()

func _pick(action: String) -> void:
	if _done:
		return
	_finish(action)

## 下一页；最后一页没选项时再点一下就结束。
func _advance() -> void:
	if _done or _lock > 0.0:
		return
	if _is_last_page():
		# 带选项的最后一页：点空白**不算选**，得真按一个选项
		if not _choices.is_empty():
			return
		_finish("")
		return
	_page += 1
	_lock = CLICK_LOCK
	UIKit.play_switch()
	_render_page()

func _finish(action: String) -> void:
	if _done:
		return
	_done = true
	visible = false
	finished.emit(action)

func _process(delta: float) -> void:
	if not visible:
		return
	if _lock > 0.0:
		_lock = maxf(0.0, _lock - delta)
	_blink += delta
	if _arrow != null and _arrow.visible:
		_arrow.modulate.a = 0.35 + 0.65 * absf(sin(_blink * 2.2))

## 鼠标点**任意地方**翻页（用户 2026-10："galgame 窗口点鼠标无法继续，只能按空格"）。
##
## ⚠️ 为什么在 `_input` 里自己做命中判定，而不是只靠 `Control._gui_input`：
## 文字框是 `PanelContainer` + `Label`，`mouse_filter` 默认是 STOP —— 点在框上会被它们
## **吃掉**，父节点的 `_gui_input` 根本收不到（就是这个 bug）。
## 而"把框设成 IGNORE 让点击穿过去"也不行：Godot 的 GUI 拾取遇到
## `MOUSE_FILTER_IGNORE` 的父节点会**整棵子树跳过**，框里的选项按钮会跟着点不动
## （门槛 questtalk 里有一条真鼠标点 accept 的断言，就是这么红的）。
## 所以：点在按钮上 → 放给按钮；点在别处（框上、立绘上、空地）→ 翻页。
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if _over_interactive(mb.position):
				return          # 「跳过」/ 选项按钮自己处理，**不要** consume
			get_viewport().set_input_as_handled()
			_advance()
			return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_finish("")
		elif k == KEY_SPACE or k == KEY_ENTER or k == KEY_KP_ENTER:
			get_viewport().set_input_as_handled()
			_advance()

## 这个点是不是落在**能按的东西**上（「跳过」或选项按钮）。
## 是的话鼠标要让给按钮 —— 否则点「跳过」会变成翻页、点选项会变成什么也没发生。
func _over_interactive(pos: Vector2) -> bool:
	if _skip != null and _skip.visible and _skip.get_global_rect().has_point(pos):
		return true
	if _choice_row != null and _choice_row.visible:
		for c in _choice_row.get_children():
			if c is Button and (c as Button).visible \
					and (c as Button).get_global_rect().has_point(pos):
				return true
	return false
