extends GdUnitTestSuite

# 存档往返：保存 → 载入 → 摘要一致，且继续推进仍一致。

const PATH := "user://test_sovit_save.json"

func test_save_load_roundtrip() -> void:
	var db := ContentDB.load_all()
	var sim_a := SimCore.new(db)
	sim_a.new_game("v0.3", 777)
	for i in 72:
		sim_a.tick_hour([])
	var before := _summary(sim_a.s)

	var err := SaveManager.save_to(PATH, sim_a)
	assert_that(err).is_equal(OK)

	var sim_b := SaveManager.load_into(PATH, db)
	assert_that(sim_b).is_not_null()
	var after := _summary(sim_b.s)
	assert_that(after).is_equal(before)

	# 载入后继续 24 小时，两边仍应一致
	for i in 24:
		sim_a.tick_hour([])
		sim_b.tick_hour([])
	assert_that(_summary(sim_b.s)).is_equal(_summary(sim_a.s))

func _summary(s: Dictionary) -> Dictionary:
	var total := 0.0
	for g in s["goods"].keys():
		total += float(s["goods"][g])
	return {
		"day": int(s["day"]), "hour": int(s["hour"]),
		"pop": (s["residents"] as Array).size(),
		"money": float(s["government"]["money"]),
		"goods": total,
	}
