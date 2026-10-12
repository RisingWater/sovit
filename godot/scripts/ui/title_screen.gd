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
const LOGO_MARGIN := 24.0
const LOGO_W := 520.0

var runner: SimRunner
var world: Node
var new_game_dialog: Node

signal start_requested

var _logo: TextureRect
var _fade: ColorRect
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

	# 右上 logo
	_logo = TextureRect.new()
	_logo.texture = load("res://assets/ui/logo_title.png")
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_logo)

	# 左下选项
	# 按钮直接压草地上读不清，垫一层半透明暗板
	var wrap := PanelContainer.new()
	wrap.name = "MenuWrap"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.66)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	wrap.add_theme_stylebox_override("panel", sb)
	add_child(wrap)
	var box := VBoxContainer.new()
	box.name = "Menu"
	box.add_theme_constant_override("separation", 8)
	wrap.add_child(box)
	var b_start := UIKit.button("开始游戏", false)
	b_start.custom_minimum_size = Vector2(200, 0)
	b_start.pressed.connect(_on_start)
	box.add_child(b_start)
	var b_load := UIKit.button("读取进度", false)
	b_load.custom_minimum_size = Vector2(200, 0)
	b_load.pressed.connect(_on_load)
	box.add_child(b_load)
	var b_quit := UIKit.button("退出游戏", false)
	b_quit.custom_minimum_size = Vector2(200, 0)
	b_quit.pressed.connect(func(): get_tree().quit())
	box.add_child(b_quit)

	# 切换村庄时的淡入淡出
	_fade = ColorRect.new()
	_fade.color = Color(0.03, 0.04, 0.06, 0.0)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)

	_layout()
	get_viewport().size_changed.connect(_layout)

func _layout() -> void:
	var vp := get_viewport_rect().size
	# 右上角
	_logo.size = Vector2(LOGO_W, LOGO_W * 581.0 / 1294.0)
	_logo.position = Vector2(vp.x - LOGO_W - LOGO_MARGIN, LOGO_MARGIN)
	# 左下角
	var wrap := get_node_or_null("MenuWrap")
	if wrap != null:
		wrap.size = wrap.get_combined_minimum_size()
		wrap.position = Vector2(LOGO_MARGIN, vp.y - wrap.size.y - LOGO_MARGIN)

## 开始展示：切到第一个村子并把镜头归位
func begin_showcase() -> void:
	_seed_idx = 0
	_t = 0.0
	_angle = 0.0
	_load_village()

func _load_village() -> void:
	if world == null or runner == null:
		return
	world.start_new_game(SHOWCASE_SEEDS[_seed_idx % SHOWCASE_SEEDS.size()], 1.0, "sovit")

func _process(delta: float) -> void:
	if world == null or world.camera == null or world.map == null:
		return
	# 镜头绕村庄中心缓慢环绕。用世界坐标：格子 * TILE。
	var center := Vector2(world.map.center) * float(world.TILE)
	if not _pan_paused:
		_angle += delta * PAN_SPEED
	world.camera.position = center + Vector2(cos(_angle) , sin(_angle) * 0.55) * PAN_RADIUS

	# 切换村庄
	if _fading == 0:
		_t += delta
		if _t >= SWITCH_SEC:
			_t = 0.0
			_fading = 1
			_pan_paused = true
	elif _fading == 1:
		_fade.color.a = minf(1.0, _fade.color.a + delta / FADE_SEC)
		if _fade.color.a >= 1.0:
			_seed_idx += 1
			_load_village()
			_pan_paused = false
			_fading = 2
	else:
		_fade.color.a = maxf(0.0, _fade.color.a - delta / FADE_SEC)
		if _fade.color.a <= 0.0:
			_fading = 0

# ---------------------------------------------------------------------------
func _on_start() -> void:
	# 交给新游戏对话框；它会调 world.start_new_game 覆盖掉展示用的那局
	if new_game_dialog != null:
		new_game_dialog.open()
		start_requested.emit()

func _on_load() -> void:
	var d := FileDialog.new()
	d.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	d.access = FileDialog.ACCESS_USERDATA
	d.add_filter("*.json", "存档")
	d.title = "读取进度…"
	d.size = Vector2i(760, 520)
	add_child(d)
	d.file_selected.connect(func(path: String):
		if world != null and world.load_from(path):
			start_requested.emit()
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	d.popup_centered()
