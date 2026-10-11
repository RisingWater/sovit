class_name UIKit
extends RefCounted

# ---------------------------------------------------------------------------
# UI 工具层：像素字体 + 9-slice StyleBox + 控件构造
#
# 素材：Kenney「UI Pack - Pixel Adventure」(CC0, 16px)。
# 该包的多数 tile 是"完整小控件"而非标准 9-slice 零件，所以这里把它的
# 圆角控件当作 9-slice 源：四角取 5x5，中间用 TILE 拉伸模式平铺
# （像素画不能用 STRETCH，会被插值糊掉）。
# ---------------------------------------------------------------------------

const UI_DIR := "res://assets/ui/"
const FONT_PATH := "res://assets/fonts/fusion-pixel-10px-zh_hans.ttf"

const FS := 10          # 字号 = 像素字体原生尺寸，禁止改
const PAD_X := 7
const BTN_H := 20
const BTN_H_SM := 16
const GAP := 3
const BAR_H := 48
const BOT_H := 112
const ROW_H := 15
const CORNER := 5       # 9-slice 角尺寸

# 取件（来自清册核对）
const T_PANEL_DARK := 36
const T_PANEL_CREAM := 33
const T_BTN := 33
const T_BTN_ACTIVE := 34
const T_STRIPE := 6

const FG_DARK := Color(0.23, 0.16, 0.11)
const FG_LIGHT := Color(1.0, 0.96, 0.86)
const FG_HEAD := Color(0.43, 0.24, 0.14)
const FG_LABEL := Color(1.0, 0.93, 0.75)
const FG_DIM := Color(0.59, 0.41, 0.28)

static var _font: FontFile = null
static var _tex_cache: Dictionary = {}


static func pixel_font() -> FontFile:
	if _font != null:
		return _font
	var f: FontFile = load(FONT_PATH)
	# 像素字体必须关掉抗锯齿与次像素定位，否则笔画发灰
	f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	f.multichannel_signed_distance_field = false
	f.hinting = TextServer.HINTING_NONE
	f.force_autohinter = false
	_font = f
	return f


static func tile(idx: int) -> Texture2D:
	if _tex_cache.has(idx):
		return _tex_cache[idx]
	var t: Texture2D = load("%stile_%04d.png" % [UI_DIR, idx])
	_tex_cache[idx] = t
	return t


static func box(idx: int, corner: int = CORNER, tint: Color = Color.WHITE) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = tile(idx)
	sb.texture_margin_left = corner
	sb.texture_margin_right = corner
	sb.texture_margin_top = corner
	sb.texture_margin_bottom = corner
	# 平铺而不是拉伸，保持像素硬边
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.modulate_color = tint
	return sb


## HUD 底：把石板面板压暗，盖在亮色地图上更清楚。
const HUD_TINT := Color(0.52, 0.56, 0.62)

## 建造卡片尺寸（缩略图 80x56 + 名称行）
const CARD_W := 88
const CARD_H := 76
const THUMB_H := 56


static func hud_box(corner: int = CORNER) -> StyleBoxTexture:
	return box(T_PANEL_DARK, corner, HUD_TINT)


static func pad(sb: StyleBoxTexture, l: int, t: int, r: int, b: int) -> StyleBoxTexture:
	sb.content_margin_left = l
	sb.content_margin_top = t
	sb.content_margin_right = r
	sb.content_margin_bottom = b
	return sb


static func make_theme() -> Theme:
	var th := Theme.new()
	th.default_font = pixel_font()
	th.default_font_size = FS

	# PanelContainer 默认用米黄纸面板
	th.set_stylebox("panel", "PanelContainer", box(T_PANEL_CREAM))

	# 按钮三态
	var normal := box(T_BTN)
	var hover := box(T_BTN)
	hover.modulate_color = Color(1.08, 1.08, 1.04)
	var pressed := box(T_BTN_ACTIVE)
	th.set_stylebox("normal", "Button", normal)
	th.set_stylebox("hover", "Button", hover)
	th.set_stylebox("pressed", "Button", pressed)
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_stylebox("disabled", "Button", box(T_BTN))
	th.set_color("font_color", "Button", FG_DARK)
	th.set_color("font_hover_color", "Button", FG_DARK)
	th.set_color("font_pressed_color", "Button", FG_LIGHT)
	th.set_color("font_disabled_color", "Button", FG_DIM)
	th.set_font_size("font_size", "Button", FS)
	th.set_constant("icon_max_width", "Button", 16)

	th.set_color("font_color", "Label", FG_DARK)
	th.set_font_size("font_size", "Label", FS)

	th.set_stylebox("panel", "Panel", box(T_PANEL_DARK))
	return th


# ---------------------------------------------------------------------------
# 控件构造
# ---------------------------------------------------------------------------
static func label(text: String, color: Color = FG_DARK) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", pixel_font())
	l.add_theme_font_size_override("font_size", FS)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, small: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", pixel_font())
	b.add_theme_font_size_override("font_size", FS)
	var h := BTN_H_SM if small else BTN_H
	b.custom_minimum_size = Vector2(0, h)
	return b


static func panel(dark: bool = false) -> PanelContainer:
	var p := PanelContainer.new()
	if dark:
		p.add_theme_stylebox_override("panel", pad(hud_box(), 6, 5, 6, 5))
	else:
		p.add_theme_stylebox_override("panel", pad(box(T_PANEL_CREAM), 6, 5, 6, 5))
	return p


static func hsep() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(0, 1)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.59, 0.41, 0.28, 0.6)
	p.add_theme_stylebox_override("panel", sb)
	return p


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


## 建造卡片：上方建筑缩略图，下方名称。点整张卡即触发。
static func card(text: String, thumb: Texture2D) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(CARD_W, CARD_H)
	b.focus_mode = Control.FOCUS_NONE
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 2
	vb.offset_right = -2
	vb.offset_top = 3
	vb.offset_bottom = -3
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 1)
	b.add_child(vb)

	var tr := TextureRect.new()
	tr.texture = thumb
	tr.custom_minimum_size = Vector2(0, THUMB_H)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(tr)

	var l := label(text)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(l)
	return b
