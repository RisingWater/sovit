extends GdUnitTestSuite

# 回放 TS 生成的 golden 脚本，逐日比对仿真摘要。
# 任何公式/顺序/常量与 docs/spec.md 不一致都会在这里暴露。

const TOL := 0.02

func test_golden_files() -> void:
	var db = ContentDB.load_all()
	assert_that(db.schema_version).is_equal(1)
	var dir = DirAccess.open("res://tests/golden")
	assert_that(dir).is_not_null()

	var mismatches := []
	for file in dir.get_files():
		if not file.ends_with(".json"):
			continue
		var text = FileAccess.get_file_as_string("res://tests/golden/" + file)
		var golden = JSON.parse_string(text)
		if golden == null:
			mismatches.append("无法解析 " + file)
			continue
		mismatches.append_array(_replay(db, golden, file))

	for m in mismatches:
		push_error(m)
	assert_that(mismatches).is_empty()

func _replay(db: ContentDB, golden: Dictionary, file: String) -> Array:
	var out := []
	var sim = SimCore.new(db)
	sim.new_game(String(golden["pack"]), int(golden["seed"]))

	var script_by_tick := {}
	for e in golden["script"]:
		script_by_tick[int(e["tick"])] = e["actions"]

	var daily: Array = golden["daily"]
	var idx = 0
	_compare(daily[0], _summarize(sim.s), file, 0, out)
	idx = 1

	var total = int(golden["days"]) * int(golden["hoursPerDay"])
	for t in total:
		var actions: Array = script_by_tick.get(t, [])
		sim.tick_hour(actions)
		if int(sim.s["hour"]) == 0:
			if idx < daily.size():
				_compare(daily[idx], _summarize(sim.s), file, idx, out)
			idx += 1
	return out

func _r3(v: float) -> float:
	return floor(v * 1000.0 + 0.5) / 1000.0

func _summarize(s: Dictionary) -> Dictionary:
	var goods := {}
	for g in s["goods"].keys():
		goods[g] = _r3(float(s["goods"][g]))
	var prices := {}
	for g in s["prices"].keys():
		prices[g] = _r3(float(s["prices"][g]))
	var housing := {}
	for g in s["housing"].keys():
		housing[g] = float(s["housing"][g])
	var shops := []
	for sh in s["shops"]:
		shops.append({
			"id": String(sh["id"]), "defId": String(sh["defId"]),
			"level": int(sh["level"]), "workers": int(sh["targetWorkers"]),
			"active": bool(sh["active"]),
		})
	shops.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	var pop = s["residents"].size()
	var sat = 0.0
	for r in s["residents"]:
		sat += float(r["satisfaction"])
	sat = sat / float(pop) if pop > 0 else 0.0
	return {
		"day": int(s["day"]), "population": pop, "satisfaction": _r3(sat),
		"hungry": int(s["history"][s["history"].size() - 1].get("hungry", 0)),
		"money": _r3(float(s["government"]["money"])),
		"goods": goods, "prices": prices, "housing": housing, "shops": shops,
	}

func _compare(exp: Dictionary, got: Dictionary, file: String, day: int, out: Array) -> void:
	var tag = "%s day#%d" % [file, day]
	if int(exp["population"]) != int(got["population"]):
		out.append("%s population %d != %d" % [tag, int(exp["population"]), int(got["population"])])
	if absf(float(exp["satisfaction"]) - float(got["satisfaction"])) > TOL:
		out.append("%s satisfaction %.4f != %.4f" % [tag, float(exp["satisfaction"]), float(got["satisfaction"])])
	if int(exp["hungry"]) != int(got["hungry"]):
		out.append("%s hungry %d != %d" % [tag, int(exp["hungry"]), int(got["hungry"])])
	if absf(float(exp["money"]) - float(got["money"])) > 0.1:
		out.append("%s money %.3f != %.3f" % [tag, float(exp["money"]), float(got["money"])])
	_compare_map(exp["goods"], got["goods"], tag + " goods", 0.05, out)
	_compare_map(exp["prices"], got["prices"], tag + " prices", 0.02, out)
	_compare_map(exp["housing"], got["housing"], tag + " housing", 0.5, out)
	_compare_shops(exp["shops"], got["shops"], tag, out)

func _compare_map(exp: Dictionary, got: Dictionary, tag: String, tol: float, out: Array) -> void:
	if exp.size() != got.size():
		out.append("%s 键数 %d != %d" % [tag, exp.size(), got.size()])
	for k in exp.keys():
		if not got.has(k):
			out.append("%s 缺少 %s" % [tag, k])
			continue
		if absf(float(exp[k]) - float(got[k])) > tol:
			out.append("%s %s %.4f != %.4f" % [tag, k, float(exp[k]), float(got[k])])

func _compare_shops(exp: Array, got: Array, tag: String, out: Array) -> void:
	if exp.size() != got.size():
		out.append("%s shops 数量 %d != %d" % [tag, exp.size(), got.size()])
		return
	for i in exp.size():
		var e: Dictionary = exp[i]
		var g: Dictionary = got[i]
		if String(e["id"]) != String(g["id"]) or int(e["level"]) != int(g["level"]) or int(e["workers"]) != int(g["workers"]) or bool(e["active"]) != bool(g["active"]):
			out.append("%s shop[%d] %s != %s" % [tag, i, str(e), str(g)])
