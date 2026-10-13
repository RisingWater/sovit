extends SceneTree

# 验证 GDScript 侧真的实现了新系统（门槛全绿并不代表功能搬过来了）。

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var db = ContentDB.load_all()
	print("technologies.json 载入: ", db.techs.size(), " 项 / 纪元 ", db.eras.size())
	print("研究所 capacity: ", db.buildings["research_institute"].get("capacity", {}))
	print("建筑工坊 capacity: ", db.buildings["construction_works"].get("capacity", {}))
	print("石制工具 toolBonus: ", db.tool_bonus("stone_tools"))
	print("v0.3 开局已研究: ", db.packs["v0.3"]["start"].get("techs", []))
	print("v1.0 开局已研究: ", db.packs["v1.0"]["start"].get("techs", []))

	var sim = SimCore.new(db)
	sim.new_game("v0.3", 5)
	print("")
	print("开局 research: ", sim.s["research"])
	print("开局 populationCap: ", sim.s["government"]["populationCap"])
	print("开局科研力/天: ", sim.research_rate())
	print("未研究时能否建采石场: ", sim.is_building_unlocked("quarry"))
	print("无科技锁的农场能否建: ", sim.is_building_unlocked("wheat_farm"))

	# 研究「研究所」→ 建成 → 科研力应该跳上去
	var t_before = sim.research_rate()
	sim.enqueue([{"type": "research", "techId": "research_institute"}])
	for h in 24 * 12:
		sim.tick_hour([])
	print("")
	print("12 天后已研究: ", sim.s["research"]["done"])
	print("科研力: ", t_before, " -> ", sim.research_rate())
	print("研究队列: ", sim.s["research"]["queue"])
	print("研究所已建: ", sim.s["shops"].filter(func(s): return s["defId"] == "research_institute").size())
	print("研究后能建采石场: ", sim.is_building_unlocked("quarry"))
	quit(0)
