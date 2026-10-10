extends SceneTree

# headless 冒烟：先跑 48 小时纯仿真，再实例化主场景跑几帧，确认无运行时错误。

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var db := ContentDB.load_all()
	var sim := SimCore.new(db)
	sim.new_game("v0.3", 12345)
	for i in 48:
		sim.tick_hour([])
	print("SMOKE sim ok: day=", int(sim.s["day"]), " pop=", (sim.s["residents"] as Array).size())

	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		push_error("SMOKE: 无法加载 main.tscn")
		quit(1)
		return
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	node.queue_free()
	await process_frame
	print("SMOKE RESULT: PASS")
	quit(0)
