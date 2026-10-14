extends SceneTree

# 开发用：生成「全科技解锁 + 资源充足 + 人手足够」的调试存档，
# 用来把每座建筑都摆一遍看外观 / 尺寸，而不用先花几十天研究科技。
#
# 用法（在 godot/ 下）：
#   "D:/wangxu/game/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe" \
#       --headless --path . -s res://tools/make_debug_save.gd
#
# 存档落在 user://debug_all_tech.json（Windows 上就是
# %APPDATA%\Godot\app_userdata\sovit\debug_all_tech.json）。
# **不碰** user://sovit_save.json —— 玩家自己的档别动。
#
# 进游戏怎么读：标题页 →「读取进度」→ 选 debug_all_tech.json。
# （游戏内快读 **F8** 读的是**默认存档位** `user://sovit_save.json`，不是这份 ——
#   想用 F8 读它就把这份复制成默认存档位。正常流程就是标题页那个按钮。）
#
# 这不是引擎里的"作弊模式" —— 它只是一份普通存档，全部靠改 state 字段：
#   * 科技全开：建筑/住房的解锁锁都在 research.done 上（docs/technology.md）
#   * 建造力 = 失业人口 × construction.unemployedRate(1.0) + 建筑工坊（docs/construction.md）
#     → 人口给到 60 且全部失业，任何建筑（buildWork 最高 48）都是当天开工当天完
#   * 口粮是**居民掏自己的存款买的**（sim_core._resolve_consumption）：
#     存款为 0 就会饿 → hungerDeathRate 死人。所以存款也必须给足。
#
# ⚠️ 住房不要多给：world_view._sync_housing 按 s["housing"][type] 的**数量**逐座生成
#    房子精灵 —— 多给几百座，地图上就真会刷出几百座房子，把要看的建筑全盖住。
#    所以住房只补到"刚好住得下"，其余留给玩家自己摆（摆完当天就能建好）。

const OUT_PATH := "user://debug_all_tech.json"

const PACK := "v0.3"
const SEED := 20261014
const POPULATION := 60
# ⚠️ 每种物资给多少，受**仓储上限**约束（docs/town.md §三）：超过的部分当晚就被丢掉。
# 所以不能像以前那样一味给 20000 —— 总量必须 ≤ storage_capacity()。
# 下面 GOODS × 商品种类 要留在 STORAGE_LEVEL 撑出来的容量之内（本文件末尾会自检）。
const GOODS := 500.0
## 额外塞一座**高级仓库**撑容量：仓库容量 = 300 + 150 × (等级 − 1)。
## 200 级 = 30,150，足够装 33 种 × 500 = 16,500，也让"挨个摆建筑"的材料够用。
const STORAGE_LEVEL := 200
# 15 座茅屋 × capacity 4 = 60，正好住满人口；人口 = 失业人口 = 建造力（v0.3 开局没有店铺）
const HOUSING := {"hut": 15.0, "wooden_house": 0.0, "brick_house": 0.0}
const MONEY := 1000000.0
const SAVINGS := 100000.0
const VILLAGE_NAME := "调试村"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		push_error("DEBUG SAVE: 无法加载 main.tscn")
		quit(1)
		return
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	var runner = node.get("runner")
	var world = node.get("world")
	if runner == null or world == null:
		push_error("DEBUG SAVE: main 未创建 runner/world")
		quit(1)
		return
	# 标题页会盖住整个游戏并接管镜头；不过这一趟不用截图，关不关都行，
	# 但 title 的 _process 每帧改 camera.position，留着会干扰后面摆建筑的定位。
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	# ---- 1) 开一局新的（这一步同时生成地图，存档里会带上 mapSeed/道路/地板）----
	world.start_new_game(SEED, 1.0, VILLAGE_NAME)
	var sim = runner.sim
	var db = runner.db

	# 2) 科技全开
	var all_techs: Array = []
	for t in db.tech_ids:
		all_techs.append(String(t))
	sim.s["research"]["done"] = all_techs
	sim.s["research"]["queue"] = []

	# 3) 国库 + 库存 + 住房（住房只补到住得下，见文件头）
	sim.s["government"]["money"] = MONEY
	sim.s["government"]["populationCap"] = 1000000000.0
	for gid in sim.s["goods"].keys():
		sim.s["goods"][gid] = GOODS
	for hid in sim.s["housing"].keys():
		sim.s["housing"][hid] = float(HOUSING.get(hid, 0.0))
		sim.s["privateHousing"][hid] = 0.0

	# 4) 人口：全部失业 → 建造力拉满
	var dist: Array = db.defaults["startDistribution"].duplicate()
	if dist.is_empty():
		dist = ["poor"]
	var sd: Dictionary = db.defaults["startResident"]
	var residents := []
	for i in POPULATION:
		residents.append({
			"id": "res#%d" % (i + 1),
			"classId": String(dist[i % dist.size()]),
			"savings": SAVINGS,
			"satisfaction": float(sd["satisfaction"]),
			"skill": float(sd["skillBase"]) + float(i % maxi(1, int(sd["skillRandom"]))),
			"employed": false,
		})
	sim.s["residents"] = residents
	sim.s["arrivals"] = 0
	# 4b) 塞一座**高级仓库**撑仓储容量（见 STORAGE_LEVEL 的说明），并派 1 个人看仓库
	#     —— 仓储建筑"没在岗工人就不算容量"（docs/town.md §3.2）。
	(sim.s["shops"] as Array).append({
		"id": "warehouse#dbg", "defId": "warehouse", "owner": "state",
		"targetWorkers": 1, "wage": float(db.economy["refWage"]),
		"wageCap": float(db.economy["defaultWageCap"]),
		"level": STORAGE_LEVEL, "active": true, "profit": 0.0,
		"skill": 50.0, "planned": 0.0, "toolBoost": 1.0,
	})
	(sim.s["residents"][0] as Dictionary)["employed"] = true
	(sim.s["residents"][0] as Dictionary)["jobShopId"] = "warehouse#dbg"
	# 首日快照跟着改，否则统计面板的人口/钱财和曲线对不上
	var hist: Array = sim.s["history"]
	if hist.size() > 0:
		hist[0]["population"] = POPULATION
		hist[0]["money"] = MONEY

	# 5) 存盘：必须用 world.save_to（写 mapSeed/road/floor/shops/housing/sites），
	#    不能用 SaveManager.save_to —— 后者只写仿真状态，读回来时地图还是上一局的。
	var err: Error = world.save_to(OUT_PATH)
	print("save ", OUT_PATH, " -> ", err)
	print("      ", ProjectSettings.globalize_path(OUT_PATH))
	if err != OK:
		quit(1)
		return

	# ---- 6) 自检：真读回来，逐座建筑试着摆 ----
	if not world.load_from(OUT_PATH):
		push_error("DEBUG SAVE: 生成的存档读不回来，别给玩家")
		quit(1)
		return
	sim = runner.sim
	var locked: Array = []
	for bid in (db.packs[PACK]["buildings"] as Array):
		if not sim.is_building_unlocked(String(bid)):
			locked.append(String(bid))
	for hid in (db.packs[PACK]["housing"] as Array):
		if not sim.is_housing_unlocked(String(hid)):
			locked.append(String(hid))

	var ids: Array = []
	ids.append_array(db.packs[PACK]["buildings"])
	ids.append_array(db.packs[PACK]["housing"])
	var failed := _try_place_all(world, db, ids)

	print("bundle: ", db.packs[PACK]["nameZh"])
	print("科技 %d / %d 已研究，队列 %d" % [
		(sim.s["research"]["done"] as Array).size(), db.tech_ids.size(),
		(sim.s["research"]["queue"] as Array).size()])
	print("人口 %d  住房容量 %d  国库 %.0f  存款 %.0f/人" % [
		(sim.s["residents"] as Array).size(), sim._housing_capacity(), MONEY, SAVINGS])
	print("建造力 %.1f 人·天/日（buildWork 最高 48）" % sim.construction_rate())
	var cap: float = sim.storage_capacity()
	var used: float = sim.stored_total()
	print("仓储 %.0f / %.0f（等级 %d 的调试仓库撑的）%s" % [
		used, cap, STORAGE_LEVEL, "" if used <= cap else "  ✗ 超了！读档当晚会被丢"])
	if used > cap:
		quit(1)
		return
	print("可建造清单 %d 项，试摆失败 %d 项：%s" % [
		ids.size(), failed.size(), "无" if failed.is_empty() else str(failed)])
	print("仍被科技锁住：%s" % ("无" if locked.is_empty() else str(locked)))
	if not locked.is_empty():
		quit(1)
		return
	print("OK -> 标题页「读取进度」选 debug_all_tech.json")
	quit(0)

## 逐项试摆（就是建造栏下单走的那条路），返回摆不下的清单。
## 地形不够的就照截图工具的老办法把脚下刷成所需地形 —— 这里只验"能不能下单"，
## 不改存档：存档在第 5 步已经写完了，之后这些改动只活在内存里。
func _try_place_all(world, db: ContentDB, ids: Array) -> Array:
	var failed: Array = []
	var center: Vector2i = world.map.center
	var i := 0
	for id in ids:
		var bid := String(id)
		var ok := false
		for attempt in 8:
			var cell: Vector2i = center + Vector2i(
				(i % 6) * 14 - 40 + (attempt % 3) * 3,
				int(i / 6) * 11 - 34 + int(attempt / 3) * 3)
			_paint_needed_terrain(world, db, bid, cell)
			if world._try_place(bid, cell):
				ok = true
				break
		if not ok:
			failed.append(bid)
		i += 1
	return failed

func _paint_needed_terrain(world, db: ContentDB, id: String, cell: Vector2i) -> void:
	var need := ""
	if db.buildings.has(id):
		need = String(db.buildings[id].get("terrain", ""))
	if need == "":
		return
	var code: int = {"forest": 1, "stone": 2, "clay": 3}.get(need, 0)
	var fp: Vector2i = world._footprint(id)
	var org := cell - Vector2i(1, 1)
	for dy in fp.y + 2:
		for dx in fp.x + 2:
			var cc := org + Vector2i(dx, dy)
			if world.map.in_bounds(cc):
				world.map.terrain[world.map.idx(cc.x, cc.y)] = code
	world._rerender_terrain()
