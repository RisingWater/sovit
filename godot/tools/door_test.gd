extends SceneTree

# 门洞（门格 + 门前通行格）与「放下 / 移动建筑时自动在门前铺一格路」的门槛。
#
# 验五件事：
#   1. 城镇中心的门洞是**两格**（用户明确要求"门口两格都必须是门洞"）：两格门格 +
#      两格门前通行格都在 `map.reserved` 里，且落在占地底边、横向相邻；
#   2. 全部建筑 / 住房的门洞声明（`art.doors`）都落在各自占地范围内；
#   3. 挑一座普通建筑放下：门格 / 门前格进 `reserved`，且 `cell_free()` 对门前格返回
#      false —— "看着是空地却建不了"是**有意**的（见 game_map.gd 的 reserved 注释）；
#   4. **工地阶段**门前那一格就已经变成道路（用户放下就能看见），
#      住房走的是另一条入口（`move_housing_to`），一并验；
#   5. 把它移走之后，**旧址那格路仍在**（用户："移走的时候可以先不擦除"）。
#
# ⚠️ 两条踩过的坑，这里都堵住了：
#   · 内容必须从**真跑起来的主场景**取（`world.runner.db`）。自己 `ContentDB.new()`
#     会拿到空字典，门槛打印"检查 0 个 … PASS" —— **假绿**。所以下面数 `_checks`，
#     为 0 直接判红。
#   · 这个脚本跑到一半出错、走不到 `quit()` 的话，SceneTree 会一直跑下去（有人因此
#     白等过 15 分钟）。跑它**必须**用带超时的独立进程：
#       powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/door_test.gd
#     （`verify.sh` 里走的是 bash 的 `timeout`，同口径；本机没装 pwsh，用 powershell.exe）

const TC := "town_center"
const SEED := 20261014
## 起始资源倍率：门槛要能建得起随机挑中的那座建筑，别让"材料不足"变成随机红。
const RES_MULT := 20.0

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("DOOR TEST FAIL: ", msg)
	print("DOOR TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _road_at(map, c: Vector2i) -> int:
	return int(map.road[map.idx(c.x, c.y)])

## 找一块能放下 `id` 的空地（返回的是 `_try_place` 的入参：**鼠标那一格**，
## 系统内部换算成"脚" = 底边那一行的最左格；见 `world_view._foot_top()`）。
## 额外要求**门前格是图内的非水面、而且现在没有路**：
##   · 水面 / 越界时"自动铺路"会被合理地跳过，断言就变成假的了；
##   · 现在没路，才能证明"路是这次放置铺出来的"，而不是本来就有的。
func _find_spot(world, id: String, skip: Vector2i, from: Vector2i) -> Vector2i:
	var fp: Vector2i = world._footprint(id)
	for dy in range(0, 44):
		for dx in range(0, 70):
			var c: Vector2i = from + Vector2i(dx, dy)
			if c == skip:
				continue
			if not world.map.in_bounds(world._foot_top(c - Vector2i(1, 0), fp) + fp - Vector2i.ONE):
				continue
			if world.place_reason(id, c) != "":
				continue
			var origin2 := c - Vector2i(1, 0)      # 入参是"脚"（底边那一行的最左格）
			var bad := false
			for f in world._door_front_cells(id, origin2, fp):
				var fc: Vector2i = f
				if not world.map.in_bounds(fc) or world.map.is_water(fc):
					bad = true
				elif _road_at(world.map, fc) != 0:
					bad = true
			if bad:
				continue
			return c
	return Vector2i(-1, -1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var world = node.get_node_or_null("World")
	if world == null:
		_fail("找不到 World")
		return
	var db = world.runner.db
	if db == null or (db.buildings as Dictionary).is_empty():
		_fail("内容库是空的（db.buildings 为空）—— 这就是那种『检查 0 个 PASS』的假绿")
		return

	# 开一局新的：地图是全新的（**一格路都没有**），"自动铺路"的断言才干净。
	# 顺手把仿真暂停：否则 runner 每 tick 就推进一小时，待建的建筑会随黎明生效，
	# 门槛就变成薛定谔的了。
	world.start_new_game(SEED, RES_MULT, "门洞测")
	world.runner.paused = true
	await process_frame
	if world.map == null or world.map.town_center.size.x <= 0:
		_fail("新局没有城镇中心")
		return

	# ---- 1. 城镇中心：两格门洞 ------------------------------------------------
	var tc: Rect2i = world.map.town_center
	var tc_fp := Vector2i(tc.size.x, tc.size.y)
	var tc_anchor: Vector2i = world._foot_anchor(tc.position, tc_fp)   # 门的偏移相对占地左上角
	var tc_doors: Array = world._door_cells(TC, tc_anchor, tc_fp)
	if tc_doors.size() != 2:
		_fail("城镇中心的门洞是 %d 格，不是两格：%s（content 的 town_center.art.doors）"
			% [tc_doors.size(), str(tc_doors)])
		return
	var d0: Vector2i = tc_doors[0]
	var d1: Vector2i = tc_doors[1]
	if d0.y != d1.y or absi(d1.x - d0.x) != 1:
		_fail("城镇中心两格门洞不在同一行、横向相邻：%s / %s" % [str(d0), str(d1)])
		return
	var bottom := tc.position.y + tc_fp.y - 1
	if d0.y != bottom or d1.y != bottom:
		_fail("城镇中心的门洞不在占地底边（y=%d）：%s / %s" % [bottom, str(d0), str(d1)])
		return
	_ok("城镇中心门洞 = 两格 %s（占地底边 y=%d、横向相邻 = 贴图上的双开门）"
		% [str(tc_doors), bottom])
	for d in tc_doors:
		if not world.map.reserved.has(d):
			_fail("城镇中心门格 %s 不在 map.reserved 里（别的建筑能把它堵死）" % str(d))
			return
		if not world._doors.has(d) or not world._walk_inside.has(d):
			_fail("城镇中心门格 %s 不是可通行格（_doors / _walk_inside）" % str(d))
			return
		var front: Vector2i = d + Vector2i(0, 1)
		if not world.map.reserved.has(front):
			_fail("城镇中心门前通行格 %s 不在 map.reserved 里" % str(front))
			return
		if world.map.cell_free(front):
			_fail("城镇中心门前通行格 %s 的 cell_free() 是 true —— 会有建筑盖在门口" % str(front))
			return
	_ok("两格门格 + 两格门前格都在 reserved 里；门前格 cell_free() == false")

	# ---- 2. 全部建筑 / 住房的门洞声明都在占地内 -------------------------------
	var declared_n := 0
	var footprint_n := 0
	var invalid: Array = []
	for pair in [["建筑", db.buildings], ["住房", db.housing]]:
		var label: String = pair[0]
		var table: Dictionary = pair[1]
		for id in table.keys():
			var bid := String(id)
			var defn: Dictionary = table[id]
			var art: Dictionary = defn.get("art", {})
			var fp: Vector2i = world._footprint(bid)
			footprint_n += 1
			var errs: Array = ContentDB.validate_doors(art, fp)
			if not errs.is_empty():
				invalid.append("%s %s：%s" % [label, bid, "；".join(errs)])
				continue
			if art.has("doors"):
				declared_n += 1
			# 走真实代码路径再验一遍：门格必须落在占地内
			for off in world._door_cells(bid, Vector2i(0, fp.y - 1), fp):
				var o: Vector2i = off
				if o.x < 0 or o.y < 0 or o.x >= fp.x or o.y >= fp.y:
					invalid.append("%s %s：门格偏移 %s 越界（占地 %dx%d）"
						% [label, bid, str(o), fp.x, fp.y])
				_checks += 1
	if not invalid.is_empty():
		_fail("\n".join(invalid))
		return
	if footprint_n == 0:
		_fail("一座建筑都没检查到（db 取空了？）—— 这种假绿比红更糟")
		return
	print("  · %d 座建筑 / 住房的门洞都落在占地内（其中 %d 座显式声明 art.doors，%d 条偏移断言）"
		% [footprint_n, declared_n, _checks])

	# ---- 3. 随机挑一座普通建筑，放下 -----------------------------------------
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var pool: Array = []
	for id in db.buildings.keys():
		var bid := String(id)
		if bid == TC:
			continue                      # 城镇中心是地图固定建筑，正常玩放不出来
		if world._can_afford(bid) != "":
			continue
		pool.append(bid)
	pool.sort()
	if pool.is_empty():
		_fail("没有建得起的普通建筑（检查 0 个）")
		return
	# 洗牌后逐个试：挑到哪座会打在输出里，门槛是可复现的
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp

	var bid := ""
	var cell := Vector2i(-1, -1)
	var from: Vector2i = world.map.town_center.position + Vector2i(12, -8)
	for cand in pool:
		var c: Vector2i = _find_spot(world, String(cand), Vector2i(-1, -1), from)
		if c.x >= 0:
			bid = String(cand)
			cell = c
			break
	if bid == "":
		_fail("随机挑出的 %d 座建筑一座都找不到能放的空地" % pool.size())
		return
	var fp: Vector2i = world._footprint(bid)
	var origin := cell - Vector2i(1, 0)
	var front0: Vector2i = (world._door_front_cells(bid, origin, fp) as Array)[0]
	_ok("随机挑中 %s（占地 %dx%d），打算放在 %s（门前格 %s）"
		% [bid, fp.x, fp.y, str(origin), str(front0)])

	if _road_at(world.map, front0) != 0:
		_fail("新局的门前格 %s 本来就是路，测不出『自动铺路』" % str(front0))
		return
	if not world._try_place(bid, cell):
		_fail("放下 %s 失败（%s）" % [bid, world.place_reason(bid, cell)])
		return
	await process_frame
	if _road_at(world.map, front0) != 1:
		_fail("放下 %s（工地阶段）后，门前通行格 %s 没有变成道路" % [bid, str(front0)])
		return
	_ok("**工地阶段**门前通行格 %s 就铺上了道路（不用等建成）" % str(front0))

	# ---- 4. 让它"建成"（和真实完工同一条路：_take_site_for → _create_shop_view）
	var sid := ""
	var count := 0
	for sh in world.runner.sim.s["shops"]:
		if String(sh["defId"]) == bid:
			count += 1
	sid = "%s#%d" % [bid, count + 1]
	world.runner.sim.s["shops"].append({
		"id": sid, "defId": bid, "owner": "state",
		"targetWorkers": int(db.buildings[bid]["workers"]),
		"wage": float(db.economy["refWage"]),
		"wageCap": float(db.economy["defaultWageCap"]),
		"level": int(db.defaults["newShop"]["level"]),
		"active": true, "profit": 0.0,
		"skill": float(db.defaults["newShop"]["skill"]),
		"planned": 0.0,
	})
	await process_frame
	await process_frame
	if not world._shop_sprites.has(sid):
		_fail("仿真里加了 %s 这条商店记录，_sync 却没把工地变成商店视图" % sid)
		return
	if world._shop_cell[sid] != origin:
		_fail("%s 建在 %s，不是工地那一格 %s（工地没被收走？）"
			% [sid, str(world._shop_cell[sid]), str(origin)])
		return

	# ---- 5. 普通建筑：门格 / 门前格进 reserved，且"看着空却建不了" -------------
	var doors: Array = world._shop_door[sid]
	if doors.is_empty():
		_fail("%s 没有门格" % sid)
		return
	for d in doors:
		if not world.map.reserved.has(d):
			_fail("%s 的门格 %s 不在 reserved 里" % [sid, str(d)])
			return
		_checks += 1
	var fcount := 0
	for f in world._door_front_cells(bid, origin, fp):
		if not world.map.reserved.has(f):
			_fail("%s 的门前通行格 %s 不在 reserved 里" % [sid, str(f)])
			return
		if world.map.cell_free(f):
			_fail("%s 的门前通行格 %s 居然 cell_free() == true" % [sid, str(f)])
			return
		fcount += 1
		_checks += 1
	_ok("%s：门格 %s 在 reserved；%d 格门前格在 reserved 且 cell_free() == false（有意不可建）"
		% [sid, str(doors), fcount])

	# ---- 6. 移动：新门前铺路，**旧址那格路不擦** ------------------------------
	var dst := _find_spot(world, bid, cell, world.map.town_center.position + Vector2i(-40, -10))
	if dst.x < 0:
		# 左边找不到就往右下再扫一圈 —— 门槛不该因为"这块地满了"变红
		dst = _find_spot(world, bid, cell, world.map.town_center.position + Vector2i(12, 20))
	if dst.x < 0:
		_fail("找不到第二块空地来测移动")
		return
	var old_front: Vector2i = front0
	if not world.move_shop_to(sid, dst - Vector2i(1, 0)):
		_fail("把 %s 移到 %s 失败" % [sid, str(dst - Vector2i(1, 0))])
		return
	await process_frame
	var new_front: Vector2i = (world._shop_door[sid] as Array)[0] + Vector2i(0, 1)
	if _road_at(world.map, new_front) != 1:
		_fail("移动到位后，新门前格 %s 没有铺路" % str(new_front))
		return
	if _road_at(world.map, old_front) != 1:
		_fail("移走之后，旧址门前格 %s 的路被擦掉了（用户要求『先不擦除』）" % str(old_front))
		return
	if world.map.reserved.has(old_front):
		_fail("移走之后，旧址门前格 %s 还占着 reserved" % str(old_front))
		return
	_ok("移动到位：新门前 %s = 道路；旧址门前 %s 的路仍在（不擦除），旧的 reserved 已释放"
		% [str(new_front), str(old_front)])

	# ---- 7. 住房走的是另一条入口（move_housing_to），一并验 -------------------
	if not db.housing.has("hut"):
		_fail("content 里没有 hut，住房那条路测不了（检查 0 个）")
		return
	var hcell := _find_spot(world, "hut", Vector2i(-1, -1), world.map.town_center.position + Vector2i(-14, 6))
	if hcell.x < 0:
		_fail("找不到放 hut 的空地")
		return
	var horigin := hcell - Vector2i(1, 0)
	var hfp: Vector2i = world._footprint("hut")
	var hfront0: Vector2i = (world._door_front_cells("hut", horigin, hfp) as Array)[0]
	if not world._try_place("hut", hcell):
		_fail("放下 hut 失败（%s）" % world.place_reason("hut", hcell))
		return
	await process_frame
	if _road_at(world.map, hfront0) != 1:
		_fail("放下住房后，门前通行格 %s 没有变成道路" % str(hfront0))
		return
	# 让 _sync() 把工地变成住房实例（真实入口：s["housing"] 计数 → _take_sites_for）
	var hcount: Dictionary = world.runner.sim.s["housing"]
	hcount["hut"] = int(float(hcount.get("hut", 0))) + 1
	world._prev_housing_n = -1
	await process_frame
	await process_frame
	var uid := ""
	for inst in world._housing_instances:
		if inst["cell"] == horigin:
			uid = String(inst["uid"])
	if uid == "":
		_fail("hut 的工地没被 _sync 收成住房实例（%s）" % str(horigin))
		return
	var hdst := _find_spot(world, "hut", hcell, world.map.town_center.position + Vector2i(-30, 20))
	if hdst.x < 0:
		_fail("找不到第二块空地来测住房移动")
		return
	if not world.move_housing_to(uid, hdst - Vector2i(1, 0)):
		_fail("把 %s 移到 %s 失败" % [uid, str(hdst - Vector2i(1, 0))])
		return
	await process_frame
	if _road_at(world.map, hfront0) != 1:
		_fail("住房移走后，旧址门前格 %s 的路被擦掉了" % str(hfront0))
		return
	_ok("住房 %s：放下就铺路；移走后旧址 %s 的路仍在" % [uid, str(hfront0)])

	# ---- 收尾 -----------------------------------------------------------------
	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("DOOR TEST 检查了 %d 条断言" % _checks)
	print("DOOR TEST RESULT: PASS")
	quit(0)
