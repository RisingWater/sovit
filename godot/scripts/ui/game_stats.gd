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
## gid -> {defId: 量}：这一样东西**被哪些建筑**吃掉了（台账 `consumedBy`，权威）。
## 用户 2026-10："工业消耗是哪类建筑多少个消耗了多少，比如面粉都是面包房消耗。"
var last_consumed_by: Dictionary = {}
## gid -> {classId: 量}：这一样东西**被哪一等居民**买走了（台账 `boughtBy`，权威）。
var last_bought_by: Dictionary = {}
## defId -> 座数（结构性数据，现算；tooltip 里的"×3"就是它）
var shop_count_by_def: Dictionary = {}
## classId -> 人数（同上；tooltip 里的"×11"）
var class_count: Dictionary = {}
var last_slots: Dictionary = {}
var last_workers: Dictionary = {}

var _last_day := -1
## 上一次采样时用的是哪一个 SimCore。
## ⚠️ 新开一局 / 读档 / 标题页那局"展示村庄"都是**换一个 SimCore 对象**
## （`world_view.start_new_game()` / `load_from()`），所以认对象最准。
var _sim_ref = null

func setup(r: SimRunner) -> void:
	runner = r
	_live_reset()

## 清空所有序列（换了一局就得清）。
func reset() -> void:
	for arr in [days, money, money_flow, population, satisfaction, hungry, employed,
			wages, tax, rent, sales, build_cost]:
		(arr as Array).clear()
	for m in [stock, produced, consumed_ind, consumed_pop, last_produced,
			last_consumed_ind, last_consumed_pop, last_shop_count, last_slots, last_workers,
			last_consumed_by, last_bought_by, shop_count_by_def, class_count]:
		(m as Dictionary).clear()
	_last_day = -1

func _live_reset() -> void:
	_sim_ref = null
	reset()

## 每帧调用；只有跨天才真正采样，返回值表示这一帧是否采到了新数据。
##
## 面板据此决定要不要重建 —— **不能每帧重建**：那会把所有子节点（含按钮）
## 不断销毁重建，按钮就永远点不动。
func poll() -> bool:
	if runner == null or runner.sim == null:
		return false
	# 换了一局就清空历史（见 `_sim_ref` 的注释）。不认这一条的话：
	# 标题页那局展示村庄（国库 50 万）的天数会跟正式这局连成一条"日净额"，
	# 财务页上就会冒出 `D6 / D7 / D51` 和一个 `-497485` —— 用户 2026-10 就是这么发现的。
	if runner.sim != _sim_ref:
		_sim_ref = runner.sim
		reset()
	var s: Dictionary = runner.sim.s
	var d := int(s["day"])
	if d == _last_day:
		return false
	_last_day = d
	_sample(s)
	return true

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
	last_consumed_by.clear()
	last_bought_by.clear()
	shop_count_by_def.clear()
	class_count.clear()
	for gid in goods.keys():
		_push_map(stock, String(gid), float(goods[gid]))

	# 座数（tooltip 里的"×3"）：**所有** shop 都数，不只是有配方、在产的那些
	for shop in s["shops"]:
		var sd := String(shop["defId"])
		shop_count_by_def[sd] = int(shop_count_by_def.get(sd, 0)) + 1
	for r in (s["residents"] as Array):
		var cid := String((r as Dictionary).get("classId", ""))
		if cid != "":
			class_count[cid] = int(class_count.get(cid, 0)) + 1

	# 工坊数 / 工位 / 工人：按产出商品归类（结构性数据，不是流量）
	for shop in s["shops"]:
		var def_id := String(shop["defId"])
		if not runner.db.buildings.has(def_id):
			continue
		var bdef: Dictionary = runner.db.buildings[def_id]
		# 建筑工坊这类产出「建造产能」的建筑没有配方，按产出商品归类时跳过
		if not bdef.has("recipe"):
			continue
		var rec: Dictionary = runner.db.recipes.get(String(bdef["recipe"]), {})
		if rec.is_empty():
			continue
		var sid := String(shop["id"])
		var workers := int(shop["targetWorkers"])
		var slots := int(bdef["maxWorkers"])
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
	# 拆分表（谁吃掉的 / 谁买走的）：面板 tooltip 直接读，不在这里重算
	for gid in (led.get("consumedBy", {}) as Dictionary).keys():
		last_consumed_by[String(gid)] = (led["consumedBy"][gid] as Dictionary).duplicate()
	for gid in (led.get("boughtBy", {}) as Dictionary).keys():
		last_bought_by[String(gid)] = (led["boughtBy"][gid] as Dictionary).duplicate()

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

# ---------------------------------------------------------------------------
# 「工业消耗 / 居民消耗」的悬停提示（用户 2026-10）
#
#   工业消耗……鼠标移过去 → 「面包房 ×3　12.0」
#   居民消耗……鼠标移过去 → 「中产 ×11　8.0」
#
# 数字全部来自 ledger 的**拆分表**（`consumedBy` / `boughtBy`，由仿真在真正扣料 /
# 成交的那一处写），这里只做"排序 + 拼字"——**不重算任何公式**。
# ---------------------------------------------------------------------------

## 数量显示：小的带一位小数，大的取整（与顶栏 chip 同一套口径）。
func _qty(v: float) -> String:
	if absf(v) < 100.0 and absf(v - round(v)) > 0.005:
		return "%.1f" % v
	return "%.0f" % v

## 「工业消耗」的悬停文案：**哪类建筑各吃掉多少**。
func industrial_tip(gid: String) -> String:
	var gname := _good_name(gid)
	var total := float(last_consumed_ind.get(gid, 0.0))
	var head := "%s · 工业消耗 %s / 日" % [gname, _qty(total)]
	var by: Dictionary = last_consumed_by.get(gid, {})
	if by.is_empty():
		if total <= 0.0:
			return head + "\n（昨天没有工坊吃它）"
		return head + "\n（这一天的台账还没有来源明细 —— 再跑一天就有了）"
	var rows := []
	for def_id in by.keys():
		var q := float(by[def_id])
		if q <= 0.001:
			continue
		rows.append([String(def_id), q])
	rows.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var lines: Array[String] = [head]
	for row in rows:
		var def_id := String(row[0])
		var cnt := int(shop_count_by_def.get(def_id, 0))
		var bname := def_id
		if runner != null and runner.db.buildings.has(def_id):
			bname = String(runner.db.buildings[def_id].get("nameZh", def_id))
		lines.append("  %s ×%d　%s" % [bname, cnt, _qty(float(row[1]))])
	return "\n".join(lines)

## 「居民消耗」的悬停文案：**哪一等居民各买走多少**。
func resident_tip(gid: String) -> String:
	var gname := _good_name(gid)
	var total := float(last_consumed_pop.get(gid, 0.0))
	var head := "%s · 居民消耗 %s / 日" % [gname, _qty(total)]
	var by: Dictionary = last_bought_by.get(gid, {})
	if by.is_empty():
		if total <= 0.0:
			return head + "\n（昨天没有居民买它）"
		return head + "\n（这一天的台账还没有阶层明细 —— 再跑一天就有了）"
	var rows := []
	for cid in by.keys():
		var q := float(by[cid])
		if q <= 0.001:
			continue
		rows.append([String(cid), q])
	rows.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var lines: Array[String] = [head]
	for row in rows:
		var cid := String(row[0])
		var cnt := int(class_count.get(cid, 0))
		var cname := cid
		if runner != null and runner.db.classes.has(cid):
			cname = String(runner.db.classes[cid].get("nameZh", cid))
		lines.append("  %s ×%d　%s" % [cname, cnt, _qty(float(row[1]))])
	return "\n".join(lines)

## 商品的中文名（商品表里没有就退回 id）。
func _good_name(gid: String) -> String:
	if runner != null and runner.db.goods.has(gid):
		return String(runner.db.goods[gid].get("nameZh", gid))
	return gid