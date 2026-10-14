extends SceneTree

# 效率科技（tech→倍率）门槛。
#
# 用户要的那 15 项科技本身只是数据，真正会坏的是**机制**：
#   · 加成必须按建筑的 `sector` 生效（不是全局、不是按商品类别）
#   · **加法**叠加（+10%+15%+20% = +45%），不是连乘
#   · 三条路都要真的涨：该产业产出、每日科研力、每日建造力
#   · 和"石制工具"的 toolBoost 是**相乘**关系
#
# 内容形状也一起锁：有配方的建筑必须都有 sector；15 项效率科技必须都有 effects。

const EFF_TECHS := [
	"crop_rotation", "irrigation", "improved_seeds",
	"workshop_division", "standardization", "assembly_line",
	"kiln_upgrade", "sawmill_machinery", "brick_press",
	"scriptorium", "academy", "printing_press",
	"crane", "scaffolding", "prefab_parts",
]

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("EFFICIENCY TEST FAIL: ", msg)
	quit(1)

func _approx(a: float, b: float, eps := 0.002) -> bool:
	return absf(a - b) <= eps

## 造一局：v0.3 开局 + 三座不同产业的工厂（只为测倍率，不会摆到地图上）。
func _make(node) -> Variant:
	var runner = node.get("runner")
	var world = node.get("world")
	world.start_new_game(20261014, 1.0, "效率测")
	var sim = runner.sim
	var s: Dictionary = sim.s
	for pair in [["wheat_farm#t", "wheat_farm"], ["coarse_weaver#t", "coarse_weaver"],
			["quarry#t", "quarry"], ["research_institute#t", "research_institute"]]:
		(s["shops"] as Array).append({
			"id": pair[0], "defId": pair[1], "owner": "state",
			"targetWorkers": 6, "wage": 3.0, "wageCap": 6.0, "level": 1,
			"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		})
	# 研究所要有人才算科研力（1 人即可让基线 > 0；这里直接把人派上去，
	# 不走 _assign_labor —— 本测试只关心倍率，不关心排产）
	(s["residents"] as Array)[0]["employed"] = true
	(s["residents"] as Array)[0]["jobShopId"] = "research_institute#t"
	return sim

func _shop_of(sim, sid: String) -> Dictionary:
	for sh in sim.s["shops"]:
		if String(sh["id"]) == sid:
			return sh
	return {}

func _learn(sim, ids: Array) -> void:
	(sim.s["research"] as Dictionary)["done"] = ids

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var runner = node.get("runner")
	var db = runner.db

	# ---- 1. 内容形状
	var missing_sector := []
	var n_recipe := 0
	for bid in db.buildings.keys():
		var d: Dictionary = db.buildings[bid]
		if d.has("recipe"):
			n_recipe += 1
			if not d.has("sector"):
				missing_sector.append(String(bid))
	if not missing_sector.is_empty():
		_fail("这些有配方的建筑没有 sector：%s" % str(missing_sector))
		return
	for tid in EFF_TECHS:
		if not db.techs.has(tid):
			_fail("缺少效率科技 %s" % tid)
			return
		var eff: Dictionary = db.techs[tid].get("effects", {})
		if eff.is_empty():
			_fail("效率科技 %s 没有 effects" % tid)
			return
	print("EFFICIENCY TEST 内容：%d 座有配方的建筑全带 sector，效率科技 %d 项全带 effects ✅" % [
		n_recipe, EFF_TECHS.size()])

	# ---- 2. 全 0 起点
	var sim = _make(node)
	if float(sim.tech_bonuses()["agri"]) != 0.0:
		_fail("开局 agri 加成不是 0")
		return
	if not _approx(sim._sector_output_boost(_shop_of(sim, "wheat_farm#t")), 1.0):
		_fail("没有科技时小麦农场倍率应为 1")
		return

	# ---- 3. 按 sector 生效：一级轮作只抬农业，工业和建材不动
	_learn(sim, ["crop_rotation"])
	var b: Dictionary = sim.tech_bonuses()
	if not _approx(float(b["agri"]), 0.10):
		_fail("轮作之后 agri 加成应为 0.10，实际 %s" % b["agri"])
		return
	if not _approx(sim._sector_output_boost(_shop_of(sim, "wheat_farm#t")), 1.10):
		_fail("轮作之后小麦农场倍率应为 1.10，实际 %s" % sim._sector_output_boost(_shop_of(sim, "wheat_farm#t")))
		return
	if not _approx(sim._sector_output_boost(_shop_of(sim, "coarse_weaver#t")), 1.0):
		_fail("轮作不该影响工业商品（粗织坊）")
		return
	if not _approx(sim._sector_output_boost(_shop_of(sim, "quarry#t")), 1.0):
		_fail("轮作不该影响建材（采石场）")
		return
	print("EFFICIENCY TEST 按 sector 生效：农业 ×%.2f，工业 ×%.2f，建材 ×%.2f ✅" % [
		sim._sector_output_boost(_shop_of(sim, "wheat_farm#t")),
		sim._sector_output_boost(_shop_of(sim, "coarse_weaver#t")),
		sim._sector_output_boost(_shop_of(sim, "quarry#t"))])

	# ---- 4. **加法**叠加：轮作 + 灌溉 = 0.25（不是 1.1×1.15−1 = 0.265）
	_learn(sim, ["crop_rotation", "irrigation"])
	b = sim.tech_bonuses()
	if not _approx(float(b["agri"]), 0.25):
		_fail("轮作+灌溉 应为 0.25（加法），实际 %s —— 是不是写成连乘了？" % b["agri"])
		return
	_learn(sim, ["crop_rotation", "irrigation", "improved_seeds"])
	if not _approx(float(sim.tech_bonuses()["agri"]), 0.45):
		_fail("三级全拿应为 0.45（+10+15+20），实际 %s" % sim.tech_bonuses()["agri"])
		return
	print("EFFICIENCY TEST 加法叠加：一级 0.10 → 二级 0.25 → 三级 0.45 ✅")

	# ---- 5. 科研 / 建造速率
	_learn(sim, [])
	var r0: float = sim._research_rate()
	var c0: float = sim._construction_rate()
	if r0 <= 0.0 or c0 <= 0.0:
		_fail("基线速率为 0（%s / %s），测不出倍率" % [r0, c0])
		return
	_learn(sim, ["scriptorium"])
	var r1: float = sim._research_rate()
	if not _approx(r1, r0 * 1.10, 0.02):
		_fail("抄书房之后科研力应为基线 ×1.10：%s → %s" % [r0, r1])
		return
	if not _approx(sim._construction_rate(), c0, 0.02):
		_fail("抄书房不该影响建造力")
		return
	_learn(sim, ["crane"])
	var c1: float = sim._construction_rate()
	if not _approx(c1, c0 * 1.10, 0.02):
		_fail("起重架之后建造力应为基线 ×1.10：%s → %s" % [c0, c1])
		return
	print("EFFICIENCY TEST 速率：科研 %.2f→%.2f，建造 %.2f→%.2f（各 +10%%）✅" % [r0, r1, c0, c1])

	# ---- 6. 与工具相乘（不是相加）：toolBoost 1.25 × 产业 1.10 = 1.375
	var sim2 = _make(node)
	_learn(sim2, ["crop_rotation"])
	var farm := _shop_of(sim2, "wheat_farm#t")
	farm["toolBoost"] = 1.25
	if not _approx(sim2._shop_tool_boost(farm) * sim2._sector_output_boost(farm), 1.375):
		_fail("toolBoost 与产业加成应为相乘：1.25 × 1.10 = 1.375，实际 %s" % (
			sim2._shop_tool_boost(farm) * sim2._sector_output_boost(farm)))
		return
	print("EFFICIENCY TEST 与工具相乘：1.25 × 1.10 = 1.375 ✅")

	# ---- 7. 端到端：轮作必须让**一天的实际产量**多 10%
	# 前面几步只验了"倍率函数算得对"；这一步验它真的走到了产出结算里
	# （倍率算对了但没接到 `_run_production_step` 上，是这类改动最典型的漏法）。
	var a: float = _day_wheat(node, [])
	var b2: float = _day_wheat(node, ["crop_rotation"])
	if a <= 0.0:
		_fail("基线一天没产出小麦（%s），测不出倍率" % a)
		return
	var ratio := b2 / a
	if not _approx(ratio, 1.10, 0.02):
		_fail("轮作之后一天的小麦产量应为 1.10 倍：%s → %s（比值 %.3f）" % [a, b2, ratio])
		return
	print("EFFICIENCY TEST 端到端：一天小麦 %.1f → %.1f（×%.2f）✅" % [a, b2, ratio])

	print("EFFICIENCY TEST RESULT: PASS")
	quit(0)

## 跑满一天（24 小时），返回**小麦净产出**。
##
## 先清空库存：v0.3 开局自带木材/粮食，不清的话会把初始物资算成"产出"。
## 这一局只有小麦农场会产小麦（磨坊/面包房不在 `_make()` 里），居民也不吃小麦，
## 所以 `goods[wheat]` 的终值就是当天的净产出。
func _day_wheat(node, done: Array) -> float:
	var sim = _make(node)
	(sim.s["research"] as Dictionary)["done"] = done
	for g in (sim.s["goods"] as Dictionary).keys():
		sim.s["goods"][g] = 0.0
	for h in 24:
		sim.tick_hour([])
	return float(sim.s["goods"].get("wheat", 0.0))
