extends Node2D

# 入口：创建 SimRunner（本次仿真）与 HUD（表现层）。

func _ready() -> void:
	var runner := SimRunner.new()
	runner.name = "SimRunner"
	add_child(runner)

	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	add_child(canvas)

	var hud = load("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	hud.runner = runner
	canvas.add_child(hud)
