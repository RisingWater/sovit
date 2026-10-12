class_name GameStats
extends RefCounted

# ---------------------------------------------------------------------------
# 统计记录器（**只读仿真状态，不修改仿真层**）
#
# 为什么不把统计塞进仿真核心：
#   仿真层有 TS ↔ GDScript 移植契约 + golden 轨迹，为 UI 功能动核心不划算，
#   而且 golden 只摘取固定字段，加字段虽不破坏轨迹，两边维护成本很高。
#   所以这里每过一个游戏日采样一次，在表现层自行累计。
#
# 取数口径（面板里会如实标注）：
#   [实际] 国库、库存、人口、满意度、饥饿、就业 —— 直接读状态 / history
#   [计划] 产量、工业消耗 —— 工坊当日 planned × 配方；planned 是黎明按在岗人数
#          排出来的批次数，所以它就是当天要发生的量
#   [公式] 工资 / 税收 / 租金 / 消费收入 —— 用与仿真层相同的公式从可见状态重算
#          （_progressive_tax / _pay_wages / _collect_rent 的逻辑，见 sim_core.gd）
# ---------------------------------------------------------------------------

const MAX_DAYS := 120

var runner: SimRunner

# 每日序列（按天追加，超上限从头丢）
var days: Array[int] = []
var money: Array[float] = []          # [实际] 国库
var money_flow: Array[float] = []     # [实际] 国库日净变化
var population: Array[int] = []
var satisfaction: Array[float] = []
var hungry: Array[int] = []
var employed: Array[int] = []

# 财务（公式）
var wages: Array[float] = []
var tax: Array[float] = []
var rent: Array[float] = []
var sales: Array[float] = []
var build_cost: Array[float] = []

# 商品：goodId -> 每日序列
var stock: Dictionary = {}       # [实际] 库存
var produced: Dictionary = {}    # [计划] 日产量
var consumed_ind: Dictionary = {} # [计划] 工业消耗
var consumed_pop: Dictionary = {} # [公式] 居民需求

## 每个商品的最新汇总（面板主表用，避免反复重算）
var last_produced: Dictionary = {}
var last_consumed_ind: Dictionary = {}
var last_consumed_pop: Dictionary = {}
var last_shop_count: Dictionary = {}
var last_slots: Dictionary = {}
var last_workers: Dictionary = {}

var _last_day := -1

func setup(r: SimRunner) -> void:
	runner = r

## 每帧调用；只有跨天才真正采样。
func poll() -> void:
	if runner == null or runner.sim == null:
		return
	var s: Dictionary = runner.sim.s
	var d := int(s["day"])
	if d == _last_day:
		return
	_last_day = d
	_sample(s)

func has_data() -> bool:
	return days.size() >= 2

# ---------------------------------------------------------------------------
func _push(arr: Array, v) -> void:
	arr.append(v)
	if arr.size() > MAX_DAYS:
		arr.remove_at(0)

func _push_map(m: Dictionary, key: String, v: float) -> void:
	if not m.has(key):
		m[key] = []
	_push(m[key], v)

func _sample(s: Dictionary) -> void:
	_push(days, int(s["day"]))

	# ---- 实际：直接从 history 尾条读，避免自己再算一遍口径不一致
	var hist: Array = s["history"]
	var snap: Dictionary = hist[hist.size() - 1] if not hist.is_empty() else {}
	var m := float(s["government"]["money"])
	_push(money, m)
	_push(money_flow, m - (money[money.size() - 2] if money.size() >= 2 else m))
	_push(population, int(snap.get("population", (s["residents"] as Array).size())))
	_push(satisfaction, float(snap.get("avgSatisfaction", 0.0)))
	_push(hungry, int(snap.get("hungry", 0)))
	_push(employed, int(snap.get("employed", 0)))

	# ---- 商品：库存（实际）
	var goods: Dictionary = s["goods"]
	last_shop_count.clear()
	last_slots.clear()
	last_workers.clear()
	last_produced.clear()
	last_consumed_ind.clear()
	for gid in goods.keys():
		_push_map(stock, String(gid), float(goods[gid]))

	# ---- 商品：产量 / 工业消耗 / 工坊数 / 工位 / 工人（计划，来自工坊排产）
	var slots_by_worker := {}      # shopId -> 在岗人数
	for r in s["residents"]:
		var js = r.get("jobShopId", null)
		if js != null and bool(r["employed"]):
			var k := String(js)
			slots_by_worker[k] = int(slots_by_worker.get(k, 0)) + 1

	for shop in s["shops"]:
		var def_id := String(shop["defId"])
		if not runner.db.buildings.has(def_id):
			continue
		var rec: Dictionary = runner.db.recipes.get(String(runner.db.buildings[def_id]["recipe"]), {})
		if rec.is_empty():
			continue
		var planned := float(shop["planned"])
		var active := bool(shop["active"])
		var sid := String(shop["id"])
		var workers := int(slots_by_worker.get(sid, 0))
		var slots := int(runner.db.buildings[def_id]["maxWorkers"])

		for gid in (rec.get("output", {}) as Dictionary).keys():
			var g := String(gid)
			var amt := planned * float(rec["output"][gid])
			last_produced[g] = float(last_produced.get(g, 0.0)) + amt
			last_shop_count[g] = int(last_shop_count.get(g, 0)) + (1 if active else 0)
			last_slots[g] = int(last_slots.get(g, 0)) + slots
			last_workers[g] = int(last_workers.get(g, 0)) + workers
		for gid in (rec.get("inputs", {}) as Dictionary).keys():
			var g := String(gid)
			var amt := planned * float(rec["inputs"][gid])
			last_consumed_ind[g] = float(last_consumed_ind.get(g, 0.0)) + amt

	# 把「工坊归类到它的产出商品」也写成序列
	for gid in last_produced.keys():
		_push_map(produced, gid, float(last_produced[gid]))
	for gid in last_consumed_ind.keys():
		_push_map(consumed_ind, gid, float(last_consumed_ind[gid]))

	# ---- 商品：居民需求（公式，来自阶层 needs × 人数）
	var class_count := {}
	for r in s["residents"]:
		var cid := String(r["classId"])
		class_count[cid] = int(class_count.get(cid, 0)) + 1
	for cid in class_count.keys():
		if not runner.db.classes.has(cid):
			continue
		for need in (runner.db.classes[cid].get("needs", []) as Array):
			# 字段名是 good（不是 goodId），见 content/classes.json
			var g := String(need.get("good", ""))
			if g == "":
				continue
			var amt := float(need["perCapita"]) * float(class_count[cid])
			last_consumed_pop[g] = float(last_consumed_pop.get(g, 0.0)) + amt
	for gid in last_consumed_pop.keys():
		_push_map(consumed_pop, gid, float(last_consumed_pop[gid]))

	# ---- 财务（公式 + 实际）
	var fin := _finance(s)
	_push(wages, fin["wages"])
	_push(tax, fin["tax"])
	_push(rent, fin["rent"])
	_push(sales, fin["sales"])
	_push(build_cost, fin["build"])

# ---------------------------------------------------------------------------
# 与 sim_core.gd 相同的公式（只读状态，不改状态）
# ---------------------------------------------------------------------------
func progressive_tax(income: float, brackets: Array) -> float:
	var t := 0.0
	var prev := 0.0
	for b in brackets:
		var upper: float = INF if b["upTo"] == null else float(b["upTo"])
		var slice := maxf(0.0, minf(income, upper) - prev)
		if slice > 0.0:
			t += slice * clampf(float(b["rate"]), 0.0, 0.95)
		prev = upper
		if income <= upper:
			break
	return snappedf(t, 0.01)

## 工资 / 税收 / 租金 / 消费收入 / 建造支出
func _finance(s: Dictionary) -> Dictionary:
	var eco: Dictionary = runner.db.economy
	var brackets: Array = s["government"]["taxBrackets"]
	var wage_by_shop := {}
	var cap_by_shop := {}
	for shop in s["shops"]:
		wage_by_shop[String(shop["id"])] = float(shop["wage"])
		cap_by_shop[String(shop["id"])] = float(shop["wageCap"])

	var welfare := snappedf(float(eco["refWage"]) * float(eco["welfareRate"]), 0.01)
	var skill_base := float(eco["skillIncomeBase"])
	var skill_max := float(eco["skillMax"])

	var gross_total := 0.0
	var tax_total := 0.0
	for r in s["residents"]:
		var is_emp := bool(r["employed"]) and r.get("jobShopId", null) != null
		var base: float = float(wage_by_shop.get(r.get("jobShopId", ""), 0.0)) if is_emp else welfare
		var gross := base
		if is_emp:
			gross = base * (skill_base + minf(skill_max, float(r["skill"])) / 100.0)
			var cap := float(cap_by_shop.get(r.get("jobShopId", ""), 0.0))
			if cap > 0.0:
				gross = minf(gross, cap)
		gross_total += gross
		tax_total += progressive_tax(gross, brackets)

	# 租金（照 _collect_rent 的口径：国有租户 + 私有租户抽税）
	var rent_val := float(s["government"]["rent"])
	var rent_income := 0.0
	var owners := 0
	var private_tenants := []
	var state_tenants := []
	for r in s["residents"]:
		if bool(r.get("homeowner", false)):
			owners += 1
		elif bool(r.get("privateTenant", false)):
			private_tenants.append(r)
		else:
			state_tenants.append(r)
	if rent_val > 0.0:
		for r in state_tenants:
			rent_income += minf(rent_val, float(r["savings"]))
		var private_total := 0.0
		for r in private_tenants:
			private_total += minf(rent_val, float(r["savings"]))
		if owners > 0:
			var share := private_total / float(owners)
			rent_income += progressive_tax(share, brackets) * float(owners)

	# 消费收入（居民需求 × 售价，受库存上限约束 —— 是估算，面板标注为「估算」）
	var sales_income := 0.0
	var goods: Dictionary = s["goods"]
	var prices: Dictionary = s["prices"]
	for gid in last_consumed_pop.keys():
		var want := float(last_consumed_pop[gid])
		var have := maxf(0.0, float(goods.get(gid, 0.0)) - float((s.get("reserved", {}) as Dictionary).get(gid, 0.0)))
		sales_income += minf(want, have) * float(prices.get(gid, 0.0))

	# 建造支出（实际：当日施工队列表的建造成本）
	var build := 0.0
	for c in s["construction"]:
		var bid := String(c.get("buildingId", ""))
		if bid != "" and runner.db.buildings.has(bid):
			for k in (runner.db.buildings[bid].get("buildCost", {}) as Dictionary).keys():
				build += float(prices.get(k, 0.0)) * float(runner.db.buildings[bid]["buildCost"][k])

	return {
		"wages": snappedf(gross_total, 0.01),
		"tax": snappedf(tax_total, 0.01),
		"rent": snappedf(rent_income, 0.01),
		"sales": snappedf(sales_income, 0.01),
		"build": snappedf(build, 0.01),
	}

# ---------------------------------------------------------------------------
# 查询辅助
# ---------------------------------------------------------------------------
func series(d: Dictionary, key: String) -> Array:
	var a = d.get(key, null)
	return a if a is Array else []

func last(arr: Array) -> float:
	return float(arr[arr.size() - 1]) if not arr.is_empty() else 0.0

func avg(arr: Array, n: int = 7) -> float:
	if arr.is_empty():
		return 0.0
	var from := maxi(0, arr.size() - n)
	var sum := 0.0
	for i in range(from, arr.size()):
		sum += float(arr[i])
	return sum / float(arr.size() - from)

## 某商品的全部指标（面板一行用）
func good_row(gid: String) -> Dictionary:
	return {
		"id": gid,
		"stock": float(stock.get(gid, [0.0])[-1]) if stock.has(gid) else 0.0,
		"produced": float(last_produced.get(gid, 0.0)),
		"consumed_ind": float(last_consumed_ind.get(gid, 0.0)),
		"consumed_pop": float(last_consumed_pop.get(gid, 0.0)),
		"shops": int(last_shop_count.get(gid, 0)),
		"slots": int(last_slots.get(gid, 0)),
		"workers": int(last_workers.get(gid, 0)),
	}
