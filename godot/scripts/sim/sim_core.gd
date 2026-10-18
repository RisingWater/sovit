class_name SimCore
extends RefCounted

# 纯仿真核心（无任何 Node / 场景依赖）。
# 公式与顺序严格对照仓库根 docs/spec.md 与 src/engine/*。

var db: ContentDB
var s: Dictionary = {}
var rng: Rng

func _init(content: ContentDB) -> void:
	db = content

## **即时生效**的动作：研究队列的增 / 撤 / 调序（用户 2026-10 要求）。
##
## 原话："我白天点了一个研究……结果队列里没有，没有实时出现。要到第二天才能调整顺序太蠢了。"
## 这三条**不花任何资源**（材料是在**开工那一刻**才扣的），只动一条队列，没理由等黎明。
## ⚠️ 其余动作（建造 / 拆除 / 改价 / 招工…）仍然**次日黎明生效** —— 那是"一天一结算"的核心
## 口径，也是黄金轨迹的确定性来源。TS 侧同一份名单：`tick.ts::IMMEDIATE_ACTIONS`。
const IMMEDIATE_ACTIONS := ["research", "cancel_research", "move_research"]

## 当场应用一条动作，并把它的公告并进 `s["log"]`（与 `tick_hour` 末尾同一口径，上限 500）。
func _apply_immediate(a: Dictionary) -> void:
	var logs := _apply_actions([a])
	if logs.is_empty():
		return
	var all_logs: Array = s["log"]
	all_logs.append_array(logs)
	if all_logs.size() > 500:
		s["log"] = all_logs.slice(all_logs.size() - 500)
	else:
		s["log"] = all_logs

func enqueue(actions: Array) -> void:
	# 合并同类命令：同一目标的设置只保留最新一条；建造类可叠加。
	for a in actions:
		var at := String(a.get("type", ""))
		if at == "end_turn":
			continue
		# 研究队列那三条：**当场生效**（不等黎明）
		if IMMEDIATE_ACTIONS.has(at):
			_apply_immediate(a)
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
	# 每栋房一个条目（2026-10）：id 单调发号 `h#N`，改建换 type 不换 id
	var housing_units := []
	var housing_seq := 0
	for gid in pack["housing"]:
		housing[gid] = 0.0
		private_housing[gid] = 0.0
		var hd: Dictionary = db.housing[gid]
		# ⚠️ GDScript 的 `Dictionary.get(k, 默认值)` **不短路** —— 默认值总会被求值。
		# 所以这里不能写 `hd.get("salePrice", db.goods[gid]["baseValue"])`：
		# 住房 2026-10 起**不再是商品**（`goods.json` 里没有 hut/wooden_house/brick_house），
		# 那样写会在 `new_game` 里直接 KeyError。
		prices[gid] = float(hd.get("salePrice", _base_value_or(gid)))
	for gid in pack["housing"]:
		var n := int(floor(float(start_housing.get(gid, 0.0))))
		for i in n:
			housing_seq += 1
			housing_units.append({"id": "h#%d" % housing_seq, "type": String(gid), "private": false})
		housing[gid] = float(n)

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
		# 住房单体（唯一真源）：`housing` / `privateHousing` 是它算出来的计数，
		# 见 docs/spec.md §5.5。`housingSeq` = 下一条房号的序号（单调，收房不回收号码）。
		"housingUnits": housing_units, "housingSeq": housing_seq,
		"shops": shops, "residents": residents, "construction": [],
		# 城镇中心是不是**破旧**的（用户 2026-10：一开局是废墟，修好才换回好图）。
		# ⚠️ 这是**表现层要用的一个开关**，仿真的任何数字都不读它 ——
		# 和 `prophet` 一样"只记事、不演化"，所以黄金摘要（按字段取的）不受影响。
		"townCenter": {"stage": "ruined"},
		# 科技：开局已研究的来自 pack.start.techs（见 docs/technology.md）
		"research": {"done": _start_techs(pack_id), "queue": []},
		# 任务（引导系统）：完成记录 + 章节奖励记录。判定与发钱都在黎明，
		# 见 docs/quests.md 与下面的 _check_quests()。
		# `shown` = 已经播过的剧情对话（`q:<id>` / `c:<章节>`）—— 只记事、不演化，
		# 和 `prophet` / `townCenter` 同一类；黄金摘要按字段取，碰不到它。
		"quests": {"done": {}, "chapters": {}, "shown": {}},
		# 山顶那位预言家（AI 辅助）：`lastAskDay` = 上次问他话是第几天（-1 = 还没问过）。
		# 冷却 PROPHET_COOLDOWN_DAYS 天，见 docs/ai-assist.md §六。
		# ⚠️ 这是**唯一一个不参与仿真演化**的状态段：问不问都不改村子的任何数值。
		# 放在状态里而不是 UI 配置里，是为了让退出重进 / 读档都绕不过冷却。
		"prophet": {"lastAskDay": -1},
		"ledgerToday": _empty_ledger(0),
		# 当日建造力预算（人·天）：黎明 _plan_construction_day 钉死，全天不变；
		# 以及当日已投入施工的建造力累加器（工作小时里逐小时累加，
		# 入夜折成「工地出工」的建造工资后清零）。见 docs/spec.md §9.3 / §9.4。
		"constructionRateToday": 0.0,
		"constructionWorkToday": 0.0,
		# 当日科研力预算（人·天）：黎明 _plan_research_day 钉死，全天不变；
		# 以及当日已投入的科研力累加器。见 docs/spec.md §10.3。
		"researchRateToday": 0.0,
		"researchWorkToday": 0.0,
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
		"produced": {}, "consumed": {}, "bought": {},
		# 拆分表：面板 tooltip 用（谁消耗了哪样东西）—— 见 TS 的 DayLedger
		"consumedBy": {}, "boughtBy": {}}

func _empty_account() -> Dictionary:
	return {"wage": 0.0, "tax": 0.0, "rent": 0.0, "spent": 0.0,
		"foodScore": 1.0, "comfortScore": 1.0, "priceScore": 1.0,
		"hungry": false, "bought": {}}

# ===========================================================================
# 时间推进
# ===========================================================================
func tick_hour(pending_actions: Array = []) -> Array:
	for a in pending_actions:
		# 研究队列那三条**当场生效**（与 `enqueue()` 同一份名单 / 同一口径）
		if IMMEDIATE_ACTIONS.has(String(a.get("type", ""))):
			_apply_immediate(a)
		else:
			s["pending"].append(a)
	var logs := []
	var h = int(s["hour"])
	if h == int(db.time["dawnHour"]):
		logs.append_array(_run_dawn())
	if h >= int(db.time["workStart"]) and h < int(db.time["workEnd"]):
		var work_hours = int(db.time["workEnd"]) - int(db.time["workStart"])
		var fraction = 1.0 / float(work_hours)
		# 生产 / 施工 / 科研**同一条件、同一节奏**（都在工作小时里按小时推进）。
		# 顺序固定为**先生产、再施工、后科研**：
		#   1. 生产：当小时刚产出的木石粘土，当小时就能用于下面两步扣料
		#   2. 施工：工地开工优先吃当小时的产出
		#   3. 科研：研究所在岗工人不参与建造力，两条队列互不争抢
		_run_production_step(fraction)
		logs.append_array(_apply_construction_hours(fraction))
		logs.append_array(_apply_research_hours(fraction))
	if h == int(db.time["settleHour"]):
		logs.append_array(_run_night())
	s["hour"] = (h + 1) % int(db.time["hoursPerDay"])
	# 公告（`s["log"]`）**逐小时累积当小时的日志**（黎明 / 白天 / 夜晚三批都算），上限 500。
	#
	# ⚠️ 这里必须管全部三批：以前只有 `_run_night()` 往里写，于是「建成投产」「研究完成」
	#    「X 改建为 Y」这类**黎明**日志根本进不了存档 —— 玩家退出再进来，公告就基本是空的
	#    （2026-10 用户报的）。`s["log"]` 是公告的**唯一真源**（UI 直接读它，见 log_tail()），
	#    所以它必须等于「玩家这一天见过的全部消息」。TS 侧同口径（src/engine/tick.ts）。
	var all_logs: Array = s["log"]
	all_logs.append_array(logs)
	if all_logs.size() > 500:
		s["log"] = all_logs.slice(all_logs.size() - 500)
	return logs

## 公告：最近 `n` 条日志（给表现层读）。
##
## 日志的真源是 `s["log"]`（进存档），这里只是取尾巴 —— 表现层**不要**再自己攒一份副本
## （曾经 `SimRunner.recent_logs` 就是这么一份影子副本，读档时被清空，公告于是全没了）。
func log_tail(n: int = 24) -> Array:
	var all_logs: Array = s.get("log", [])
	if n <= 0 or all_logs.size() <= n:
		return all_logs
	return all_logs.slice(all_logs.size() - n)

## 公告总条数（面板用来显示"共 N 条，显示最近 24 条"）。
func log_size() -> int:
	return (s.get("log", []) as Array).size()

func _run_dawn() -> Array:
	var logs := []
	s["day"] = int(s["day"]) + 1
	# 新的一天：台账清零（晚上结算时挂到当天快照）
	s["ledgerToday"] = _empty_ledger(int(s["day"]))
	# 取消建造的日志就在这一批里（见 _apply_actions）—— 必须并进黎明这批日志，
	# 否则"退回了什么"既不在公告里、也不进存档。
	logs.append_array(_apply_actions(s["pending"]))
	s["pending"] = []
	logs.append_array(_activate_completed())
	logs.append_array(_activate_research())
	_assign_labor()
	# 工具必须在排产之前分配：它决定今天各工坊的产出倍率（shop.toolBoost）
	logs.append_array(_allocate_tools())
	_plan_production()
	# 当日建造力预算：必须在**用工之后**（建造力取决于失业人口与建筑工坊的在岗人数），
	# 且必须在第一个工作小时之前 —— 全天按这个数投入，不每小时现算（见 _plan_construction_day）
	_plan_construction_day()
	# 当日科研力预算：同样在**用工之后**、第一个工作小时之前 —— 全天按这个数投入
	# （见 _plan_research_day）。顺序固定为**先施工、后科研**，与白天、夜晚两处一致。
	_plan_research_day()
	# 任务（引导系统）放在**最后**：完工的建筑、生效的科技、刚放行的人口都已经写进 state，
	# 判定就是"看眼前这个村子有没有"，所以玩家先干了、任务后出现也照样算完成。
	# 契约见 docs/quests.md（TS 侧 src/engine/systems/quests.ts::checkQuests）。
	logs.append_array(_check_quests())
	return logs

func _run_night() -> Array:
	var day = int(s["day"])
	var logs := []
	# 施工收尾必须在工资之前：它把**白天已经投进去的**建造力折算成
	# 「在工地上出工」的失业人口（建造工资，见 docs/spec.md §9.4）。
	logs.append_array(_settle_construction(day))
	# 研究独立成队、不占人口：科研力已经在白天按小时投完了，这里只诊断队首为什么没动
	# （见 docs/spec.md §10.4）
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
	# ⚠️ 这里**不**往 s["log"] 写：公告的累积统一发生在 tick_hour()（唯一入口，见那里的注释）。
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
func _apply_actions(actions: Array) -> Array:
	## 返回**这些命令产生的日志**（目前只有取消建造会写一条：退料明细没有别的出口）。
	## 调用方 `_run_dawn()` 把它们并进黎明那批日志 —— 公告的累积统一发生在 tick_hour()
	## 这一个入口，所以这里**不直接**碰 `s["log"]`（与 TS 的 applyActions(logs) 同形制）。
	var logs := []
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
			"repair_town_center":
				# 修缮城镇中心（用户 2026-10：开局是废墟，第三章先**初步修缮**、第四章再**修好**）。
				# 和别的命令一样**次日黎明生效**；材料不够就白下这一单。
				# `stage` = 这一步走到哪：`patched`（初步修缮）/ `restored`（彻底修好，缺省）。
				# ⚠️ match 分支里不要用 `:=`（GDScript 会报 "Expected end of statement"）。
				var to_stage := String(action.get("stage", "restored"))
				if can_repair_town_center(to_stage):
					var cost: Dictionary = town_center_repair_cost(to_stage)
					var afford: bool = true
					for gid in cost.keys():
						if float(s["goods"].get(gid, 0.0)) < float(cost[gid]):
							afford = false
					if afford:
						for gid in cost.keys():
							s["goods"][gid] = SimUtil.r2(
								float(s["goods"].get(gid, 0.0)) - float(cost[gid]))
						s["townCenter"] = {"stage": to_stage}
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
			"upgrade_housing":
				# `unitId`：玩家从某栋房的面板点「改建」时带上它（指名到栋，进度条才钉得住）
				_try_upgrade_housing(String(action["goodId"]), String(action.get("unitId", "")))
			"move_construction":
				_move_construction(String(action["id"]), int(action.get("delta", 0)))
			"cancel_construction":
				var cres := _cancel_construction(String(action["id"]))
				if bool(cres["ok"]):
					logs.append({"day": int(s["day"]), "kind": "invest", "text": String(cres["text"])})
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
				var rres := _cancel_research(String(action["techId"]))
				if bool(rres["ok"]):
					logs.append({"day": int(s["day"]), "kind": "invest", "text": String(rres["text"])})
			"move_research":
				_move_research(String(action["id"]), int(action.get("delta", 0)))
			_:
				pass
	return logs

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
		var def_id := String(shop["defId"])
		for g in (recipe["inputs"] as Dictionary).keys():
			var q = float(recipe["inputs"][g])
			if q > 0.0:
				s["goods"][g] = float(s["goods"].get(g, 0.0)) - q * batches
				s["reserved"][g] = maxf(0.0, float(s["reserved"].get(g, 0.0)) - q * batches)
				lt["consumed"][g] = _r4(float(lt["consumed"].get(g, 0.0)) + q * batches)
				# 台账的**来源拆分**（哪个建筑吃掉了它）：面板 tooltip 直接读这张表，
				# 所以必须在真正扣料的这一处累加（用户 2026-10："面粉都是面包房消耗"）。
				_ledger_add_by(lt, "consumedBy", String(g), def_id, q * batches)
		var fuel = float(recipe.get("fuel", 0.0))
		if fuel > 0.0:
			s["goods"]["firewood"] = float(s["goods"].get("firewood", 0.0)) - fuel * batches
			s["reserved"]["firewood"] = maxf(0.0, float(s["reserved"].get("firewood", 0.0)) - fuel * batches)
			lt["consumed"]["firewood"] = _r4(float(lt["consumed"].get("firewood", 0.0)) + fuel * batches)
			_ledger_add_by(lt, "consumedBy", "firewood", def_id, fuel * batches)
		# 只放大**产出**，投入（上面几段）完全不动 —— 这就是"虚空产量"。
		# 倍率 = 工具（+25%）× 该产业的效率科技加成（见 tech_bonuses()），两者相乘。
		var boost = _shop_tool_boost(shop) * _sector_output_boost(shop)
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
#      超了就在日终结算时把货丢掉 —— **每种物资按同一比例削减**（见 §3.3）。
#   2. **每种物资的软上限**（玩家逐项设置，缺项 = 不限）。先按它修剪，再按全局
#      上限修剪：某一种货囤满自己的额度后就不再挤占全局空间。
#
# 两步都在 `_apply_spoilage` **之后**：先损耗、后判上限 —— 损耗腾出来的空间
# 可以救下本来会被丢掉的货。
#
# ⚠️ 2026-10 改：全局那一步原来是**按 `baseValue` 升序丢**（先丢便宜的）。
# 那条规则有个致命副作用 —— **食物恰好是最便宜的**（蔬菜 1.2 / 粗面包 1.3），
# 于是「开局资源 x2」（1960 > 容量 1000）第一晚就把 400 粗面包 + 174.6 蔬菜全丢了，
# 剩下的全是木材/石块/砖，接下来几天饿死一半人。用户原话：「怎么能先盯着食物
# 丢弃，应该是各种物资平均丢弃吧。」现在改成**同比例削减**。
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

## 向下取整到两位小数（与 TS `storage.ts::floor2` 同构）。
func _floor2(v: float) -> float:
	return floor(v * 100.0) / 100.0

func _good_name(gid: String) -> String:
	var g = db.goods.get(gid, null)
	return String(g["nameZh"]) if g != null else gid

## 日终丢弃。返回日志（调用方并进当日 logs）。见 docs/town.md §3.3。
##
## ⚠️ 在建工程的材料在**工作小时**开工时（`_apply_construction_hours`）就已经从
## `goods` 扣走了，而它在夜晚顺序里排在日终丢弃之前 —— 所以不会出现
## 「把工地材料丢了导致工地卡死」。
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

	# ② 全局总量上限：**每种物资按同一比例削减**（确定性：一次乘 + 一次向下取整）
	var cap = storage_capacity()
	var total = stored_total()
	if cap > 0.0 and total > cap:
		var keep = cap / total
		var after := 0.0
		for gid in _pack()["goods"]:
			var cur = float(s["goods"].get(gid, 0.0))
			if cur <= 0.0:
				continue
			var nxt = _floor2(cur * keep)
			s["goods"][gid] = nxt
			after += nxt
		logs.append({"day": day, "kind": "storage",
			"text": "仓储超限（%s / %s）：所有物资按 %s%% 削减，共丢弃 %s 单位" % [
				_num_str(SimUtil.r2(total)), _num_str(SimUtil.r2(cap)),
				_num_str(SimUtil.r2(keep * 100.0)), _num_str(SimUtil.r2(total - after))]})
	return logs

## 数字转文本：对齐 JS 模板字符串里数字的呈现（整数不带 ".0"）。
func _num_str(v: float) -> String:
	if is_finite(v) and v == floor(v) and absf(v) < 1000000000000000.0:
		return str(int(v))
	return str(v)

func _good_value(gid: String, qty: float) -> float:
	var g = db.goods.get(gid, null)
	return (float(g["baseValue"]) if g != null else 0.0) * qty

## 商品的基准价；该 id 不在 `db.goods` 里时返回 `fallback`。
##
## ⚠️ 存在的唯一理由：GDScript 的 `Dictionary.get(k, 默认值)` **不短路**（与 TS 的 `??` 不同），
## 默认值总会被求值。住房 2026-10 起不再是商品，所以凡是"住房 id 取价格、缺项回退到商品基准价"
## 的地方都必须先把这个回退值算出来 —— 写成 `db.goods[gid]["baseValue"]` 会当场 KeyError。
func _base_value_or(gid: String, fallback: float = 1.0) -> float:
	var g = db.goods.get(gid, null)
	return float(g["baseValue"]) if g != null else fallback

# ===========================================================================
# 用工
# ===========================================================================
func _assigned_workers(shop_id: String) -> int:
	var n = 0
	for r in s["residents"]:
		if r.get("jobShopId", null) == shop_id:
			n += 1
	return n

## 在岗工人明细，供检视面板的「员工」段显示：
##   `[{ "id": "res#7", "skill": 62.0, "wage": 2.74 }, ...]`
##
## `wage` = 这个人**当日从本店拿到的毛工资**（含熟练度加成与工资上限），走的就是
## `_worker_gross_wage()` —— 与 `_pay_wages()` 共用同一个函数，所以面板上写的数
## 和晚上实际发的钱**不可能对不上**。名字由表现层用 `Names.for_id(id)` 生成（视图层的事）。
func shop_workers(shop_id: String) -> Array:
	var out := []
	var shop = _find_shop(shop_id)
	if shop == null:
		return out
	for r in s["residents"]:
		if String(r.get("jobShopId", "")) != shop_id:
			continue
		out.append({
			"id": String(r["id"]),
			"skill": float(r["skill"]),
			"wage": SimUtil.r2(_worker_gross_wage(shop, r)),
		})
	return out

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

## 一个在岗工人当日的**毛工资**：
##   工资 × (skillIncomeBase + min(skillMax, 熟练度) / 100)，再夹到本店工资上限。
##
## ⚠️ `_pay_wages()` 与检视面板的「员工」段**必须共用这一个函数** —— 否则面板上写的
## 工资和晚上实际发出去的钱会悄悄分叉（熟练度那一段最容易写歪）。
func _worker_gross_wage(shop: Dictionary, r: Dictionary) -> float:
	var base = float(db.economy["skillIncomeBase"]) + minf(float(db.economy["skillMax"]), float(r["skill"])) / 100.0
	var gross = float(shop["wage"]) * base
	var cap = float(shop["wageCap"])
	if cap > 0.0:
		gross = minf(gross, cap)
	return gross

func _pay_wages(day: int) -> Array:
	var brackets: Array = s["government"]["taxBrackets"]

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
			var shop = _find_shop(String(r["jobShopId"]))
			if shop != null:
				gross = _worker_gross_wage(shop, r)
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
#
# ⚠️ 2026-10 起住房有**单体身份**：`s["housingUnits"]` 一栋一个条目
# （`{id: "h#N", type, private, ownerId?}`），而 `s["housing"]` / `s["privateHousing"]`
# 变成**派生计数**（`_sync_housing_counts()` 从 units 重算）。
# 容量 / 租金 / 任务 / 黄金摘要继续读计数，行为不变；但"哪一栋在改建 / 哪一栋被买下"
# 现在都指到具体那一栋（`housing_upgrade` 条目带 `housingUnitId`）。
# 两个引擎同口径（TS 侧 `systems/housing.ts`）。
# ===========================================================================

## 从 units 重算 `housing` / `privateHousing`。**任何**增删房 / 改建 / 私有化之后都要调。
func _sync_housing_counts() -> void:
	for gid in s["housing"].keys():
		s["housing"][gid] = 0.0
	for gid in s["privateHousing"].keys():
		s["privateHousing"][gid] = 0.0
	for u in s["housingUnits"]:
		var t := String(u["type"])
		if not s["housing"].has(t):
			s["housing"][t] = 0.0
		if not s["privateHousing"].has(t):
			s["privateHousing"][t] = 0.0
		s["housing"][t] = float(s["housing"][t]) + 1.0
		if bool(u.get("private", false)):
			s["privateHousing"][t] = float(s["privateHousing"][t]) + 1.0

## 新建一栋房（发号 `h#N`，单调、不回收）。
func _add_housing_unit(good_id: String, private: bool = false, owner_id: String = "") -> Dictionary:
	s["housingSeq"] = int(s.get("housingSeq", 0)) + 1
	var unit := {"id": "h#%d" % int(s["housingSeq"]), "type": good_id, "private": private}
	if owner_id != "":
		unit["ownerId"] = owner_id
	(s["housingUnits"] as Array).append(unit)
	_sync_housing_counts()
	return unit

func _housing_unit(unit_id: String) -> Variant:
	for u in s["housingUnits"]:
		if String(u["id"]) == unit_id:
			return u
	return null

## 调试 / 测试 / 截图工具用：把某房型的**栋数**改成 n（增删 units，计数自动重算）。
##
## ⚠️ 正式玩法不许调它 —— 增删房只走 `_add_housing_unit()` / 改建 / 私有化。
## 存在的理由：以前大家直接写 `s["housing"]["hut"] = 8`，而现在那两个是**派生计数**，
## 直接写会在下一次 `_sync_housing_counts()` 被抹掉（而且和 units 打架）。
func debug_set_housing_units(good_id: String, n: int) -> void:
	var cur := 0
	for u in s["housingUnits"]:
		if String(u["type"]) == good_id:
			cur += 1
	while cur < n:
		_add_housing_unit(good_id)
		cur += 1
	while cur > n:
		var removed := false
		for i in range((s["housingUnits"] as Array).size() - 1, -1, -1):
			var u2: Dictionary = (s["housingUnits"] as Array)[i]
			if String(u2["type"]) == good_id and not bool(u2.get("private", false)):
				(s["housingUnits"] as Array).remove_at(i)
				removed = true
				break
		if not removed:
			break
		cur -= 1
	_sync_housing_counts()

## 第一栋**国有**的同房型房（私有住房市场卖的是这个）。
func _first_state_housing_unit(good_id: String) -> Variant:
	for u in s["housingUnits"]:
		if String(u["type"]) == good_id and not bool(u.get("private", false)):
			return u
	return null

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
		var price = float(s["prices"].get(gid, def.get("salePrice", _base_value_or(gid))))
		if price <= 0.0:
			continue
		var sold = 0
		while sold_total < per_day:
			# 卖的是**具体某一栋**（国有、还没被买走的）
			var unit = _first_state_housing_unit(gid)
			if unit == null:
				break
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
			buyer["ownedUnitId"] = String(unit["id"])
			s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) + price)
			unit["private"] = true
			unit["ownerId"] = String(buyer["id"])
			sold += 1
			sold_total += 1
		if sold > 0:
			logs.append({"day": day, "kind": "invest", "text": "%d 户购买私有住房（¥%.0f/户）" % [sold, price]})
	_sync_housing_counts()
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
					# 台账的**阶层拆分**（哪一等居民买走了它）—— 面板 tooltip 直接读
					# （用户 2026-10："中产 x11 消耗多少资源"）。
					_ledger_add_by(s["ledgerToday"], "boughtBy", String(target),
						String(r["classId"]), sold, 2)
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

# ---------------------------------------------------------------------------
# 只读访问器（给 AI 辅助 `scripts/sim/advisor.gd` 与表现层用）
#
# 这三个数本来就有私有实现，这里只是**开个门**：AI 辅助要拿它们去算"缺不缺"，
# 与其让 advisor 去戳 `_housing_capacity()` 这种下划线函数，不如明写一行。
# **它们不改状态**，加进来对黄金轨迹零影响（迁移契约不变）。
# ---------------------------------------------------------------------------
func housing_capacity() -> int:
	return _housing_capacity()

func private_capacity() -> int:
	return _private_capacity()

func job_capacity() -> int:
	return _job_capacity()

# ---------------------------------------------------------------------------
# 预言家（AI 辅助）的冷却 —— 见 docs/ai-assist.md §六
#
# 规则一句话：**问一次要隔 5 天**（用户 2026-10 定）。这是唯一一个"不参与仿真演化"
# 的状态段：问不问都不改村子的任何数值，它只是记账。所以：
#   · 不进命令队列（命令是**次日黎明生效**，而冷却必须当场生效）
#   · 但记在 `s["prophet"]` 里，于是退出重进、读档、改存档都绕不过去
#   · `mark_prophet_asked()` 是这一层**唯一**的写状态入口（表现层调它，不直接写 s）
# ---------------------------------------------------------------------------

## 问一次预言家要隔几天。
const PROPHET_COOLDOWN_DAYS := 5

## 还要等几天才能再问（0 = 现在就能问）。没问过 = 0。
func prophet_days_left() -> int:
	var last := int((s.get("prophet", {}) as Dictionary).get("lastAskDay", -1))
	if last < 0:
		return 0
	return maxi(0, last + PROPHET_COOLDOWN_DAYS - int(s["day"]))

func can_ask_prophet() -> bool:
	return prophet_days_left() <= 0

## 记一次"问到了"（冷却从**这一天**起算），并把这回的问答存进历史。
## ⚠️ 由表现层在**拿到回答之后**调（失败 / 正在问都不算），并且只作用于这一条账。
##
## `answer` 为空 = 只记冷却、不记历史（门槛与截图工具会这么调）。
## `charge_cooldown = false` = **不占冷却**（用户 2026-10：第一章收尾瑟拉菲娜自己送的那次
## 「免费预言」）。历史照记（玩家回头能翻），只是不罚 5 天。
## ⚠️ 历史**只在真的有回答时才写键** —— 新开局的状态里没有 `log`，
## 这样黄金轨迹的摘要素一个字节都不会变（见 `prophecy_log()` 的注释）。
func mark_prophet_asked(q: String = "", answer: String = "", charge_cooldown: bool = true) -> void:
	var p: Dictionary = s.get("prophet", {})
	if charge_cooldown:
		p["lastAskDay"] = int(s["day"])
	if answer.strip_edges() != "":
		var log: Array = p.get("log", [])
		log.append({"d": int(s["day"]), "q": q, "t": answer})
		# 上限 30 条：够玩家翻回去看，又不至于让存档无限长
		while log.size() > PROPHECY_LOG_MAX:
			log.pop_front()
		p["log"] = log
	s["prophet"] = p

## 历史预言的上限（条）
const PROPHECY_LOG_MAX := 30

## 历史预言（只读）。每条 = `{d: 第几天, q: 问话, t: 她说的原文}`，旧的在前面。
## ⚠️ 没问过时**连这个键都没有** —— 返回空数组，但状态本身保持"和黄金轨迹一致"。
func prophecy_log() -> Array:
	return (s.get("prophet", {}) as Dictionary).get("log", [])

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
	# ⚠️ `housing_upgrade` 是"原地改建"：改完 housing[from]−1 / housing[to]+1，总栋数不变，
	#    所以它**不能**算成一个新名额（否则改建一次就白白吃掉一格土地）。
	for c in s["construction"]:
		if String(c["kind"]) != "upgrade" and String(c["kind"]) != "housing_upgrade":
			n += 1
	for gid in s["housing"].keys():
		n += int(floor(float(s["housing"][gid])))
	return n

## 住房**改建**（见 docs/spec.md §5.4）的差价材料与工期。与 TS 的 `housingUpgradeSpec()`
## 必须同口径（门槛 `housingupgrade` 会拿真实数字对拍）：
##   材料 = 对目标房型 buildCost 的每一项取 max(0, 目标 − 原房型)，只认当前包里的商品；
##   工期 = max(1, 目标 buildWork − 原房型 buildWork)。
func _housing_upgrade_spec(from_def: Dictionary, to_def: Dictionary) -> Dictionary:
	var mats := []
	var good_set = _good_set()
	var to_cost: Dictionary = to_def.get("buildCost", {})
	var from_cost: Dictionary = from_def.get("buildCost", {})
	for gid in to_cost.keys():
		var q = float(to_cost[gid])
		if q <= 0.0 or not good_set.has(gid):
			continue
		var diff = SimUtil.r2(q - float(from_cost.get(gid, 0.0)))
		if diff > 0.0:
			mats.append([gid, diff])
	var work = maxf(1.0, SimUtil.r2(float(to_def["buildWork"]) - float(from_def["buildWork"])))
	return {"mats": mats, "money": 0.0, "work": work}

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
	if kind == "housing_upgrade":
		var f = String(c.get("housingId", ""))
		var t = String(c.get("toHousingId", ""))
		if not db.housing.has(f) or not db.housing.has(t):
			return {}
		var spec: Dictionary = _housing_upgrade_spec(db.housing[f], db.housing[t])
		return {"mats": spec["mats"], "money": 0.0}
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
	if kind == "housing_upgrade":
		var hf = String(c.get("housingId", ""))
		var ht = String(c.get("toHousingId", ""))
		var n1 = String(db.housing[hf]["nameZh"]) if db.housing.has(hf) else hf
		var n2 = String(db.housing[ht]["nameZh"]) if db.housing.has(ht) else ht
		return "%s 改建（→ %s）" % [n1, n2]
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

## 住房改建：下单进施工队列（材料在开工时才扣）。见 docs/spec.md §5.4。
##
## ⚠️ 三条规矩（与 TS 的 `tryUpgradeHousing()` 一致）：
##   · **只允许国有住房**：私有住房是居民买下的私产（`HousingUnit.private` + 房主 ownedQuality），
##     改建的口径复杂且容易算乱（用户拍板：私有住房不能改建）；
##   · **在途的改建也算占用**：2 栋茅屋只能排 2 条改建 —— 否则完工时会凭空多出一栋木屋；
##   · **目标房型要已解锁**（和 `build_housing` 同一条规矩）。
##
## 2026-10 起**指名到栋**：条目里带 `housingUnitId`（`unit_id` 指定，不指定就挑最早那栋
## 可改建的）。完工时换那栋的 `type`，**id 不变** —— 于是"哪一栋在改建"是确定的，
## 地图上的进度条不用再按顺序猜。
func _try_upgrade_housing(good_id: String, unit_id: String = "") -> void:
	if not _pack()["housing"].has(good_id):
		return
	if not db.housing.has(good_id):
		return
	var from_def: Dictionary = db.housing[good_id]
	var to_id = String(from_def.get("upgradeTo", ""))
	if to_id == "" or not db.housing.has(to_id):
		return	# 链尾（砖房）/ 别墅：不能改建
	if not is_housing_unlocked(to_id):
		return
	var target = _pick_upgradable_unit(good_id, unit_id)
	if target == null:
		return
	var spec: Dictionary = _housing_upgrade_spec(from_def, db.housing[to_id])
	var work = float(spec["work"])
	_order({
		"id": "c#%d-re-%s" % [s["construction"].size() + 1, good_id],
		"kind": "housing_upgrade", "buildingId": "", "shopId": "",
		"housingId": good_id, "toHousingId": to_id,
		"housingUnitId": String(target["id"]),
		"remaining": work, "totalRequired": work, "started": false,
	})

## 挑一栋可改建的房：国有（非私有）、房型对、且**没有**已经在改建队列里。
## `unit_id` 非空时指名那一栋（找不到 / 房型不对 / 私有 → 返回 null）。
## 与 TS `pickUpgradableUnit()` 同口径。
func _pick_upgradable_unit(good_id: String, unit_id: String = "") -> Variant:
	var busy := {}
	for c in s["construction"]:
		if String(c.get("kind", "")) == "housing_upgrade":
			var bid := String(c.get("housingUnitId", ""))
			if bid != "":
				busy[bid] = true
	if unit_id != "":
		for u in s["housingUnits"]:
			if String(u["id"]) != unit_id:
				continue
			if String(u["type"]) != good_id or bool(u.get("private", false)) or busy.has(unit_id):
				return null
			return u
		return null
	for u in s["housingUnits"]:
		if String(u["type"]) != good_id or bool(u.get("private", false)):
			continue
		if busy.has(String(u["id"])):
			continue
		return u
	return null

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
	# 效率科技（抄书房/学院/印刷术）：**整条速率**乘 (1 + 加成)。
	# 口径与 TS `researchRate()` 一致，见 docs/spec.md §10.1。
	rate *= 1.0 + float(tech_bonuses()["research"])
	return SimUtil.r2(rate)

func research_rate() -> float:
	## 供 UI 读取的当日科研力速率。
	return _research_rate()

func _research_shortage(tech: Dictionary) -> String:
	## 队首缺哪种材料（够则返回空串）；等待诊断的文案与判定只有这一份。
	for gid in (tech["cost"]["goods"] as Dictionary).keys():
		if float(s["goods"].get(gid, 0.0)) < float(tech["cost"]["goods"][gid]):
			return "%s 需 %s" % [gid, tech["cost"]["goods"][gid]]
	return ""

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
		# 队首是否正卡在材料上（等待诊断去重用；见 _apply_research_hours）
		"waiting": false,
	})

## 研究队列里 `id` 的下标（-1 = 不在队列里）。
func research_index(id: String) -> int:
	var q: Array = s["research"]["queue"]
	for i in q.size():
		if String(q[i]["id"]) == id:
			return i
	return -1

## 研究队列调序：按 `delta` 的方向挪**一位**（-1 上移 / +1 下移）。
## 与施工队列的 `_move_construction()` **同一套语义**：只改顺序 —— 不重算 `remaining`、
## 不改 `started`、不退料。已开工的被挪到后面时只是**暂停**（队首先吃到科研力）。
func _move_research(id: String, delta: int) -> Dictionary:
	var q: Array = s["research"]["queue"]
	var i := research_index(id)
	if i < 0:
		return {"ok": false, "reason": "不在研究队列中"}
	var step := signi(delta)
	if step == 0:
		return {"ok": false, "reason": "没有移动"}
	var j := i + step
	if j < 0:
		return {"ok": false, "reason": "已经是队首"}
	if j >= q.size():
		return {"ok": false, "reason": "已经是队尾"}
	var a = q[i]
	q[i] = q[j]
	q[j] = a
	return {"ok": true}

## 取消退料的**计算**部分（**只算不改状态**）—— 与施工的
## `construction_refund_preview()` 同一口径：
##   还没开工 → 一分原料都没扣过，退 0
##   已开工   → 退回量 = 已扣原料 × (remaining / totalRequired)
## 科研力**本身**不退（它是每日产能，不是库存）。
func research_cancel_preview(id: String) -> Dictionary:
	var q: Array = s["research"]["queue"]
	var i := research_index(id)
	if i < 0:
		return {"ok": false, "reason": "不在研究队列中", "index": -1, "started": false,
			"used": 0.0, "total": 0.0, "refund": [], "label": "", "text": ""}
	var p: Dictionary = q[i]
	var tech = db.techs.get(id, null)
	var label := String(tech["nameZh"]) if tech != null else id
	var total := float(p["totalRequired"])
	var used := maxf(0.0, total - float(p["remaining"]))
	var ratio := 0.0
	if bool(p["started"]) and total > 0.0:
		ratio = clampf(float(p["remaining"]) / total, 0.0, 1.0)
	var refund := []
	if tech != null:
		for gid in (tech["cost"]["goods"] as Dictionary).keys():
			var back := SimUtil.r2(float(tech["cost"]["goods"][gid]) * ratio)
			if back > 0.0:
				refund.append([gid, back])
	var text := ""
	if not bool(p["started"]):
		text = "取消研究「%s」（还没开工，材料没扣过）" % label
	else:
		var pct := 0 if total <= 0.0 else int(round(used / total * 100.0))
		var parts := []
		for r in refund:
			parts.append("%s×%s" % [_good_name(String(r[0])), SimUtil.r2(float(r[1]))])
		if parts.is_empty():
			text = "取消研究「%s」（已投入 %d%%），没有可退的材料" % [label, pct]
		else:
			text = "取消研究「%s」（已投入 %d%%），退回 %s" % [label, pct, "、".join(parts)]
	return {"ok": true, "index": i, "started": bool(p["started"]), "used": used,
		"total": total, "refund": refund, "label": label, "text": text}

## 取消研究（从队列移除 + **按进度退回原料**）。
## ⚠️ 口径与施工的撤单一致：材料是开工那一刻扣的 → 没开工退 0；开工了退还没干完的那份。
func _cancel_research(tid: String) -> Dictionary:
	var plan := research_cancel_preview(tid)
	if not bool(plan["ok"]):
		return plan
	for r in plan["refund"]:
		s["goods"][r[0]] = SimUtil.r2(float(s["goods"].get(r[0], 0.0)) + float(r[1]))
	(s["research"]["queue"] as Array).remove_at(int(plan["index"]))
	return plan

func _plan_research_day() -> void:
	## 黎明：钉死**当日科研力预算**。
	##
	## 为什么要有它（不是为了好看，是为了让"一天总量不变"有个**硬闸**）：
	## 科研进度是按"这一天投了多少"（`researchWorkToday`）抵着预算走的 ——
	## 没有这个数就只能靠"每小时都现算一次 `_research_rate()`"，而那要依赖
	## "同一天里 `shop["skill"]` 不变"（它只在黎明 `_assign_labor` 与入夜
	## `_grow_skills` 两处变）。多一条依赖就多一个将来会被改坏的地方，
	## 何况施工那边（`_plan_construction_day`）钉的是同一道预算，两边完全同构。
	##
	## 口径：**一天的预算 = 这一天黎明那一刻的 `_research_rate()`**，全天不变
	## （与"产能不结转、当天没用完即作废"同一精神）。
	s["researchWorkToday"] = 0.0
	s["researchRateToday"] = _research_rate()

func _apply_research_hours(fraction: float) -> Array:
	## 工作小时：把**固定的一份**科研力（`researchRateToday × fraction`）投入队首科技。
	##
	## 与 `_run_production_step` / `_apply_construction_hours` **同一节奏、同一条件**
	## （workStart <= h < workEnd，fraction = 1/工作小时数）。
	##
	## **每小时投入量是个常数**（`researchRateToday / 工作小时数`），**不是**"把队首
	## 剩下的需求摊到当天剩下的小时里"：队首只剩 5、日产能 12 时，就是每小时 1、
	## 走 5 个小时在**当天中途**跑完 —— 既不会 18:00 才跳完，也不会被压进一个小时。
	##
	## 队列语义（先进先出、串行）：
	##   队首未开工 → 先扣材料（**开工时刻 = 这一天第一个工作小时**，不是夜晚）；
	##   材料不足 → 停在队首等待，**不跳过**
	##   **队首中途跑完 → 这一小时剩下的产能继续投给下一条**（同小时、串行）：
	##   这是"一天总量 = 当天科研力"这个不变量成立的关键 —— 剩下的产能不许丢。
	##   队列空了就作废（**不结转到第二天**）
	## `remaining` 用 r4 累积：12 次 r2 会漂移（一天就不再恰好等于日产能）。
	## 「开始研究」只在 started 翻转时写一次；「等待材料」只在队首进入等待的那一刻
	## 写一条（p["waiting"] 去重），**不逐小时刷屏**。
	##
	## ⚠️ 完工**不在这里激活**：跑完后仍然留在队列里，等夜晚之后的黎明
	## `_activate_research` 才出队生效 —— 见 docs/spec.md §10.5。
	var logs := []
	# 这一个小时的产能：**常数**（当日科研力 × 1/工作小时数）。
	# 再拿当日累计兜一道底（同一小时被多调一次也不会多投），两道都不取整。
	var rate_today = float(s.get("researchRateToday", 0.0))
	var left = minf(rate_today * fraction, rate_today - float(s.get("researchWorkToday", 0.0)))
	if left <= 0.0:
		return logs
	for p in s["research"]["queue"]:
		# 产能用完了就停（队首跑完时从这里溢到下一条，不是 break）
		if left <= 0.0:
			break
		var tech = db.techs.get(String(p["id"]), null)
		if tech == null:
			break	# 科技定义缺失：这里不刷屏（与施工的 break 同口径）
		if not bool(p.get("started", false)):
			var gap := _research_shortage(tech)
			if gap != "":
				# 停在队首等待材料，**不跳过**。同一个"等待"只写一条日志
				#（白天每小时都会撞上同一个缺口；有 waiting 标志才不刷屏）
				if not bool(p.get("waiting", false)):
					p["waiting"] = true
					logs.append({"day": int(s["day"]), "kind": "invest",
						"text": "研究「%s」等待材料（%s）" % [tech["nameZh"], gap]})
				break
			for gid in (tech["cost"]["goods"] as Dictionary).keys():
				s["goods"][gid] = SimUtil.r2(float(s["goods"].get(gid, 0.0)) - float(tech["cost"]["goods"][gid]))
			p["started"] = true
			p["waiting"] = false
			logs.append({"day": int(s["day"]), "kind": "invest",
				"text": "开始研究「%s」（需科研力 %s）" % [tech["nameZh"], SimUtil.r2(float(p["totalRequired"]))]})
		var used = minf(left, float(p["remaining"]))
		p["remaining"] = maxf(0.0, _r4(float(p["remaining"]) - used))
		left = _r4(left - used)
		s["researchWorkToday"] = _r4(float(s.get("researchWorkToday", 0.0)) + used)
	return logs

func _settle_research(day: int) -> Array:
	## 夜晚：研究的**收尾**（科研力已经在工作小时里按小时投完了，见 _apply_research_hours）。
	##
	## 只做一件事：队首为什么没动 —— 写一条诊断（每天最多一条）。
	## 白天每小时都可能撞上材料不足，日志若写在小时里会刷屏，所以挪到这里，
	## 与施工的 _settle_construction 同一套口径（见 docs/spec.md §9.4 / §10.4）。
	var logs := []
	# 科研力为 0 时队首本来就没机会开工（不是材料的问题）：不写诊断，与施工同口径
	if _research_rate() <= 0.0:
		return logs
	var q: Array = s["research"]["queue"]
	if q.is_empty():
		return logs
	var p: Dictionary = q[0]
	var tech = db.techs.get(String(p["id"]), null)
	if tech == null:
		return logs
	# 队首已经跑完（在等黎明生效）：今天的科研力是被它正常吃掉的，不是卡住
	if bool(p.get("started", false)) and float(p["remaining"]) <= 0.0:
		return logs
	var gap := _research_shortage(tech)
	if gap != "":
		logs.append({"day": day, "kind": "invest",
			"text": "研究「%s」等待材料（%s）" % [tech["nameZh"], gap]})
	return logs

func _activate_research() -> Array:
	## ⚠️ 这里是**扫全队列**取走 `remaining <= 0` 的（与施工的 `_activate_completed` 同形制），
	## 不是老版本的"只看队首"：队列本身先进先出，正常玩只有队首能跑完；但**调序**能把一条
	## 跑完的挪到后面 —— 只认队首的话它要等再次轮到才生效，玩家会看到"完成了却没解锁"。
	var logs := []
	var remaining := []
	for item in (s["research"]["queue"] as Array):
		if float(item["remaining"]) > 0.0:
			remaining.append(item)
			continue
		s["research"]["done"].append(String(item["id"]))
		var tech = db.techs.get(String(item["id"]), null)
		logs.append({"day": int(s["day"]), "kind": "invest",
			"text": "研究完成：%s" % (String(tech["nameZh"]) if tech != null else String(item["id"]))})
	s["research"]["queue"] = remaining
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
			# 台账拆分表：工具是被**这栋建筑**吃掉的（资源页的悬停明细读它）
			_ledger_add_by(s["ledgerToday"], "consumedBy", gid,
				String(shop["defId"]), need)
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

## 已研究科技的效率加成，五个键：agri / goods / material（产出）、research、build。
##
## ⚠️ **加法**叠加（+10% +15% +20% = +45%），不是连乘 —— 连乘后期滚雪球，
## 而且玩家在面板上没法一眼算出"我现在是多少"。口径与 TS `techBonuses()` 一致，
## 契约见 docs/spec.md。
func tech_bonuses() -> Dictionary:
	var out := {"agri": 0.0, "goods": 0.0, "material": 0.0, "research": 0.0, "build": 0.0}
	for tid in (s["research"]["done"] as Array):
		var t = db.techs.get(String(tid), null)
		if t == null:
			continue
		for k in (t.get("effects", {}) as Dictionary).keys():
			var key := String(k)
			if out.has(key):
				out[key] = float(out[key]) + float(t["effects"][k])
	return out

## 某座商店的**产业**产出加成：1 + tech_bonuses()[该建筑的 sector]。
## 建筑没写 sector（无配方建筑）就返回 1。
func _sector_output_boost(shop: Dictionary) -> float:
	var def = db.buildings.get(shop["defId"], null)
	if def == null:
		return 1.0
	var sec := String(def.get("sector", ""))
	if sec == "":
		return 1.0
	return 1.0 + float(tech_bonuses().get(sec, 0.0))

## 本店今日的**制造加成**，拆成两项给检视面板显示：
##   `{ "total": 1.78, "tool": 1.25, "tech": 1.42 }`（`total = tool × tech`）
##
## 两项的来源：`tool` = 黎明分配的工具（`shop.toolBoost`，见 `_allocate_tools`），
## `tech` = 本产业效率科技（见 `_sector_output_boost`）。它**只放大产出**、不放大投入
## （docs/spec.md §2.2 的"虚空产量"）。只读入口 —— 公式本体仍在这两个私有函数里，
## 表现层不许自己算（见 godot/AGENTS.md 分层）。
func shop_output_boost(shop_id: String) -> Dictionary:
	var shop = _find_shop(shop_id)
	if shop == null:
		return {"total": 1.0, "tool": 1.0, "tech": 1.0}
	var tool = _shop_tool_boost(shop)
	var tech = _sector_output_boost(shop)
	return {"total": tool * tech, "tool": tool, "tech": tech}

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
	# 效率科技（起重架/脚手架/预制件）：**整条速率**乘 (1 + 加成)。见 docs/spec.md §9.1。
	rate *= 1.0 + float(tech_bonuses()["build"])
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

func _plan_construction_day() -> void:
	## 黎明：钉死**当日建造力预算**。
	##
	## 为什么要有它（与 _plan_research_day 是同一道闸，不是为了好看）：
	## 施工的账是按"这一天投了多少"（constructionWorkToday）记的，如果每个工作小时
	## 都现算一次 _construction_rate()，"一天总量 = 当日建造力"这件事就押在
	## "同一天里 _construction_rate() 不变"这个**隐含前提**上 —— 而它取决于失业人口
	## 与建筑工坊的在岗人数（黎明 _assign_labor 之外，任何中途的人事变动都会当场
	## 改变现算值，当天的总量就不再是"今天有多少建造力"）。
	## 钉死之后，"当天的总量恰好等于黎明那一刻的建造力"是一条**硬闸**，没有隐含前提。
	##
	## 口径：**一天的预算 = 这一天黎明那一刻的 _construction_rate()**，全天不变
	## （与"产能不结转、当天没用完即作废"同一精神）。
	s["constructionWorkToday"] = 0.0
	s["constructionRateToday"] = _construction_rate()

func _apply_construction_hours(fraction: float) -> Array:
	## 工作小时：把**固定的一份**建造力（constructionRateToday × fraction）投入队首工程。
	##
	## 与 `_run_production_step` **同一节奏、同一条件**（workStart <= h < workEnd，
	## fraction = 1/工作小时数），所以"一天 = 当日建造力（黎明钉住的值）"这个总量不变，
	## 只是摊平到工作小时里 —— 工地上白天能看见进度在爬。
	##
	## **每小时投入量是个常数**（constructionRateToday / 工作小时数），起手就不现算
	## _construction_rate()：当天中途的人事变动（在岗人数 / 失业人口）不会动摇今天的量。
	##
	## 队列语义与从前逐字一致（先进先出、串行）：
	##   队首未开工 → 先扣材料（**开工时刻 = 这一天第一个工作小时**）；
	##   材料不足 → 停在队首等待，**不跳过**
	##   产能没用完就溢给下一个工程；产能耗尽即停止
	## `remaining` 用 r4 累积：12 次 r2 会漂移（一天就不再恰好等于 constructionRate）。
	## 「等待材料」的诊断留给夜晚（_settle_construction，每天最多一条），这里不刷屏。
	var logs := []
	# rate 是「这一个小时里的产能」：**黎明钉住的当日预算** × 这一份，不取整
	# （取整会让工作小时加起来不等于日产能），只有落进状态的两处
	# （remaining / 当日累计）用 r4。
	# ⚠️ 用 .get(..., 0.0) 而不是裸读：旧存档（或手搓的状态）没有这个键时，
	# 裸读会直接抛 "Invalid access to property or key"（不是静默兜 0），
	# 白天就再也投不出建造力。
	var rate = float(s.get("constructionRateToday", 0.0)) * fraction
	var work = 0.0
	for c in s["construction"]:
		if rate <= 0.0:
			break
		if not bool(c.get("started", false)):
			var spec = _cost_of(c)
			if spec.is_empty():
				break
			if not _can_afford(spec):
				break
			_pay_cost(spec)
			c["started"] = true
			logs.append({"day": int(s["day"]), "kind": "invest",
				"text": "%s 开工（需建造力 %s）" % [_label_of(c), SimUtil.r2(float(c["totalRequired"]))]})
		var used = minf(rate, float(c["remaining"]))
		c["remaining"] = _r4(float(c["remaining"]) - used)
		rate -= used
		work += used
	# 当日累计投入：入夜时一次性折成「工地出工」（_mark_construction_workers）
	s["constructionWorkToday"] = _r4(float(s.get("constructionWorkToday", 0.0)) + work)
	return logs

func _settle_construction(day: int) -> Array:
	## 夜晚：施工的**收尾**（产能已经在工作小时里按小时投完了，见 _apply_construction_hours）。
	##
	## 只做两件事：
	##   1. 队首为什么没动 —— 写一条诊断（每天最多一条）。白天每小时都可能撞上材料不足，
	##      日志若写在小时里会刷屏，所以挪到这里。
	##      诊断对象是**第一条未开工**的工程，且它前面不能有"已开工但没干完"的工程
	##      （那说明产能是被前面的工程正常吃掉的，不是卡住）
	##   2. 把当日累计投入的建造力折成「工地出工」的失业人口（建造工资，在 _pay_wages 之前）
	var logs := []
	# 产能为 0 时队首本来就没机会开工（不是材料的问题），与旧口径一致：不写诊断
	if _construction_rate() > 0.0:
		var blocked = null
		for c in s["construction"]:
			if not bool(c.get("started", false)):
				blocked = c	# 卡住的是**第一条未开工**的工程
				break
			# 前面那几条已开工、还没干完 —— 今天的产能是被它们吃掉的，不是材料的问题，
			# 别误报"等待材料"（旧口径：产能耗尽就先 break 了，根本走不到后面那条）
			if float(c["remaining"]) > 0.0:
				break
		if blocked != null:
			var spec = _cost_of(blocked)
			if spec.is_empty():
				logs.append({"day": day, "kind": "invest", "text": "%s 定义缺失，施工停摆" % _label_of(blocked)})
			elif not _can_afford(spec):
				logs.append({"day": day, "kind": "invest", "text": "%s 等待材料（%s）" % [_label_of(blocked), _shortage_reason(spec)]})
	_mark_construction_workers(float(s.get("constructionWorkToday", 0.0)))
	s["constructionWorkToday"] = 0.0
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
			_add_housing_unit(hid)
			logs.append({"day": int(s["day"]), "kind": "invest", "text": "建成住房"})
		elif kind == "housing_upgrade":
			# 原地改建：**那一栋**换房型，id 不变、栋数不变（土地名额因此也不变，见 _used_slots）。
			var hfrom = String(c.get("housingId", ""))
			var hto = String(c.get("toHousingId", ""))
			if hfrom != "" and hto != "":
				var uid := String(c.get("housingUnitId", ""))
				var unit = _housing_unit(uid) if uid != "" else null
				if unit == null:
					# 老存档 / 手工构造的条目没有房号：退化成"换一栋"（栋数不变）
					unit = _pick_upgradable_unit(hfrom)
				if unit != null:
					unit["type"] = hto
					_sync_housing_counts()
				var nf = String(db.housing[hfrom]["nameZh"]) if db.housing.has(hfrom) else hfrom
				var nt = String(db.housing[hto]["nameZh"]) if db.housing.has(hto) else hto
				logs.append({"day": int(s["day"]), "kind": "invest",
					"text": "%s 改建为 %s" % [nf, nt]})
	s["construction"] = remaining
	return logs

# ---------------------------------------------------------------------------
# 建造队列：调序 / 取消（与 TS 的 `moveConstruction()` / `cancelConstruction()` 同口径）
#
# 队列本来就是**先进先出**的一条 `s["construction"]`：队首（index 0）先开工、产能没用完
# 才溢给下一条。以前玩家只能下单、**没法改顺序**；这两条把队列变成可管理的。
#
# ⚠️ 调序只改"谁先吃到建造力"：不重算 `remaining`、不改 `started`、不退料。已经在建的
#    工程被挪到后面时只是**暂停**（前面的工程先吃产能）。见 docs/construction.md 六。
# ---------------------------------------------------------------------------

## 施工队列里 `id` 这条的下标（-1 = 不在队列里）。
func construction_index(id: String) -> int:
	var list: Array = s["construction"]
	for k in list.size():
		if String(list[k]["id"]) == id:
			return k
	return -1

## 调序：把 `id` 这条按 `delta` 的方向挪**一位**（-1 上移 / +1 下移）。
func _move_construction(id: String, delta: int) -> Dictionary:
	var list: Array = s["construction"]
	var i := construction_index(id)
	if i < 0:
		return {"ok": false, "reason": "该工程已不在队列里"}
	var step := signi(delta)
	if step == 0:
		return {"ok": false, "reason": "没有移动"}
	var j := i + step
	if j < 0:
		return {"ok": false, "reason": "已经是队首"}
	if j >= list.size():
		return {"ok": false, "reason": "已经是队尾"}
	var a = list[i]
	list[i] = list[j]
	list[j] = a
	return {"ok": true}

## 取消退料的**计算**部分（**只算不改状态**）—— 口径与 TS 的 `planCancel()` 逐字一致：
##   还没开工 → 一分钱都没扣过，退 0（材料原地不动）
##   已开工   → 退回量 = 已扣材料 × (remaining / totalRequired)（只退没干完的那一份）
## 建造力**本身**不退 —— 它是每日产能，不是库存（与 demolish 同口径）。
##
## 拆成"算"与"落地"两半是为了 UI 的二次确认：点第一下要先看到"会退回什么"。
func construction_refund_preview(id: String) -> Dictionary:
	var list: Array = s["construction"]
	var i := construction_index(id)
	if i < 0:
		return {"ok": false, "reason": "该工程已不在队列里", "index": -1, "started": false,
			"used": 0.0, "total": 0.0, "refund": [], "money": 0.0, "label": "", "text": ""}
	var c: Dictionary = list[i]
	var spec: Dictionary = _cost_of(c)
	var label := _label_of(c)
	var total := float(c["totalRequired"])
	var used := maxf(0.0, total - float(c["remaining"]))
	var ratio := 0.0
	if bool(c["started"]) and total > 0.0:
		ratio = clampf(float(c["remaining"]) / total, 0.0, 1.0)
	var refund := []
	var money := 0.0
	if not spec.is_empty():
		for m in spec["mats"]:
			var back := SimUtil.r2(float(m[1]) * ratio)
			if back > 0.0:
				refund.append([m[0], back])
		if float(spec["money"]) > 0.0:
			money = SimUtil.r2(float(spec["money"]) * ratio)
	var text := ""
	if not bool(c["started"]):
		text = "取消「%s」（还没开工，材料没扣过）" % label
	else:
		var pct := 0 if total <= 0.0 else int(round(used / total * 100.0))
		var parts := []
		for r in refund:
			parts.append("%s×%s" % [_good_name(String(r[0])), SimUtil.r2(float(r[1]))])
		if money > 0.0:
			parts.append("¥%s" % SimUtil.r2(money))
		if parts.is_empty():
			text = "取消「%s」（已投入 %d%%），没有可退的材料" % [label, pct]
		else:
			text = "取消「%s」（已投入 %d%%），退回 %s" % [label, pct, "、".join(parts)]
	return {"ok": true, "index": i, "started": bool(c["started"]), "used": used,
		"total": total, "refund": refund, "money": money, "label": label, "text": text}

## 落地：把预览里算出来的退料并进国库，再把这条从队列里摘掉。
func _cancel_construction(id: String) -> Dictionary:
	var plan := construction_refund_preview(id)
	if not bool(plan["ok"]):
		return plan
	for r in plan["refund"]:
		s["goods"][r[0]] = SimUtil.r2(float(s["goods"].get(r[0], 0.0)) + float(r[1]))
	if float(plan["money"]) > 0.0:
		s["government"]["money"] = SimUtil.r2(float(s["government"]["money"]) + float(plan["money"]))
	(s["construction"] as Array).remove_at(int(plan["index"]))
	return plan

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

# ===========================================================================
# 任务（引导系统）—— 契约见 docs/quests.md；TS 侧 src/engine/systems/quests.ts
#
# 四条要点（与 TS 逐条同口径）：
#   1. 任务 = 一组对**当前状态**的只读谓词（goals 全为真 = 完成），不接"提交"
#   2. 判定 + 发钱都在**黎明**（_run_dawn 末尾）—— 玩家先干了、任务后出现照样算完成
#   3. 渐进显示：requires 没全完成的任务**看不见**（quest_view() 不返回它）
#   4. 显示文案由**引擎**拼（quest_view 里的 text），UI 不要自己拼 —— 两边必须一模一样
# ===========================================================================

## 城镇中心的三段状态（用户 2026-10：第三章先「初步修缮」，第四章再「修缮」）。
##   ruined   开局：塌了半边（`town_center_ruined.png`）
##   patched  初步修缮：还立着，裂着、爬着藤（`town_center_patched.png`）
##   restored 修好（`town_center.png`）
const TOWN_CENTER_STAGES := ["ruined", "patched", "restored"]
## 初步修缮与彻底修缮的用料。**唯一一份**：判定够不够、面板上列材料、TS 侧
## `investment.ts` 都是这个数。
## ⚠️ 内容里两条任务 `hint` 写的数字是**文字**，改价只能人肉对齐
## （`check-quests.ts` 有两条把两边钉死的断言）。
const TOWN_CENTER_PATCH_COST := {"wood": 20.0, "stone": 10.0}
const TOWN_CENTER_REPAIR_COST := {"wood": 30.0, "stone": 20.0, "brick": 15.0}

## 现在到哪一段了（`ruined` / `patched` / `restored`）。
## 兼容老状态：老存档只有 `{ruined: bool}` → 据此换算。
func town_center_stage() -> String:
	var tc: Dictionary = s.get("townCenter", {})
	var st := String(tc.get("stage", ""))
	if TOWN_CENTER_STAGES.has(st):
		return st
	return "restored" if not bool(tc.get("ruined", true)) else "ruined"

## 这一步的用料（UI 读它画材料行，不要自己再抄一份）。
## `stage` = 要走到的目标段：`patched` / `restored`。
func town_center_repair_cost(stage: String = "") -> Dictionary:
	var to := stage if stage != "" else ("patched" if town_center_stage() == "ruined" else "restored")
	if to == "patched":
		return TOWN_CENTER_PATCH_COST.duplicate()
	return TOWN_CENTER_REPAIR_COST.duplicate()

## 这一步能不能走（顺序是硬闸：ruined → patched → restored，不能跳级）。
func can_repair_town_center(stage: String) -> bool:
	var cur := town_center_stage()
	if stage == "patched":
		return cur == "ruined"
	if stage == "restored":
		return cur == "patched"
	return false

## `building_repaired` 的 id 归一：内容里写的是口语名 `townhall`，
## 建筑表里叫 `town_center`。两个写法都认，统一成建筑表里那个（用于取中文名）。
## 与 TS `quests.ts::repairTargetBuilding` 同表。
func _repair_target_building(id: String) -> String:
	return "town_center" if id == "townhall" else id

## 这座"塌了的"建筑**达到要求的段位**了吗（目前只有城镇中心这一座）。
func _quest_repaired(id: String, want_stage: String = "restored") -> bool:
	if _repair_target_building(id) != "town_center":
		return false
	var cur := TOWN_CENTER_STAGES.find(town_center_stage())
	var want := TOWN_CENTER_STAGES.find(want_stage)
	return cur >= 0 and want >= 0 and cur >= want

## 进度文案里的那个词（两段不同措辞；TS 侧 `repairStageWord` 必须逐字一致）。
func _repair_stage_word(want_stage: String) -> String:
	return "已初步修复" if want_stage == "patched" else "已修复"


## 进度数字一律向下取整（对齐 TS `quests.ts::shown` 的 Math.floor）。
func _quest_shown(x: float) -> int:
	return int(floor(x + 1e-9))

## 历史上（含今天）某商品的单日产量峰值（"看产能，不看库存"就靠它）。
func _quest_produced_peak(gid: String) -> float:
	var today: Dictionary = s.get("ledgerToday", {})
	var peak := float((today.get("produced", {}) as Dictionary).get(gid, 0.0))
	for snap in (s.get("history", []) as Array):
		var led: Dictionary = (snap as Dictionary).get("ledger", {})
		var v := float((led.get("produced", {}) as Dictionary).get(gid, 0.0))
		if v > peak:
			peak = v
	return peak

## 平均满意度（与 TS `quests.ts::avgSatisfaction` 同口径：算术平均，没人时为 0）。
func quest_avg_satisfaction() -> float:
	var residents: Array = s.get("residents", [])
	if residents.is_empty():
		return 0.0
	var acc := 0.0
	for r in residents:
		acc += float(r["satisfaction"])
	return acc / float(residents.size())

func _quest_name(kind: String, id: String) -> String:
	if kind == "building":
		return String((db.buildings.get(id, {}) as Dictionary).get("nameZh", id))
	if kind == "housing":
		return String((db.housing.get(id, {}) as Dictionary).get("nameZh", id))
	if kind == "class":
		return String((db.classes.get(id, {}) as Dictionary).get("nameZh", id))
	if kind == "tech":
		return String((db.techs.get(id, {}) as Dictionary).get("nameZh", id))
	return String((db.goods.get(id, {}) as Dictionary).get("nameZh", id))

## 单个目标的进度（只读）：{have, need, met, text}。文案必须与 TS 逐字一致。
func _quest_goal_progress(goal: Dictionary) -> Dictionary:
	var type := String(goal.get("type", ""))
	var gid := String(goal.get("id", ""))
	var need := float(goal.get("min", 1))
	var have := 0.0
	var text := ""
	if type == "building" and bool(goal.get("repaired", false)):
		# `repaired: true` 换个口径：数的是"这座塌了的建筑修好/初步修好了吗"，不是"建了几座"。
		# 内容里的主写法是 `building_repaired`，这个别名收着是给换写法用的。
		var w1 := String(goal.get("stage", "restored"))
		have = 1.0 if _quest_repaired(gid, w1) else 0.0
		need = 1.0
		text = "%s %s %d/%d" % [_quest_name("building", _repair_target_building(gid)),
			_repair_stage_word(w1), _quest_shown(have), int(need)]
	elif type == "building":
		var n := 0
		for shop in (s["shops"] as Array):
			if String(shop["defId"]) == gid:
				n += 1
		have = float(n)
		text = "%s %d/%d" % [_quest_name("building", gid), _quest_shown(have), int(need)]
	elif type == "building_repaired":
		# 一座**塌了的**建筑已经修到某个段位（用户 2026-10：第三章初步修缮、第四章修好）。
		# `stage` 缺省 = "restored"（修好）；"patched" = 至少初步修缮过。
		var want := String(goal.get("stage", "restored"))
		have = 1.0 if _quest_repaired(gid, want) else 0.0
		need = 1.0
		text = "%s %s %d/%d" % [_quest_name("building", _repair_target_building(gid)),
			_repair_stage_word(want), _quest_shown(have), int(need)]
	elif type == "housing":
		have = float((s["housing"] as Dictionary).get(gid, 0))
		text = "%s %d/%d" % [_quest_name("housing", gid), _quest_shown(have), int(need)]
	elif type == "housing_capacity":
		have = float(_housing_capacity())
		text = "住房容量 %d/%d" % [_quest_shown(have), int(need)]
	elif type == "population":
		have = float((s["residents"] as Array).size())
		text = "人口 %d/%d" % [_quest_shown(have), int(need)]
	elif type == "class":
		var n2 := 0
		for r in (s["residents"] as Array):
			if String(r["classId"]) == gid:
				n2 += 1
		have = float(n2)
		text = "%s %d/%d" % [_quest_name("class", gid), _quest_shown(have), int(need)]
	elif type == "tech":
		have = 1.0 if (s["research"]["done"] as Array).has(gid) else 0.0
		need = 1.0
		text = "研究「%s」" % _quest_name("tech", gid)
	elif type == "tech_count":
		have = float((s["research"]["done"] as Array).size())
		text = "完成科技 %d/%d" % [_quest_shown(have), int(need)]
	elif type == "good":
		have = float((s["goods"] as Dictionary).get(gid, 0.0))
		text = "%s %d/%d" % [_quest_name("good", gid), _quest_shown(have), int(need)]
	elif type == "produced":
		have = _quest_produced_peak(gid)
		text = "%s单日产量 %d/%d" % [_quest_name("good", gid), _quest_shown(have), int(need)]
	elif type == "avg_satisfaction":
		have = quest_avg_satisfaction()
		text = "平均满意度 %d/%d" % [_quest_shown(have), int(need)]
	elif type == "private_housing":
		var n3 := 0
		for v in (s["privateHousing"] as Dictionary).values():
			n3 += int(floor(float(v)))
		have = float(n3)
		text = "私有住房 %d/%d 户" % [_quest_shown(have), int(need)]
	return {"have": have, "need": need, "met": have + 1e-9 >= need, "text": text}

## 前置是否都完成过。
func _quest_unlocked(def: Dictionary) -> bool:
	var done: Dictionary = s["quests"]["done"]
	for r in (def.get("requires", []) as Array):
		if not done.has(String(r)):
			return false
	return true

## 一条任务的进度（只读）。引擎判定与 UI 显示共用这一份。
func quest_progress(qid: String) -> Dictionary:
	var def: Dictionary = db.quests.get(qid, {})
	if def.is_empty():
		return {}
	var goals := []
	var met := true
	for g in (def.get("goals", []) as Array):
		var p := _quest_goal_progress(g)
		goals.append(p)
		if not bool(p["met"]):
			met = false
	var done: Dictionary = s["quests"]["done"]
	var is_done := done.has(qid)
	var out := {
		"id": qid,
		"chapter": int(def["chapter"]),
		"title": String(def["title"]),
		"hint": String(def["hint"]),
		# 任务面板右侧要的两项：描述（智囊口吻）与奖励金额。
		# TS 那边 `QuestProgress` 直接带着整个 `def`，所以这两项本来就在；
		# GDScript 这边是把 def 摊平的，**摊平就要摊全** —— 少一项 UI 就得
		# 自己回去翻 `db`，那就等于把内容细节漏进表现层了。
		"brief": String(def.get("brief", "")),
		"reward": float(def["reward"]),
		"side": bool(def.get("side", false)),
		"goals": goals,
		"met": met,
		"done": is_done,
		"day": -1,
	}
	if is_done:
		out["day"] = int(done[qid])
	return out

## 追踪条要显示的东西：**只给还没完成的**（已解锁的）。
##
## ⚠️ 用户 2026-10："面板每天 6:00 要把已经完成的任务从右侧面板中拿掉" ——
## 任务正是在黎明（6:00）结算的，所以"刚做完的那条"**当场就从条上收走**，
## 不像以前那样再赖一天（`done[qid] >= day`）。完成了什么由公告与任务面板负责，
## 追踪条只该显示"接下来干什么"。
##
## 渐进显示照旧：`requires` 没全完成的任务**不返回** —— 玩家不该知道后面还有什么。
func quest_view() -> Array:
	var out := []
	var done: Dictionary = s["quests"]["done"]
	for qid in db.quest_ids:
		if done.has(qid):
			continue
		if not _quest_unlocked(db.quests[qid]):
			continue
		out.append(quest_progress(qid))
	return out

## 任务**面板**要的东西：所有"玩家已经知道"的任务 —— 已完成的 + 已解锁未完成的。
##
## 与 `quest_view()` 的分工：
##   · quest_view()    = 追踪条用，只给"当前该做 / 今天刚做完"的几条
##   · quest_journal() = 面板用，做过的历史要留着（玩家回头能翻），所以**已完成的
##                       不论第几天都返回**
##
## ⚠️ 渐进显示这条契约两边都守：`requires` 没全完成、且自己也没完成的，**一律不返回**
## —— 面板上连"有个锁着的任务"都不该看得出来。
## 返回顺序 = 内容定义顺序（面板左树按 chapter 分组后就是章节内顺序）。
func quest_journal() -> Array:
	var out := []
	var done: Dictionary = s["quests"]["done"]
	for qid in db.quest_ids:
		if not done.has(qid) and not _quest_unlocked(db.quests[qid]):
			continue
		out.append(quest_progress(qid))
	return out

# ---------------------------------------------------------------------------
# 剧情对话（用户 2026-10）—— 与 TS `quests.ts::questTalks` 同口径
#
# 两处要弹 galgame 对话，共用「说话人 + 立绘 + 逐行台词（+ 可选选项）」这个形状：
#   1. **任务触发**：任务一出现在追踪条上，发布人（`giver`）就把这条任务的
#      `brief` 逐句说一遍 —— 所以 `brief` 必须是能当台词念的话
#   2. **章节完成**：内容里的 `chapters[].outro`
#
# 判定"该播哪一条"靠**状态比对**（`quests.shown` 里没有的 = 还没播过），不是事件队列：
# 队列会丢，比对不会 —— 读档 / 退出重进都不重播也不漏播。
# ---------------------------------------------------------------------------

## 把一段话按**句末标点**切成"一页一句"的台词（TS `splitSentences` 同口径）。
## 只认 `。！？…`；`：` `，` `、` 不切 —— 切了一句话就断成两截，念起来不像人话。
func _split_sentences(text: String) -> Array:
	var out := []
	var cur := ""
	for i in text.length():
		var ch := text[i]
		cur += ch
		if "。！？…".contains(ch):
			var t := cur.strip_edges()
			if t != "":
				out.append(t)
			cur = ""
	var rest := cur.strip_edges()
	if rest != "":
		out.append(rest)
	return out

## 还没播过的对话，**按内容顺序**排好（第 1 章任务 → 第 1 章收尾 → 第 2 章 …）。
##
## 为什么按章节交错、而不是"先全部任务再全部收尾"：第一章一结束，第二章的任务当晚
## 就会一起解锁 —— 收尾那段必须排在下一章任务之前，否则瑟拉菲娜的登场会插在
## 露娜的"蔬菜农场"后面。
func quest_talks_pending() -> Array:
	var out := []
	var shown: Dictionary = (s["quests"] as Dictionary).get("shown", {})
	var done: Dictionary = s["quests"]["done"]
	var chapters: Dictionary = s["quests"]["chapters"]
	for ch in db.chapters:
		var cid := str(int(ch["id"]))
		for qid in db.quest_ids:
			var def: Dictionary = db.quests[qid]
			if int(def["chapter"]) != int(ch["id"]) or done.has(qid):
				continue
			if not _quest_unlocked(def):
				continue
			var key := "q:" + String(qid)
			if bool(shown.get(key, false)):
				continue
			out.append({
				"key": key, "kind": "quest", "id": String(qid),
				"chapter": int(ch["id"]),
				"speaker": String(def.get("giver", "")),
				"portrait": String(def.get("giverPortrait", "")),
				"lines": _split_sentences(String(def.get("brief", ""))),
			})
		if not chapters.has(cid):
			continue
		var outro: Dictionary = ch.get("outro", {})
		if outro.is_empty():
			continue
		var ckey := "c:" + cid
		if bool(shown.get(ckey, false)):
			continue
		out.append({
			"key": ckey, "kind": "outro", "id": cid, "chapter": int(ch["id"]),
			"speaker": String(outro.get("speaker", "")),
			"portrait": String(outro.get("portrait", "")),
			"lines": (outro.get("lines", []) as Array).duplicate(),
			"choices": (outro.get("choices", []) as Array).duplicate(),
		})
	return out

## 记一笔"这段播过了"（只记事，不改任何数字）。
func quest_talk_mark_shown(key: String) -> void:
	if not (s["quests"].get("shown", null) is Dictionary):
		s["quests"]["shown"] = {}
	s["quests"]["shown"][key] = true

## 某一章的主线是不是都结算过了（章节奖励记在 `quests.chapters` 上）。
func quest_chapter_done(cid: int) -> bool:
	return (s["quests"]["chapters"] as Dictionary).has(str(cid))

## 预言家（瑟拉菲娜）解锁了没有：**第一章收尾之后**（用户 2026-10）。
## 在那之前左侧不出现「预言」圆钮、顶栏水晶球也点不出东西 —— 因为剧情里她是
## 第一章结尾才登场的。规则写在这儿，HUD 与面板都只读它。
func prophet_unlocked() -> bool:
	return quest_chapter_done(1)

## 黎明结算：把已经达成的任务记账、发钱、写公告（不用玩家"提交"）。
##
## 用 `while`/`sweep` 反复扫：同一次黎明里可能**连锁**完成（刚建好的研究所让一条
## 早就达成、只差它当前置的任务当场结算）。顺序固定为 db.quest_ids（内容定义顺序）。
func _check_quests() -> Array:
	var logs := []
	var day := int(s["day"])
	var done: Dictionary = s["quests"]["done"]
	var finished := []
	for _sweep in range(db.quest_ids.size() + 1):
		var progressed := false
		for qid in db.quest_ids:
			if done.has(qid):
				continue
			var def: Dictionary = db.quests[qid]
			if not _quest_unlocked(def):
				continue
			if not bool(quest_progress(qid)["met"]):
				continue
			done[qid] = day
			s["government"]["money"] = SimUtil.r2(
				float(s["government"]["money"]) + float(def["reward"]))
			finished.append(def)
			progressed = true
		if not progressed:
			break

	# 章节奖励：本章"算数"的任务全绿（支线不影响）
	var chapters: Dictionary = s["quests"]["chapters"]
	var chapter_done := []
	for ch in db.chapters:
		var cid := str(int(ch["id"]))
		if chapters.has(cid):
			continue
		var list := []
		for qid in db.quest_ids:
			var def2: Dictionary = db.quests[qid]
			if int(def2["chapter"]) != int(ch["id"]) or bool(def2.get("side", false)):
				continue
			list.append(qid)
		if list.is_empty():
			continue
		var all_done := true
		for qid in list:
			if not done.has(qid):
				all_done = false
				break
		if not all_done:
			continue
		chapters[cid] = day
		s["government"]["money"] = SimUtil.r2(
			float(s["government"]["money"]) + float(ch["reward"]))
		chapter_done.append(ch)

	if not finished.is_empty():
		if finished.size() == 1:
			var only: Dictionary = finished[0]
			logs.append(_quest_log(day, "完成任务：%s（+%d 金）" % [String(only["title"]), int(only["reward"])]))
		else:
			var total := 0
			var titles := PackedStringArray()
			for q in finished:
				total += int(q["reward"])
				titles.append(String(q["title"]))
			logs.append(_quest_log(day, "完成 %d 项任务（+%d 金）：%s"
				% [finished.size(), total, "、".join(titles)]))

		# 这次结算把哪些任务"顶"了出来 —— 只报这些，别把早就可见的再报一遍
		var just_done := {}
		for q in finished:
			just_done[String(q["id"])] = true
		var opened := PackedStringArray()
		for qid in db.quest_ids:
			if done.has(qid):
				continue
			var def3: Dictionary = db.quests[qid]
			var hit := false
			for r in (def3.get("requires", []) as Array):
				if just_done.has(String(r)):
					hit = true
					break
			if not hit or not _quest_unlocked(def3):
				continue
			opened.append(String(def3["title"]))
		if not opened.is_empty():
			logs.append(_quest_log(day, "新任务：%s" % "、".join(opened)))

	for ch in chapter_done:
		logs.append(_quest_log(day, "章节「%s」全部完成（+%d 金）"
			% [String(ch["title"]), int(ch["reward"])]))
	return logs

func _quest_log(day: int, text: String) -> Dictionary:
	return {"day": day, "kind": "info", "text": text}

## 台账里的"拆分表"累加：`ledger[key][good][bucket] += qty`。
##
## `key` = `"consumedBy"`（bucket = 建筑 defId）或 `"boughtBy"`（bucket = 阶层 classId）。
## 面板的商品 tooltip 直接读这两张表（用户 2026-10："面粉都是面包房消耗" /
## "中产 x11 消耗多少资源"）—— 所以只能在**真正扣料 / 成交的那一处**写，UI 不许重算。
func _ledger_add_by(ledger: Dictionary, key: String, good_id: String, bucket: String,
		qty: float, digits: int = 4) -> void:
	if not ledger.has(key):
		ledger[key] = {}
	var table: Dictionary = ledger[key]
	if not table.has(good_id):
		table[good_id] = {}
	var by: Dictionary = table[good_id]
	var cur := float(by.get(bucket, 0.0)) + qty
	by[bucket] = _r4(cur) if digits >= 4 else SimUtil.r2(cur)