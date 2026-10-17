extends SceneTree

# 住房改建（茅屋 → 木屋 → 砖房）门槛。
#
# 用户要求："茅屋可以升级成木屋，木屋升级成砖房，但是别墅要单独建造。"
# 链由 content/housing.json 的 `upgradeTo` **显式**给出（不是"按 quality 自动推下一档"）——
# 所以别墅（同样是高档房）只要没人指向它，就天然只能单独建。见 docs/spec.md §5.4。
#
# 验五件事：
#   1. 链与差价：茅屋→木屋 = 木 2 + 砖 3 / 建造力 12；木屋→砖房 = 石头 3 / 12；砖房不指向谁
#      （数字与 TS 的 `housingUpgradeSpec()` 同口径 —— node 侧门槛 `check-housing-upgrade.ts`）；
#   2. 引擎（GDScript 这份实现）：下单 → 队列里出现条目 → 完工时茅屋 −1、木屋 +1，**栋数不变**；
#   3. 世界层：升级中的住房头顶有进度条（先灰后蓝）、悬停能看进度；
#   4. 私有住房不能改建（居民买下的私产）；
#   5. 住房面板里给得出「改建为木屋」按钮，且私有时置灰。
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/housingupgrade_test.gd

const SEED := 20261016
const RES_MULT := 20.0

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("HOUSINGUPGRADE TEST FAIL: ", msg)
	print("HOUSINGUPGRADE TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

## 在内容区里按前缀找按钮（面板每次重建，所以每次都重新找）。
func _find_button(ins, prefix: String) -> Button:
	var stack: Array = [ins._body]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is Button and String((n as Button).text).begins_with(prefix):
			return n
		for c in n.get_children():
			stack.append(c)
	return null

func _entries(sim, kind: String) -> Array:
	var out := []
	for c in (sim.s["construction"] as Array):
		if String(c.get("kind", "")) == kind:
			out.append(c)
	return out

## 材料列表比较：GDScript 里 JSON 数字统一是 float（2.0），不能拿字符串比。
func _mats_eq(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in got.size():
		if String(got[i][0]) != String(want[i][0]):
			return false
		if absf(float(got[i][1]) - float(want[i][1])) > 0.001:
			return false
	return true

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
	var ins = node.get_node_or_null("UI/Root/Inspector")
	if world == null or ins == null:
		_fail("找不到 World / Inspector")
		return
	var db = world.runner.db
	var sim = world.runner.sim

	# ---- 1. 内容链与差价 ------------------------------------------------------
	var hut: Dictionary = db.housing["hut"]
	var wood: Dictionary = db.housing["wooden_house"]
	var brick: Dictionary = db.housing["brick_house"]
	if String(hut.get("upgradeTo", "")) != "wooden_house" \
			or String(wood.get("upgradeTo", "")) != "brick_house":
		_fail("改建链不是 茅屋→木屋→砖房：%s / %s"
			% [String(hut.get("upgradeTo", "")), String(wood.get("upgradeTo", ""))])
		return
	if brick.has("upgradeTo"):
		_fail("砖房不该指向任何房型（链到此为止）：%s" % String(brick.get("upgradeTo", "")))
		return
	var targets := {}
	for hid in db.housing.keys():
		targets[String(db.housing[hid].get("upgradeTo", ""))] = true
	if targets.has("villa"):
		_fail("有房型指向 villa —— 别墅必须只能单独建造")
		return
	_ok("链是显式的：茅屋 → 木屋 → 砖房；砖房不指向谁（别墅不在链里）")

	var s1: Dictionary = sim._housing_upgrade_spec(hut, wood)
	var s2: Dictionary = sim._housing_upgrade_spec(wood, brick)
	if not _mats_eq(s1["mats"], [["wood", 2], ["brick", 3]]) or float(s1["work"]) != 12.0:
		_fail("茅屋→木屋 的差价应为 木 2 / 砖 3 · 工期 12，实际 %s · %s" % [str(s1["mats"]), str(s1["work"])])
		return
	if not _mats_eq(s2["mats"], [["stone", 3]]) or float(s2["work"]) != 12.0:
		_fail("木屋→砖房 的差价应为 石头 3 · 工期 12，实际 %s · %s" % [str(s2["mats"]), str(s2["work"])])
		return
	_ok("差价公式与 TS 同口径：茅屋→木屋 木2+砖3/12；木屋→砖房 石头3/12")

	# ---- 2. 引擎：下单 → 完工，数量转移 ---------------------------------------
	world.start_new_game(SEED, RES_MULT, "改建测")
	world.runner.paused = true
	await process_frame
	sim = world.runner.sim
	sim.s["research"]["done"] = db.tech_ids.duplicate()
	for g in ["wood", "stone", "brick", "clay", "firewood"]:
		sim.s["goods"][g] = 400.0
	await process_frame
	var huts0 := int(floor(float(sim.s["housing"].get("hut", 0.0))))
	var wood0 := int(floor(float(sim.s["housing"].get("wooden_house", 0.0))))
	var slots0: int = sim._used_slots()
	if huts0 < 1:
		_fail("新局没有茅屋，测不了")
		return
	world.runner.enqueue([{"type": "upgrade_housing", "goodId": "hut"}])
	await process_frame
	# 命令次日黎明（hour 6）生效；先看"刚下单"这条 pending 状态
	var inst0: Dictionary = world._housing_instances[0]
	var st_pending: Dictionary = world._housing_upgrade_state(inst0)
	if String(st_pending.get("state", "")) != "pending":
		_fail("刚下单时那条住房应显示 pending，实际 %s" % str(st_pending))
		return
	_ok("刚下单（未生效）：住房头顶 = pending / frac 0")

	for h in 8:
		sim.tick_hour([])
		await process_frame
	var ups: Array = _entries(sim, "housing_upgrade")
	if ups.size() != 1:
		_fail("黎明后施工队列里应有一条住房改建，实际 %d 条" % ups.size())
		return
	if String(ups[0].get("toHousingId", "")) != "wooden_house":
		_fail("条目里的目标房型不对：%s" % String(ups[0].get("toHousingId", "")))
		return
	var st_build: Dictionary = world._housing_upgrade_state(inst0)
	if String(st_build.get("state", "")) != "building":
		_fail("施工中那条住房应显示 building，实际 %s" % str(st_build))
		return
	var tip: String = world.site_tip_at(inst0["cell"])
	if not tip.contains("改建") or not tip.contains("建造力"):
		_fail("改建中的住房悬停提示不对：%s" % tip)
		return
	_ok("施工中：进度条 = building（%.0f%%），提示「%s」"
		% [float(st_build["frac"]) * 100.0, tip.replace("\n", " / ")])

	for h in 48:
		sim.tick_hour([])
		await process_frame
	if not _entries(sim, "housing_upgrade").is_empty():
		_fail("两天后改建还没完工")
		return
	var huts1 := int(floor(float(sim.s["housing"].get("hut", 0.0))))
	var wood1 := int(floor(float(sim.s["housing"].get("wooden_house", 0.0))))
	if huts1 != huts0 - 1 or wood1 != wood0 + 1:
		_fail("完工后应 茅屋 %d→%d、木屋 %d→%d，实际 茅屋 %d / 木屋 %d"
			% [huts0, huts0 - 1, wood0, wood0 + 1, huts1, wood1])
		return
	if sim._used_slots() != slots0:
		_fail("改建不该改变土地名额：%d → %d" % [slots0, sim._used_slots()])
		return
	if not world._housing_upgrade_state(world._housing_instances[0]).is_empty():
		_fail("完工后还留着改建进度条")
		return
	_ok("完工：茅屋 %d→%d、木屋 %d→%d，土地名额 %d 不变，进度条收掉"
		% [huts0, huts1, wood0, wood1, slots0])

	# ---- 3. 住房面板：按钮存在且可用 -----------------------------------------
	var uid := String(world._housing_instances[0]["uid"])
	ins.show_housing(uid)
	await process_frame
	var btn := _find_button(ins, "改建为")
	if btn == null:
		_fail("住房面板里没有「改建为…」按钮")
		return
	if btn.disabled:
		_fail("国有住房的改建按钮不该置灰：%s" % btn.text)
		return
	_ok("住房面板按钮：「%s」（可用）" % btn.text)

	# ---- 4. 私有住房不能改建 --------------------------------------------------
	# 私有化的分配口径：`_assign_homes()` 按实例顺序把前 N 座标成私有。
	sim.s["privateHousing"]["hut"] = 1.0
	world._assign_homes()
	await process_frame
	var priv_inst: Dictionary = {}
	for inst in world._housing_instances:
		if String(inst["type"]) == "hut" and bool(inst["private"]):
			priv_inst = inst
			break
	if priv_inst.is_empty():
		_fail("没能造出一座私有茅屋（_assign_homes 没标 private？）")
		return
	if not world._housing_upgrade_state(priv_inst).is_empty():
		_fail("私有住房不该显示改建进度条（它不会被改建）")
		return
	ins.show_housing(String(priv_inst["uid"]))
	await process_frame
	var pbtn := _find_button(ins, "改建为")
	if pbtn == null:
		_fail("私有住房的面板里也该有按钮（置灰 + 说明），实际没有")
		return
	if not pbtn.disabled:
		_fail("私有住房的改建按钮必须置灰")
		return
	# 引擎层面也要拦：直接把全部茅屋私有化，再试一次下单
	sim.s["privateHousing"]["hut"] = float(sim.s["housing"]["hut"])
	var before := _entries(sim, "housing_upgrade").size()
	sim._try_upgrade_housing("hut")
	if _entries(sim, "housing_upgrade").size() != before:
		_fail("私有住房竟然排进了改建队列")
		return
	_ok("私有住房：按钮置灰 + 引擎拒绝下单（私有住房不能改建）")

	# ---- 5. 一批茅屋同时改建：房子要**原地换**、进度条不许乱跳 ------------------
	#
	# 用户 2026-10 报的两个症状：
	#   · "茅屋改建木屋之后，房子并没有消失，而是多了一座木屋"
	#     —— 地图这边原来只加不减（`_sync` 里只有 `while have < want`）
	#   · "有大量茅屋在升级的时候，升级条到处乱跳"
	#     —— 进度条按"第 i 条在途改建 ↔ 同类型第 i 座房子"配对，两边必须都按 FIFO 挪；
	#        收错那一座（尾部）或者干脆不收，配对就整体错位、条就跳到别的房子上
	world.start_new_game(SEED, RES_MULT, "改建批测")
	await process_frame
	sim = world.runner.sim
	sim.s["research"]["done"] = db.tech_ids.duplicate()
	for g in ["wood", "stone", "brick", "clay", "firewood"]:
		sim.s["goods"][g] = 400.0
	await process_frame
	world.runner.paused = true
	var huts_before := int(floor(float(sim.s["housing"].get("hut", 0.0))))
	var wood_before := int(floor(float(sim.s["housing"].get("wooden_house", 0.0))))
	var inst_before: int = world._housing_instances.size()
	if huts_before < 3:
		_fail("新局的茅屋太少（%d 座），测不了" % huts_before)
		return
	# 连下 3 条改建
	for i in 3:
		world.runner.enqueue([{"type": "upgrade_housing", "goodId": "hut"}])
	await process_frame
	# 记下"改建前第一座茅屋的格子"——FIFO 的话，它应该第一个被换掉
	var first_hut_cell: Vector2i = Vector2i(-1, -1)
	for inst in world._housing_instances:
		if String(inst["type"]) == "hut":
			first_hut_cell = inst["cell"]
			break
	for h in 8:
		sim.tick_hour([])
		await process_frame
	var ups3: Array = _entries(sim, "housing_upgrade")
	if ups3.size() != 3:
		_fail("黎明后施工队列里应有 3 条改建，实际 %d 条" % ups3.size())
		return
	# 配对：第一座茅屋头顶应当是**队首**那条（building = 正在施工）
	var hut0: Dictionary = {}
	for inst in world._housing_instances:
		if String(inst["type"]) == "hut":
			hut0 = inst
			break
	if hut0.is_empty() or int(world._housing_ordinal(hut0)) != 0:
		_fail("第一座茅屋的序号不是 0（进度条配对会错位）")
		return
	var st0: Dictionary = world._housing_upgrade_state(hut0)
	if String(st0.get("state", "")) != "building":
		_fail("第一座茅屋头顶应当是队首那条（building），实际 %s" % str(st0))
		return
	# 只让**第一条**完工，然后立刻验"配对没有错位"—— 这才是"进度条到处乱跳"的直接断言：
	# 剩下那几座里**最早的一座**（序号仍是 0）必须继续顶着**新的队首**那条。
	#
	# ⚠️ 必须人为把进度拉开：一次工作小时可能同时完工两条（第一版就是这么红的：
	#    采样到的中间态是"还剩 1 条"，中间那一帧根本没看到）。
	ups3[0]["remaining"] = 0.5
	for i in range(1, ups3.size()):
		ups3[i]["remaining"] = 9999.0
	var guard := 0
	while _entries(sim, "housing_upgrade").size() == ups3.size() and guard < 120:
		sim.tick_hour([])
		await process_frame
		guard += 1
	var left := _entries(sim, "housing_upgrade")
	if left.size() != ups3.size() - 1:
		_fail("把进度拉开之后应当**恰好**完工 1 条（还剩 %d 条）" % left.size())
		return
	var at_first_mid := ""
	var hut_next: Dictionary = {}
	for inst in world._housing_instances:
		if inst["cell"] == first_hut_cell:
			at_first_mid = String(inst["type"])
		elif String(inst["type"]) == "hut" and hut_next.is_empty():
			hut_next = inst
	if at_first_mid != "wooden_house":
		_fail("第一条改建完工后，原来那座茅屋那一格是「%s」，应当是 wooden_house（原地换）"
			% at_first_mid)
		return
	if hut_next.is_empty() or int(world._housing_ordinal(hut_next)) != 0:
		_fail("第一条完工后，剩下那座茅屋的序号不是 0（配对整体错位 → 进度条会跳房子）")
		return
	var st1: Dictionary = world._housing_upgrade_state(hut_next)
	var want1: Dictionary = world._entry_bar_state(left[0])
	if String(st1.get("state", "")) != String(want1.get("state", "")) \
			or absf(float(st1.get("frac", 0.0)) - float(want1.get("frac", 0.0))) > 0.001:
		_fail("第一条完工后进度条没跟到队首那条：显示 %s / 应为 %s（条在跳房子）"
			% [str(st1), str(want1)])
		return
	# 把剩下那几条的进度放回去，让它们照常完工
	for c in left:
		c["remaining"] = 1.0
	# 让它完工（多跑几天）
	for h in 72:
		sim.tick_hour([])
		await process_frame
	var huts_after := int(floor(float(sim.s["housing"].get("hut", 0.0))))
	var wood_after := int(floor(float(sim.s["housing"].get("wooden_house", 0.0))))
	if huts_after != huts_before - 3 or wood_after != wood_before + 3:
		_fail("3 条改建完工后应 茅屋 %d→%d、木屋 %d→%d，实际 茅屋 %d / 木屋 %d" % [
			huts_before, huts_before - 3, wood_before, wood_before + 3, huts_after, wood_after])
		return
	# ① 地图上的实例总数不变（房还是那些房，只是三座换了个样）
	if world._housing_instances.size() != inst_before:
		_fail("改建之后地图上的房子数量变了：%d → %d（旧房没消失 / 多建了一座）"
			% [inst_before, world._housing_instances.size()])
		return
	# ② 第一座茅屋那一格现在必须是木屋（原地变样），且**没有**茅屋还占着它
	var at_first := ""
	for inst in world._housing_instances:
		if inst["cell"] == first_hut_cell:
			at_first = String(inst["type"])
	if at_first != "wooden_house":
		_fail("原来第一座茅屋那一格现在是「%s」，应当是 wooden_house（原地换房）" % at_first)
		return
	# ③ 茅屋实例数 = 引擎里的茅屋数（不许有"幽灵茅屋"留在图上）
	var hut_views := 0
	for inst in world._housing_instances:
		if String(inst["type"]) == "hut":
			hut_views += 1
	if hut_views != huts_after:
		_fail("地图上茅屋实例 %d 座，引擎里只有 %d 座（幽灵房子）" % [hut_views, huts_after])
		return
	# ④ 完工后没有残留的改建进度条
	for inst in world._housing_instances:
		if not world._housing_upgrade_state(inst).is_empty():
			_fail("改建都完工了，还有房子头顶挂着进度条（配对错位）")
			return
	_ok("3 座茅屋同时改建：原地换成木屋（实例数 %d 不变）、无幽灵房子、无残留进度条"
		% inst_before)

	if _checks == 0:
		_fail("一条都没检查到（假绿）")
		return
	print("HOUSINGUPGRADE TEST 检查了 %d 条断言" % _checks)
	print("HOUSINGUPGRADE TEST RESULT: PASS")
	quit(0)
