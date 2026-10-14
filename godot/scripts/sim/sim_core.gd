class_name SimCore
extends RefCounted

# 纯仿真核心（无任何 Node / 场景依赖）。
# 公式与顺序严格对照仓库根 docs/spec.md 与 src/engine/*。

var db: ContentDB
var s: Dictionary = {}
var rng: Rng

func _init(content: ContentDB) -> void:
	db = content

func enqueue(actions: Array) -> void:
	# 合并同类命令：同一目标的设置只保留最新一条；建造类可叠加。
	for a in actions:
		if String(a.get("type", "")) == "end_turn":
			continue
		var key = _action_key(a)
		if key == "":
			s["pending"].append(a)
			continue
		var replaced = false
		var pending: Array = s["pending"]
		for i in pending.size():
			if _action_key(pending[i]) == key:
				pending[i] = a
				replaced = true
				break
		if not replaced:
			pending.append(a)

# 可合并命令的键；建造/建房等可叠加，返回 "" 表示追加。
static func _action_key(a: Dictionary) -> String:
	var t = String(a.get("type", ""))
	match t:
		"set_wage", "set_wage_cap", "set_workers", "toggle", "expand", "demolish":
			return t + ":" + String(a.get("shopId", ""))
		"set_price":
			return t + ":" + String(a.get("goodId", ""))
		"set_tax_bracket":
			return t + ":" + str(int(a.get("index", 0)))
		"set_tax", "set_rent", "set_population_cap", "set_storage_caps":
			return t
		"research", "cancel_research":
			return t + ":" + String(a.get("techId", ""))
		_:
			return ""

# 可用花料量 = 库存 − 当日已锁定（计划）消耗。
func available(gid: String) -> float:
	return float(s["goods"].get(gid, 0.0)) - float(s["reserved"].get(gid, 0.0))

# 实时花料（铺地板用）：只能花未计划的部分；不足则拒绝。
func spend(gid: String, qty: float) -> bool:
	if available(gid) < qty:
		return false
	s["goods"][gid] = float(s["goods"].get(gid, 0.0)) - qty
	return true

# ===========================================================================
# 初始状态
# ===========================================================================
func new_game(pack_id: String, seed_value: int, resource_mult: float = 1.0) -> void:
	var pack: Dictionary = db.packs[pack_id]
	var start: Dictionary = pack["start"]
	rng = Rng.new(seed_value)

	var goods := {}
	var prices := {}
	var start_goods: Dictionary = start["goods"]
	for gid in pack["goods"]:
		goods[gid] = float(start_goods.get(gid, 0.0))
		var gd: Dictionary = db.goods[gid]
		if String(gd["category"]) == "housing":
			continue
		prices[gid] = float(gd["baseValue"])

	var housing := {}
	var private_housing := {}
	var start_housing: Dictionary = start["housing"]
	for gid in pack["housing"]:
		housing[gid] = float(start_housing.get(gid, 0.0))
		private_housing[gid] = 0.0
		var hd: Dictionary = db.housing[gid]
		prices[gid] = float(hd.get("salePrice", db.goods[gid]["baseValue"]))

	var shops := []
	var start_shops: Dictionary = start["shops"]
	for def_id in start_shops.keys():
		var cnt = int(start_shops[def_id])
		var d: Dictionary = db.buildings[def_id]
		for i in cnt:
			shops.append({
				"id": "%s#%d" % [def_id, i + 1],
				"defId": def_id,
				"owner": "state",
				"targetWorkers": int(d["workers"]),
				"wage": float(db.economy["refWage"]),
				"wageCap": float(db.economy["defaultWageCap"]),
				"level": int(db.defaults["newShop"]["level"]),
				"active": true,
				"profit": 0.0,
				"skill": float(db.defaults["newShop"]["skill"]),
				"planned": 0.0,
			})

	var dist: Array = db.defaults["startDistribution"].duplicate()
	if dist.is_empty():
		dist = ["poor"]
	var sd: Dictionary = db.defaults["startResident"]
	var residents := []
	var pop = int(start["population"])
	for i in pop:
		residents.append({
			"id": "res#%d" % (i + 1),
			"classId": String(dist[i % dist.size()]),
			"savings": float(sd["savings"]),
			"satisfaction": float(sd["satisfaction"]),
			"skill": float(sd["skillBase"]) + floor(rng.next() * float(sd["skillRandom"])),
			"employed": false,
		})

	var money = float(start["money"])
	# 开局资源倍率（难度）：只缩放初始库存与国库，不参与任何后续公式，
	# 所以默认 1.0 时结果与从前逐位相同（golden 不受影响）。
	if resource_mult != 1.0:
		for gid in goods.keys():
			goods[gid] = goods[gid] * resource_mult
		money = money * resource_mult
	s = {
		"pack": pack_id, "seed": seed_value, "rngState": rng.state,
		"day": 0, "hour": 0, "pending": [], "reserved": {},
		"government": {
			"money": money,
			"taxBrackets": _dup_brackets(db.economy["defaultTaxBrackets"]),
			"rent": float(db.economy["defaultRent"]),
			"subsidyBudget": 0.0,
			# 人口上限（玩家可调）：迁入只看住房 + 粮食 + 满意度，规模由它兜住。
			# 见 docs/spec.md §8。
			"populationCap": 1000000000.0,
			# 每种物资的软上限（玩家在「设置资源」里逐项设置）；缺项 = 该项不限。
			# 见 docs/town.md §3.6。
			"storageCaps": {},
		},
		"goods": goods, "housing": housing, "privateHousing": private_housing, "prices": prices,
		"shops": shops, "residents": residents, "construction": [],
		# 科技：开局已研究的来自 pack.start.techs（见 docs/technology.md）
		"research": {"done": _start_techs(pack_id), "queue": []},
		"ledgerToday": _empty_ledger(0),
		"history": [{"day": 0, "population": pop, "avgSatisfaction": float(sd["satisfaction"]), "money": money, "hungry": 0, "employed": 0, "ledger": _empty_ledger(0)}],
		"log": [], "alerts": [], "arrivals": 0,
		# 村庄名（可改，随存档保存）。UI 层显示用，不参与任何仿真计算。
		"villageName": "sovit",
	}

## 空白台账 / 空白个人账目。
## 逐人账目与每日台账分开放，是为了将来做差异化分配（按收入/偏好/距离）
## 时不必再动数据结构 —— 现在所有人平均分配，逐人数值 == 阶层数值。
func _start_techs(pack_id: String) -> Array:
	## 开局已研究完的科技（pack.start.techs；缺省为空 = 只有无科技锁的建筑可建）。
	## ⚠️ 必须显式收 pack_id：这个函数在 s 组装到一半时被调用，village 里 _pack() 还取不到 s["pack"]。
	var out: Array = []
	var p = db.packs.get(pack_id, null)
	if p == null:
		return out
	for t in (p.get("start", {}) as Dictionary).get("techs", []):
		out.append(String(t))
	return out
func _empty_ledger(day: int) -> Dictionary:
	return {"day": day, "wages": 0.0, "tax": 0.0, "rent": 0.0, "sales": 0.0,
		"produced": {}, "consumed": {}, "bought": {}}

func _empty_account() -> Dictionary:
	return {"wage": 0.0, "tax": 0.0, "rent": 0.0, "spent": 0.0,
		"foodScore": 1.0, "comfortScore": 1.0, "priceScore": 1.0,
		"hungry": false, "bought": {}}

# ===========================================================================
# 时间推进
# ===========================================================================
func tick_hour(pending_actions: Array = []) -> Array:
	for a in pending_actions:
		s["pending"].append(a)
	var logs := []
	var h = int(s["hour"])
	if h == int(db.time["dawnHour"]):
		logs.append_array(_run_dawn())
	if h >= int(db.time["workStart"]) and h < int(db.time["workEnd"]):
		var work_hours = int(db.time["workEnd"]) - int(db.time["workStart"])
		_run_production_step(1.0 / float(work_hours))
	if h == int(db.time["settleHour"]):
		logs.append_array(_run_night())
	s["hour"] = (h + 1) % int(db.time["hoursPerDay"])
	return logs

func _run_dawn() -> Array:
	var logs := []
	s["day"] = int(s["day"]) + 1
	# 新的一天：台账清零（晚上结算时挂到当天快照）
	s["ledgerToday"] = _empty_ledger(int(s["day"]))
	_apply_actions(s["pending"])
	s["pending"] = []
	logs.append_array(_activate_completed())
	logs.append_array(_activate_research())
	_assign_labor()
	# 工具必须在排产之前分配：它决定今天各工坊的产出倍率（shop.toolBoost）
	logs.append_array(_allocate_tools())
	_plan_production()
	return logs

func _run_night() -> Array:
	var day = int(s["day"])
	var logs := []
	# 施工结算必须在工资之前：它决定当天有多少失业人口「在工地上出工」（建造工资）。
	logs.append_array(_settle_construction(day))
	# 研究独立成队、不占人口：只消耗科研力（研究所）与材料
	logs.append_array(_settle_research(day))
	logs.append_array(_pay_wages(day))
	_assign_tenure()
	logs.append_array(_collect_rent(day))
	var cons = _run_consumption(day)
	logs.append_array(cons["logs"])
	logs.append_array(_run_private_housing_market(day))
	_assign_tenure()
	_update_satisfaction(cons["foodScore"], cons["comfortScore"], cons["priceScore"])
	logs.append_array(_update_population(cons["hungry"], day))
	logs.append_array(_apply_admission(day))
	_apply_spoilage()
	# 仓储超限丢弃：紧接损耗之后（见 docs/town.md §3.3）——
	# 先损耗、后判上限，损耗腾出来的空间能救下本来会被丢掉的货
	logs.append_array(apply_storage_cap(day))
	_grow_skills()
	_compute_arrivals()
	s["reserved"] = {}

	s["history"].append(_make_snapshot(cons["hungry"]))
	if s["history"].size() > 400:
		s["history"] = s["history"].slice(s["history"].size() - 400)
	s["alerts"] = _build_alerts(cons["hungry"])
	# 日志也要落进 state（TS 侧 `state.log = [...state.log, ...logs]` 并截断 500）。
	# ⚠️ 这是历史遗留的 parity 缺口：GDScript 以前只把日志**返回**给调用方，
	# 从不写进存档 —— 于是"仓储超限丢弃 X 单位 Y"这类日志在 Godot 侧的
	# `sim.s["log"]` 里看不到（UI 读的是 runner.recent_logs，所以之前没暴露）。
	var all_logs: Array = (s["log"] as Array)
	all_logs.append_array(logs)
	if all_logs.size() > 500:
		s["log"] = all_logs.slice(all_logs.size() - 500)
	return logs

# ===========================================================================
# 内容包 / 快查
# ===========================================================================
func _pack() -> Dictionary:
	return db.packs[s["pack"]]

func _good_set() -> Dictionary:
	var d := {}
	for g in _pack()["goods"]:
		d[g] = true
	return d

func _class_order() -> Array:
	var ids: Array = _pack()["classes"].duplicate()
	ids.sort_custom(func(a, b): return int(db.classes[a]["wealthThreshold"]) < int(db.classes[b]["wealthThreshold"]))
	return ids

func _class_level(cid: String) -> int:
	var c = db.classes.get(cid, null)
	return int(c["housingLevel"]) if c != null else 1

# ===========================================================================
# 动作
# ===========================================================================
func _apply_actions(actions: Array) -> void:
	for action in actions:
		var t = String(action["type"])
		match t:
			"end_turn":
				pass
			"set_wage":
				var shop = _find_shop(String(action["shopId"]))
				if shop != null:
					shop["wage"] = SimUtil.r2(clampf(float(action["value"]), 0.0, 999.0))
			"set_wage_cap":
				var shop = _find_shop(String(action["shopId"]))
				if shop != null:
					shop["wageCap"] = SimUtil.r2(clampf(float(action["value"]), 0.0, 999.0))
			"set_workers":
				var shop = _find_shop(String(action["shopId"]))
				if shop != null:
					var d: Dictionary = db.buildings[shop["defId"]]
					# 上限用**有效工位数**，不是 maxWorkers（研究所升级会 +slotsPerLevel）
					shop["targetWorkers"] = int(round(clampf(float(action["value"]), 0.0,
						float(effective_slots(d, int(shop["level"]))))))
			"demolish":
				# 拆除：退**建造资源**（按 buildCost 原样退回），不退建造力
				# （那是每日产能/已投入的人工）。工人变回失业是 _assign_labor 现算的
				# 自然结果。只作用于**已建成**的（在建的走取消施工那条路）。
				for i in range((s["shops"] as Array).size() - 1, -1, -1):
					if String(s["shops"][i]["id"]) != String(action["shopId"]):
						continue
					var dd = db.buildings.get(String(s["shops"][i]["defId"]), null)
					if dd != null:
						for gid in (dd.get("buildCost", {}) as Dictionary).keys():
							var q = float(dd["buildCost"][gid])
							if q <= 0.0 or not db.goods.has(String(gid)):
								continue
							s["goods"][gid] = SimUtil.r2(float(s["goods"].get(gid, 0.0)) + q)
					s["shops"].remove_at(i)
					break
			"set_price":
				s["prices"][String(action["goodId"])] = SimUtil.r2(maxf(0.01, float(action["value"])))
			"toggle":
				var shop = _find_shop(String(action["shopId"]))
				if shop != null:
					shop["active"] = bool(action["active"])
			"expand":
				_try_expand(String(action["shopId"]))
			"build":
				_try_build(String(action["buildingId"]))
			"build_housing":
				_try_build_housing(String(action["goodId"]))
			"set_tax":
				s["government"]["taxBrackets"] = [{"upTo": null, "rate": clampf(float(action["value"]), 0.0, 0.95)}]
			"set_tax_bracket":
				_set_tax_bracket(action)
			"set_rent":
				s["government"]["rent"] = SimUtil.r2(clampf(float(action["value"]), 0.0, 99.0))
			"set_population_cap":
				s["government"]["populationCap"] = maxf(0.0, floor(float(action["value"])))
			"set_storage_caps":
				_set_storage_caps(action)
			"research":
				_start_research(String(action["techId"]))
			"cancel_research":
				_cancel_research(String(action["techId"]))
			_:
				pass

func _set_tax_bracket(action: Dictionary) -> void:
	var bs: Array = s["government"]["taxBrackets"]
	var i = int(round(float(action["index"])))
	if i < 0 or i >= bs.size():
		return
	if action.has("upTo"):
		var u = action["upTo"]
		bs[i]["upTo"] = null if u == null else SimUtil.r2(maxf(0.0, float(u)))
	if action.has("rate"):
		bs[i]["rate"] = clampf(float(action["rate"]), 0.0, 0.95)
	_sanitize_brackets(bs)

## 每种物资的软上限（玩家逐项设置，见 docs/town.md §3.6）。
##
## **整体替换**：传什么就是什么，缺项 = 该项不限。只收本 pack 里真实存在的商品，
## 数值取非负整数；0 视为「不限」（与 TS 侧 src/engine/actions.ts 同口径）。
func _set_storage_caps(action: Dictionary) -> void:
	var next := {}
	var gset = _good_set()
	var caps: Dictionary = action.get("caps", {})
	for gid in caps.keys():
		var key := String(gid)
		if not gset.has(key):
			continue
		var n = int(maxf(0.0, floor(_to_number(caps[gid]))))
		if n > 0:
			next[key] = n
	s["government"]["storageCaps"] = next

## 宽松的数字转换（对齐 JS 的 Number()）：非数字 / null 一律当 0。
func _to_number(v: Variant) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING:
			return float(v) if String(v).is_valid_float() else 0.0
		_:
			return 0.0

func _sanitize_brackets(bs: Array) -> void:
	for i in bs.size():
		bs[i]["rate"] = clampf(float(bs[i]["rate"]), 0.0, 0.95)
		if i == bs.size() - 1:
			bs[i]["upTo"] = null
		else:
			var prev = float(bs[i - 1]["upTo"]) if i > 0 and bs[i - 1]["upTo"] != null else 0.0
			var up = float(bs[i]["upTo"]) if bs[i]["upTo"] != null else prev + 1.0
			if up <= prev:
				up = SimUtil.r2(prev + 1.0)
			bs[i]["upTo"] = up

func _dup_brackets(bs: Array) -> Array:
	var out := []
	for b in bs:
		out.append({"upTo": b["upTo"], "rate": float(b["rate"])})
	return out

func _find_shop(shop_id: String) -> Variant:
	for shop in s["shops"]:
		if shop["id"] == shop_id:
			return shop
	return null

# ===========================================================================
# 生产
# ===========================================================================
func _plan_production() -> void:
	for shop in s["shops"]:
		shop["planned"] = 0.0

	var items := []
	var demand := {}
	var reserved := {}
	for shop in s["shops"]:
		if not bool(shop["active"]):
			continue
		var def: Dictionary = db.buildings[shop["defId"]]
		if not def.has("recipe"):
			continue
		var recipe: Dictionary = db.recipes[def["recipe"]]
		var workers = _assigned_workers(shop["id"])
		if workers <= 0:
			continue
		var staffing = float(workers) / float(def["workers"])
		var skill_eff = float(db.tuning["skillEffectBase"]) + float(db.tuning["skillEffectSlope"]) * (float(shop["skill"]) / 100.0)
		var desired = float(recipe["baseRate"]) * staffing * skill_eff * float(shop["level"])
		if desired <= 0.0:
			continue
		var input_per := {}
		for g in (recipe["inputs"] as Dictionary).keys():
			var q = float(recipe["inputs"][g])
			if q > 0.0:
				input_per[g] = float(input_per.get(g, 0.0)) + q
		var fuel = float(recipe.get("fuel", 0.0))
		if fuel > 0.0:
			input_per["firewood"] = float(input_per.get("firewood", 0.0)) + fuel
		items.append({"shop": shop, "desired": desired, "inputPer": input_per, "output": recipe["output"]})
		for g in input_per.keys():
			demand[g] = float(demand.get(g, 0.0)) + float(input_per[g]) * desired

	var factor := {}
	for g in demand.keys():
		var avail = float(s["goods"].get(g, 0.0))
		factor[g] = minf(1.0, avail / float(demand[g])) if float(demand[g]) > 0.0 else 1.0

	for it in items:
		var f = 1.0
		for g in (it["inputPer"] as Dictionary).keys():
			f = minf(f, float(factor[g]))
		var planned = float(it["desired"]) * f
		it["shop"]["planned"] = planned
		for g in (it["inputPer"] as Dictionary).keys():
			reserved[g] = float(reserved.get(g, 0.0)) + float(it["inputPer"][g]) * planned
		var out_val = 0.0
		for g in (it["output"] as Dictionary).keys():
			out_val += _good_value(g, float(it["output"][g]) * planned)
		var in_val = 0.0
		for g in (it["inputPer"] as Dictionary).keys():
			in_val += _good_value(g, float(it["inputPer"][g]) * planned)
		var wages = float(_assigned_workers(it["shop"]["id"])) * float(it["shop"]["wage"])
		it["shop"]["profit"] = SimUtil.r2(out_val - in_val - wages)

	s["reserved"] = reserved

func _run_production_step(fraction: float) -> void:
	for shop in s["shops"]:
		if not bool(shop["active"]) or float(shop["planned"]) <= 0.0:
			continue
		var def: Dictionary = db.buildings[shop["defId"]]
		if not def.has("recipe"):
			continue
		var recipe: Dictionary = db.recipes[def["recipe"]]
		var batches = float(shop["planned"]) * fraction
		var lt: Dictionary = s["ledgerToday"]
		for g in (recipe["inputs"] as Dictionary).keys():
			var q = float(recipe["inputs"][g])
			if q > 0.0:
				s["goods"][g] = float(s["goods"].get(g, 0.0)) - q * batches
				s["reserved"][g] = maxf(0.0, float(s["reserved"].get(g, 0.0)) - q * batches)
				lt["consumed"][g] = _r4(float(lt["consumed"].get(g, 0.0)) + q * batches)
		var fuel = float(recipe.get("fuel", 0.0))
		if fuel > 0.0:
			s["goods"]["firewood"] = float(s["goods"].get("firewood", 0.0)) - fuel * batches
			s["reserved"]["firewood"] = maxf(0.0, float(s["reserved"].get("firewood", 0.0)) - fuel * batches)
			lt["consumed"]["firewood"] = _r4(float(lt["consumed"].get("firewood", 0.0)) + fuel * batches)
		# 只放大**产出**，投入（上面几段）完全不动 —— 这就是"虚空产量"。
		var boost = _shop_tool_boost(shop)
		for g in (recipe["output"] as Dictionary).keys():
			var q = float(recipe["output"][g])
			if q > 0.0:
				s["goods"][g] = float(s["goods"].get(g, 0.0)) + q * batches * boost
				lt["produced"][g] = _r4(float(lt["produced"].get(g, 0.0)) + q * batches * boost)

## 四位小数：小时累计的物料流量用它，避免逐小时四舍五入累积漂移
func _r4(v: float) -> float:
	return floor(v * 10000.0 + 0.5) / 10000.0

func _apply_spoilage() -> void:
	for gid in _pack()["goods"]:
		var g = db.goods.get(gid, null)
		if g == null:
			continue
		var pr = float(g.get("perishRate", 0.0))
		if pr <= 0.0:
			continue
		var cur = float(s["goods"].get(gid, 0.0))
		if cur <= 0.0:
			continue
		s["goods"][gid] = SimUtil.r2(cur * (1.0 - minf(1.0, pr)))

# ===========================================================================
# 仓储（设计见 docs/town.md §三）
#
# 两层口径：
#   1. **全局总量上限** = 所有仓储建筑的容量之和（城镇中心 + 每座仓库）。
#      超了就在日终结算时把货丢掉 —— 先丢便宜的（baseValue 升序）。
#   2. **每种物资的软上限**（玩家逐项设置，缺项 = 不限）。先按它修剪，再按全局
#      上限修剪：某一种货囤满自己的额度后就不再挤占全局空间。
#
# 两步都在 `_apply_spoilage` **之后**：先损耗、后判上限 —— 损耗腾出来的空间
# 可以救下本来会被丢掉的货。
# ===========================================================================

## 一座建筑在某个等级下的仓储容量。
func _shop_storage(def: Dictionary, level: int) -> float:
	if not def.has("storage"):
		return 0.0
	var st: Dictionary = def["storage"]
	return float(st.get("storage", 0.0)) + float(st.get("storagePerLevel", 0.0)) * maxf(0.0, float(level - 1))

## 全局仓储容量。
##
## **需要工人的仓储建筑，没人在岗就不算容量** —— 用户要求「每个仓库目前需要有
## 一个工人」；城镇中心 `workers = 0`，直接计入。
func storage_capacity() -> float:
	var cap := 0.0
	for shop in s["shops"]:
		var def = db.buildings.get(String(shop["defId"]), null)
		if def == null or not def.has("storage"):
			continue
		if int(def.get("workers", 0)) > 0 and _assigned_workers(String(shop["id"])) < 1:
			continue
		cap += _shop_storage(def, int(shop["level"]))
	return SimUtil.r2(cap)

## 当前库存总量（该 pack 的全部商品之和，含易腐品）。
func stored_total() -> float:
	var n := 0.0
	for gid in _pack()["goods"]:
		n += float(s["goods"].get(gid, 0.0))
	return SimUtil.r2(n)

## 丢弃顺序：`baseValue` 升序（先丢便宜的），并列按 goodId 字典序。
func _discard_order() -> Array:
	var rows := []
	for gid in _pack()["goods"]:
		var g = db.goods.get(gid, null)
		rows.append([(float(g["baseValue"]) if g != null else 0.0), String(gid)])
	rows.sort_custom(func(a, b): return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	var out := []
	for r in rows:
		out.append(r[1])
	return out

func _good_name(gid: String) -> String:
	var g = db.goods.get(gid, null)
	return String(g["nameZh"]) if g != null else gid

## 日终丢弃。返回日志（调用方并进当日 logs）。见 docs/town.md §3.3。
##
## ⚠️ 在建工程的材料在 `_settle_construction` 阶段就已经从 `goods` 扣走了，
## 而它在夜晚顺序里排在前面 —— 所以不会出现「把工地材料丢了导致工地卡死」。
func apply_storage_cap(day: int) -> Array:
	var logs := []

	# ① 逐项软上限
	var caps: Dictionary = s["government"].get("storageCaps", {})
	for gid in _pack()["goods"]:
		var key := String(gid)
		if not caps.has(key):
			continue
		var lim = float(caps[key])
		var cur = float(s["goods"].get(key, 0.0))
		if cur <= lim:
			continue
		var lost = SimUtil.r2(cur - lim)
		s["goods"][key] = SimUtil.r2(lim)
		logs.append({"day": day, "kind": "storage",
			"text": "%s 超过单项上限 %s，丢弃 %s 单位" % [_good_name(key), _num_str(lim), _num_str(lost)]})

	# ② 全局总量上限
	var cap = storage_capacity()
	var over = SimUtil.r2(stored_total() - cap)
	if cap > 0.0 and over > 0.0:
		for gid in _discard_order():
			if over <= 0.0:
				break
			var cur = float(s["goods"].get(gid, 0.0))
			if cur <= 0.0:
				continue
			var take = SimUtil.r2(minf(cur, over))
			s["goods"][gid] = SimUtil.r2(cur - take)
			over = SimUtil.r2(over - take)
			logs.append({"day": day, "kind": "storage",
				"text": "仓储超限，丢弃 %s 单位 %s" % [_num_str(take), _good_name(gid)]})
	return logs

## 数字转文本：对齐 JS 模板字符串里数字的呈现（整数不带 ".0"）。
func _num_str(v: float) -> String:
	if is_finite(v) and v == floor(v) and absf(v) < 1000000000000000.0:
		return str(int(v))
	return str(v)

func _good_value(gid: String, qty: float) -> float:
	var g = db.goods.get(gid, null)
	return (float(g["baseValue"]) if g != null else 0.0) * qty

# ===========================================================================
# 用工
# ===========================================================================
func _assigned_workers(shop_id: String) -> int:
	var n = 0
	for r in s["residents"]:
		if r.get("jobShopId", null) == shop_id:
			n += 1
	return n

func _food_chain_goods() -> Dictionary:
	var setd := {}
	var seed_class = db.classes.get(String(db.tuning["foodChainSeedClass"]), null)
	if seed_class != null:
		for n in seed_class["needs"]:
			var g = db.goods.get(String(n["good"]), null)
			if g != null and String(g["category"]) == "food":
				setd[String(n["good"])] = true
	if setd.is_empty():
		for gid in _pack()["goods"]:
			var g = db.goods.get(gid, null)
			if g != null and String(g["category"]) == "food":
				setd[gid] = true
	var changed = true
	while changed:
		changed = false
		for rid in db.recipes.keys():
			var recipe: Dictionary = db.recipes[rid]
			var hit = false
			for og in (recipe["output"] as Dictionary).keys():
				if setd.has(og):
					hit = true
			if not hit:
				continue
			for ig in (recipe["inputs"] as Dictionary).keys():
				if not setd.has(ig) and _good_set().has(ig):
					setd[ig] = true
					changed = true
	return setd

func _food_chain_shop_ids() -> Dictionary:
	## 食品产业链上的店铺 id 集合。
	var chain = _food_chain_goods()
	var out := {}
	for shop in s["shops"]:
		var def = db.buildings.get(shop["defId"], null)
		if def == null or not def.has("recipe"):
			continue
		var recipe = db.recipes.get(String(def["recipe"]), null)
		if recipe == null:
			continue
		for gid in (recipe["output"] as Dictionary).keys():
			if chain.has(gid):
				out[shop["id"]] = true
				break
	return out

## 有效工位数 = 基础工位 + 升级带来的工位（见 TS 侧 effectiveSlots）。
##
## 「研究所」这类**产能建筑**升级会加 `capacity.slotsPerLevel` 个工位，
## 所以工位上限**不是** `maxWorkers` 那个常数。
##
## 这是**唯一口径**：_assign_labor（实际派人）与 UI 的用工拖动条上限都调它。
## 两处各写一遍迟早分叉 —— 抽出来之前 set_workers 就是按 maxWorkers 截断的，
## 于是"把研究所升到 L3、拖满 12 人"会被静默夹回 6 人。
func effective_slots(def: Dictionary, level: int) -> int:
	var n = float(def.get("maxWorkers", def.get("workers", 0)))
	if def.has("capacity"):
		n += float(def["capacity"]["slotsPerLevel"]) * (float(level) - 1.0)
	return int(maxf(0.0, n))

func _assign_labor() -> void:
	for r in s["residents"]:
		r["employed"] = false
		r.erase("jobShopId")
		r.erase("constructionPay")

	var pop = s["residents"].size()
	var food_chain_shops = _food_chain_shop_ids()

	var info := []
	for shop in s["shops"]:
		var def = db.buildings.get(shop["defId"], null)
		var want = 0
		if bool(shop["active"]) and def != null:
			want = int(maxf(0.0, minf(float(shop["targetWorkers"]), float(effective_slots(def, int(shop["level"]))))))
		info.append({"want": want, "priority": food_chain_shops.has(shop["id"])})

	var assign := []
	assign.resize(s["shops"].size())
	assign.fill(0)
	var budget = pop

	for i in info.size():
		if not info[i]["priority"]:
			continue
		var a = int(minf(float(info[i]["want"]), float(budget)))
		assign[i] = a
		budget -= a

	var others := []
	for i in info.size():
		if not info[i]["priority"]:
			others.append(i)
	var total_want = 0
	for i in others:
		total_want += int(info[i]["want"])
	if budget > 0 and total_want > 0:
		if total_want <= budget:
			for i in others:
				assign[i] = int(info[i]["want"])
		else:
			var remainders := []
			var used = 0
			for i in others:
				var exact = float(int(info[i]["want"]) * budget) / float(total_want)
				var base = int(floor(exact))
				assign[i] = base
				used += base
				remainders.append({"i": i, "rem": exact - float(base)})
			remainders.sort_custom(func(a, b):
				if a["rem"] != b["rem"]:
					return a["rem"] > b["rem"]
				return a["i"] < b["i"])
			for item in remainders:
				if used >= budget:
					break
				var i = item["i"]
				if assign[i] < int(info[i]["want"]):
					assign[i] = assign[i] + 1
					used += 1

	var cursor = 0
	for idx in range(s["shops"].size()):
		var shop: Dictionary = s["shops"][idx]
		var want = assign[idx]
		var skills := []
		var k = 0
		while k < want and cursor < s["residents"].size():
			var r: Dictionary = s["residents"][cursor]
			cursor += 1
			r["employed"] = true
			r["jobShopId"] = shop["id"]
			skills.append(float(r["skill"]))
			k += 1
		shop["skill"] = _avg(skills) if not skills.is_empty() else 0.0

func _grow_skills() -> void:
	var smax = float(db.economy["skillMax"])
	var gain = float(db.economy["skillGainPerDay"])
	for r in s["residents"]:
		if bool(r["employed"]):
			r["skill"] = minf(smax, float(r["skill"]) + gain)

# ===========================================================================
# 财政
# ===========================================================================
func _progressive_tax(income: float, brackets: Array) -> float:
	var tax = 0.0
	var prev = 0.0
	for b in brackets:
		var upper = INF if b["upTo"] == null else float(b["upTo"])
		var slice = maxf(0.0, minf(income, upper) - prev)
		if slice > 0.0:
			tax += slice * clampf(float(b["rate"]), 0.0, 0.95)
		prev = upper
		if income <= upper:
			break
	return SimUtil.r2(tax)

func _pay_wages(day: int) -> Array:
	var wage_by_shop := {}
	var cap_by_shop := {}
	for shop in s["shops"]:
		wage_by_shop[shop["id"]] = float(shop["wage"])
		cap_by_shop[shop["id"]] = float(shop["wageCap"])
	var brackets: Array = s["government"]["taxBrackets"]
	var skill_base = float(db.economy["skillIncomeBase"])
	var skill_max = float(db.economy["skillMax"])

	var gross_total = 0.0
	var tax_total = 0.0
	for r in s["residents"]:
		var gross = 0.0
		var build_pay = float(r.get("constructionPay", 0.0))
		if build_pay > 0.0:
			# 工地临时工：日薪已由施工结算按「当日实际投入的建造力」算出。
			# 非熟练临时工，不吃熟练度加成、也不受工坊工资上限约束。
			gross = build_pay
		elif bool(r["employed"]) and r.get("jobShopId", null) != null:
			var wage_base = float(wage_by_shop.get(r.get("jobShopId", ""), 0.0))
			gross = wage_base * (skill_base + minf(skill_max, float(r["skill"])) / 100.0)
			var cap = float(cap_by_shop.get(r.get("jobShopId", ""), 0.0))
			if cap > 0.0:
				gross = minf(gross, cap)
		# else: 失业且没有工程可做 → 无收入（失业保障金已取消，见 docs/construction.md 五）
		var tax = _progressive_tax(gross, brackets)
		r["savings"] = SimUtil.r2(float(r["savings"]) + gross - tax)
		gross_total += gross
		tax_total += tax
		# 逐人记账：工资（含工地出工报酬）与代扣税。租与消费在后面两步追加到同一份账目。
		var acc := _empty_account()
		acc["wage"] = SimUtil.r2(gross)
		acc["tax"] = SimUtil.r2(tax)
		r["account"] = acc
		s["ledgerToday"]["wages"] = SimUtil.r2(float(s["ledgerToday"]["wages"]) + gross)
		s["ledgerToday"]["tax"] = SimUtil.r2(float(s["ledgerToday"]["tax"]) + tax)
	s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) - gross_total + tax_total)
	return [{"day": day, "kind": "finance", "text": "发放工资 ¥%.2f" % SimUtil.r2(gross_total)}]

# ===========================================================================
# 住房
# ===========================================================================
func _housing_capacity() -> int:
	var cap = 0
	for gid in s["housing"].keys():
		var def = db.housing.get(gid, null)
		if def != null:
			cap += int(def["capacity"]) * int(floor(float(s["housing"][gid])))
	return cap

func _private_capacity() -> int:
	var cap = 0
	for gid in s["privateHousing"].keys():
		var def = db.housing.get(gid, null)
		if def != null:
			cap += int(def["capacity"]) * int(floor(float(s["privateHousing"][gid])))
	return cap

func _assign_tenure() -> void:
	for r in s["residents"]:
		r["privateTenant"] = false
		r["housingQuality"] = int(r.get("ownedQuality", 1)) if bool(r.get("homeowner", false)) else 0

	var owner_by_quality = {1: 0, 2: 0, 3: 0}
	for r in s["residents"]:
		if bool(r.get("homeowner", false)):
			var q = int(r.get("ownedQuality", 1))
			owner_by_quality[q] = int(owner_by_quality.get(q, 0)) + 1

	var private_slots = {1: 0, 2: 0, 3: 0}
	var state_slots = {1: 0, 2: 0, 3: 0}
	for gid in s["housing"].keys():
		var def = db.housing.get(gid, null)
		if def == null:
			continue
		var n = int(floor(float(s["housing"][gid])))
		var priv = int(minf(float(n), floor(float(s["privateHousing"].get(gid, 0.0)))))
		var q = int(def["quality"])
		var cap = int(def["capacity"])
		private_slots[q] = int(private_slots.get(q, 0)) + priv * cap
		state_slots[q] = int(state_slots.get(q, 0)) + (n - priv) * cap
	for q in [1, 2, 3]:
		private_slots[q] = int(maxf(0.0, float(int(private_slots.get(q, 0)) - int(owner_by_quality.get(q, 0)))))

	var order = _class_order()
	var tenants := []
	for r in s["residents"]:
		if not bool(r.get("homeowner", false)):
			tenants.append(r)
	tenants.sort_custom(func(a, b): return order.find(a["classId"]) > order.find(b["classId"]))

	for r in tenants:
		var assigned = false
		for q in [3, 2, 1]:
			if not assigned and int(private_slots[q]) > 0:
				private_slots[q] = int(private_slots[q]) - 1
				r["privateTenant"] = true
				r["housingQuality"] = q
				assigned = true
		for q in [3, 2, 1]:
			if not assigned and int(state_slots[q]) > 0:
				state_slots[q] = int(state_slots[q]) - 1
				r["housingQuality"] = q
				assigned = true

func _collect_rent(day: int) -> Array:
	var rent = float(s["government"]["rent"])
	if rent <= 0.0 or s["residents"].is_empty():
		return []
	if _housing_capacity() <= 0:
		return []

	var owners := []
	var private_tenants := []
	var state_tenants := []
	for r in s["residents"]:
		if bool(r.get("homeowner", false)):
			owners.append(r)
		elif bool(r.get("privateTenant", false)):
			private_tenants.append(r)
		else:
			state_tenants.append(r)

	var gov_total = 0.0
	for r in state_tenants:
		var pay = minf(rent, float(r["savings"]))
		r["savings"] = SimUtil.r2(float(r["savings"]) - pay)
		gov_total += pay
		_add_rent(r, pay)

	var private_total = 0.0
	for r in private_tenants:
		var pay = minf(rent, float(r["savings"]))
		r["savings"] = SimUtil.r2(float(r["savings"]) - pay)
		private_total += pay
		_add_rent(r, pay)

	var brackets: Array = s["government"]["taxBrackets"]
	var gross_share = private_total / float(owners.size()) if not owners.is_empty() else 0.0
	var tax_per_owner = _progressive_tax(gross_share, brackets) if not owners.is_empty() else 0.0
	var rent_tax = SimUtil.r2(tax_per_owner * float(owners.size()))
	var net_share = SimUtil.r2(gross_share - tax_per_owner)
	if not owners.is_empty() and net_share > 0.0:
		for o in owners:
			o["savings"] = SimUtil.r2(float(o["savings"]) + net_share)

	s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) + gov_total + rent_tax)
	s["ledgerToday"]["rent"] = SimUtil.r2(float(s["ledgerToday"]["rent"]) + gov_total + rent_tax)
	return []

## 把一笔租金记到个人账目上（账目可能已被 _pay_wages 建好，也可能没有）
func _add_rent(r: Dictionary, pay: float) -> void:
	if not r.has("account"):
		r["account"] = _empty_account()
	r["account"]["rent"] = SimUtil.r2(float(r["account"]["rent"]) + pay)

func _run_private_housing_market(day: int) -> Array:
	var logs := []
	var sold_total = 0
	var per_day = int(db.economy["privateHousingPerDay"])
	var need_threshold = float(db.economy["privateHousingNeedThreshold"])

	for gid in _pack()["housing"]:
		var def: Dictionary = db.housing[gid]
		var price = float(s["prices"].get(gid, def.get("salePrice", db.goods[gid]["baseValue"])))
		if price <= 0.0:
			continue
		var state_owned = int(floor(float(s["housing"].get(gid, 0.0)) - float(s["privateHousing"].get(gid, 0.0))))
		var sold = 0
		while state_owned > 0 and sold_total < per_day:
			var buyer: Variant = null
			for r in s["residents"]:
				if bool(r.get("homeowner", false)):
					continue
				var lvl = _class_level(r["classId"])
				if lvl < 2:
					continue
				if lvl != int(def["quality"]):
					continue
				if float(r["savings"]) < price + 5.0:
					continue
				if float(r["satisfaction"]) < need_threshold:
					continue
				if buyer == null or float(r["savings"]) > float(buyer["savings"]):
					buyer = r
			if buyer == null:
				break
			buyer["savings"] = SimUtil.r2(float(buyer["savings"]) - price)
			buyer["homeowner"] = true
			buyer["ownedQuality"] = int(def["quality"])
			s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) + price)
			s["privateHousing"][gid] = float(s["privateHousing"].get(gid, 0.0)) + 1.0
			state_owned -= 1
			sold += 1
			sold_total += 1
		if sold > 0:
			logs.append({"day": day, "kind": "invest", "text": "%d 户购买私有住房（¥%.0f/户）" % [sold, price]})
	return logs

# ===========================================================================
# 消费
# ===========================================================================
func _run_consumption(day: int) -> Dictionary:
	var food_score := {}
	var comfort_score := {}
	var price_score_map := {}
	var sold_by_good := {}
	var hungry = 0
	var revenue = 0.0
	var good_set = _good_set()
	var basic_foods: Array = db.tuning["basicFoods"]
	var price_intercept = float(db.economy["priceIntercept"])
	var price_slope = float(db.economy["priceSlope"])
	var lux_elastic = float(db.economy["luxuryElasticity"])
	var elastic = float(db.economy["priceElasticity"])
	var pf_min = float(db.tuning["priceFactorMin"])
	var pf_max = float(db.tuning["priceFactorMax"])
	var hungry_th = float(db.tuning["hungryThreshold"])

	for class_id in db.classes.keys():
		var def: Dictionary = db.classes[class_id]
		var members := []
		for r in s["residents"]:
			if r["classId"] == class_id:
				members.append(r)
		if members.is_empty():
			food_score[class_id] = 1.0
			comfort_score[class_id] = 1.0
			price_score_map[class_id] = 1.0
			continue

		var food_sum = 0.0
		var comfort_sum = 0.0
		var price_sum = 0.0
		for r in members:
			var food_needed = 0.0
			var food_consumed = 0.0
			var comfort_needed = 0.0
			var comfort_consumed = 0.0
			var price_num = 0.0
			var price_den = 0.0
			var spent_by_resident = 0.0
			for need in def["needs"]:
				var need_good = String(need["good"])
				var gdef = db.goods.get(need_good, null)
				var is_food = gdef != null and String(gdef["category"]) == "food"
				var candidates = [need_good]
				if need.has("fallbacks"):
					for fb in need["fallbacks"]:
						candidates.append(fb)
				var filtered := []
				for c in candidates:
					if good_set.has(c):
						filtered.append(c)
				candidates = filtered
				if is_food:
					for b in basic_foods:
						if good_set.has(b) and not candidates.has(b):
							candidates.append(b)
				if candidates.is_empty():
					continue
				var demand = float(need["perCapita"])
				var target = candidates[0]
				for c in candidates:
					if float(s["goods"].get(c, 0.0)) > 0.001:
						target = c
						break
				var tgdef = db.goods.get(target, null)
				var base = float(tgdef["baseValue"]) if tgdef != null else 1.0
				var price = maxf(0.01, float(s["prices"].get(target, base)))
				var e = lux_elastic if db.is_luxury(target) else elastic
				var factor = clampf(pow(base / price, e), pf_min, pf_max)
				var desired = demand * factor
				var affordable = float(r["savings"]) / price if price > 0.0 else desired
				var want = minf(desired, affordable)
				var sold = minf(want, float(s["goods"].get(target, 0.0)))
				s["goods"][target] = SimUtil.r2(float(s["goods"].get(target, 0.0)) - sold)
				var cost = sold * price
				r["savings"] = SimUtil.r2(maxf(0.0, float(r["savings"]) - cost))
				revenue += cost
				spent_by_resident += cost
				if sold > 0.0:
					if not r.has("account"):
						r["account"] = _empty_account()
					var bought: Dictionary = r["account"]["bought"]
					bought[target] = SimUtil.r2(float(bought.get(target, 0.0)) + sold)
					var lt: Dictionary = s["ledgerToday"]["bought"]
					lt[target] = SimUtil.r2(float(lt.get(target, 0.0)) + sold)
				if is_food:
					food_needed += demand
					food_consumed += sold
				else:
					comfort_needed += demand
					comfort_consumed += sold
				sold_by_good[target] = float(sold_by_good.get(target, 0.0)) + sold
				var ps = clampf(price_intercept - price_slope * (price / base), 0.0, 1.0)
				price_num += ps * demand
				price_den += demand
			var f = clampf(food_consumed / food_needed, 0.0, 1.0) if food_needed > 0.0 else 1.0
			var c = clampf(comfort_consumed / comfort_needed, 0.0, 1.0) if comfort_needed > 0.0 else 1.0
			food_sum += f
			comfort_sum += c
			price_sum += (price_num / price_den) if price_den > 0.0 else 1.0
			var is_hungry = f < hungry_th
			if is_hungry:
				hungry += 1
			# 逐人记账：当日消耗（bought）、支出、三项满足率、是否挨饿。
			# 目前按阶层 perCapita 平均分配，所以逐人数值 == 阶层数值；
			# 分开记录是为了将来做差异化分配时不必再动数据结构。
			if not r.has("account"):
				r["account"] = _empty_account()
			var acc: Dictionary = r["account"]
			acc["foodScore"] = floor(f * 1000.0 + 0.5) / 1000.0
			acc["comfortScore"] = floor(c * 1000.0 + 0.5) / 1000.0
			acc["priceScore"] = floor(((price_num / price_den) if price_den > 0.0 else 1.0) * 1000.0 + 0.5) / 1000.0
			acc["hungry"] = is_hungry
			acc["spent"] = SimUtil.r2(float(acc["spent"]) + spent_by_resident)
		food_score[class_id] = food_sum / float(members.size())
		comfort_score[class_id] = comfort_sum / float(members.size())
		price_score_map[class_id] = price_sum / float(members.size())

	s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) + revenue)
	s["ledgerToday"]["sales"] = SimUtil.r2(float(s["ledgerToday"]["sales"]) + revenue)
	return {"foodScore": food_score, "comfortScore": comfort_score, "priceScore": price_score_map, "hungry": hungry, "revenue": SimUtil.r2(revenue), "logs": []}

# ===========================================================================
# 满意度
# ===========================================================================
func _update_satisfaction(food_score: Dictionary, comfort_score: Dictionary, price_score_map: Dictionary) -> void:
	var w: Dictionary = db.economy["weights"]
	var weight_sum = float(w["food"]) + float(w["wage"]) + float(w["price"]) + float(w["employment"]) + float(w["comfort"])
	var ref_wage = float(db.economy["refWage"])
	var smoothing = float(db.economy["satisfactionSmoothing"])
	var wage_cap = float(db.tuning["wageScoreCap"])
	var unemp_score = float(db.tuning["unemployedEmploymentScore"])
	var housing_pen = float(db.economy["housingQualityPenalty"])

	var wage_by_shop := {}
	for shop in s["shops"]:
		wage_by_shop[shop["id"]] = float(shop["wage"])
	var net_income = ref_wage - _progressive_tax(ref_wage, s["government"]["taxBrackets"])
	var rent_pressure = clampf(float(s["government"]["rent"]) / maxf(0.1, net_income), 0.0, 1.0)

	for r in s["residents"]:
		var cid = String(r["classId"])
		var food = float(food_score.get(cid, 1.0))
		var comfort = float(comfort_score.get(cid, 1.0))
		var price = float(price_score_map.get(cid, 1.0))
		var employed = bool(r["employed"])
		# 收入：在职工坊工资 / 工地出工报酬；失业且无工程可做 = 0（保障金已取消）
		var build_pay = float(r.get("constructionPay", 0.0))
		var wage = 0.0
		if build_pay > 0.0:
			wage = build_pay
		elif employed and r.get("jobShopId", null) != null:
			wage = float(wage_by_shop.get(r.get("jobShopId", ""), 0.0))
		var wage_score = clampf(wage / ref_wage, 0.0, wage_cap) / wage_cap
		var employment_score = 1.0 if employed else unemp_score
		var base = 100.0 * (float(w["food"]) * food + float(w["wage"]) * wage_score + float(w["price"]) * price + float(w["employment"]) * employment_score + float(w["comfort"]) * comfort) / weight_sum

		var required = _class_level(cid)
		var quality = int(r.get("housingQuality", 1))
		var quality_penalty = float(-(required - quality) * housing_pen) if quality < required else 0.0
		var housing_adj = 0.0
		if bool(r.get("homeowner", false)):
			housing_adj = float(db.economy["privateHousingSatBonus"])
		elif bool(r.get("privateTenant", false)):
			housing_adj = float(db.economy["privateTenantSatBonus"]) - rent_pressure * float(db.economy["rentSatPenalty"])
		else:
			housing_adj = -rent_pressure * float(db.economy["rentSatPenalty"])
		housing_adj += quality_penalty
		var class_bonus = float(db.classes[cid].get("satBonus", 0.0))
		var target = clampf(base + housing_adj + class_bonus, 0.0, 100.0)
		r["satisfaction"] = clampf(float(r["satisfaction"]) + (target - float(r["satisfaction"])) * smoothing, 0.0, 100.0)

# ===========================================================================
# 人口 / 移民
# ===========================================================================
func _next_resident_index() -> int:
	var mx = s["residents"].size()
	var rx := RegEx.new()
	rx.compile("#([0-9]+)$")
	for r in s["residents"]:
		var m = rx.search(String(r["id"]))
		if m != null:
			var n = int(m.get_string(1))
			if n > mx:
				mx = n
	return mx + 1

func _make_resident(class_id: String) -> Dictionary:
	var rd: Dictionary = db.defaults["newResident"]
	return {
		"id": "res#%d" % _next_resident_index(),
		"classId": class_id,
		"savings": float(rd["savings"]),
		"satisfaction": float(rd["satisfaction"]),
		"skill": float(rd["skillBase"]) + floor(rng.next() * float(rd["skillRandom"])),
		"employed": false,
	}

func _update_classes() -> void:
	var ladder := []
	for cid in _pack()["classes"]:
		if db.classes.has(cid):
			ladder.append(db.classes[cid])
	if ladder.is_empty():
		return
	ladder.sort_custom(func(a, b): return float(a["wealthThreshold"]) < float(b["wealthThreshold"]))
	for r in s["residents"]:
		var cls: Dictionary = ladder[0]
		for c in ladder:
			if float(r["savings"]) >= float(c["wealthThreshold"]):
				cls = c
		r["classId"] = String(cls["id"])

func _update_population(hungry: int, day: int) -> Array:
	var logs := []
	var pop = s["residents"].size()
	if pop == 0:
		return logs
	var avg_sat = _avg_sat()

	if hungry > 0:
		var deaths = int(maxf(0.0, ceil(float(hungry) * float(db.economy["hungerDeathRate"]))))
		deaths = int(minf(float(deaths), maxf(0.0, float(pop - int(db.economy["minPopulation"])))))
		if deaths > 0:
			var doomed: Array = s["residents"].duplicate()
			doomed.sort_custom(func(a, b): return float(a["satisfaction"]) < float(b["satisfaction"]))
			doomed = doomed.slice(0, deaths)
			var confiscated = 0.0
			var ids := {}
			for r in doomed:
				confiscated += float(r["savings"])
				ids[r["id"]] = true
			var kept := []
			for r in s["residents"]:
				if not ids.has(r["id"]):
					kept.append(r)
			s["residents"] = kept
			s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) + confiscated)
			logs.append({"day": day, "kind": "population", "text": "%d 人因饥饿死亡" % deaths})

	if avg_sat < float(db.economy["emigrationSatThreshold"]):
		var leave = int(maxf(1.0, floor(float(pop) * 0.02)))
		leave = int(minf(float(leave), maxf(0.0, float(pop - int(db.economy["minPopulation"])))))
		if leave > 0:
			var doomed2: Array = s["residents"].duplicate()
			doomed2.sort_custom(func(a, b): return float(a["satisfaction"]) < float(b["satisfaction"]))
			doomed2 = doomed2.slice(0, leave)
			var ids2 := {}
			for r in doomed2:
				ids2[r["id"]] = true
			var kept2 := []
			for r in s["residents"]:
				if not ids2.has(r["id"]):
					kept2.append(r)
			s["residents"] = kept2
			logs.append({"day": day, "kind": "population", "text": "%d 人迁离村庄" % leave})

	_update_classes()
	return logs

func _job_capacity() -> int:
	## 仅供 UI / 测试参考的「当前开出的岗位数」。
	## ⚠️ 迁入**不再**看它（见 _apply_admission）：岗位可以后补，卡它会让村子永远长不大。
	var total = 0
	for shop in s["shops"]:
		if not bool(shop["active"]):
			continue
		var def = db.buildings.get(shop["defId"], null)
		if def != null:
			total += int(minf(float(shop["targetWorkers"]), float(def["maxWorkers"])))
	return total

func _apply_admission(day: int) -> Array:
	## admit = min(想来人数, 住房余量, 人口上限 − 人口)
	## **不看岗位数**：岗位可以后补，卡它会让村子永远长不大。见 docs/spec.md §8。
	var pop = s["residents"].size()
	if pop == 0 or int(s["arrivals"]) <= 0:
		return []
	var cap = float(s["government"]["populationCap"])
	var room = int(maxf(0.0, minf(float(_housing_capacity() - pop), cap - float(pop))))
	var admit = int(minf(float(s["arrivals"]), float(room)))
	if admit <= 0:
		return []
	for i in admit:
		s["residents"].append(_make_resident("poor"))
	return [{"day": day, "kind": "population", "text": "%d 人获准迁入（本回合想来 %d 人）" % [admit, int(s["arrivals"])]}]

func _compute_arrivals() -> void:
	## 只看两件事：满意度够不够，以及昨天有没有闹饥荒。岗位数不参与。
	var pop = s["residents"].size()
	var th = float(db.economy["immigrationSatThreshold"])
	if pop == 0:
		s["arrivals"] = 0
		return
	# 食物充足：昨日饥饿比例超过阈值就没有人来
	var hist: Array = s["history"]
	var hungry = int(hist[hist.size() - 1].get("hungry", 0)) if hist.size() > 0 else 0
	if float(hungry) > maxf(1.0, float(pop) * float(db.economy["immigrationHungryRate"])):
		s["arrivals"] = 0
		return
	var avg_sat = _avg_sat()
	if avg_sat < th:
		s["arrivals"] = 0
		return
	s["arrivals"] = int(maxf(0.0, round(float(pop) * float(db.economy["immigrationRate"]) * (avg_sat - th) / (100.0 - th))))

# ===========================================================================
# 施工
# ===========================================================================
func _max_slots() -> float:
	var v = db.economy.get("maxBuildingSlots", null)
	return INF if v == null else float(v)

func _used_slots() -> int:
	var n = s["shops"].size()
	for c in s["construction"]:
		if String(c["kind"]) != "upgrade":
			n += 1
	for gid in s["housing"].keys():
		n += int(floor(float(s["housing"][gid])))
	return n

func _present_cost(def: Dictionary) -> Array:
	var out := []
	var good_set = _good_set()
	for gid in (def.get("buildCost", {}) as Dictionary).keys():
		var q = float(def["buildCost"][gid])
		if q > 0.0 and good_set.has(gid):
			out.append([gid, q])
	return out

func _upgrade_work(level: int) -> float:
	## 升级所需建造力：每 +1 级 = upgradePerLevel × 当前等级。
	return float(db.economy["construction"]["upgradePerLevel"]) * float(level)

func _cost_of(c: Dictionary) -> Dictionary:
	## 某工程的开工成本：{"mats": [[gid, qty]], "money": float}；定义缺失 → {}。
	var kind = String(c["kind"])
	if kind == "shop":
		var bid = String(c.get("buildingId", ""))
		var def = db.buildings.get(bid, null)
		if def == null:
			return {}
		var mats = _present_cost(def)
		if not mats.is_empty():
			return {"mats": mats, "money": 0.0}
		return {"mats": [], "money": float(db.economy["buildMoneyByTier"][str(int(def["tier"]))])}
	if kind == "upgrade":
		var shop = _find_shop(String(c.get("shopId", "")))
		if shop == null or not db.buildings.has(shop["defId"]):
			return {}
		var def2: Dictionary = db.buildings[shop["defId"]]
		var mats2 = _present_cost(def2)
		if mats2.is_empty():
			return {"mats": [], "money": float(db.economy["expandMoneyBase"]) * float(shop["level"])}
		var scaled := []
		for m in mats2:
			scaled.append([m[0], float(m[1]) * float(shop["level"])])
		return {"mats": scaled, "money": 0.0}
	if kind == "housing":
		var hid = String(c.get("housingId", ""))
		if not db.housing.has(hid):
			return {}
		return {"mats": _present_cost(db.housing[hid]), "money": 0.0}
	return {}

func _shortage_reason(spec: Dictionary) -> String:
	for m in spec["mats"]:
		if float(s["goods"].get(m[0], 0.0)) < float(m[1]):
			return "材料不足：%s 需 %s" % [m[0], SimUtil.r2(float(m[1]))]
	if float(s["government"]["money"]) < float(spec["money"]):
		return "资金不足（需 ¥%s）" % SimUtil.r2(float(spec["money"]))
	return "资源不足"

func _can_afford(spec: Dictionary) -> bool:
	for m in spec["mats"]:
		if float(s["goods"].get(m[0], 0.0)) < float(m[1]):
			return false
	return float(s["government"]["money"]) >= float(spec["money"])

func _pay_cost(spec: Dictionary) -> void:
	for m in spec["mats"]:
		s["goods"][m[0]] = SimUtil.r2(float(s["goods"].get(m[0], 0.0)) - float(m[1]))
	var money = float(spec["money"])
	if money > 0.0:
		s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) - money)

func _label_of(c: Dictionary) -> String:
	var kind = String(c["kind"])
	if kind == "shop":
		var def = db.buildings.get(String(c.get("buildingId", "")), null)
		return String(def["nameZh"]) if def != null else String(c.get("buildingId", ""))
	if kind == "housing":
		var hdef = db.housing.get(String(c.get("housingId", "")), null)
		return String(hdef["nameZh"]) if hdef != null else String(c.get("housingId", ""))
	if kind == "upgrade":
		var d2 = db.buildings.get(String(c.get("buildingId", "")), null)
		return "%s 升级" % (String(d2["nameZh"]) if d2 != null else String(c.get("buildingId", "")))
	return String(c["id"])

func _order(c: Dictionary) -> void:
	## 下单：只检查资源够不够并占住队列位，**不扣材料**（材料在开工时扣）。
	var spec = _cost_of(c)
	if spec.is_empty():
		return
	if not _can_afford(spec):
		return
	s["construction"].append(c)

func _try_expand(shop_id: String) -> void:
	var shop = _find_shop(shop_id)
	if shop == null:
		return
	if not db.buildings.has(shop["defId"]):
		return
	for c in s["construction"]:
		if String(c["kind"]) == "upgrade" and String(c.get("shopId", "")) == shop_id:
			return
	var work = _upgrade_work(int(shop["level"]))
	_order({
		"id": "c#%d-up-%s" % [s["construction"].size() + 1, shop_id],
		"kind": "upgrade", "buildingId": shop["defId"], "shopId": shop_id, "housingId": "",
		"remaining": work, "totalRequired": work, "started": false,
	})

func _try_build(building_id: String) -> void:
	if not _pack()["buildings"].has(building_id):
		return
	# 科技没研究出来就不能建（见 docs/technology.md）
	if not is_building_unlocked(building_id):
		return
	var def: Dictionary = db.buildings[building_id]
	if _used_slots() >= _max_slots():
		return
	var work = float(def["buildWork"])
	_order({
		"id": "c#%d-%s" % [s["construction"].size() + 1, building_id],
		"kind": "shop", "buildingId": building_id, "shopId": "", "housingId": "",
		"remaining": work, "totalRequired": work, "started": false,
	})

func _try_build_housing(good_id: String) -> void:
	if not _pack()["housing"].has(good_id):
		return
	if not is_housing_unlocked(good_id):
		return
	var def: Dictionary = db.housing[good_id]
	if _used_slots() >= _max_slots():
		return
	var work = float(def["buildWork"])
	_order({
		"id": "c#%d-house-%s" % [s["construction"].size() + 1, good_id],
		"kind": "housing", "buildingId": "", "shopId": "", "housingId": good_id,
		"remaining": work, "totalRequired": work, "started": false,
	})

# ===========================================================================
# 研究（见 docs/technology.md）
#
# 科研力 = 每日产能（速率，不是库存），与建造力同构：
#   基础 research.baseRate + Σ(研究所在岗工人 × perWorker × (1+levelBonus×(等级−1)) × 熟练度曲线)
# 科技消耗「科研力 + 原材料」：材料在**开工时**扣（队首开始投入科研力时），
# 进度按先进先出队列逐日投入，产能不结转。跑完在**次日黎明**解锁建筑。
# ===========================================================================
func _is_researched(tid: String) -> bool:
	return (s["research"]["done"] as Array).has(tid)

func _is_queued_tech(tid: String) -> bool:
	for p in s["research"]["queue"]:
		if String(p["id"]) == tid:
			return true
	return false

func _research_rate() -> float:
	var rate = float(db.economy["research"]["baseRate"])
	for shop in s["shops"]:
		var def = db.buildings.get(shop["defId"], null)
		if def == null or not bool(shop["active"]) or not _capacity_kind(def, "research"):
			continue
		var cap: Dictionary = def["capacity"]
		var skill_eff = float(db.tuning["skillEffectBase"]) + float(db.tuning["skillEffectSlope"]) * (float(shop["skill"]) / 100.0)
		var level_mul = 1.0 + float(cap["levelBonus"]) * (float(shop["level"]) - 1.0)
		rate += float(_assigned_workers(shop["id"])) * float(cap["perWorker"]) * level_mul * skill_eff
	return SimUtil.r2(rate)

func research_rate() -> float:
	## 供 UI 读取的当日科研力速率。
	return _research_rate()

## 该建筑现在能不能建：没有科技锁，或解锁它的科技已完成。
func is_building_unlocked(bid: String) -> bool:
	var tid = db.tech_for_building(bid)
	if tid == "":
		return true
	return _is_researched(tid)

func is_housing_unlocked(hid: String) -> bool:
	var tid = db.tech_for_housing(hid)
	if tid == "":
		return true
	return _is_researched(tid)

func _start_research(tid: String) -> void:
	if not db.techs.has(tid) or _is_researched(tid) or _is_queued_tech(tid):
		return
	var tech: Dictionary = db.techs[tid]
	for r in tech["requires"]:
		if not _is_researched(String(r)):
			return
	# 只检查材料够不够，**不扣**（材料在开工时扣，与施工一致）
	for gid in (tech["cost"]["goods"] as Dictionary).keys():
		if float(s["goods"].get(gid, 0.0)) < float(tech["cost"]["goods"][gid]):
			return
	s["research"]["queue"].append({
		"id": tid,
		"remaining": float(tech["research"]),
		"totalRequired": float(tech["research"]),
		"started": false,
	})

func _cancel_research(tid: String) -> void:
	var q: Array = s["research"]["queue"]
	for i in range(q.size()):
		if String(q[i]["id"]) == tid:
			q.remove_at(i)
			return

func _settle_research(day: int) -> Array:
	var logs := []
	var rate = _research_rate()
	for p in s["research"]["queue"]:
		if rate <= 0.0:
			break
		var tech = db.techs.get(String(p["id"]), null)
		if tech == null:
			break
		if not bool(p.get("started", false)):
			var short := false
			for gid in (tech["cost"]["goods"] as Dictionary).keys():
				if float(s["goods"].get(gid, 0.0)) < float(tech["cost"]["goods"][gid]):
					logs.append({"day": day, "kind": "invest",
						"text": "研究「%s」等待材料（%s 需 %s）" % [tech["nameZh"], gid, tech["cost"]["goods"][gid]]})
					short = true
					break
			if short:
				break
			for gid in (tech["cost"]["goods"] as Dictionary).keys():
				s["goods"][gid] = SimUtil.r2(float(s["goods"].get(gid, 0.0)) - float(tech["cost"]["goods"][gid]))
			p["started"] = true
			logs.append({"day": day, "kind": "invest",
				"text": "开始研究「%s」（需科研力 %s）" % [tech["nameZh"], SimUtil.r2(float(p["totalRequired"]))]})
		var used = minf(rate, float(p["remaining"]))
		p["remaining"] = SimUtil.r2(float(p["remaining"]) - used)
		rate = SimUtil.r2(rate - used)
	return logs

func _activate_research() -> Array:
	var logs := []
	while (s["research"]["queue"] as Array).size() > 0 and float(s["research"]["queue"][0]["remaining"]) <= 0.0:
		var done_item: Dictionary = s["research"]["queue"].pop_front()
		s["research"]["done"].append(String(done_item["id"]))
		var tech = db.techs.get(String(done_item["id"]), null)
		logs.append({"day": int(s["day"]), "kind": "invest",
			"text": "研究完成：%s" % (String(tech["nameZh"]) if tech != null else String(done_item["id"]))})
	return logs

# ===========================================================================
# 工具（见 docs/technology.md §八）
#
# 工坊按**在岗工位**每日消耗工具，换来**产出 ×(1+toolBonus)、投入不变**
# —— 单位原料成品率提高（"虚空产量"）。
# 黎明一次性分配、当天不变，结果存进 shop.toolBoost；生产小时只把它乘在**产出**上。
# ===========================================================================
func _allocate_tools() -> Array:
	var logs := []
	var per = float(db.economy["tools"]["perWorkstation"])
	var order: Array = db.economy["tools"]["order"]
	var boosted = 0

	for shop in s["shops"]:
		shop["toolBoost"] = 1.0
		var def = db.buildings.get(shop["defId"], null)
		# 只有产商品的工坊耗工具；产能建筑（建筑工坊/研究所）不产商品，加成无从施加
		if def == null or not def.has("recipe") or not bool(shop["active"]):
			continue
		var workers = _assigned_workers(shop["id"])
		if workers <= 0:
			continue
		var need = SimUtil.r2(per * float(workers))
		if need <= 0.0:
			continue
		# 由低到高排列，这里从**最高级**往下找第一个够用的
		for i in range(order.size() - 1, -1, -1):
			var gid = String(order[i])
			var bonus = db.tool_bonus(gid)
			if bonus <= 0.0 or float(s["goods"].get(gid, 0.0)) < need:
				continue
			s["goods"][gid] = SimUtil.r2(float(s["goods"].get(gid, 0.0)) - need)
			s["ledgerToday"]["consumed"][gid] = SimUtil.r2(
				float(s["ledgerToday"]["consumed"].get(gid, 0.0)) + need)
			shop["toolBoost"] = 1.0 + bonus
			boosted += 1
			break

	var total_need = 0.0
	for shop in s["shops"]:
		var def2 = db.buildings.get(shop["defId"], null)
		if def2 != null and def2.has("recipe") and bool(shop["active"]):
			total_need += float(_assigned_workers(shop["id"])) * per
	if total_need > 0.0:
		logs.append({"day": int(s["day"]), "kind": "production",
			"text": "工具：%d 座工坊已装配（需求 %s/日）" % [boosted, SimUtil.r2(total_need)]})
	return logs

func _shop_tool_boost(shop: Dictionary) -> float:
	var b = float(shop.get("toolBoost", 1.0))
	return b if b > 0.0 else 1.0

func _capacity_kind(def: Dictionary, kind: String) -> bool:	## 该建筑是否是某种产能来源（不产商品、只产每日产能）。见 docs/technology.md §6.2。
	if not def.has("capacity"):
		return false
	return String((def["capacity"] as Dictionary).get("kind", "")) == kind

func _is_construction_works(def: Dictionary) -> bool:
	return _capacity_kind(def, "build")

func construction_rate() -> float:
	## 供 UI 读取的当日建造力速率（人·天/日）。
	return _construction_rate()

func _construction_rate() -> float:
	## 当日施工产能（建造力 / 人·天）：
	##   失业人口 × construction.unemployedRate
	## + Σ(建筑工坊在岗工人 × capacity.perWorker × (1 + levelBonus × (等级−1)) × 熟练度曲线)
	var cfg: Dictionary = db.economy["construction"]
	var unemp_rate = float(cfg["unemployedRate"])
	var rate = 0.0
	for r in s["residents"]:
		if not bool(r["employed"]):
			rate += unemp_rate
	for shop in s["shops"]:
		var def = db.buildings.get(shop["defId"], null)
		if def == null or not bool(shop["active"]) or not _is_construction_works(def):
			continue
		var cap: Dictionary = def["capacity"]
		var skill_eff = float(db.tuning["skillEffectBase"]) + float(db.tuning["skillEffectSlope"]) * (float(shop["skill"]) / 100.0)
		var level_mul = 1.0 + float(cap["levelBonus"]) * (float(shop["level"]) - 1.0)
		rate += float(_assigned_workers(shop["id"])) * float(cap["perWorker"]) * level_mul * skill_eff
	return SimUtil.r2(rate)

func _mark_construction_workers(work: float) -> void:
	## 建造结算后：把当日实际投入的建造力折算成「在工地上出工」的失业人口。
	## 见 docs/construction.md 五：工地临时工拿 refWage × wageRate，没工程可做者 0。
	if work <= 0.0:
		return
	var idle := []
	for r in s["residents"]:
		if not bool(r["employed"]):
			idle.append(r)
	if idle.is_empty():
		return
	var n = int(minf(float(idle.size()), ceil(work - 1e-9)))
	var bill = SimUtil.r2(work * float(db.economy["refWage"]) * float(db.economy["construction"]["wageRate"]))
	var per = SimUtil.r2(bill / float(n))
	for i in range(n):
		idle[i]["employed"] = true
		idle[i]["constructionPay"] = per

func _settle_construction(day: int) -> Array:
	## 夜晚：把当日产能投入队首工程（先进先出，串行）。
	## 队首未开工 → 先扣材料；材料不足 → 停在队首等待，不跳过。
	var logs := []
	var rate = _construction_rate()
	var work = 0.0
	for c in s["construction"]:
		if rate <= 0.0:
			break
		if not bool(c.get("started", false)):
			var spec = _cost_of(c)
			if spec.is_empty():
				logs.append({"day": day, "kind": "invest", "text": "%s 定义缺失，施工停摆" % _label_of(c)})
				break
			if not _can_afford(spec):
				logs.append({"day": day, "kind": "invest", "text": "%s 等待材料（%s）" % [_label_of(c), _shortage_reason(spec)]})
				break
			_pay_cost(spec)
			c["started"] = true
			logs.append({"day": day, "kind": "invest", "text": "%s 开工（需建造力 %s）" % [_label_of(c), SimUtil.r2(float(c["totalRequired"]))]})
		var used = minf(rate, float(c["remaining"]))
		c["remaining"] = SimUtil.r2(float(c["remaining"]) - used)
		rate = SimUtil.r2(rate - used)
		work = SimUtil.r2(work + used)
	_mark_construction_workers(work)
	return logs

func _activate_completed() -> Array:
	var logs := []
	var remaining := []
	for c in s["construction"]:
		if float(c["remaining"]) > 0.0:
			remaining.append(c)
			continue
		var kind = String(c["kind"])
		if kind == "shop":
			var bid = String(c["buildingId"])
			if not db.buildings.has(bid):
				continue
			var def: Dictionary = db.buildings[bid]
			var count = 0
			for sh in s["shops"]:
				if sh["defId"] == bid:
					count += 1
			s["shops"].append({
				"id": "%s#%d" % [bid, count + 1],
				"defId": bid, "owner": "state",
				"targetWorkers": int(def["workers"]),
				"wage": float(db.economy["refWage"]),
				"wageCap": float(db.economy["defaultWageCap"]),
				"level": int(db.defaults["newShop"]["level"]),
				"active": true, "profit": 0.0,
				"skill": float(db.defaults["newShop"]["skill"]),
				"planned": 0.0,
			})
			logs.append({"day": int(s["day"]), "kind": "invest", "text": "%s 建成投产" % def["nameZh"]})
		elif kind == "upgrade":
			var shop = _find_shop(String(c["shopId"]))
			if shop != null:
				var udef = db.buildings.get(String(shop["defId"]), null)
				# 升级会改**有效工位数**（capacity.slotsPerLevel），用工目标要跟着走：
				#   改之前满员 → 改完仍满员
				#   改之前不满员 → **保留原来的绝对数字**（不按比例缩放）
				var before = effective_slots(udef, int(shop["level"])) if udef != null else 0
				var was_full = int(shop["targetWorkers"]) >= before
				shop["level"] = int(shop["level"]) + 1
				if udef != null and was_full:
					shop["targetWorkers"] = effective_slots(udef, int(shop["level"]))
				logs.append({"day": int(s["day"]), "kind": "invest", "text": "升级至 Lv%d" % int(shop["level"])})
		elif kind == "housing":
			var hid = String(c["housingId"])
			s["housing"][hid] = float(s["housing"].get(hid, 0.0)) + 1.0
			logs.append({"day": int(s["day"]), "kind": "invest", "text": "建成住房"})
	s["construction"] = remaining
	return logs

# ===========================================================================
# 快照 / 提示
# ===========================================================================
func _avg(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var t = 0.0
	for v in values:
		t += float(v)
	return t / float(values.size())

func _avg_sat() -> float:
	if s["residents"].is_empty():
		return 0.0
	var t = 0.0
	for r in s["residents"]:
		t += float(r["satisfaction"])
	return t / float(s["residents"].size())

func _make_snapshot(hungry: int) -> Dictionary:
	var employed = 0
	for r in s["residents"]:
		if bool(r["employed"]):
			employed += 1
	return {
		"day": int(s["day"]),
		"population": s["residents"].size(),
		"avgSatisfaction": floor(_avg_sat() * 10.0 + 0.5) / 10.0,
		"money": float(s["government"]["money"]),
		"hungry": hungry,
		"employed": employed,
		# 当日实际流量台账（逐人账目挂在每个 resident 的 account 上）
		"ledger": s["ledgerToday"],
	}

func _build_alerts(hungry: int) -> Array:
	# ⚠️ 顺序必须与 TS `tick.ts::buildAlerts` **逐条一致**（hunger → storage_full →
	# low_satisfaction）：alerts 会进黄金轨迹摘要，顺序不同就是对拍不一致。
	var alerts := []
	if hungry > 0:
		alerts.append({"type": "hunger", "count": hungry, "text": "%d 人处于饥饿" % hungry})
	# 仓储满了必须报警：否则货凭空消失，玩家会以为是 bug（docs/town.md §3.3）
	var cap = storage_capacity()
	var used = stored_total()
	if cap > 0.0 and used >= cap:
		alerts.append({"type": "storage_full", "count": int(round(used)),
			"text": "仓储已满（%d / %d）" % [int(round(used)), int(round(cap))]})
	# 满意度偏低。⚠️ 这条 TS 侧一直有、GDScript 侧一直漏了（历史遗留的 parity 缺口），
	# 2026-10 一并补上。口径照 `tick.ts::avgSatisfaction`：全体居民满意度的算术平均，
	# 没人时为 0。
	var avg_sat := 0.0
	if not (s["residents"] as Array).is_empty():
		var acc := 0.0
		for r in s["residents"]:
			acc += float(r["satisfaction"])
		avg_sat = acc / float((s["residents"] as Array).size())
	if avg_sat < 45.0:
		alerts.append({"type": "low_satisfaction", "count": int(round(avg_sat)),
			"text": "平均满意度偏低"})
	return alerts
