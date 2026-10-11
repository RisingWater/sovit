extends Node2D

# 入口：创建 SimRunner（仿真）+ WorldView（地图/建筑/小人）+ UI。
# F5 存档 / F9 读档。

var runner: SimRunner
var world
var _inspector

func _ready() -> void:
	runner = SimRunner.new()
	runner.name = "SimRunner"
	add_child(runner)

	world = load("res://scripts/world/world_view.gd").new()
	world.name = "World"
	world.setup(runner, 12345)
	add_child(world)

	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var theme := UIKit.make_theme()

	var root_ui := Control.new()
	root_ui.name = "Root"
	root_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ui.theme = theme
	canvas.add_child(root_ui)

	var hud = load("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	hud.runner = runner
	hud.world = world
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

	world.select_building.connect(_inspector.show_building)
	world.select_housing.connect(_inspector.show_housing)
	world.select_resident.connect(_inspector.show_resident)
	world.select_none.connect(_inspector.clear)
	world.notice.connect(hud.set_notice)

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
