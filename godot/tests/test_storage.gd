extends GdUnitTestSuite

# 仓储（docs/town.md §三；TS 契约 src/engine/systems/storage.ts）。
#
# golden 的固定命令脚本只有 20 天、开局物资 980 < 容量 2000，**碰不到上限**，
# 所以这里把两层口径单独锁住：容量口径（工人在岗才算）、全局削减
# （**所有物资按同一比例**，见 docs/spec.md §2.4）、逐项软上限先于全局上限。

func _mk(seed_value: int = 4242) -> SimCore:
	var db := ContentDB.load_all()
	var sim := SimCore.new(db)
	sim.new_game("v0.3", seed_value)
	# v0.3 开局：一座城镇中心（workers = 0），开局物资合计 980。
	return sim

func _add_shop(sim: SimCore, sid: String, def_id: String, level: int) -> void:
	sim.s["shops"].append({
		"id": sid, "defId": def_id, "owner": "state", "targetWorkers": 1,
		"wage": 0.0, "wageCap": 0.0, "level": level, "active": true,
		"profit": 0.0, "skill": 1.0, "planned": 0.0, "toolBoost": 1.0,
	})

## 派人到岗（_assigned_workers 只看 jobShopId）。
func _staff(sim: SimCore, rid: String, sid: String) -> void:
	sim.s["residents"].append({
		"id": rid, "classId": "poor", "savings": 0.0, "satisfaction": 50.0,
		"skill": 1.0, "employed": true, "jobShopId": sid,
	})

func _zero_goods(sim: SimCore) -> void:
	for gid in sim.s["goods"].keys():
		sim.s["goods"][gid] = 0.0

func _put(sim: SimCore, gid: String, v: float) -> void:
	sim.s["goods"][gid] = v

func test_town_center_counts_and_unstaffed_warehouse_does_not() -> void:
	var sim := _mk()
	# 城镇中心 workers = 0 → 直接计入；开局库存 980，不超限
	assert_that(sim.storage_capacity()).is_equal_approx(2000.0, 0.001)
	assert_that(sim.stored_total()).is_equal_approx(980.0, 0.001)

	# 仓库 workers = 1 → 没人在岗就不算容量
	_add_shop(sim, "warehouse#1", "warehouse", 1)
	assert_that(sim.storage_capacity()).is_equal_approx(2000.0, 0.001)

	# 派 1 人：+300
	_staff(sim, "res#w1", "warehouse#1")
	assert_that(sim.storage_capacity()).is_equal_approx(2300.0, 0.001)

	# 升到 3 级：300 + 150×2 = 600
	sim.s["shops"][1]["level"] = 3
	assert_that(sim.storage_capacity()).is_equal_approx(2600.0, 0.001)

	# 人走了 → 加成立刻消失（每晚 _assign_labor 现算）
	sim.s["residents"].pop_back()
	assert_that(sim.storage_capacity()).is_equal_approx(2000.0, 0.001)

func test_global_cap_shrinks_all_goods_proportionally() -> void:
	# 2026-10 改：原来是「按 baseValue 升序丢（先丢便宜的）」——
	# 食物恰好最便宜，于是开局资源 x2 时第一晚就把 400 粗面包 + 174.6 蔬菜全丢了，
	# 剩下的全是木材/石块/砖，接下来几天饿死一半人。现在所有物资按同一比例削减。
	var sim := _mk()
	_zero_goods(sim)
	_put(sim, "vegetable", 30.0)      # 便宜（1.2），旧规则下第一个被丢
	_put(sim, "coarse_bread", 30.0)   # 便宜（1.3）
	_put(sim, "wood", 1970.0)         # 贵（1.5）
	var keep := 2000.0 / 2030.0
	var logs := sim.apply_storage_cap(3)

	assert_that(sim.stored_total() <= 2000.0).is_true()
	assert_that(sim.stored_total() > 1999.5).is_true()
	# 核心断言：食物没有被单独针对（旧规则下这两项都会是 0）
	assert_that(float(sim.s["goods"]["vegetable"]) > 0.0).is_true()
	assert_that(float(sim.s["goods"]["coarse_bread"]) > 0.0).is_true()
	# 便宜的和贵的按同一个比例削减
	assert_that(float(sim.s["goods"]["coarse_bread"])).is_equal_approx(30.0 * keep, 0.02)
	assert_that(float(sim.s["goods"]["wood"])).is_equal_approx(1970.0 * keep, 0.02)
	assert_that(logs.size()).is_equal(1)
	assert_that(String(logs[0]["kind"])).is_equal("storage")
	assert_that(String(logs[0]["text"])).contains("削减")
	assert_that(int(logs[0]["day"])).is_equal(3)

func test_no_storage_building_means_no_discard() -> void:
	# cap == 0 时不做任何丢弃（否则会有一类"没有仓储 = 全丢光"的荒谬存档）
	var sim := _mk()
	sim.s["shops"] = []
	_zero_goods(sim)
	_put(sim, "wood", 500.0)
	var logs := sim.apply_storage_cap(1)
	assert_that(sim.storage_capacity()).is_equal_approx(0.0, 0.001)
	assert_that(float(sim.s["goods"]["wood"])).is_equal_approx(500.0, 0.001)
	assert_that(logs).is_empty()

func test_soft_caps_trim_before_global_cap() -> void:
	# ① 逐项软上限：先按它修剪，再按全局上限修剪（两层）
	var sim := _mk()
	_zero_goods(sim)
	_put(sim, "wood", 400.0)
	_put(sim, "stone", 100.0)
	sim.s["government"]["storageCaps"] = {"wood": 50}
	var logs := sim.apply_storage_cap(2)
	assert_that(float(sim.s["goods"]["wood"])).is_equal_approx(50.0, 0.001)
	assert_that(sim.stored_total()).is_equal_approx(150.0, 0.001)
	assert_that(logs.size()).is_equal(1)
	assert_that(String(logs[0]["text"])).contains("超过单项上限 50，丢弃 350 单位")

	# ② 软上限把货挡在别人前面：全局超限时，被软上限削过的货先退出占用，
	#    没被削的货就不用跟着缩水
	var sim2 := _mk()
	_zero_goods(sim2)
	_put(sim2, "wood", 2000.0)
	_put(sim2, "coarse_bread", 30.0)
	sim2.apply_storage_cap(2)
	# 合计 2030 → 超 30 → 所有物资按比例缩水：面包也掉了一点
	assert_that(float(sim2.s["goods"]["coarse_bread"]) < 30.0).is_true()
	assert_that(float(sim2.s["goods"]["coarse_bread"]) > 29.0).is_true()

	var sim3 := _mk()
	_zero_goods(sim3)
	_put(sim3, "wood", 2000.0)
	_put(sim3, "coarse_bread", 30.0)
	sim3.s["government"]["storageCaps"] = {"wood": 1900}   # 木材先被削到 1900
	sim3.apply_storage_cap(2)
	# 1900 + 30 = 1930 < 2000 → 全局那一步不触发，面包一点没动
	assert_that(float(sim3.s["goods"]["wood"])).is_equal_approx(1900.0, 0.001)
	assert_that(float(sim3.s["goods"]["coarse_bread"])).is_equal_approx(30.0, 0.001)

func test_action_set_storage_caps_replaces_and_sanitizes() -> void:
	var sim := _mk()
	sim._apply_actions([{
		"type": "set_storage_caps",
		"caps": {"wood": 12.9, "stone": 7, "clay": 0, "brick": -3, "not_a_good": 99, "flax": "abc"},
	}])
	var caps: Dictionary = sim.s["government"]["storageCaps"]
	# 整体替换：非负整数、0 视为不限（丢键）、只收本 pack 存在的商品
	assert_that(caps.has("wood")).is_true()
	assert_that(int(caps["wood"])).is_equal(12)
	assert_that(int(caps["stone"])).is_equal(7)
	assert_that(caps.has("clay")).is_false()
	assert_that(caps.has("brick")).is_false()
	assert_that(caps.has("not_a_good")).is_false()
	assert_that(caps.has("flax")).is_false()

	# 再传一次 = 整体替换（旧键不留）
	sim._apply_actions([{"type": "set_storage_caps", "caps": {"stone": 3}}])
	caps = sim.s["government"]["storageCaps"]
	assert_that(caps.size()).is_equal(1)
	assert_that(int(caps["stone"])).is_equal(3)

func test_storage_full_alert() -> void:
	var sim := _mk()
	_zero_goods(sim)
	_put(sim, "wood", 1999.0)
	assert_that(sim._build_alerts(0)).is_empty()

	_put(sim, "wood", 2000.0)
	var alerts: Array = sim._build_alerts(0)
	var hit := {}
	for a in alerts:
		hit[String(a["type"])] = a
	assert_that(hit.has("storage_full")).is_true()
	assert_that(int(hit["storage_full"]["count"])).is_equal(2000)
	assert_that(String(hit["storage_full"]["text"])).is_equal("仓储已满（2000 / 2000）")
