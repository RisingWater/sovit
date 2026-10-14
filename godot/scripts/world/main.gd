extends Node2D

# 入口：创建 SimRunner（仿真）+ WorldView（地图/建筑/小人）+ UI。
# F5 存档 / F9 读档。

var runner: SimRunner
var world
var _inspector
var _stats: GameStats
var _panel_stats
var _panel_tech
var _music
var _daylight
var _sfx
var _minimap
var _esc_menu
var _new_game
var _save_dialog
var _dlg_layer: CanvasLayer
var _title
var _title_layer
var root_ui: Control

func _ready() -> void:
	runner = SimRunner.new()
	runner.name = "SimRunner"
	add_child(runner)

	# 背景音乐：Shimmer Sill 两首轮流播放
	_music = load("res://scripts/ui/music.gd").new()
	_music.name = "Music"
	add_child(_music)

	# 菜单音效（Kenney UI SFX，CC0）。UIKit 是静态类，只能通过静态字段注入。
	_sfx = load("res://scripts/ui/sfx.gd").new()
	_sfx.name = "Sfx"
	add_child(_sfx)
	UIKit.sfx = _sfx

	world = load("res://scripts/world/world_view.gd").new()
	world.name = "World"
	world.setup(runner, 12345)
	add_child(world)

	# 昼夜光影：CanvasModulate 挂默认 canvas，只影响世界；UI 在 CanvasLayer 上不受影响
	_daylight = load("res://scripts/world/daylight.gd").new()
	_daylight.name = "Daylight"
	_daylight.setup(runner)
	add_child(_daylight)

	# 统计记录器：每过一个游戏日采样一次（只读仿真状态）
	_stats = GameStats.new()
	_stats.setup(runner)

	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	# 世界里的建筑名标签也在 CanvasLayer 上（layer=1），同层时先后顺序不可靠，
	# 会把字盖到统计面板上。UI 抬到 10，确保压在所有世界元素之上。
	canvas.layer = 10
	add_child(canvas)

	var theme := UIKit.make_theme()

	root_ui = Control.new()
	root_ui.name = "Root"
	root_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ui.theme = theme
	# 主题还要挂到 **window** 上：提示框（TooltipPanel）是独立弹出窗口，
	# 不在 root_ui 的子树里，只设 root_ui.theme 的话它拿不到。
	# 这就是"提示框改了样式却没变化"的原因。
	get_window().theme = theme
	canvas.add_child(root_ui)
	# 让世界知道 UI 根节点：鼠标落在 UI 面板上时不当作地图操作
	world.ui_root = root_ui

	var hud = load("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	hud.runner = runner
	hud.world = world
	# 必须在 add_child 之前赋值：hud._ready() 里就会读 music 来刷新按钮文案
	hud.music = _music
	hud.sfx = _sfx
	hud.left_inset = 168.0      # 红巾宽 160 + 间隙
	root_ui.add_child(hud)

	var bar = load("res://scripts/ui/build_bar.gd").new()
	bar.name = "BuildBar"
	bar.runner = runner
	bar.world = world
	root_ui.add_child(bar)

	_inspector = load("res://scripts/ui/inspector.gd").new()
	_inspector.name = "Inspector"
	_inspector.runner = runner
	_inspector.world = world
	root_ui.add_child(_inspector)

	_panel_stats = load("res://scripts/ui/panel_stats.gd").new()
	_panel_stats.name = "Stats"
	_panel_stats.setup(runner, world, _stats)
	root_ui.add_child(_panel_stats)
	hud.stats_panel = _panel_stats

	_panel_tech = load("res://scripts/ui/panel_tech.gd").new()
	_panel_tech.name = "Tech"
	_panel_tech.setup(runner, world)
	root_ui.add_child(_panel_tech)
	hud.tech_panel = _panel_tech

	world.select_building.connect(_inspector.show_building)
	world.select_housing.connect(_inspector.show_housing)
	world.select_resident.connect(_inspector.show_resident)
	world.select_none.connect(_inspector.clear)
	world.notice.connect(hud.set_notice)

	# 左上角小地图挂件（画在 HUD 之上）
	_minimap = load("res://scripts/ui/minimap_widget.gd").new()
	_minimap.name = "Minimap"
	_minimap.setup(runner, world)
	root_ui.add_child(_minimap)

	# ESC 菜单（最上层）
	_esc_menu = load("res://scripts/ui/esc_menu.gd").new()
	_esc_menu.name = "EscMenu"
	_esc_menu.setup(runner, world, hud)
	root_ui.add_child(_esc_menu)
	hud.esc_menu = _esc_menu

	# 新游戏对话框（标题页与 ESC 菜单都会用它）
	_new_game = load("res://scripts/ui/new_game_dialog.gd").new()
	_new_game.name = "NewGame"
	_new_game.setup(runner, world)
	root_ui.add_child(_new_game)
	_esc_menu.new_game_dialog = _new_game

	# 存档 / 读档对话框（自绘，见 save_dialog.gd 顶部注释）。
	# ESC 菜单和标题页的「读取进度」都走它 —— 以前那三处各自 new 一个 FileDialog，
	# 于是弹出来是"一半像素游戏风、一半 Godot 默认灰 UI"。
	#
	# ⚠️ 挂在自己的 CanvasLayer（layer 30）上，**不能**放进 root_ui：
	# 标题页期间 `root_ui.visible = false`，放里面的话从标题页点「读取进度」
	# 根本看不到对话框（取消之后还会被留在游戏里，因为露 UI 是标题页那套流程干的）。
	_dlg_layer = CanvasLayer.new()
	_dlg_layer.name = "DialogLayer"
	_dlg_layer.layer = 30
	add_child(_dlg_layer)
	_save_dialog = load("res://scripts/ui/save_dialog.gd").new()
	_save_dialog.name = "SaveDialog"
	# 不显式给主题的话它用的是 Godot 默认主题（理由同下面的标题页）
	_save_dialog.theme = theme
	_save_dialog.setup(runner, world)
	_dlg_layer.add_child(_save_dialog)
	_esc_menu.save_dialog = _save_dialog
	# 读档成功：如果当时还在标题页，就读档结果直接进游戏
	_save_dialog.loaded.connect(func(_p):
		if _title_layer != null and _title_layer.visible:
			_end_title())

	# 标题页：独立 CanvasLayer，压在整个游戏 UI 之上。
	# 展示期间把 root_ui 整个藏掉 —— 玩家看不到 HUD、点不到建造栏、也够不着 ESC 菜单，
	# 从玩家角度这局就是只读展示。开始游戏时再重新开局覆盖它。
	_title_layer = CanvasLayer.new()
	_title_layer.name = "TitleLayer"
	_title_layer.layer = 20
	add_child(_title_layer)
	_title = load("res://scripts/ui/title_screen.gd").new()
	_title.name = "Title"
	# 标题页挂在独立 CanvasLayer 上，**不在 root_ui 的子树里**，
	# 所以拿不到 root_ui.theme —— 不显式给的话它用的是 Godot 默认主题
	# （扁平灰按钮），和游戏内那套像素框完全不是一回事。
	_title.theme = theme
	_title.setup(runner, world, _new_game)
	_title.save_dialog = _save_dialog
	_title_layer.add_child(_title)
	_title.start_requested.connect(_end_title)
	root_ui.visible = false
	# 标题页期间关掉世界的鼠标输入。
	# 标题页挂在独立 CanvasLayer 上、不是 root_ui 的子节点，所以 world_view 里
	# 那个"鼠标在 UI 上就不碰镜头"的守卫认不出它 —— 结果在标题页滚轮照样能缩放。
	# 标题页是展示，屏幕上不该有"能操作地图"的错觉。
	world.set_process_unhandled_input(false)
	_title.begin_showcase()

## 标题页结束：露出游戏 UI（展示用的那局已被新游戏/读档覆盖）
func _end_title() -> void:
	root_ui.visible = true
	_title_layer.visible = false
	# 必须停掉 _process —— 它每帧都在改 camera.position，
	# 不停的话开局/读档之后镜头还会被标题页的环绕拉走。
	_title.set_process(false)
	world.set_process_unhandled_input(true)

func _process(_delta: float) -> void:
	if _stats == null:
		return
	# 只在真的采到新数据（跨天）时才重建面板。
	# 曾经写成"只要面板可见就 refresh()"，结果每帧销毁重建所有子节点，
	# 按钮永远点不动 —— 面板看起来正常，就是没反应。
	if _stats.poll() and _panel_stats != null and _panel_stats.visible:
		_panel_stats.refresh()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		# 标题页期间不弹游戏内菜单（那时 HUD 整个是隐藏的）
		if _title_layer != null and _title_layer.visible:
			return
		_esc_menu.toggle()
	if event.keycode == KEY_F5:
		var err := SaveManager.save_to(SaveManager.DEFAULT_PATH, runner.sim)
		print("save: ", err)
	elif event.keycode == KEY_F9:
		var loaded = SaveManager.load_into(SaveManager.DEFAULT_PATH, runner.db)
		if loaded != null:
			runner.sim = loaded
			runner.recent_logs = []
			runner.hour_ticked.emit()
			print("load: ok")
