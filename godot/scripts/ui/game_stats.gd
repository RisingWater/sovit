class_name GameStats
extends RefCounted

# ---------------------------------------------------------------------------
# 取数口径（全部来自仿真层的权威记录）
#   [实际] 库存、国库、人口、满意度、饥饿、就业 —— 直接读状态 / history
#   [实际] 产量、工业消耗、居民购买 —— 读当天 DaySnapshot.ledger
#   [实际] 工资/税收/租金/消费回款 —— 读当天 DaySnapshot.ledger
#   [实际] 逐人工资/税/租/消费/满足率/是否挨饿 —— 读 resident.account
#   [结构] 工坊数 / 工位 / 工人 —— 由 shops 现算（不是流量，无需记账）
#
# 这些字段由仿真层每个游戏日写入（TS 与 GDScript 双边同步），
# 所以面板不再自己重算公式，也就没有口径漂移风险。
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

	# ---- 商品：库存（实际）+ 工坊结构（现算）
	var goods: Dictionary = s["goods"]
	last_shop_count.clear()
	last_slots.clear()
	last_workers.clear()
	last_produced.clear()
	last_consumed_ind.clear()
	last_consumed_pop.clear()
	for gid in goods.keys():
		_push_map(stock, String(gid), float(goods[gid]))

	# 工坊数 / 工位 / 工人：按产出商品归类（结构性数据，不是流量）
	for shop in s["shops"]:
		var def_id := String(shop["defId"])
		if not runner.db.buildings.has(def_id):
			continue
		var rec: Dictionary = runner.db.recipes.get(String(runner.db.buildings[def_id]["recipe"]), {})
		if rec.is_empty():
			continue
		var sid := String(shop["id"])
		var workers := int(shop["targetWorkers"])
		var slots := int(runner.db.buildings[def_id]["maxWorkers"])
		for gid in (rec.get("output", {}) as Dictionary).keys():
			var g := String(gid)
			last_shop_count[g] = int(last_shop_count.get(g, 0)) + (1 if bool(shop["active"]) else 0)
			last_slots[g] = int(last_slots.get(g, 0)) + slots
			last_workers[g] = int(last_workers.get(g, 0)) + workers

	# ---- 商品：产量 / 工业消耗 / 居民购买 —— 直接读当天台账（权威）
	var led: Dictionary = snap.get("ledger", {})
	for gid in (led.get("produced", {}) as Dictionary).keys():
		last_produced[String(gid)] = float(led["produced"][gid])
	for gid in (led.get("consumed", {}) as Dictionary).keys():
		last_consumed_ind[String(gid)] = float(led["consumed"][gid])
	for gid in (led.get("bought", {}) as Dictionary).keys():
		last_consumed_pop[String(gid)] = float(led["bought"][gid])

	for gid in last_produced.keys():
		_push_map(produced, gid, float(last_produced[gid]))
	for gid in last_consumed_ind.keys():
		_push_map(consumed_ind, gid, float(last_consumed_ind[gid]))
	for gid in last_consumed_pop.keys():
		_push_map(consumed_pop, gid, float(last_consumed_pop[gid]))

	# ---- 财务 —— 直接读当天台账（权威），不再重算公式
	_push(wages, float(led.get("wages", 0.0)))
	_push(tax, float(led.get("tax", 0.0)))
	_push(rent, float(led.get("rent", 0.0)))
	_push(sales, float(led.get("sales", 0.0)))
	_push(build_cost, 0.0)

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
