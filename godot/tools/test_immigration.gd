extends SceneTree

# 手动调试工具（不在 verify.sh 门槛里）：观察新迁入规则的效果。
#
# 现在迁入只看：**满意度 + 食物充足 + 住房余量 + 人口上限**（不再看岗位数）。
# 用法：Godot --headless --path godot --script res://tools/test_immigration.gd

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var db = ContentDB.load_all()
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 1)
	# 这些建筑现在都带科技锁，先直接标成已研究，好让这个工具专注看迁入
	sim.s["research"]["done"] = ["stonework", "digging", "construction"]
	var acts := []
	for i in 10:
		acts.append({"type": "build_housing", "goodId": "hut"})
	for bid in ["lumberjack", "quarry", "clay_pit", "wheat_farm", "construction_works"]:
		acts.append({"type": "build", "buildingId": bid})
	sim.enqueue(acts)
	for d in 8:
		for h in 24:
			sim.tick_hour([])
		var s = sim.s
		print("day ", int(s["day"]), " pop ", (s["residents"] as Array).size(),
			" arrivals ", int(s["arrivals"]),
			" houseCap ", sim._housing_capacity(), " jobCap ", sim._job_capacity(),
			" popCap ", int(float(s["government"]["populationCap"])))
	quit(0)
