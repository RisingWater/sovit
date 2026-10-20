extends PanelContainer

# ---------------------------------------------------------------------------
# 科技树上的一张卡片：图标 + 名字 + **效果** + 状态。
#
# 卡片**不判断任何规则**（能不能研究、前置够不够），只做两件事：
#   1. 把鼠标事件转给 panel_tech
#   2. 把 tooltip 请求转给 panel_tech（`_make_custom_tooltip` 才能返回带图标的 Control）
# 规则集中在面板一处，免得卡片和面板各判一套、将来分叉。
#
# ⚠️ `tooltip_text` 必须非空，Godot 才会去调 `_make_custom_tooltip`。
#    这里放科技名（真到了没有自定义 tooltip 的那天，至少还能显示个名字）。
#
# 2026-10（用户："这科技是干嘛完全看不明白"）：卡片上多一行**效果**
# （"商队 +1" / "载货 80 件" / "买价 -10%"）。原来只有名字 + "需先研究"，
# 十六张卡片摆在一起等于十六个黑盒 —— 效果只藏在 tooltip 里，没人会去挨个悬停。
# 文字由面板拼（`panel_tech._card_effect()`），卡片只负责显示。
# ---------------------------------------------------------------------------

const CARD_W := 108
## 没有效果行的高度（「制造」页的那棵树下全是这个尺寸）。
const CARD_H := 86
## 有效果行的高度（「效率」「贸易」两页）。多出来的 18 = 一行字 + 行距。
const CARD_H_EFFECT := 104

const BG_READY := Color(0.94, 0.90, 0.79)
const BG_LOCKED := Color(0.79, 0.77, 0.73)

## 效果行用绿色：与面板顶部"效率科技：农业食品 +10%"那行同一个含义（加成）。
## 状态行自己会变色（橙=研究中、绿=已完成、灰=需先研究），所以效果行不能也乱变色。
const EFFECT_COLOR := Color(0.22, 0.47, 0.24)

var host: Node = null
var tech_id := ""

var _name_label: Label
var _effect_label: Label
var _state_label: Label
var _icon: TextureRect
var _sb: StyleBoxFlat


func setup(p_host: Node, tid: String, disp: String, tex: Texture2D) -> void:
	host = p_host
	tech_id = tid

	custom_minimum_size = Vector2(CARD_W, CARD_H)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	tooltip_text = disp

	_sb = StyleBoxFlat.new()
	_sb.bg_color = BG_READY
	_sb.set_border_width_all(2)
	_sb.border_color = Color(0.62, 0.36, 0.16)
	_sb.set_corner_radius_all(3)
	_sb.content_margin_left = 4
	_sb.content_margin_right = 4
	_sb.content_margin_top = 5
	_sb.content_margin_bottom = 5
	add_theme_stylebox_override("panel", _sb)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vb)

	_icon = TextureRect.new()
	_icon.texture = tex
	_icon.custom_minimum_size = Vector2(UIKit.TECH_ICON_SIZE, UIKit.TECH_ICON_SIZE)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# 图标有两种原生尺寸：老的一批是 32×32，2026-10 用户补的第三批是 **64×64**
	# （方形画布、内容长边 58，见素材包的 `科技图标清单_v3.md`）。
	# 卡片只有 86 高，64 塞不下（图标 + 两行字就撑爆），所以**统一按 32 显示**：
	#   · 64 → 32 是整除 ÷2，像素不糊
	#   · 32 → 32 原样
	# 所以这里必须用 KEEP_ASPECT_CENTERED（KEEP_CENTERED 不缩放，64 的会画到卡片外）。
	# 想放大图标就跟 `CARD_W / CARD_H / TECH_ICON_SIZE` 一起改，别单独动这一个。
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_icon)

	_name_label = UIKit.label(disp, UIKit.FG_DARK)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.custom_minimum_size = Vector2(CARD_W - 14, 0)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_name_label)

	# 效果行：面板调 `set_effect()` 才显示（没有效果就藏着，不占高度）
	_effect_label = UIKit.label("", EFFECT_COLOR)
	_effect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_effect_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effect_label.custom_minimum_size = Vector2(CARD_W - 14, 0)
	_effect_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effect_label.visible = false
	vb.add_child(_effect_label)

	_state_label = UIKit.label("", UIKit.FG_DIM)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_state_label)


## 效果那一行（"商队 +1"）。空串 = 这项科技没有可写的加成（卡片保持矮的那版）。
func set_effect(text: String) -> void:
	_effect_label.text = text
	_effect_label.visible = text != ""


## 由面板调用：更新这张卡片的四种（五种，含"已排队待生效"）外观。
func set_state(text: String, color: Color, enabled: bool) -> void:
	_state_label.text = text
	_state_label.add_theme_color_override("font_color", color)
	_sb.border_color = color
	_sb.bg_color = BG_READY if enabled else BG_LOCKED
	# 不能研究的一律压暗，一眼就能看出"还没轮到它"
	modulate = Color(1, 1, 1, 1) if enabled else Color(0.72, 0.72, 0.72, 1)


func _make_custom_tooltip(_for_text: String) -> Object:
	if host != null and host.has_method("build_tooltip"):
		return host.build_tooltip(tech_id)
	return null


func _gui_input(event: InputEvent) -> void:
	if host != null and host.has_method("card_input"):
		host.card_input(self, event)
