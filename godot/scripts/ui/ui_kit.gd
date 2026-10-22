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
# 用 12px 那一档：10px 在 1600x900 下太小。像素字体只能用原生档位，
# 否则笔画会被重采样（10 -> 14 之类一定会糊）。
const FONT_PATH := "res://assets/fonts/fusion-pixel-12px-zh_hans.ttf"

const FS := 12          # 字号 = 像素字体原生尺寸，禁止改
## 大字档：12 的整数 2 倍。像素字体只能按整数倍放大，
## 12 -> 16 这类非整数会被重采样糊掉；24 实测每像素正好 2x2。
const BIG_FS := 24
## 村名长度上限。不是随便定的：小地图红巾宽 160px、村名用 BIG_FS=24px 像素字，
## 6 个汉字正好 144px。这个值是唯一来源，红巾、对话框、重开入口都引用它。
const NAME_MAX := 6
## 世界内标签专用字号：与大字档同值，理由同上。
const LABEL_FS := 24
const PAD_X := 9
const BTN_H := 26
const BTN_H_SM := 21
const GAP := 4
const BAR_H := 58
const BOT_H := 134
const ROW_H := 18
## 商品图标显示尺寸。手绘图标原生 32（程序化兜底是 16，放大到 32 也是整数倍）。
const CHIP_ICON := 32

## 面板标题 / 页签用的小图标（财政、科技…）。
##
## 与商品图标分开放：`assets/ui/panel/` 是**面板装饰**，`assets/icons/` 是商品图标。
## 混在一起的话 `GoodIcons.count_hand_drawn()` 会把面板图标也数进去。
const PANEL_ICON_DIR := "res://assets/ui/panel/"

## 取面板图标；没有则返回 null（调用方自己决定要不要留白）。
static func panel_icon(name: String) -> Texture2D:
	var p := PANEL_ICON_DIR + name + ".png"
	if ResourceLoader.exists(p):
		return load(p)
	return null

## 邦交（B4）：势力徽记 / 关系牌 / 动作按钮（`assets/ui/faction/`，48 或 32 原生）。
##
## 文件名 = 势力 id（`court` / `peak`…）、`rel_<档位>`（`rel_enemy`…）、`gift` / `treaty` / `war`。
## 取不到返回 null —— 面板那边自己决定要不要留白（别让缺图变成空白方块）。
const FACTION_ICON_DIR := "res://assets/ui/faction/"

static func faction_icon(name: String) -> Texture2D:
	if name == "":
		return null
	var p := FACTION_ICON_DIR + name + ".png"
	if ResourceLoader.exists(p):
		return load(p)
	return null

## 某势力当前该挂哪张关系牌：**附庸优先**（状态位压过数值档），其余按档位。
## `f` 是 `SimCore.factions_snapshot()` 里的一项（要 `band` / `vassal`）。
static func relation_icon(faction_id: String, f: Dictionary) -> Texture2D:
	var key := "rel_vassal" if bool(f.get("vassal", false)) \
		else "rel_" + String(f.get("band", "neutral"))
	var tex := faction_icon(key)
	if tex == null:
		tex = faction_icon("rel_neutral")
	return tex

## 顶栏 / 侧边圆钮用的"状态"图标（人口 / 就业 / 金币 / 建造力 / 研究力 / 移民 / 资源工业…）。
##
## 来自用户提供的素材包（作者 workbuddy，MIT），由 `scripts/import-stat-icons.py`
## 导到 `assets/ui/panel/`。命名用**英文**（population / money / build …），
## 不用中文文件名 —— 中文名在跨平台工具链里最容易出编码问题。
const STAT_ICON := 24

## 取状态图标；没有则返回 null（调用方自己决定要不要退回文字）。
static func stat_icon(name: String) -> Texture2D:
	if name == "":
		return null
	return panel_icon(name)

## 左侧圆钮的图标：`assets/ui/nav/<name>.png`（**圆盘烤在图里**，48×48 原生）。
##
## 2026-10 用户："圆框全是马赛克……直接用这个带圆形背景的图标吧" ——
## 圆盘（外圈深木 + 米色盘面）由 `scripts/gen-icons.py` 在 32px 图标下面合成进去，
## 按钮自己用空 StyleBox 不画框，所以边缘是**抗锯齿**的，不再是 3 倍 Nearest 拉出来的马赛克。
##
## 没有 nav 版时退回面板图标（`stat_icon`），这样新加一个圆钮也不会突然没图标。
const NAV_ICON_DIR := "res://assets/ui/nav/"

static func nav_icon(name: String) -> Texture2D:
	if name == "":
		return null
	var p := NAV_ICON_DIR + name + ".png"
	if ResourceLoader.exists(p):
		return load(p)
	return stat_icon(name)

## 科技树卡片图标（`assets/ui/tech/<techId>.png`，作者 workbuddy，MIT）。
## 文件名就是科技 id，所以这里直接用 id 取。
const TECH_ICON_DIR := "res://assets/ui/tech/"

## 2026-10 之前这里有一张 `TECH_ICON_ALIAS`（议价三档复用 _1 那张图）。用户："用 comfyui
## 来生成缺失的图标，交易的艺术 / 砍价的技巧这几个图标都重新做" —— 现在六档各有各的图，
## 别名表连同 `check-routes.ts::ICON_ALIAS` 一起删掉了。**别再引入"复用"**：
## 别名只写一边（TS 门槛或 UI）时，另一边拿不到图就是一块空白，而且不报错。
static func tech_icon(tech_id: String) -> Texture2D:
	var p := TECH_ICON_DIR + tech_id + ".png"
	if ResourceLoader.exists(p):
		return load(p)
	return null

## 科技卡片里的图标尺寸。**显示**一律 32：老素材是原生 32，2026-10 第三批是 64×64，
## 64 → 32 正好整除 ÷2（`tech_card.gd` 用 KEEP_ASPECT_CENTERED 缩，不会糊也不会溢出）。
const TECH_ICON_SIZE := 32

## 面板图标在按钮里的显示尺寸。按钮只有 21px 高，放 32px 会把整行撑开。
const PANEL_ICON_BTN := 16

## 用工拖动条的把手（8x12 像素：木身 + 上下金属箍，与左侧圆钮同一套配色）。
## 由 scripts/gen-art.ts 的 sliderGrabber() 生成，`npm run gen:art` 可重跑。
static func slider_grabber() -> Texture2D:
	var p := "res://assets/ui/slider_grabber.png"
	if ResourceLoader.exists(p):
		return load(p)
	return null


## 行内金额用的小金币（16×16 原生，价格 / 国库前面那一枚）。
##
## ⚠️ 别拿 `stat_icon("money")` 当行内金币：那是"财政"页签的图标（三级台阶式金币堆），
## 缩到 16px 看着像柱状图。用户 2026-10："价格用 @ 也太傻了，金币图标为什么不用？"
## 所以专门画了这枚（`scripts/gen-art.ts::coinIcon()`）。
static func coin_icon() -> Texture2D:
	var p := "res://assets/ui/coin.png"
	if ResourceLoader.exists(p):
		return load(p)
	return stat_icon("money")

## 建筑 / 住房缩略图，带兜底链。
##
## 全部缩略图都由 `npm run gen:art` 生成到 `assets/thumbs/<id>.png`
## （v3 成品整图是缩放来的，其余是程序化拼装后缩的）。
## 兜底到 buildings/ 是为了"缩略图还没生成"时不至于拿到 null。
##
## 全 UI 走这一个入口：建造栏和科技面板各写一份的话，
## 迟早有一处漏掉兜底（科技面板就这么漏过一次）。
static func thumb(id: String) -> Texture2D:
	var cands: Array[String] = [
		"res://assets/thumbs/%s.png" % id,
		"res://assets/buildings/%s.png" % id,
	]
	for p in cands:
		if ResourceLoader.exists(p):
			return load(p)
	return null
const CORNER := 5       # 9-slice 角尺寸

## 效率科技的效果键 → 中文。**唯一定义在这里**：科技面板顶部的累计行、卡片 tooltip、
## 研究所面板的「研究队列」页都读它（三处各写一份迟早会不一致）。
const EFFECT_NAMES := {
	"agri": "农业食品",
	"goods": "工业商品",
	"material": "建材",
	"research": "科研速度",
	"build": "建造速度",
	"services": "民生服务",
}

# 取件（来自清册核对）。tile 备件库已清过（2026-10）：ui/ 下只留这三张在用的，
# 其余 Kenney tile 与 T_STRIPE 一并删除（未被任何 box() 调用）。
const T_PANEL_DARK := 36
const T_PANEL_CREAM := 33
const T_BTN := 33
const T_BTN_ACTIVE := 34

const FG_DARK := Color(0.23, 0.16, 0.11)
const FG_LIGHT := Color(1.0, 0.96, 0.86)
const FG_HEAD := Color(0.43, 0.24, 0.14)
const FG_LABEL := Color(1.0, 0.93, 0.75)
const FG_DIM := Color(0.59, 0.41, 0.28)

static var _font: FontFile = null
static var _tex_cache: Dictionary = {}
## 音效播放器（由 main 注入）。UIKit 是静态类，拿不到实例，只能这样接。
## 为 null 时按钮照常工作，只是没声音。
static var sfx: Node = null


## 给按钮挂上点击音效。
## 悬停音太吵，去掉了 —— 悬停触发太频繁，菜单里像在响铃。
static func _wire_sfx(b: Button) -> void:
	if sfx == null:
		return
	b.pressed.connect(func(): sfx.click())


## 切换类操作（Tab、开关）用它，和普通点击区分开
static func play_switch() -> void:
	if sfx != null:
		sfx.switch_sfx()


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


## 缺字形 → 能画的替身。**只收"意思不变"的换法**：
## 数学符号换 ASCII、弯引号换「」、全角空格换半角。
## 表里没有的缺字直接**丢掉** —— 画成空/方块比少一个字更糟。
##
## ⚠️ 两条规矩：
##   ① 替身本身也必须是字体里**有**的字。`✓` 和 `√`(U+221A) 都缺，所以对勾只能退到 `·`；
##      `×`(U+00D7) 是有的，叉号照用。加条目之前先用 `Font.has_char()` 问一下引擎。
##   ② **键写成码点（int），不要写成字符字面量**：这张表的键按定义就是"字体里没有的字"，
##      写进字符串字面量会被门槛 `glyph_test` 抓个正着（它扫的就是字面量里的字）。
##      码点只出现在注释里 —— 注释不进画面，门槛不看。
##
## 为什么需要它：这条约束对**代码里写的字**靠门槛 `glyph_test` 兜
## （UI 里不许出现缺字形），但**模型的回答是运行时来的**，门槛管不着。
## 于是运行期再过一道这个函数（`AiClient.clean_reply()` 会调）。
const GLYPH_FIX := {
	0x2212: "-",        # − 减号 → ASCII 减号
	0x2211: "Σ",        # ∑ 求和 → 希腊 Sigma（字体里有）
	0x2248: "约",        # ≈ 约等于
	0x2260: "!=",       # ≠
	0x2264: "<=",       # ≤
	0x2265: ">=",       # ≥
	0x2717: "×",        # ✗
	0x2718: "×",        # ✘
	0x2713: "·",        # ✓（√ 也是缺的，只能退到点）
	0x2714: "·",        # ✔
	0x26A0: "！",        # ⚠
	0x2757: "！",        # ❗
	0x274C: "×",        # ❌
	0x201C: "「", 0x201D: "」",   # 弯双引号 → 直角引号
	0x2018: "「", 0x2019: "」",   # 弯单引号 → 直角引号
	0x3000: " ",        # 全角空格 → 半角
}

## 把一段文本收拾成"像素字体画得出来"的样子。
static func sanitize_text(s: String) -> String:
	var f := pixel_font()
	if f == null:
		return s
	var out := ""
	for i in s.length():
		var ch := s[i]
		if f.has_char(ch.unicode_at(0)):
			out += ch
			continue
		var fix: Variant = GLYPH_FIX.get(ch.unicode_at(0), null)
		if fix != null:
			out += String(fix)
		# 表里没有的：丢掉
	return out


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

## 建造卡片尺寸（缩略图 100x72 + 名称行）
const CARD_W := 112
const CARD_H := 96
const THUMB_H := 72


static func hud_box(corner: int = CORNER) -> StyleBoxTexture:
	return box(T_PANEL_DARK, corner, HUD_TINT)


## 「凹陷」底：列表 / 输入框 / 只读槽位用它。和 HUD 底同一块石板压暗，
## 于是米黄按钮摆在上面就是清楚的"亮件压暗底"关系。
static func inset_box(corner: int = CORNER, bright: float = 1.0) -> StyleBoxTexture:
	var tint := HUD_TINT
	if bright != 1.0:
		tint = Color(HUD_TINT.r * bright, HUD_TINT.g * bright, HUD_TINT.b * bright)
	return box(T_PANEL_DARK, corner, tint)


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

	# 输入框 / 多行输入：**凹陷石板底 + 亮色字**。
	#
	# 之前完全没设，于是 LineEdit 是 Godot 默认的白色方块 + 系统字体 ——
	# 用户在存档对话框里看到的就是"一半像素游戏风、一半默认灰 UI"
	# （同类问题还有 FileDialog 的列表、路径栏、下拉框、滚动条）。
	# 这里补齐输入框这一类；列表由 `inset_box()` 交给各对话框自绘。
	var le_normal := pad(inset_box(), 7, 3, 7, 3)
	var le_focus := pad(inset_box(CORNER, 1.25), 7, 3, 7, 3)
	th.set_stylebox("normal", "LineEdit", le_normal)
	th.set_stylebox("focus", "LineEdit", le_focus)
	th.set_stylebox("read_only", "LineEdit", pad(inset_box(CORNER, 0.8), 7, 3, 7, 3))
	th.set_color("font_color", "LineEdit", FG_LIGHT)
	th.set_color("font_placeholder_color", "LineEdit", Color(0.72, 0.76, 0.80, 0.75))
	th.set_color("font_selected_color", "LineEdit", FG_DARK)
	th.set_color("caret_color", "LineEdit", FG_LABEL)
	th.set_color("selection_color", "LineEdit", Color(0.98, 0.80, 0.42, 0.55))
	th.set_color("clear_button_color", "LineEdit", FG_LABEL)
	th.set_color("clear_button_color_pressed", "LineEdit", FG_HEAD)
	th.set_font_size("font_size", "LineEdit", FS)
	th.set_constant("minimum_character_width", "LineEdit", 3)

	th.set_stylebox("panel", "Panel", box(T_PANEL_DARK))

	# 提示框：用与其它面板同款的像素米黄纸框（不是纯色块），风格统一。
	# ⚠️ 光设这里还不够 —— 提示框是个**独立弹出窗口**，不在 root_ui 的子树里，
	#    拿不到 root_ui.theme。必须在 main.gd 里把主题挂到 window 上，
	#    否则这里设了也是白设（这就是"设了还是不透明地没变化"的原因）。
	th.set_stylebox("panel", "TooltipPanel", pad(box(T_PANEL_CREAM), 10, 7, 10, 7))
	th.set_color("font_color", "TooltipLabel", FG_DARK)
	th.set_font_size("font_size", "TooltipLabel", FS)
	return th


# ---------------------------------------------------------------------------
# 控件构造
# ---------------------------------------------------------------------------
## ⚠️ **数字就用 12（本字号），不要再给数字单独放大一档**。
## 2026-10 试过一版"所有数字用 18px"（起因：资源面板那几个大字看着很像素 —— 它们其实是
## 24px = 12 的整数 2 倍），用户看过之后否掉了："算了，数字改回来吧，不好看。"
## 所以顶栏、表格里的数字和正文同档。真要放大某处，用 `_big()`（BIG_FS=24，整数倍才不糊）；
## **别用 14 / 16 / 18 / 22 这种非整数倍去放大正文**，笔画会拆散。
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
	_wire_sfx(b)
	return b


## 输入框：凹陷石板底 + 亮色像素字。
## 显式挂字体/底纹，不依赖主题传递 —— 子窗口、弹出层拿不到 root theme 时也一样。
static func input(placeholder: String = "", max_len: int = 0) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	if max_len > 0:
		e.max_length = max_len
	e.custom_minimum_size = Vector2(0, BTN_H_SM)
	e.add_theme_font_override("font", pixel_font())
	e.add_theme_font_size_override("font_size", FS)
	e.add_theme_stylebox_override("normal", pad(inset_box(), 7, 3, 7, 3))
	e.add_theme_stylebox_override("focus", pad(inset_box(CORNER, 1.25), 7, 3, 7, 3))
	e.add_theme_color_override("font_color", FG_LIGHT)
	e.add_theme_color_override("caret_color", FG_LABEL)
	return e


## 列表行：米黄按钮 + 左对齐文字 + 稍高的行距。
## 选中态由调用方把底纹换成 `T_BTN_ACTIVE`（见 save_dialog）。
static func row_button(text: String) -> Button:
	var b := button(text)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, BTN_H_SM + 6)
	return b


## 纯图标按钮（速度控制用）。图标按原生 16px 显示，不缩放。
static func icon_button(icon_path: String, tip: String) -> Button:
	var b := Button.new()
	b.icon = load(icon_path)
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", pixel_font())
	b.add_theme_font_size_override("font_size", FS)
	b.custom_minimum_size = Vector2(BTN_H_SM + 8, BTN_H_SM)
	_wire_sfx(b)
	return b


## 「图标 + 文字」按钮：两者作为**一组**居中。
##
## ⚠️ 为什么不能用 Button 自带的 `icon` 属性：
##   Godot 把图标按 `icon_alignment` 定位、文字按 `alignment` 定位 —— **两者互不知情**。
##   窄按钮（宽度 = 内容宽，比如顶栏那个）刚好重合，看着是对的；
##   一旦按钮比内容宽（ESC 菜单里面板固定 240 宽），就变成
##   **"图标钉在最左、文字在正中间"两截**（实测）。两个都设 CENTER 更糟：
##   图标直接压在文字上（问号压在「辅」字上）。
##   所以这里跟 `card()` 一个办法：把内容当子节点塞进去，自己排。
##
## 宽度：先带着文字建一遍按钮（Godot 才会算出含内边距的正确宽度），量完再清掉文字、
## 把宽度钉成"原宽 + 图标 + 间隔"。宁可略宽也不要窄 —— 窄了内容会溢出按钮。
static func icon_text_button(text: String, icon: Texture2D, small: bool = false) -> Button:
	var b := button(text, small)
	var want := b.get_combined_minimum_size()
	b.text = ""
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var extra := 0.0
	if icon != null:
		var tr := TextureRect.new()
		tr.texture = icon
		tr.custom_minimum_size = Vector2(PANEL_ICON_BTN, PANEL_ICON_BTN)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tr)
		extra = PANEL_ICON_BTN + 5.0
	var l := label(text)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	b.custom_minimum_size = Vector2(want.x + extra, want.y)
	return b


## 图标**钉在按钮最左边**、文字**整体居中**的按钮（ESC 菜单那一列用，用户 2026-10 点名要）。
##
## 与 `icon_text_button()` 的区别：
##   · `icon_text_button()` 把"图标 + 文字"当成一组居中 —— 顶栏那种窄按钮要它（宽度贴着内容）；
##   · 这个的图标**不参与文字的排版**，所以文字在整条按钮里是真居中、图标不跟着文字跑。
##     按钮宽（ESC 菜单 240）的时候，这正是想要的样子。
##
## 图标的锚点用 `PRESET_CENTER_LEFT` + 固定偏移，所以按钮高度变了它也跟着垂直居中。
const ICON_LEFT_PAD := 9.0

static func icon_left_button(text: String, icon: Texture2D, icon_px: int = PANEL_ICON_BTN) -> Button:
	var b := button(text)
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	if icon == null:
		return b
	var tr := TextureRect.new()
	tr.name = "Icon"
	tr.texture = icon
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	var s := float(icon_px)
	tr.offset_left = ICON_LEFT_PAD
	tr.offset_right = ICON_LEFT_PAD + s
	tr.offset_top = -s * 0.5
	tr.offset_bottom = s * 0.5
	b.add_child(tr)
	return b


## 换掉 `icon_left_button()` / `icon_text_button()` 里那张图（冷却期间换灰问号那种）。
static func set_button_icon(b: Button, icon: Texture2D) -> void:
	if b == null or icon == null:
		return
	var tr := b.get_node_or_null("Icon") as TextureRect
	if tr != null:
		tr.texture = icon
		return
	# `icon_text_button()` 把图标塞在内部的 HBox 里（没有名字），退一步按类型找
	for c in b.get_children():
		if c is TextureRect:
			(c as TextureRect).texture = icon
			return
		if c is HBoxContainer:
			for g in c.get_children():
				if g is TextureRect:
					(g as TextureRect).texture = icon
					return


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


## 全屏面板共用的两件小事：藏掉地图那一侧的常驻件（小地图 + 左侧圆钮）、
## 以及"还有没有别的全屏面板开着"。
##
## 为什么要有它：Stats / Tech / QuestPanel / AiPanel 都是铺满视口的**兄弟节点**，
## 小地图的上沿本来就压在顶栏里 —— 光靠"面板盖住"会把它切成半个卡在左上角
## （用户报过："你没有隐藏地图，所以全屏 panel 出来的时候左上角很奇怪"）；
## 而**谁最后关**都得把常驻件还回来，所以"还开着没有"要问全体，不能只问自己。
##
## `host` 传面板自己（它必须是 `root_ui` 的子节点，常驻件是它的兄弟）。
const FULLSCREEN_PANELS := ["Stats", "Tech", "QuestPanel", "AiPanel"]

static func any_panel_open(host: Control, self_open: bool) -> bool:
	if self_open:
		return true
	var parent: Node = host.get_parent() if host != null else null
	if parent == null:
		return false
	for n in FULLSCREEN_PANELS:
		var c: Node = parent.get_node_or_null(n)
		if c != null and (c as CanvasItem).visible:
			return true
	return false

static func show_map_chrome(host: Control, on: bool) -> void:
	var parent: Node = host.get_parent() if host != null else null
	if parent == null:
		return
	for n in ["Minimap", "NavCol"]:
		var c: Node = parent.get_node_or_null(n)
		if c != null:
			(c as CanvasItem).visible = on

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
	_wire_sfx(b)
	return b
