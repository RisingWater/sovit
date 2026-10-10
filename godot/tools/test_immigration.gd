extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var db = ContentDB.load_all()
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 1)
	var acts := []
	for i in 10:
		acts.append({"type": "build_housing", "goodId": "hut"})
	acts.append({"type": "build", "buildingId": "lumberjack"})
	acts.append({"type": "build", "buildingId": "quarry"})
	acts.append({"type": "build", "buildingId": "clay_pit"})
	acts.append({"type": "build", "buildingId": "wheat_farm"})
	acts.append({"type": "build", "buildingId": "construction_works"})
	sim.enqueue(acts)
	for d in 8:
		for h in 24:
			sim.tick_hour([])
		var s = sim.s
		print("day ", int(s["day"]), " pop ", (s["residents"] as Array).size(),
			" arrivals ", int(s["arrivals"]),
			" houseCap ", sim._housing_capacity(), " jobCap ", sim._job_capacity(),
			" allow ", int(float(s["government"]["immigrationAllowance"])))
	quit(0)
