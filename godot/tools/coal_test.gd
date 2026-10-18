extends SceneTree

# 煤矿门槛（用户 2026-10："地图上添加煤矿"）。
#
# 和铁矿（`iron_test.gd`）是同一套骨架，但煤多了一件事：**它是燃料**。
# 所以这条盯六件事：
#   1. 地形：`GameMap.COAL = 6`、名字 "coal"、WATER 不受影响
#   2. 生成：真的煤矿脉、够量、出生点附近找得到、同种子可复现
#   3. 画得出来：`extra.png` 索引 54（石 50 / 粘土 51 / 地板 52 / 铁 53 / 煤 54）
#   4. 内容：煤矿场（`coal_mine`，terrain "coal"）产 `coal`，归「矿场」页，中文「煤矿」
#   5. 放置：煤矿脉上能建、草地上被拒
#   6. **烧煤**：砖窑有煤就烧煤（台账 `consumed` / `consumedBy` 记煤，不是木柴）；
#      没煤就烧木柴；煤木柴都没有 → 一条都不产（不能凭空烧）
#
# red 的含义：① 地图上没有煤 ② 有煤但画不出来 ③ 有煤没建筑采
# ④ 燃料还是写死木柴（煤白挖） ⑤ 没燃料也能产（凭空烧）

const SEED := 20261020
const MIN_COAL_CELLS := 80

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("COAL TEST FAIL: ", msg)
	quit(1)

func _approx(a: float, b: float, eps: float = 0.001) -> bool:
	return absf(a - b) <= eps

func _run() -> void:
	# ---- 1. 地形常量 ------------------------------------------------------
	if GameMap.COAL != 6:
		_fail("GameMap.COAL 应当是 6（实际 %d）" % GameMap.COAL)
		return
	if GameMap.terrain_name(GameMap.COAL) != "coal":
		_fail("terrain_name(COAL) 应当返回 \"coal\"（实际 \"%s\"）"
			% GameMap.terrain_name(GameMap.COAL))
		return
	if GameMap.terrain_name(GameMap.WATER) != "water":
		_fail("加了 COAL 之后 WATER 的 terrain_name 变了（地形表错位）")
		return
	print("COAL TEST 地形：COAL=6 / terrain_name=\"coal\"，WATER 未错位 ✅")

	# ---- 2. 生成 ----------------------------------------------------------
	var m := GameMap.new()
	m.generate(SEED)
	var cells: Array = []
	for y in GameMap.H:
		for x in GameMap.W:
			if m.terrain[m.idx(x, y)] == GameMap.COAL:
				cells.append(Vector2i(x, y))
	if cells.size() < MIN_COAL_CELLS:
		_fail("种子 %d 生成的地图上只有 %d 格煤矿（至少该有 %d 格）"
			% [SEED, cells.size(), MIN_COAL_CELLS])
		return
	var nearest := 1 << 30
	for c in cells:
		nearest = mini(nearest, maxi(absi(c.x - m.center.x), absi(c.y - m.center.y)))
	if nearest > 30:
		_fail("最近的煤矿离出生点 %d 格 —— 太远，玩家开局看不到煤" % nearest)
		return
	var m2 := GameMap.new()
	m2.generate(SEED)
	if m2.terrain != m.terrain:
		_fail("同一个种子生成两次，地形不一样（煤脉位置会随存档漂）")
		return
	print("COAL TEST 生成：%d 格煤矿，最近一格离中心 %d 格，同种子可复现 ✅"
		% [cells.size(), nearest])

	# ---- 3/4/5. 真地图：渲染 + 内容 + 放置 --------------------------------
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame
	var world = node.get("world")
	var runner = node.get("runner")
	var db = runner.db
	var real := Vector2i(-1, -1)
	var world_cells: Array = []
	for y in GameMap.H:
		for x in GameMap.W:
			if world.map.terrain[world.map.idx(x, y)] == GameMap.COAL:
				world_cells.append(Vector2i(x, y))
				if real.x < 0:
					real = Vector2i(x, y)
	if real.x < 0:
		_fail("开局那张地图上一格煤矿都没有")
		return
	var layer = world.terrain_layer
	var want: Vector2i = world._extra_cell(54)
	if layer.get_cell_source_id(real) != 1 or layer.get_cell_atlas_coords(real) != want:
		_fail("煤矿格 %s 画的是 source=%d atlas=%s，应为 source=1 atlas=%s（索引 54）"
			% [str(real), layer.get_cell_source_id(real),
				str(layer.get_cell_atlas_coords(real)), str(want)])
		return
	print("COAL TEST 渲染：煤矿格 %s → extra.png 索引 54 ✅" % str(real))

	if not db.goods.has("coal"):
		_fail("内容里没有 coal 这个商品")
		return
	if not db.buildings.has("coal_mine"):
		_fail("内容里没有煤矿场（coal_mine）")
		return
	var b: Dictionary = db.buildings["coal_mine"]
	if String(b.get("terrain", "")) != "coal":
		_fail("煤矿场的 terrain 是「%s」，应当是 coal" % String(b.get("terrain", "")))
		return
	var rec: Dictionary = db.recipes.get(String(b.get("recipe", "")), {})
	if not (rec.get("output", {}) as Dictionary).has("coal"):
		_fail("煤矿场的配方不产 coal（产出 %s）" % str(rec.get("output", {})))
		return
	if db.build_category("coal_mine") != "矿场":
		_fail("煤矿场落在「%s」页，应当归「矿场」" % db.build_category("coal_mine"))
		return
	if String(db.TERRAIN_ZH.get("coal", "")) != "煤矿":
		_fail("地形中文名表里没有「煤矿」（建造栏会显示 \"需地形：coal\"）")
		return
	var fp: Vector2i = world._footprint("coal_mine")
	var place_top := Vector2i(-1, -1)
	for c in world_cells:
		var cand: Vector2i = world._foot_top(c, fp)
		var ok_all := true
		for dy in fp.y:
			for dx in fp.x:
				if world.map.terrain_at(cand + Vector2i(dx, dy)) != GameMap.COAL:
					ok_all = false
		if ok_all:
			place_top = cand
			break
	if place_top.x < 0:
		_fail("找不到一处 %dx%d 全是煤的空地（煤脉太小，煤矿场建不下来）" % [fp.x, fp.y])
		return
	var mouse_cell := Vector2i(place_top.x + 1, place_top.y + fp.y - 1)
	var why: String = world.place_reason("coal_mine", mouse_cell)
	if why != "":
		_fail("煤矿脉 %s 上放煤矿场被拒：%s" % [str(place_top), why])
		return
	var grass := Vector2i(world.map.center.x, world.map.center.y + 10)
	if world.place_reason("coal_mine", grass) == "":
		_fail("草地上也能放煤矿场（地形闸失效，煤就不算资源了）")
		return
	print("COAL TEST 内容/放置：煤矿场（terrain=coal，产煤 %d/日）+ 矿场页 + 中文「煤矿」+ 草地上被拒 ✅"
		% int(float((rec.get("output", {}) as Dictionary).get("coal", 0))))

	# ---- 6. 烧煤 ----------------------------------------------------------
	var sim = runner.sim
	# 造一座砖窑（fuel 4/批）+ 人口 + 原料
	var d: Dictionary = db.buildings["brick_kiln"]
	sim.s["shops"].append({
		"id": "t_kiln", "defId": "brick_kiln", "owner": "state",
		"targetWorkers": int(d["workers"]),
		"wage": float(db.economy["refWage"]),
		"wageCap": float(db.economy["defaultWageCap"]),
		"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	for _i in 4:
		(sim.s["residents"] as Array).append({
			"id": "res#coal%d" % ((sim.s["residents"] as Array).size() + 1),
			"classId": "poor", "savings": 30.0, "satisfaction": 70.0,
			"skill": 50.0, "employed": false,
		})
	sim.s["goods"]["clay"] = 500.0
	sim.s["goods"]["coal"] = 100.0
	sim.s["goods"]["firewood"] = 100.0
	sim._run_dawn()
	var kiln = null
	for sh in (sim.s["shops"] as Array):
		if String(sh["id"]) == "t_kiln":
			kiln = sh
	if kiln == null:
		_fail("找不到刚建的砖窑")
		return
	if String(kiln.get("fuelGood", "")) != "coal":
		_fail("有煤也有木柴时应当先烧煤，实际挑的是「%s」" % String(kiln.get("fuelGood", "")))
		return
	if float(kiln.get("planned", 0.0)) <= 0.0:
		_fail("砖窑一点都没排产（原料/工人不够，测不了烧煤）")
		return
	var coal0 := float(sim.s["goods"]["coal"])
	var wood0 := float(sim.s["goods"]["firewood"])
	sim._run_production_step(1.0)
	# ⚠️ 口径：**只看这块砖窑自己烧了多少**（台账 `consumedBy`），
	# 不看"库存净变化" —— 村里别的建筑（煤矿场、其它烧料工坊）也会动煤，
	# 2026-10 加盔甲/弓箭两件商品时就撞上过：净变化 +0.94，其实砖窑照烧不误。
	var wood_used := wood0 - float(sim.s["goods"]["firewood"])
	var led: Dictionary = sim.s["ledgerToday"]
	var by: Dictionary = (led.get("consumedBy", {}) as Dictionary).get("coal", {})
	if not by.has("brick_kiln"):
		_fail("台账 consumedBy[coal] 里没有 brick_kiln（砖窑没烧煤，或没记账）")
		return
	var coal_used := float(by["brick_kiln"])
	if coal_used <= 0.0:
		_fail("砖窑烧煤量 %.2f，应当 > 0（煤库存 %.2f → %.2f）" % [coal_used, coal0, float(sim.s["goods"]["coal"])])
		return
	if wood_used > 0.001:
		_fail("砖窑同时烧了木柴（%.2f）—— 一天只该烧一种燃料" % wood_used)
		return
	print("COAL TEST 烧煤：有煤 → 挑煤、只扣煤（%.2f），台账记着 brick_kiln ✅" % coal_used)

	# 没煤 → 改烧木柴
	sim.s["goods"]["coal"] = 0.0
	sim.s["goods"]["firewood"] = 100.0
	sim._run_dawn()
	if String(kiln.get("fuelGood", "")) != "firewood":
		_fail("没煤时应当改烧木柴，实际「%s」" % String(kiln.get("fuelGood", "")))
		return
	var wood1 := float(sim.s["goods"]["firewood"])
	sim._run_production_step(1.0)
	if float(sim.s["goods"]["firewood"]) >= wood1:
		_fail("没煤时砖窑也没烧木柴（木柴 %.2f → %.2f）"
			% [wood1, float(sim.s["goods"]["firewood"])])
		return
	print("COAL TEST 兜底：没煤 → 改烧木柴 ✅")

	# 两种燃料都没有 → 一条都不产（不能凭空烧）
	sim.s["goods"]["coal"] = 0.0
	sim.s["goods"]["firewood"] = 0.0
	sim._run_dawn()
	if float(kiln.get("planned", 0.0)) > 0.001:
		_fail("煤和木柴都没有，砖窑却排了 %.2f 批（凭空烧）" % float(kiln.get("planned", 0.0)))
		return
	var brick0 := float(sim.s["goods"].get("brick", 0.0))
	sim._run_production_step(1.0)
	if absf(float(sim.s["goods"].get("brick", 0.0)) - brick0) > 0.001:
		_fail("没有燃料却产出了砖（凭空烧）")
		return
	print("COAL TEST 无燃料：不排产、不产砖 ✅")

	print("COAL TEST RESULT: PASS")
	quit(0)
