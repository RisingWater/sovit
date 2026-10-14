extends SceneTree

# 遮挡（draw order）验证：
#   1. 建筑之间 —— 前排建筑必须盖住后排（建筑贴图可以比占地高，见 content 的 art.foot）
#   2. 小人 —— 站在建筑**后面**（脚底在地面线之上）要被挡住；
#              站在**前面**（脚底在地面线之下）要压在建筑上
#   3. 道路 —— 地面层，永远在建筑/小人下面（建筑压住的是身后的路面，不是身前的）
#
# 用确定性布置：把 6 个居民沿一条竖线摆在建筑的前后，而不是靠他们自己乱走。
# 截图 + 断言一起出：断言查"排序键"，截图给人看。
#
# 用法（在 godot/ 下，**不能加 --headless**：headless 没有渲染，抓不到帧）：
#   <godot> --path . -s res://tools/occlusion_test.gd -- [out.png] [zoom]

const SEED := 20261014
const TEST_ID := "construction_works" # 128x84，占地 8x3 -> 贴图比占地高 36px
const PEOPLE := 6

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := "user://occl.png"
	if args.size() > 0:
		out_path = args[0]
	var zoom := 3.0
	if args.size() > 1 and args[1].is_valid_float():
		zoom = float(args[1])

	var ps: PackedScene = load("res://scenes/main.tscn")
	if ps == null:
		_fail("无法加载 main.tscn")
		return
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var runner = node.get("runner")
	var world = node.get("world")
	if runner == null or world == null:
		_fail("main 未创建 runner/world")
		return
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	world.start_new_game(SEED, 1.0, "遮挡")
	var all: Array = []
	for t in runner.db.tech_ids:
		all.append(String(t))
	runner.sim.s["research"]["done"] = all
	runner.sim.s["government"]["money"] = 999999.0
	for gid in runner.sim.s["goods"].keys():
		runner.sim.s["goods"][gid] = 9999.0
	runner.sim.s["hour"] = 12

	var failed: Array = []

	# ---- 断言 1：容器必须是 y 排序的，否则遮挡无从谈起
	if not world.building_layer.y_sort_enabled:
		failed.append("building_layer.y_sort_enabled 不是 true")

	# ---- 断言 2：占地来自 content 的 art.foot，而不是贴图尺寸
	var fp: Vector2i = world._footprint(TEST_ID)
	var tex: Texture2D = world._texture_for(TEST_ID)
	if fp != Vector2i(8, 3):
		failed.append("%s 占地应为 (8,3)，实际 %s" % [TEST_ID, str(fp)])
	if tex == null:
		_fail("没有贴图 " + TEST_ID)
		return
	if tex.get_height() <= fp.y * 16:
		failed.append("%s 贴图(%d) 应当高于占地(%d) —— 否则这条溢出路径没被覆盖"
			% [TEST_ID, tex.get_height(), fp.y * 16])

	# ---- 铺一条路穿过测试区（验证道路不会被压错）
	var c: Vector2i = world.map.center
	var org := c + Vector2i(-6, -14)
	for dy in 30:
		for dx in 14:
			var cc := org + Vector2i(dx, dy)
			if world.map.in_bounds(cc):
				world.map.road[world.map.idx(cc.x, cc.y)] = 1
	world._rerender_terrain()

	# ---- 摆建筑并直接结算成完工
	var placed := false
	for nudge in [Vector2i(0, 0), Vector2i(0, -18), Vector2i(0, 18), Vector2i(-9, 0)]:
		var cell: Vector2i = c + nudge
		if world._try_place(TEST_ID, cell):
			placed = true
			org = cell - Vector2i(1, 1)
			break
	if not placed:
		_fail("摆不下 " + TEST_ID)
		return
	var shops: Array = runner.sim.s["shops"]
	shops.append({
		"id": TEST_ID + "#1", "defId": TEST_ID, "owner": "state",
		"targetWorkers": 3, "wage": 3.0, "wageCap": 6.0, "level": 1,
		"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0, "toolBoost": 1.0,
	})
	runner.sim.s["pending"] = []
	runner.sim.s["construction"] = []
	for f in 6:
		await process_frame

	# ---- 断言 3：建筑节点的 y 必须等于"地面线"（占地底边），y 排序才会按地面线排
	var sid := TEST_ID + "#1"
	var spr = world._shop_sprites.get(sid, null)
	if spr == null:
		failed.append("建筑精灵没建出来：" + sid)
	else:
		var want_y := float(org.y * 16 + fp.y * 16)
		if absf(spr.position.y - want_y) > 0.01:
			failed.append("建筑节点 y 应为地面线 %.1f，实际 %.1f" % [want_y, spr.position.y])

	# ---- 把居民沿一条竖线摆在建筑前后（每人脚底一档），并暂停仿真免得他们走开
	var base_y := float(org.y * 16 + fp.y * 16)
	var mid_x := float(org.x * 16 + fp.x * 16 * 0.5)
	runner.paused = true
	var people: Array = world._agents
	if people.size() < PEOPLE:
		failed.append("居民不够摆（只有 %d 个）" % people.size())
	for i in mini(PEOPLE, people.size()):
		var a: Dictionary = people[i]
		# i=0..2 在建筑后面（脚底在地面线之上），i=3..5 在前面
		var y := base_y + (float(i) - 2.5) * 12.0
		var x := mid_x + (float(i % 3) - 1.0) * 22.0
		a["pos"] = Vector2(x, y)
		a["target"] = a["pos"]
		a["home"] = a["pos"]
		a["prev_pos"] = a["pos"]
	for f in 4:
		await process_frame

	# ---- 断言 4：小人节点的 y 必须等于脚底 y（地面线）
	for i in mini(PEOPLE, people.size()):
		var a: Dictionary = people[i]
		var nd = a.get("node", null)
		if not is_instance_valid(nd):
			failed.append("居民节点没建出来：%s" % a["id"])
			continue
		if absf(nd.position.y - float(a["pos"].y)) > 0.01:
			failed.append("小人节点 y 应为脚底 %.1f，实际 %.1f" % [a["pos"].y, nd.position.y])

	# ---- 断言 5：前后关系要落在正确的 z 排序上
	# y 排序的规则是"y 小的先画"，所以建筑后面的人 y 必须小于建筑地面线，
	# 前面的人必须大于地面线 —— 否则遮挡关系是反的。
	if people.size() >= PEOPLE:
		var behind_y: float = people[0]["pos"].y
		var front_y: float = people[PEOPLE - 1]["pos"].y
		if not (behind_y < base_y):
			failed.append("被安排在后面的人 y(%.1f) 没有小于地面线(%.1f)" % [behind_y, base_y])
		if not (front_y > base_y):
			failed.append("被安排在前面的人 y(%.1f) 没有大于地面线(%.1f)" % [front_y, base_y])

	# ---- 截图（只在有渲染时做）。headless 下没有渲染，`await frame_post_draw`
	# 永远不返回，会让门槛挂住 —— 所以 headless 只跑断言、不截图。
	var headless := DisplayServer.get_name() == "headless"
	if not headless:
		var ui = node.get_node_or_null("UI")
		if ui != null:
			ui.visible = false
		if world.camera != null:
			world.camera.position = Vector2(mid_x, base_y - 8.0)
			world.camera.zoom = Vector2(zoom, zoom)
		for f in 8:
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		if img == null:
			_fail("拿不到 viewport 图像")
			return
		var err := img.save_png(out_path)
		print("OCCLUSION shot -> ", out_path, " err=", err)

	if failed.is_empty():
		print("OCCLUSION TEST RESULT: PASS")
		quit(0)
	else:
		for m in failed:
			print("  ✗ ", m)
		print("OCCLUSION TEST RESULT: FAIL")
		quit(1)

func _fail(msg: String) -> void:
	print("  ✗ ", msg)
	print("OCCLUSION TEST RESULT: FAIL")
	quit(1)
