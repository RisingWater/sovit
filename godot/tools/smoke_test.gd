extends SceneTree

# headless 冒烟：跑纯仿真 + 实例化主场景跑多帧 + 建造一栋并推进两天，确认无运行时错误。

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

	var runner = node.get("runner")
	var world = node.get("world")
	if runner == null or world == null:
		push_error("SMOKE: main 未创建 runner/world")
		quit(1)
		return

	# 在地图上下一单（应被接受并生成施工点）
	var c: Vector2i = world.map.center + Vector2i(6, 6)
	world._try_place("coarse_mill", c)
	print("SMOKE pending=", (runner.sim.s["pending"] as Array).size())

	# 推进 3 天，让建筑完工、小人走动
	for i in 72:
		runner.sim.tick_hour([])
		await process_frame

	print("SMOKE shops=", (runner.sim.s["shops"] as Array).size(), " day=", int(runner.sim.s["day"]))
	node.queue_free()
	await process_frame
	print("SMOKE RESULT: PASS")
	quit(0)
