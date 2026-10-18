extends SceneTree

# 铁矿资源门槛（用户 2026-10：「地图上加入铁矿资源」）。
#
# 这条盯的是"从地形到玩法"的整条链，少一环就等于没加：
#   1. `GameMap` 有 IRON 这个地形（而且不在 WATER 之前被当成别的）
#   2. 生成的地图上**真的有**铁矿脉：数量够、出生点附近看得见、同种子可复现
#   3. 铁矿脉**画得出来**：terrain 层用的是 extra.png 索引 53（石 50 / 粘土 51 / 地板 52）
#   4. 内容里有铁矿场（`iron_mine`）：建在 `terrain:"iron"` 上、产 `iron_ore`、归「矿场」页
#   5. 放置判定真的拦：草地上放不下、铁矿脉上放得下；提示文案是中文「需地形：铁矿」
#
# red 的含义：① 地图上再也不会出现铁（玩家找不到资源）② 出现了但画不出来（一片草地）
# ③ 有铁但没建筑能采（死资源）④ 满地都能建铁矿场（地形闸失效）。

const SEED := 20261017
const MIN_IRON_CELLS := 60

var _failed := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("IRON TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	# ---- 1. 地形常量与名字 ------------------------------------------------
	if GameMap.IRON != 5:
		_fail("GameMap.IRON 应当是 5（实际 %d）—— 地形数组里错位会把河画成铁" % GameMap.IRON)
		return
	if GameMap.terrain_name(GameMap.IRON) != "iron":
		_fail("terrain_name(IRON) 应当返回 \"iron\"（实际 \"%s\"）"
			% GameMap.terrain_name(GameMap.IRON))
		return
	if GameMap.terrain_name(GameMap.WATER) != "water":
		_fail("加了 IRON 之后 WATER 的 terrain_name 变了（地形表错位）")
		return
	print("IRON TEST 地形：IRON=5 / terrain_name=\"iron\"，WATER 未错位 ✅")

	# ---- 2. 生成：数量、位置、可复现 ---------------------------------------
	var m := GameMap.new()
	m.generate(SEED)
	var cells: Array = []
	for y in GameMap.H:
		for x in GameMap.W:
			if m.terrain[m.idx(x, y)] == GameMap.IRON:
				cells.append(Vector2i(x, y))
	if cells.size() < MIN_IRON_CELLS:
		_fail("种子 %d 生成的地图上只有 %d 格铁矿（至少该有 %d 格）"
			% [SEED, cells.size(), MIN_IRON_CELLS])
		return
	var nearest := 1 << 30
	var nearest_cell := Vector2i(-1, -1)
	for c in cells:
		var d: int = maxi(absi(c.x - m.center.x), absi(c.y - m.center.y))
		if d < nearest:
			nearest = d
			nearest_cell = c
	if nearest > 30:
		_fail("最近的铁矿离出生点 %d 格（%s）—— 太远，玩家开局看不到铁"
			% [nearest, str(nearest_cell)])
		return
	var m2 := GameMap.new()
	m2.generate(SEED)
	if m2.terrain != m.terrain:
		_fail("同一个种子生成两次，地形不一样（铁脉位置会随存档漂）")
		return
	print("IRON TEST 生成：%d 格铁矿，最近一格离中心 %d 格（%s），同种子可复现 ✅"
		% [cells.size(), nearest, str(nearest_cell)])

	# ---- 3. 画得出来：terrain 层用 extra.png 索引 53 ------------------------
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
	# 用真地图（开局那张）里的任意一格铁矿来验渲染
	var real_iron := Vector2i(-1, -1)
	for y in GameMap.H:
		for x in GameMap.W:
			if world.map.terrain[world.map.idx(x, y)] == GameMap.IRON:
				real_iron = Vector2i(x, y)
				break
		if real_iron.x >= 0:
			break
	if real_iron.x < 0:
		_fail("开局那张地图上一格铁矿都没有")
		return
	var layer = world.terrain_layer
	var src: int = layer.get_cell_source_id(real_iron)
	var atlas: Vector2i = layer.get_cell_atlas_coords(real_iron)
	var want: Vector2i = world._extra_cell(53)
	if src != 1 or atlas != want:
		_fail("铁矿格 %s 画的是 source=%d atlas=%s，应为 source=1 atlas=%s（extra.png 索引 53）"
			% [str(real_iron), src, str(atlas), str(want)])
		return
	# 索引 53 必须真的在 extra 图集范围内（8 列 x 7 行 = 56 格）
	if 53 >= world.EXTRA_COLS * world.EXTRA_ROWS:
		_fail("extra 图集只有 %d 格，放不下索引 53" % (world.EXTRA_COLS * world.EXTRA_ROWS))
		return
	print("IRON TEST 渲染：铁矿格 %s → extra.png 索引 53（不是草地/石矿）✅" % str(real_iron))

	# ---- 4. 内容：铁矿场能采它 --------------------------------------------
	if not db.goods.has("iron_ore"):
		_fail("内容里没有 iron_ore 这个商品")
		return
	if not db.buildings.has("iron_mine"):
		_fail("内容里没有铁矿场（iron_mine）")
		return
	var b: Dictionary = db.buildings["iron_mine"]
	if String(b.get("terrain", "")) != "iron":
		_fail("铁矿场的 terrain 是「%s」，应当是 iron（不然它能建在草地上）"
			% String(b.get("terrain", "")))
		return
	# ⚠️ `bdef.recipe` 是**配方 id 字符串**（"r_<id>"），不是内联字典 —— 要去 `db.recipes` 取
	var rid := String(b.get("recipe", ""))
	if not db.recipes.has(rid):
		_fail("铁矿场没有配方（recipe=%s）" % rid)
		return
	var out: Dictionary = (db.recipes[rid] as Dictionary).get("output", {})
	if not out.has("iron_ore"):
		_fail("铁矿场的配方不产 iron_ore（产出 %s）" % str(out))
		return
	if db.build_category("iron_mine") != "矿场":
		_fail("铁矿场落在「%s」页，应当归「矿场」" % db.build_category("iron_mine"))
		return
	if String(db.TERRAIN_ZH.get("iron", "")) != "铁矿":
		_fail("地形中文名表里没有「铁矿」（建造栏会显示 \"需地形：iron\"）")
		return
	print("IRON TEST 内容：铁矿场（terrain=iron，产 iron_ore %d/日）+ 矿场页 + 中文「铁矿」✅"
		% int(float(out.get("iron_ore", 0))))

	# ---- 5. 放置判定：草地不行、铁矿脉可以 ---------------------------------
	var fp: Vector2i = world._footprint("iron_mine")
	# 找一处"全是铁矿"的空地。
	# ⚠️ 必须在**世界这张地图**上找 —— 上面那段 `cells` 来自另建的一张同种子地图，
	#    而世界地图用的是**开局那个种子**，两张图的矿脉位置不一样（第一版就是这么误判的）。
	var world_cells: Array = []
	for y in GameMap.H:
		for x in GameMap.W:
			if world.map.terrain[world.map.idx(x, y)] == GameMap.IRON:
				world_cells.append(Vector2i(x, y))
	# ⚠️ `place_reason()` 收的是**鼠标格**（和真正点击同一条路径）：它内部
	#    `anchor = cell - (1, 0)` 再往上推占地 —— 所以"左上角"和"鼠标格"差一列和几行。
	#    直接喂左上角会被判成"资源不符"（第一版就是这么红的）。这里两种都验：
	#    底层 `map.terrain_ok()` 用左上角，`place_reason()` 用鼠标格。
	var place_top := Vector2i(-1, -1)
	for c in world_cells:
		var cand: Vector2i = world._foot_top(c, fp)
		var ok_all := true
		for dy in fp.y:
			for dx in fp.x:
				if world.map.terrain_at(cand + Vector2i(dx, dy)) != GameMap.IRON:
					ok_all = false
		if ok_all:
			place_top = cand
			break
	if place_top.x < 0:
		_fail("找不到一处 %dx%d 全是铁矿的空地（矿脉太小，铁矿场建不下来）" % [fp.x, fp.y])
		return
	if not world.map.terrain_ok(place_top, fp.x, fp.y, ["iron"]):
		_fail("底层判定：%dx%d 全铁矿的地块 %s 也不让建" % [fp.x, fp.y, str(place_top)])
		return
	# 鼠标格：左上角 + (1, 0) + 往下 (fp.y - 1) 行（反推 place_reason 的换算）
	var mouse_cell := Vector2i(place_top.x + 1, place_top.y + fp.y - 1)
	var on_iron: String = world.place_reason("iron_mine", mouse_cell)
	if on_iron != "":
		_fail("在铁矿脉 %s（鼠标格 %s）上放铁矿场被拒：%s"
			% [str(place_top), str(mouse_cell), on_iron])
		return
	# 草地（出生点旁边那块被清成草地的仓库区）必须放不下
	var on_grass := Vector2i(world.map.center.x, world.map.center.y + 10)
	var grass_reason: String = world.place_reason("iron_mine", on_grass)
	if grass_reason == "":
		_fail("草地上也能放铁矿场（地形闸失效，铁就不算资源了）")
		return
	if not grass_reason.contains("资源"):
		_fail("草地被拒的理由是「%s」，应当说明是资源/地形不符" % grass_reason)
		return
	print("IRON TEST 放置：铁矿脉 %s 上可建、草地上被拒（「%s」）✅" % [str(place_top), grass_reason])

	print("IRON TEST RESULT: PASS")
	quit(0)
