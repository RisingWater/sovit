extends Control

# 开场剧情（第 1~5 幕）。用户 2026-10 给的完整分幕脚本。
#
# 形式：
#   · 第 1 幕 —— **黑屏白字**，一行一行出现（这里按"一页一组字"推进，点一下就翻页）
#   · 第 2~4 幕 —— 村庄地图压暗，立绘从右侧滑入，文字框在**下中**（galgame 那种），
#     框右下角一个闪动的「▼」提示可以继续
#   · 第 5 幕 —— 剧情收尾：露出游戏 UI，智囊的小头像落在**左下角**，说最后一句
#
# 剧情期间**时间暂停**（`main` 负责 `runner.set_paused`），音乐换成开场那首
# （`music.play_intro()`，播完自动回到常规轮播）。
#
# 推进：点一下 / 空格 / 回车 → 下一页；`Esc` 或右上角「跳过」→ 直接进游戏。
# ⚠️ 剧情文本里**不许出现像素字体没有的字**（见 godot/AGENTS.md 的缺字表），门槛 `intro_test` 会查。

signal finished

## 立绘在剧情里占屏高多少（半身像，底部贴屏幕底边）
const PORTRAIT_H := 0.78
## 第 5 幕左下角那个小头像的高度（像素）
const CORNER_H := 300.0
## 文字框宽度
const BOX_W := 900.0
## 黑屏旁白**自动翻页**的间隔（用户 2026-10："黑屏的字母要带自动跳过，比如 3 秒自动下一句"）。
## 只有第 1 幕（黑屏）自动走；后面有立绘的几幕还是点一下翻 —— 那是"对话"，玩家要自己控节奏。
const NARR_AUTO_SEC := 3.0

## 每一幕：`bg` = black / village / game，`who` = 立绘 id（空 = 旁白），
## `pages` = 一页一组字（每页里一行一个字符串）。
const SCRIPT := [
	{
		"bg": "black", "who": "",
		"pages": [
			["帝国纪元（AE）312 年。"],
			["老国王年事已高，", "膝下有七个儿子。"],
			["按照传统，", "每位王子成年后，", "都要被分封到边陲之地，", "独自经营一片领地。"],
			["三年之后，", "国王将根据各领地的繁荣程度，", "决定继承人。"],
			["你，是第七王子。"],
			["你的封地，", "只有 {pop} 个村民，", "一片荒地，几座茅屋", "和一座摇摇欲坠的城镇中心。"],
		],
	},
	{
		"bg": "village", "who": "sebastian",
		"pages": [
			["殿下，老臣塞巴斯蒂安，奉国王之命辅佐您。"],
			["这片土地虽然贫瘠，", "但只要经营得当，", "未必不能成为富庶之地。"],
			["只是……老臣得提醒您，", "国库只有 {money} 金币，", "{pop} 个村民，连饭都吃不饱。"],
			["您得先建农场，种小麦，", "再建磨坊、面包房。", "否则，冬天之前，他们会饿死。"],
		],
	},
	{
		"bg": "village", "who": "vera",
		"pages": [
			["殿下，我是您的财务官，薇拉。"],
			["国库 {money} 金币，我给您算过了。"],
			["除去各种开销，可能，撑不过 30 天。"],
			["您最好想清楚，每一分钱花在哪。"],
			["……还有，别乱花钱。"],
		],
	},
	{
		"bg": "village", "who": "reynard",
		"pages": [
			["殿下，国王陛下有旨。"],
			["陛下让我转告您：", "三年之后，他将巡视各领地，", "根据繁荣程度，决定继承人。"],
			["您的六位兄长，", "有的已经建起了城镇，", "有的已经养起了军队。"],
			["而您……"],
			["陛下希望您不要让他失望。"],
			["对了，陛下还让我带句话：", "他会看着您的。"],
		],
	},
	{
		"bg": "game", "who": "sebastian",
		"pages": [
			["殿下，先建农场吧。", "食物可能撑不了多久。"],
		],
	},
]

## 说话人的中文名、立绘、头像统一走 `Cast`（见 scripts/ui/cast.gd）：
## 内容里同一个人有 `renard` / `reynard`、`vila` / `vera`、`seraphina` / `serafina`
## 三种拼法，名字表散着写迟早对错人。

var _act := 0
var _page := 0
## 当前这一页已经停了多久（黑屏旁白到点自动翻）
var _wait := 0.0
## 每一幕的立绘换过没有（换人时上一个滑出去、新的滑进来）
var _shown_who := ""
var _done := false
var _blink := 0.0
## 把 {money} / {pop} 换成开局真实数字
var _subs := {"money": "2000", "pop": "12"}

var _black: ColorRect
var _dim: ColorRect
## 黑屏旁白（第 1 幕）：居中白字，不用 galgame 那个米黄框
var _narr: Label
var _portrait: TextureRect
var _corner: TextureRect
var _box: PanelContainer
var _name_lb: Label
var _text_lb: Label
var _arrow: Label
var _skip: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	# 黑幕（第 1 幕）
	_black = ColorRect.new()
	_black.color = Color(0.02, 0.02, 0.03, 1.0)
	_black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_black)

	# 压暗（第 2~4 幕，叠在村庄地图上）
	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.02, 0.03, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	# 黑屏旁白（第 1 幕）：居中白字
	_narr = UIKit.label("", Color(0.93, 0.92, 0.88))
	_narr.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	_narr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_narr.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_narr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_narr)

	# 立绘（右侧，底部贴屏幕底边）
	_portrait = TextureRect.new()
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_portrait)

	# 第 5 幕左下角的小头像
	_corner = TextureRect.new()
	_corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_corner.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_corner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_corner.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_corner.visible = false
	add_child(_corner)

	# 文字框（下中）
	_box = PanelContainer.new()
	_box.add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 20, 14, 20, 16))
	_box.visible = false
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

	# 跳过（右上角，别让玩家被一段剧情关住）
	_skip = UIKit.button("跳过", true)
	_skip.tooltip_text = "直接进入游戏（Esc 也行）"
	_skip.pressed.connect(_finish)
	add_child(_skip)

	_layout()
	get_viewport().size_changed.connect(_layout)

func _layout() -> void:
	var vp := get_viewport_rect().size
	if _skip != null:
		_skip.position = Vector2(vp.x - _skip.size.x - 16.0, 14.0)
	if _black != null:
		# 黑幕/压暗是**全屏锚定**的，别在这里改 size（会报 "opposite anchors" 的警告）
		pass
	if _narr != null:
		_narr.size = Vector2(vp.x - 240.0, vp.y * 0.6)
		_narr.position = Vector2(120.0, (vp.y - vp.y * 0.6) * 0.5)
	if _portrait != null:
		var ph := vp.y * PORTRAIT_H
		var pw := ph * 640.0 / 960.0
		_portrait.size = Vector2(pw, ph)
		_portrait.position = Vector2(vp.x - pw - 40.0, vp.y - ph)
	if _corner != null:
		# 头像（AtlasTexture 裁到上半身）：按实际纹理比例算宽
		var cw := CORNER_H
		if _corner.texture != null and _corner.texture.get_height() > 0.0:
			cw = CORNER_H * _corner.texture.get_width() / _corner.texture.get_height()
		_corner.size = Vector2(cw, CORNER_H)
		_corner.position = Vector2(24.0, vp.y - CORNER_H - 8.0)
	if _box != null:
		var h := _box.get_combined_minimum_size().y
		_box.size = Vector2(BOX_W, h)
		# 第 5 幕给左下角那个头像让位
		var left := 24.0 + (_corner.size.x + 20.0 if _corner != null and _corner.visible else 0.0)
		var x := clampf((vp.x - BOX_W) * 0.5, left, maxf(left, vp.x - BOX_W - 24.0))
		_box.position = Vector2(x, vp.y - h - 56.0)

## 开始播放。`sim` 用来把 {money}/{pop} 换成真实数字。
func begin(sim) -> void:
	if sim != null and sim.s != null:
		_subs["money"] = "%.0f" % float((sim.s["government"] as Dictionary)["money"])
		_subs["pop"] = str((sim.s["residents"] as Array).size())
	_act = 0
	_page = 0
	_done = false
	_shown_who = ""
	visible = true
	_apply_act()
	_render_page()

## 跳到第 i 幕（0 起，第 1 幕 = 0）。给截图工具和门槛用 —— 一路点过去太慢。
func jump_to_act(i: int) -> void:
	_act = clampi(i, 0, SCRIPT.size() - 1)
	_page = 0
	_shown_who = ""
	_apply_act()
	_render_page()

# ---------------------------------------------------------------------------
func _act_data() -> Dictionary:
	return SCRIPT[clampi(_act, 0, SCRIPT.size() - 1)]

func _apply_act() -> void:
	var a := _act_data()
	var bg := String(a["bg"])
	_black.visible = bg == "black"
	# 压暗只压在"还在地图前说话"的那几幕；第 5 幕已经进游戏了，不能再压暗
	_dim.visible = bg == "village"
	var who := String(a["who"])
	_corner.visible = bg == "game" and who != ""
	_box.visible = bg != "black"
	# 立绘：黑屏/收尾那一幕不出大图；其余从右侧滑进来
	if bg == "village" and who != "":
		_set_portrait(who)
	else:
		_portrait.visible = false
	if bg == "game" and who != "":
		_corner.texture = _corner_texture(who)
	_layout()

func _set_portrait(who: String) -> void:
	var tex := _portrait_texture(who)
	if tex == null:
		_portrait.visible = false
		return
	_portrait.texture = tex
	_portrait.visible = true
	# 换人：从屏幕右侧滑进来（用户："立绘从右侧滑入"）
	if who != _shown_who:
		_shown_who = who
		var vp := get_viewport_rect().size
		var target := Vector2(vp.x - _portrait.size.x - 40.0, vp.y - _portrait.size.y)
		_portrait.position = Vector2(vp.x + 20.0, target.y)
		var tw := create_tween()
		tw.tween_property(_portrait, "position", target, 0.35) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _portrait_texture(who: String) -> Texture2D:
	return Cast.portrait(who)

## 第 5 幕左下角那个**头像**：立绘是半身像，直接缩到 300 高会整条人都挤在角上，
## 所以只取**上面 36%**（头顶到胸口），看起来才是"头像"。
func _corner_texture(who: String) -> Texture2D:
	return Cast.portrait_head(who)

func _page_text() -> String:
	var a := _act_data()
	var pages: Array = a["pages"]
	var lines: Array = pages[clampi(_page, 0, pages.size() - 1)]
	var out := PackedStringArray()
	for l in lines:
		var t := String(l)
		for k in _subs.keys():
			t = t.replace("{%s}" % k, String(_subs[k]))
		out.append(t)
	return "\n".join(out)

func _render_page() -> void:
	var a := _act_data()
	var who := String(a["who"])
	var bg := String(a["bg"])
	# 第 1 幕是"黑屏白字"，居中；其余是 galgame 那种下中的文字框
	_narr.visible = bg == "black"
	_box.visible = bg != "black"
	if _narr.visible:
		_narr.text = _page_text()
	_name_lb.visible = who != ""
	_name_lb.text = Cast.speaker_name(who) if who != "" else ""
	_text_lb.text = _page_text()
	_arrow.visible = bg != "black"
	# 每翻一页就从 0 重新计时（手动翻页也重置）
	_wait = 0.0
	_layout()

## 下一页；这一幕翻完了就进下一幕。
func _advance() -> void:
	if _done:
		return
	_wait = 0.0
	var pages: Array = _act_data()["pages"]
	if _page + 1 < pages.size():
		_page += 1
		_render_page()
		UIKit.play_switch()
		return
	_act += 1
	_page = 0
	if _act >= SCRIPT.size():
		_finish()
		return
	_apply_act()
	_render_page()
	UIKit.play_switch()

func _finish() -> void:
	if _done:
		return
	_done = true
	visible = false
	finished.emit()

func _process(delta: float) -> void:
	if not visible:
		return
	# 「▼」闪一下，提示还能继续
	_blink += delta
	if _arrow != null and _arrow.visible:
		_arrow.modulate.a = 0.35 + 0.65 * absf(sin(_blink * 2.2))
	# 黑屏旁白到点自己翻（用户 2026-10："3 秒自动下一句"）；手动点会重置计时
	if String(_act_data()["bg"]) == "black" and _box != null and not _box.visible:
		_wait += delta
		if _wait >= NARR_AUTO_SEC:
			_wait = 0.0
			_advance()

## 鼠标点**任意地方**翻页。
##
## ⚠️ 和任务对话（`quest_talk.gd`）同一个坑：文字框是 `PanelContainer` + `Label`，
## `mouse_filter` 默认 STOP，点在框上会被吃掉、父节点的 `_gui_input` 收不到 ——
## 于是"点鼠标没反应、只能按空格"。这里在 `_input` 里自己判命中，框上也能翻。
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			# 「跳过」按钮自己吃，别把它的点击变成翻页
			if _skip != null and _skip.visible and _skip.get_global_rect().has_point(mb.position):
				return
			get_viewport().set_input_as_handled()
			_advance()
			return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_finish()
		elif k == KEY_SPACE or k == KEY_ENTER or k == KEY_KP_ENTER:
			get_viewport().set_input_as_handled()
			_advance()
