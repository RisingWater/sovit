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
		"set_wage", "set_wage_cap", "set_workers", "toggle", "expand":
			return t + ":" + String(a.get("shopId", ""))
		"set_price":
			return t + ":" + String(a.get("goodId", ""))
		"set_tax_bracket":
			return t + ":" + str(int(a.get("index", 0)))
		"set_tax", "set_rent", "set_immigration":
			return t
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
			"immigrationAllowance": 1000000000.0,
		},
		"goods": goods, "housing": housing, "privateHousing": private_housing, "prices": prices,
		"shops": shops, "residents": residents, "construction": [],
		"ledgerToday": _empty_ledger(0),
		"history": [{"day": 0, "population": pop, "avgSatisfaction": float(sd["satisfaction"]), "money": money, "hungry": 0, "employed": 0, "ledger": _empty_ledger(0)}],
		"log": [], "alerts": [], "arrivals": 0,
		# 村庄名（可改，随存档保存）。UI 层显示用，不参与任何仿真计算。
		"villageName": "sovit",
	}

## 空白台账 / 空白个人账目。
## 逐人账目与每日台账分开放，是为了将来做差异化分配（按收入/偏好/距离）
## 时不必再动数据结构 —— 现在所有人平均分配，逐人数值 == 阶层数值。
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
	_assign_labor()
	_plan_production()
	return logs

func _run_night() -> Array:
	var day = int(s["day"])
	var logs := []
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
	_advance_construction()
	_apply_spoilage()
	_grow_skills()
	_compute_arrivals()
	s["reserved"] = {}

	s["history"].append(_make_snapshot(cons["hungry"]))
	if s["history"].size() > 400:
		s["history"] = s["history"].slice(s["history"].size() - 400)
	s["alerts"] = _build_alerts(cons["hungry"])
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
					shop["targetWorkers"] = int(round(clampf(float(action["value"]), 0.0, float(d["maxWorkers"]))))
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
			"set_immigration":
				s["government"]["immigrationAllowance"] = maxf(0.0, floor(float(action["value"])))
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
		for g in (recipe["output"] as Dictionary).keys():
			var q = float(recipe["output"][g])
			if q > 0.0:
				s["goods"][g] = float(s["goods"].get(g, 0.0)) + q * batches
				lt["produced"][g] = _r4(float(lt["produced"].get(g, 0.0)) + q * batches)

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

func _assign_labor() -> void:
	for r in s["residents"]:
		r["employed"] = false
		r.erase("jobShopId")

	var pop = s["residents"].size()
	var food_chain = _food_chain_goods()

	var info := []
	for shop in s["shops"]:
		var def = db.buildings.get(shop["defId"], null)
		var want = 0
		if bool(shop["active"]) and def != null:
			want = int(maxf(0.0, minf(float(shop["targetWorkers"]), float(def["maxWorkers"]))))
		var priority = false
		if def != null:
			var recipe: Dictionary = db.recipes[def["recipe"]]
			for gid in (recipe["output"] as Dictionary).keys():
				if food_chain.has(gid):
					priority = true
		info.append({"want": want, "priority": priority})

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
	var welfare = SimUtil.r2(float(db.economy["refWage"]) * float(db.economy["welfareRate"]))
	var skill_base = float(db.economy["skillIncomeBase"])
	var skill_max = float(db.economy["skillMax"])

	var gross_total = 0.0
	var tax_total = 0.0
	for r in s["residents"]:
		var employed = bool(r["employed"]) and r.get("jobShopId", null) != null
		var wage_base = float(wage_by_shop.get(r.get("jobShopId", ""), 0.0)) if employed else welfare
		var gross = wage_base
		if employed:
			gross = wage_base * (skill_base + minf(skill_max, float(r["skill"])) / 100.0)
			var cap = float(cap_by_shop.get(r.get("jobShopId", ""), 0.0))
			if cap > 0.0:
				gross = minf(gross, cap)
		var tax = _progressive_tax(gross, brackets)
		r["savings"] = SimUtil.r2(float(r["savings"]) + gross - tax)
		gross_total += gross
		tax_total += tax
		# 逐人记账：工资/保障金与代扣税。租与消费在后面两步追加到同一份账目。
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
	var welfare = float(db.economy["refWage"]) * float(db.economy["welfareRate"])
	var net_income = ref_wage - _progressive_tax(ref_wage, s["government"]["taxBrackets"])
	var rent_pressure = clampf(float(s["government"]["rent"]) / maxf(0.1, net_income), 0.0, 1.0)

	for r in s["residents"]:
		var cid = String(r["classId"])
		var food = float(food_score.get(cid, 1.0))
		var comfort = float(comfort_score.get(cid, 1.0))
		var price = float(price_score_map.get(cid, 1.0))
		var employed = bool(r["employed"]) and r.get("jobShopId", null) != null
		var wage = float(wage_by_shop.get(r.get("jobShopId", ""), 0.0)) if employed else welfare
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
	var total = 0
	for shop in s["shops"]:
		if not bool(shop["active"]):
			continue
		var def = db.buildings.get(shop["defId"], null)
		if def != null:
			total += int(minf(float(shop["targetWorkers"]), float(def["maxWorkers"])))
	return total

func _apply_admission(day: int) -> Array:
	var pop = s["residents"].size()
	if pop == 0 or int(s["arrivals"]) <= 0:
		return []
	var room = int(maxf(0.0, minf(float(_housing_capacity() - pop), float(_job_capacity() - pop))))
	var allow = int(maxf(0.0, floor(float(s["government"]["immigrationAllowance"]))))
	var admit = int(minf(float(s["arrivals"]), minf(float(allow), float(room))))
	if admit <= 0:
		return []
	for i in admit:
		s["residents"].append(_make_resident("poor"))
	return [{"day": day, "kind": "population", "text": "%d 人获准迁入" % admit}]

func _compute_arrivals() -> void:
	var pop = s["residents"].size()
	var th = float(db.economy["immigrationSatThreshold"])
	if pop == 0:
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

func _try_expand(shop_id: String) -> void:
	var shop = _find_shop(shop_id)
	if shop == null:
		return
	var def: Dictionary = db.buildings[shop["defId"]]
	for c in s["construction"]:
		if String(c["kind"]) == "upgrade" and String(c.get("shopId", "")) == shop_id:
			return
	var mats = _present_cost(def)
	if not mats.is_empty():
		var scale = float(shop["level"])
		for m in mats:
			if float(s["goods"].get(m[0], 0.0)) < float(m[1]) * scale:
				return
		for m in mats:
			s["goods"][m[0]] = SimUtil.r2(float(s["goods"].get(m[0], 0.0)) - float(m[1]) * scale)
	else:
		var cost = float(db.economy["expandMoneyBase"]) * float(shop["level"])
		if float(s["government"]["money"]) < cost:
			return
		s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) - cost)
	s["construction"].append(_new_construction("upgrade", "up-%s" % shop_id, shop["defId"], shop_id, ""))

func _try_build(building_id: String) -> void:
	if not _pack()["buildings"].has(building_id):
		return
	var def: Dictionary = db.buildings[building_id]
	if _used_slots() >= _max_slots():
		return
	var mats = _present_cost(def)
	if not mats.is_empty():
		for m in mats:
			if float(s["goods"].get(m[0], 0.0)) < float(m[1]):
				return
		for m in mats:
			s["goods"][m[0]] = SimUtil.r2(float(s["goods"].get(m[0], 0.0)) - float(m[1]))
	else:
		var cost = float(db.economy["buildMoneyByTier"][str(int(def["tier"]))])
		if float(s["government"]["money"]) < cost:
			return
		s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) - cost)
	s["construction"].append(_new_construction("shop", building_id, building_id, "", ""))

func _try_build_housing(good_id: String) -> void:
	if not _pack()["housing"].has(good_id):
		return
	var def: Dictionary = db.housing[good_id]
	if _used_slots() >= _max_slots():
		return
	var mats = _present_cost(def)
	for m in mats:
		if float(s["goods"].get(m[0], 0.0)) < float(m[1]):
			return
	for m in mats:
		s["goods"][m[0]] = SimUtil.r2(float(s["goods"].get(m[0], 0.0)) - float(m[1]))
	s["construction"].append(_new_construction("housing", "house-%s" % good_id, "", "", good_id))

func _new_construction(kind: String, tag: String, building_id: String, shop_id: String, housing_id: String) -> Dictionary:
	var days = int(db.economy["constructionDays"])
	return {
		"id": "c#%d-%s" % [s["construction"].size() + 1, tag],
		"kind": kind, "buildingId": building_id, "shopId": shop_id, "housingId": housing_id,
		"daysLeft": days, "totalDays": days,
	}

func _advance_construction() -> void:
	for c in s["construction"]:
		c["daysLeft"] = int(c["daysLeft"]) - 1

func _activate_completed() -> Array:
	var logs := []
	var remaining := []
	for c in s["construction"]:
		if int(c["daysLeft"]) > 0:
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
				shop["level"] = int(shop["level"]) + 1
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
	var alerts := []
	if hungry > 0:
		alerts.append({"type": "hunger", "count": hungry, "text": "%d 人处于饥饿" % hungry})
	return alerts
