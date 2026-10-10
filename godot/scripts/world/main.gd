extends Node2D

# 入口：创建 SimRunner（本次仿真）与 HUD（表现层）。F5 存档 / F9 读档。

var runner: SimRunner

func _ready() -> void:
	runner = SimRunner.new()
	runner.name = "SimRunner"
	add_child(runner)

	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var hud = load("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	hud.runner = runner
	canvas.add_child(hud)

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
