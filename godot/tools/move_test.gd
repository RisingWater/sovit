extends SceneTree

# 复现"移动建筑崩溃"：摆一座 → 跑几天 → 移动它。
# godot --headless --path godot -s res://tools/move_test.gd

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var runner = node.get("runner")
	var world = node.get("world")
	if runner == null or world == null:
		print("MOVE TEST: main 未创建 runner/world")
		quit(1)
		return

	var c: Vector2i = world.map.center
	var id := "coarse_weaver"
	var cell := c + Vector2i(-14, -8)
	print("MOVE TEST place=", world._try_place(id, cell), " fp=", world._footprint(id))
	# 施工要 2 天，跑久一点让 shop 真正落地
	for h in 120:
		runner.sim.tick_hour([])
		await process_frame

	var sid := ""
	for s in runner.sim.s["shops"]:
		sid = String(s["id"])
		break
	print("MOVE TEST sid=", sid, " has_sprite=", world._shop_sprites.has(sid))

	if sid != "":
		print("MOVE TEST begin_move_shop ...")
		world.begin_move_shop(sid)
		print("MOVE TEST begin ok, move_mode=", world.move_mode)
		var dst := c + Vector2i(12, 4)
		print("MOVE TEST move_shop_to ", dst, " ...")
		var ok = world.move_shop_to(sid, dst)
		print("MOVE TEST move_shop_to -> ", ok)
		await process_frame
		await process_frame

	# 住房也试一次
	var uid := ""
	for k in world._housing_by_uid.keys():
		uid = String(k)
		break
	print("MOVE TEST housing uid=", uid)
	if uid != "":
		world.begin_move_housing(uid)
		var ok2 = world.move_housing_to(uid, c + Vector2i(-8, 12))
		print("MOVE TEST move_housing_to -> ", ok2)
	await process_frame

	# 反复移动同一座：标签表不能无限增长（旧标签释放后条目要被剔除）
	var before: int = world._label_items.size()
	for i in 10:
		world.move_housing_to(uid, c + Vector2i(-8 + i, 12))
		await process_frame
	await process_frame
	var after: int = world._label_items.size()
	print("MOVE TEST labels before=", before, " after10moves=", after,
		" -> ", "OK" if after <= before + 1 else "LEAK!")

	# 关键回归点：标签表里不能残留已释放的节点。
	# 移动建筑会 queue_free 旧标签，而 _update_labels 过去用带类型的赋值去取它，
	# 直接抛 "Trying to assign invalid previously freed instance"。
	var stale := 0
	for it in world._label_items:
		if not is_instance_valid(it["node"]):
			stale += 1
	if stale > 0:
		print("MOVE TEST FAIL: 标签表残留 ", stale, " 个已释放节点")
		quit(1)
		return

	if after > before + 1:
		print("MOVE TEST FAIL: 标签表泄漏")
		quit(1)
		return

	print("MOVE TEST RESULT: PASS")
	quit(0)
