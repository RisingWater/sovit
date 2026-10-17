extends Control

# 标题页：右上 logo，左下三个选项，背景是只读展示的村庄。
#
# 「只读展示」的实现方式
#   不进新开一套 SimRunner/WorldView —— 那要把世界重建一遍，代价大且容易不同步。
#   直接让**现有的** runner/world 跑一个展示种子，并把整个游戏 UI（root_ui）藏起来。
#   从玩家角度它就是只读的：看不到 HUD、点不到建造栏、ESC 菜单也够不着。
#   点「开始游戏」时才用新游戏对话框重新开局 —— 展示用的那局直接被覆盖掉，
#   所以不会污染存档。

const SWITCH_SEC := 14.0        # 每隔多久换一个村庄
const FADE_SEC := 1.2           # 切换时的淡入淡出时长
const PAN_RADIUS := 240.0       # 镜头绕村庄中心缓慢环绕的半径（世界像素）
const PAN_SPEED := 0.09         # 弧度/秒，很慢
## 展示用的固定种子。轮流用，切换时换下一个。
const SHOWCASE_SEEDS := [20240101, 777, 90210]
const LOGO_MARGIN := 28.0       # 四周留白
const LOGO_MAX_W := 960.0       # logo 最宽（1600 宽的视口下约 60%，高度靠宽高比反推）
const LOGO_FALLBACK_AR := 1.62  # 贴图读不到宽高比时的兜底（1277x786）
const MENU_BTN_H := 72.0

var runner: SimRunner
var world: Node
var new_game_dialog: Node
## 存档 / 读档对话框（自绘，main 注入；见 save_dialog.gd）
var save_dialog: Node = null

signal start_requested

var _logo: TextureRect
var _fade: ColorRect
var _top_scrim: TextureRect
var _bot_scrim: TextureRect
var _ar := LOGO_FALLBACK_AR
var _seed_idx := 0
var _t := 0.0
var _angle := 0.0
var _fading := 0            # 0=无 1=淡出中 2=淡入中
var _pan_paused := false

func setup(r: SimRunner, w: Node, dlg: Node) -> void:
	runner = r
	world = w
	new_game_dialog = dlg

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 切换村庄的淡入淡出。必须**最先**加进来 —— 它是全屏 ColorRect，
	# 后加就会盖住 logo 和按钮。放在最底下只挡世界那一层。
	_fade = ColorRect.new()
	_fade.color = Color(0.03, 0.04, 0.06, 0.0)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)

	# 上下两条压暗的渐变（兄弟顺序 = 绘制顺序，所以必须在 logo / 菜单之前加）：
	#   · 上：木刻 logo 是深底暖色，直接压在亮色的田地/屋顶上会糊成一片
	#   · 下：米黄纸框的菜单也要有底才读得清
	_top_scrim = _scrim(true)
	_bot_scrim = _scrim(false)

	# 正中 logo
	_logo = TextureRect.new()
	_logo.name = "Logo"
	_logo.texture = load("res://assets/ui/logo_title.png")
	if _logo.texture != null:
		var ts: Vector2 = _logo.texture.get_size()
		if ts.y > 0.0:
			_ar = ts.x / ts.y
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_logo)

	# 底部选项
	# 用与其它面板同款的像素米黄纸框（原来是半透明纯色块，和 UI 不是一套）。
	var wrap := PanelContainer.new()
	wrap.name = "MenuWrap"
	wrap.add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 18, 16, 18, 16))
	add_child(wrap)
	var box := VBoxContainer.new()
	box.name = "Menu"
	box.add_theme_constant_override("separation", 8)
	wrap.add_child(box)
	var b_start := UIKit.button("开始游戏", false)
	_big_button(b_start)
	b_start.pressed.connect(_on_start)
	box.add_child(b_start)
	var b_load := UIKit.button("读取进度", false)
	_big_button(b_load)
	b_load.pressed.connect(_on_load)
	box.add_child(b_load)
	var b_quit := UIKit.button("退出游戏", false)
	_big_button(b_quit)
	b_quit.pressed.connect(func(): get_tree().quit())
	box.add_child(b_quit)

	_layout()
	get_viewport().size_changed.connect(_layout)

## 标题页的按钮比游戏内大一倍：字号提到 BIG_FS(24)，尺寸跟着翻倍
func _big_button(b: Button) -> void:
	b.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	b.custom_minimum_size = Vector2(400, MENU_BTN_H)

## 一条上下压暗的渐变。返回的 TextureRect 由 `_layout()` 定尺寸位置。
func _scrim(top: bool) -> TextureRect:
	var g := Gradient.new()
	# 上面那条要盖住整个 logo（木刻字是暖色深底，直接压在亮色屋顶上会糊）
	g.set_color(0, Color(0, 0, 0, 0.58) if top else Color(0, 0, 0, 0.0))
	g.set_color(1, Color(0, 0, 0, 0.0) if top else Color(0, 0, 0, 0.80))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 8
	t.height = 512          # 竖着拉满也要够平滑，64 会看到色阶
	t.fill_from = Vector2(0.5, 0.0)
	t.fill_to = Vector2(0.5, 1.0)
	var r := TextureRect.new()
	r.name = "TopScrim" if top else "BotScrim"
	r.texture = t
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	return r

func _layout() -> void:
	var vp := get_viewport_rect().size
	var wrap := get_node_or_null("MenuWrap")
	var menu_h := MENU_BTN_H * 3.0 + 8.0 * 2.0 + 32.0
	if wrap != null:
		wrap.size = wrap.get_combined_minimum_size()
		menu_h = wrap.size.y
	# logo 拿走菜单上面那一整块，按**可用高度**反推宽度 —— 窗口再矮也不会压到菜单上
	var avail_h := maxf(120.0, vp.y - menu_h - LOGO_MARGIN * 3.0)
	var w := minf(minf(LOGO_MAX_W, vp.x - LOGO_MARGIN * 2.0), avail_h * _ar)
	var h := w / _ar
	_logo.size = Vector2(w, h)
	_logo.position = Vector2((vp.x - w) * 0.5, LOGO_MARGIN + (avail_h - h) * 0.5)
	# 菜单居中贴底
	if wrap != null:
		wrap.position = Vector2((vp.x - wrap.size.x) * 0.5, vp.y - menu_h - LOGO_MARGIN)
	# 渐变：上面压到 55%（logo 整个落在这一段里），下面 48%（菜单）
	var sh := vp.y * 0.55
	if _top_scrim != null:
		_top_scrim.position = Vector2.ZERO
		_top_scrim.size = Vector2(vp.x, sh)
	var bh := vp.y * 0.48
	if _bot_scrim != null:
		_bot_scrim.position = Vector2(0.0, vp.y - bh)
		_bot_scrim.size = Vector2(vp.x, bh)

## 开始展示：切到第一个村子并把镜头归位
func begin_showcase() -> void:
	_seed_idx = 0
	_t = 0.0
	_angle = 0.0
	_load_village()

func _load_village() -> void:
	if world == null or runner == null:
		return
	world.showcase_village(SHOWCASE_SEEDS[_seed_idx % SHOWCASE_SEEDS.size()])
	_t = 0.0
	if _fade != null:
		_fade.color.a = 0.0

func _process(delta: float) -> void:
	if world == null or world.camera == null or world.map == null:
		return
	# 镜头绕村庄中心缓慢环绕。用世界坐标：格子 * TILE。
	var center := Vector2(world.map.center) * float(world.TILE)
	if not _pan_paused:
		_angle += delta * PAN_SPEED
	world.camera.position = center + Vector2(cos(_angle) , sin(_angle) * 0.55) * PAN_RADIUS

	# 切换村庄。
	# delta 要夹一下：展示村庄的生成（铺路/摆建筑/快进几天）要花几秒，
	# 首帧的 delta 就是那几秒，不夹的话一次就把 SWITCH_SEC 顶满，
	# 标题页一出来就是全黑（正在淡出）。
	var d := minf(delta, 0.1)
	if _fading == 0:
		_t += d
		if _t >= SWITCH_SEC:
			_t = 0.0
			_fading = 1
			_pan_paused = true
	elif _fading == 1:
		_fade.color.a = minf(1.0, _fade.color.a + d / FADE_SEC)
		if _fade.color.a >= 1.0:
			_seed_idx += 1
			_load_village()
			_pan_paused = false
			_fading = 2
	else:
		_fade.color.a = maxf(0.0, _fade.color.a - d / FADE_SEC)
		if _fade.color.a <= 0.0:
			_fading = 0

# ---------------------------------------------------------------------------
func _on_start() -> void:
	# 交给新游戏对话框；它会调 world.start_new_game 覆盖掉展示用的那局
	if new_game_dialog != null:
		new_game_dialog.open()
		start_requested.emit()

func _on_load() -> void:
	# 走自绘的存档对话框（main 注入）。它挂在独立的 DialogLayer 上，
	# 所以标题页期间也看得见；读档成功后它会 loaded 信号 → main 收起标题页。
	if save_dialog != null:
		save_dialog.open_load(runner, world)
