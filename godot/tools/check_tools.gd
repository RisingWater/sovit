extends SceneTree

# 验证工具加成：产出 ×1.25，**投入不变**（"虚空产量"）。

func _init() -> void:
	call_deferred("_run")

func _mk(with_tools: bool) -> SimCore:
	var db = ContentDB.load_all()
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 9)
	# 直接标成已研究，专注看工具效果
	sim.s["research"]["done"] = ["stonework", "digging", "construction", "toolmaking"]
	sim.s["government"]["populationCap"] = 0.0
	# 造一座面包房（有投入也有产出，最容易看出"投入不变、产出变多"）
	sim.s["shops"] = [{
		"id": "coarse_bakery#1", "defId": "coarse_bakery", "owner": "state",
		"targetWorkers": 2, "wage": 3.0, "wageCap": 6.0, "level": 1, "active": true,
		"profit": 0.0, "skill": 50.0, "planned": 0.0, "toolBoost": 1.0,
	}]
	sim.s["goods"]["coarse_flour"] = 500.0
	sim.s["goods"]["stone_tools"] = 50.0 if with_tools else 0.0
	return sim

func _run_one(with_tools: bool) -> Dictionary:
	var sim = _mk(with_tools)
	var flour0 = float(sim.s["goods"]["coarse_flour"])
	var bread0 = float(sim.s["goods"]["coarse_bread"])
	# 只跑一个工作日的生产小时
	sim._assign_labor()
	sim._allocate_tools()
	sim._plan_production()
	var boost = float(sim.s["shops"][0].get("toolBoost", 1.0))
	for h in 12:
		sim._run_production_step(1.0 / 12.0)
	var used_flour = flour0 - float(sim.s["goods"]["coarse_flour"])
	var made_bread = float(sim.s["goods"]["coarse_bread"]) - bread0
	var tools_left = float(sim.s["goods"]["stone_tools"])
	return {"boost": boost, "flour_used": used_flour, "bread_made": made_bread, "tools_left": tools_left}

func _run() -> void:
	var a = _run_one(false)
	var b = _run_one(true)
	print("无工具: ", a)
	print("有工具: ", b)
	print("")
	print("产出倍率: ", a["bread_made"], " -> ", b["bread_made"],
		"  实际 ", snappedf(b["bread_made"] / a["bread_made"], 0.0001))
	print("投入变化: ", a["flour_used"], " -> ", b["flour_used"],
		"  比值 ", snappedf(b["flour_used"] / a["flour_used"], 0.0001), "（应 ≈ 1）")
	print("工具消耗: 50 -> ", b["tools_left"], "（应 49.9 = 0.05 × 2 人）")
	quit(0)
