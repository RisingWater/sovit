extends Node2D

# 入口：创建 SimRunner（仿真）+ WorldView（地图/建筑/小人）+ UI。
# F5 存档 / F9 读档。

var runner: SimRunner
var world
var _inspector
var _stats: GameStats
var _panel_stats
var _music
var _daylight
var _sfx

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

	var root_ui := Control.new()
	root_ui.name = "Root"
	root_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ui.theme = theme
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

	world.select_building.connect(_inspector.show_building)
	world.select_housing.connect(_inspector.show_housing)
	world.select_resident.connect(_inspector.show_resident)
	world.select_none.connect(_inspector.clear)
	world.notice.connect(hud.set_notice)

func _process(_delta: float) -> void:
	if _stats != null:
		_stats.poll()
		if _panel_stats != null and _panel_stats.visible:
			_panel_stats.refresh()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
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
