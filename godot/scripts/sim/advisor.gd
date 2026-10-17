class_name Advisor
extends RefCounted

# ===========================================================================
# AI 辅助的**程序计算层**：把局势算成"下一步做什么"。
#
# 契约见 `docs/ai-assist.md`。三条必须守住的原则：
#
#   1. **只读**：这里从不写 `sim.s`，也从不入队命令。它跟 `quest_view()` 一样
#      只是"看" —— 所以它**不影响确定性**，黄金轨迹不因为它变一个字节。
#   2. **不重抄公式**：够不够 / 缺多少 / 能产多少，一律直接调引擎自己的函数
#      （`_cost_of() / _can_afford() / _shortage_reason() / _assigned_workers()` …），
#      绝不另写一份成本或产能算式。数字要错就两边一起错、一起修。
#      （这也是它放在 `scripts/sim/` 而不是 `scripts/ui/` 的原因：与引擎同层。）
#   3. **算完再问**：LLM 只做"排序 + 讲因果"，**不做算术**。提示词里每一个数字
#      都是这一层算好的，并要求模型"只许引用给出的数字"。
#
# 为什么要有第 3 条：让模型自己数库存、比轻重，它会编。把"缺 石 12（有 3）"
# 这样的事实喂进去，它就只能拿这些事实去组织语言。
#
# 两个入口：
#   · `plan()` / `plan_text()` —— 本地计算出的候选（`plan()` 进提示词与沙盘汇总；
#     `plan_text()` 是它的纯文本渲染，**面板不再显示它** —— 用户 2026-10："不要本地分析"）
#   · `messages()`             —— 规则 + 局势 + 本地计算 → 发给 LLM 的两条消息
# ===========================================================================

## 建议的紧急度。数字越小越靠前（`plan()` 按它排序）。
const P_URGENT := 0      # 已经在饿死人 / 已经在流失
const P_HIGH := 1        # 卡住了成长（移民进不来、任务过不去、工程不动）
const P_NORMAL := 2      # 该做但不急
const P_LOW := 3         # 锦上添花

## `plan()` 最多给几条。再多玩家也读不完，提示词也会跟着变长。
const MAX_PLAN := 6
## 认识的 goal 类型（与 `src/engine/types.ts::QuestGoal` 同一份口径）。
## ⚠️ 内容里出现这里没有的类型 = 那条任务在建议里**静默消失**（玩家少一条引导，
## 而且不报错）。门槛 `ai_test.gd` 会拿内容里的全部类型跟这份表对拍。
const KNOWN_GOAL_TYPES := ["building", "housing", "housing_capacity", "population",
	"class", "tech", "tech_count", "good", "produced", "avg_satisfaction", "private_housing",
	"building_repaired"]
## 提示词里"可建清单"最多列几项。
const MAX_BUILD_LIST := 28
## 任务那一段最多细讲几个任务。
const MAX_QUEST_LIST := 6

var sim: SimCore
var db: ContentDB = null
## 玩家在面板里额外敲的问题（可空）。
var question := ""
## 建筑 → 建造栏页签名（由 UI 注入 `BuildBar._category_of`）。
## 不注入时建议里只写「建造栏」，不编一个不存在的页签名 ——
## 页签是**表现层**的分组，sim 层不该硬编码它。
var cat_of: Callable = Callable()

func _init(core: SimCore) -> void:
	sim = core
	db = null if core == null else core.db

# ---------------------------------------------------------------------------
# 小工具：名字 / 数字
# ---------------------------------------------------------------------------
## 显示数字：整数不带小数点，其余一位小数。与引擎无关，纯粹为了读着舒服。
func _n(x: float) -> String:
	if absf(x - round(x)) < 0.05:
		return str(int(round(x)))
	return "%.1f" % x

func gname(gid: String) -> String:
	var g: Dictionary = db.goods.get(gid, {})
	return String(g.get("nameZh", gid)) if not g.is_empty() else gid

func bname(bid: String) -> String:
	var b: Dictionary = db.buildings.get(bid, {})
	return String(b.get("nameZh", bid)) if not b.is_empty() else bid

func hname(hid: String) -> String:
	var h: Dictionary = db.housing.get(hid, {})
	return String(h.get("nameZh", hid)) if not h.is_empty() else hid

func tname(tid: String) -> String:
	var t: Dictionary = db.techs.get(tid, {})
	return String(t.get("nameZh", tid)) if not t.is_empty() else tid

func cname(cid: String) -> String:
	var c: Dictionary = db.classes.get(cid, {})
	return String(c.get("nameZh", cid)) if not c.is_empty() else cid

func stock(gid: String) -> float:
	return float(sim.s["goods"].get(gid, 0.0))

func _cat(bid: String) -> String:
	return String(cat_of.call(bid)) if cat_of.is_valid() else ""

## 「建造栏「农场」页」/「建造栏」（拿不到页签名时不编）。
func _where_to_build(bid: String) -> String:
	var c := _cat(bid)
	return "建造栏「%s」页" % c if c != "" else "建造栏"

# ---------------------------------------------------------------------------
# 读数：人口 / 住房 / 岗位
# ---------------------------------------------------------------------------
func pop() -> int:
	return (sim.s["residents"] as Array).size()

## 各阶层人数（按 classes.json 的财富门槛排序，不是字典序）。
func class_counts() -> Array:
	var out: Array = []
	for cid in _class_order():
		var n := 0
		for r in sim.s["residents"]:
			if String(r["classId"]) == cid:
				n += 1
		out.append({"id": cid, "name": cname(cid), "count": n})
	return out

func _class_order() -> Array:
	var ids: Array = db.classes.keys()
	ids.sort_custom(func(a, b):
		return int(db.classes[a]["wealthThreshold"]) < int(db.classes[b]["wealthThreshold"]))
	return ids

func employed_count() -> int:
	var n := 0
	for r in sim.s["residents"]:
		if bool(r["employed"]):
			n += 1
	return n

## 住房总览。私有房仍住着人，只是不再是公房。
func housing_summary() -> Dictionary:
	var rows: Array = []
	var capacity := 0
	var state_owned := 0
	for hid in db.housing.keys():
		var total := int(floor(float(sim.s["housing"].get(hid, 0.0))))
		var priv := int(floor(float(sim.s["privateHousing"].get(hid, 0.0))))
		if total <= 0 and priv <= 0:
			continue
		var hd: Dictionary = db.housing[hid]
		var cap_each := int(hd["capacity"])
		capacity += cap_each * total
		state_owned += maxi(0, total - priv)
		rows.append({"id": String(hid), "name": hname(String(hid)), "count": total,
			"private": priv, "capacity_each": cap_each})
	return {
		"capacity": capacity, "pop": pop(), "vacant": capacity - pop(),
		"rows": rows, "state_owned": state_owned,
		"arrivals": int(sim.s.get("arrivals", 0)),
		"population_cap": float(sim.s["government"].get("populationCap", 0.0)),
	}

# ---------------------------------------------------------------------------
# 读数：生产 / 原料
# ---------------------------------------------------------------------------
## 某商品「本日计划产量」= Σ 各建筑 计划批量 × 配方产出 × 工具与科技加成。
##
## `planned` 是黎明 `_plan_production()` 算好的（已经按原料够不够打了折），
## 两个加成也直接调引擎 —— 这一层不重算任何一个系数。
func planned_daily(gid: String) -> float:
	var total := 0.0
	for shop in sim.s["shops"]:
		if not bool(shop["active"]):
			continue
		var def: Dictionary = db.buildings.get(String(shop["defId"]), {})
		if not def.has("recipe"):
			continue
		var rec: Dictionary = db.recipes.get(String(def["recipe"]), {})
		var q := float((rec.get("output", {}) as Dictionary).get(gid, 0.0))
		if q <= 0.0:
			continue
		var boost := sim._shop_tool_boost(shop) * sim._sector_output_boost(shop)
		total += q * float(shop["planned"]) * boost
	return total

## 建筑清单：谁在岗、本日产什么、哪种原料已经见底。
func prod_rows() -> Array:
	var rows: Array = []
	for shop in sim.s["shops"]:
		var def: Dictionary = db.buildings.get(String(shop["defId"]), {})
		if def.is_empty():
			continue
		var row := {
			"id": String(shop["id"]), "def_id": String(shop["defId"]),
			"name": bname(String(shop["defId"])), "level": int(shop["level"]),
			"active": bool(shop["active"]),
			"workers": sim._assigned_workers(String(shop["id"])),
			"target": int(shop["targetWorkers"]),
			"planned": float(shop["planned"]),
			"output": {}, "binding": [],
		}
		if def.has("recipe"):
			var rec: Dictionary = db.recipes.get(String(def["recipe"]), {})
			var boost := sim._shop_tool_boost(shop) * sim._sector_output_boost(shop)
			var out := {}
			for gid in (rec.get("output", {}) as Dictionary).keys():
				var q := float(rec["output"][gid]) * float(shop["planned"]) * boost
				if q > 0.0:
					out[gid] = q
			row["output"] = out
			# 「原料见底」不用重算：黎明 `_plan_production()` 把该留的料记在
			# `s["reserved"]` 里，库存被压到预留线以下就是这个料在卡产能。
			for gid in (rec.get("inputs", {}) as Dictionary).keys():
				if float(rec["inputs"][gid]) > 0.0 and _is_binding(String(gid)):
					(row["binding"] as Array).append(String(gid))
			if float(rec.get("fuel", 0.0)) > 0.0 and _is_binding("firewood"):
				(row["binding"] as Array).append("firewood")
		rows.append(row)
	return rows

func _is_binding(gid: String) -> bool:
	var reserved := float(sim.s["reserved"].get(gid, 0.0))
	return reserved > 0.0 and stock(gid) <= reserved + 0.0001

## 谁产这个商品（产出量最大的那座）。"缺 木"→"把伐木场补上"就靠它。
func producer_of(gid: String) -> String:
	var best := ""
	var best_q := 0.0
	for bid in db.buildings.keys():
		var def: Dictionary = db.buildings[bid]
		if not def.has("recipe"):
			continue
		var rec: Dictionary = db.recipes.get(String(def["recipe"]), {})
		var q := float((rec.get("output", {}) as Dictionary).get(gid, 0.0))
		if q > best_q:
			best_q = q
			best = String(bid)
	return best

func shop_count(bid: String) -> int:
	var n := 0
	for shop in sim.s["shops"]:
		if String(shop["defId"]) == bid:
			n += 1
	return n

## 要把某商品的日产量再提高 `gap`，大约还要几座同类建筑。
##
## 口径是**观察值**：拿现有同类建筑的"本日计划产量"当一座的产能
## （不重算 baseRate × 人手 × 技能 —— 那是引擎的事，重算迟早会漂）。
func extra_shops_for(gid: String, gap: float) -> int:
	if gap <= 0.0:
		return 0
	var per := 0.0
	var seen := {}
	for shop in sim.s["shops"]:
		var bid := String(shop["defId"])
		var def: Dictionary = db.buildings.get(bid, {})
		if not def.has("recipe"):
			continue
		var rec: Dictionary = db.recipes.get(String(def["recipe"]), {})
		if float((rec.get("output", {}) as Dictionary).get(gid, 0.0)) <= 0.0:
			continue
		if seen.has(bid):
			continue
		seen[bid] = true
		per = maxf(per, planned_daily(gid) / maxf(1.0, float(shop_count(bid))))
	if per <= 0.0001:
		return 1
	return maxi(1, ceili(gap / per))

# ---------------------------------------------------------------------------
# 读数：食物
# ---------------------------------------------------------------------------
## 名义日需：各阶层 `needs[].perCapita` × 该阶层人数。
##
## ⚠️ 这是**名义**值：真实消耗还看替代品（fallbacks）与价格弹性，实测量在
## `ledgerToday.consumed` 里。两个都报，是为了让模型看得出来"缺的是哪一项"，
## 而不是把名义值当真理。这一层不重算消费公式。
func nominal_demand() -> Dictionary:
	var out := {}
	var counts := {}
	for r in sim.s["residents"]:
		var cid := String(r["classId"])
		counts[cid] = int(counts.get(cid, 0)) + 1
	for cid in counts.keys():
		var def: Dictionary = db.classes.get(cid, {})
		for need in (def.get("needs", []) as Array):
			var gid := String(need["good"])
			out[gid] = float(out.get(gid, 0.0)) + float(need["perCapita"]) * float(counts[cid])
	return out

func food_summary() -> Dictionary:
	var demand := nominal_demand()
	var consumed: Dictionary = sim.s["ledgerToday"].get("consumed", {})
	# 基础食物（`tuning.basicFoods`）可以互相顶，所以"还能撑几天"按它们合起来算
	var basics: Array = db.tuning["basicFoods"]
	var rows: Array = []
	var seen := {}
	var d_sum := 0.0
	var s_sum := 0.0
	var k_sum := 0.0
	for gid in basics:
		if not db.goods.has(String(gid)):
			continue
		seen[String(gid)] = true
		var d := float(demand.get(String(gid), 0.0))
		var sup := planned_daily(String(gid))
		var k := stock(String(gid))
		d_sum += d
		s_sum += sup
		k_sum += k
		rows.append({"id": String(gid), "name": gname(String(gid)),
			"demand": d, "supply": sup, "stock": k, "basic": true})
	# 昨天真的吃了什么（含非基础食物）：缺口往往在这一列里才看得出来
	for gid in consumed.keys():
		var g := String(gid)
		if seen.has(g) or not db.goods.has(g):
			continue
		var gd: Dictionary = db.goods[g]
		if String(gd.get("category", "")) != "food":
			continue
		rows.append({"id": g, "name": gname(g), "demand": float(demand.get(g, 0.0)),
			"supply": planned_daily(g), "stock": stock(g), "basic": false})
	var net := d_sum - s_sum
	var days := -1.0
	if net > 0.0001:
		days = k_sum / net
	return {
		"rows": rows, "demand_total": d_sum, "supply_total": s_sum, "stock_total": k_sum,
		"net": net, "days_left": days,
		"hungry": int(_last_snapshot().get("hungry", 0)),
		"consumed": consumed, "demand_by_good": demand,
	}

func _last_snapshot() -> Dictionary:
	var hist: Array = sim.s.get("history", [])
	return hist[hist.size() - 1] if not hist.is_empty() else {}

# ---------------------------------------------------------------------------
# 读数：满意度（只看已记下来的分项，不重算权重和）
# ---------------------------------------------------------------------------
## 满意度短板。分项取"逐人账目里**当天**记下的满足率"的平均
## （`account.foodScore / comfortScore / priceScore` + 在岗与否），
## 权重取内容里的 `economy.weights` —— 都是读，不是算。
func sat_summary() -> Dictionary:
	var residents: Array = sim.s["residents"]
	var food := 0.0
	var comfort := 0.0
	var price := 0.0
	var employment := 0.0
	var wages := 0.0
	var wage_n := 0
	for r in residents:
		var a: Dictionary = r.get("account", {})
		food += float(a.get("foodScore", 1.0))
		comfort += float(a.get("comfortScore", 1.0))
		price += float(a.get("priceScore", 1.0))
		employment += 1.0 if bool(r["employed"]) else 0.0
		if float(a.get("wage", 0.0)) > 0.0:
			wages += float(a["wage"])
			wage_n += 1
	var n := maxi(1, residents.size())
	var w: Dictionary = db.economy["weights"]
	var rows: Array = [
		{"key": "food", "label": "食物", "score": food / float(n), "weight": float(w["food"])},
		{"key": "comfort", "label": "舒适", "score": comfort / float(n), "weight": float(w["comfort"])},
		{"key": "price", "label": "物价", "score": price / float(n), "weight": float(w["price"])},
		{"key": "employment", "label": "就业", "score": employment / float(n), "weight": float(w["employment"])},
	]
	rows.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))
	return {
		"avg": sim.quest_avg_satisfaction(),
		"factors": rows,
		"weakest": rows[0] if not rows.is_empty() else {},
		"avg_wage": (wages / float(wage_n)) if wage_n > 0 else 0.0,
		"ref_wage": float(db.economy["refWage"]),
		"immigration_threshold": float(db.economy["immigrationSatThreshold"]),
		"emigration_threshold": float(db.economy["emigrationSatThreshold"]),
	}

# ---------------------------------------------------------------------------
# 读数：科技 / 施工 / 仓储 / 任务
# ---------------------------------------------------------------------------
func tech_summary() -> Dictionary:
	var done_names := PackedStringArray()
	for tid in sim.s["research"]["done"]:
		done_names.append(tname(String(tid)))
	var queue: Array = []
	for e in sim.s["research"]["queue"]:
		queue.append({"id": String(e["id"]), "name": tname(String(e["id"])),
			"remaining": float(e["remaining"]), "total": float(e["totalRequired"]),
			"started": bool(e["started"])})
	var available: Array = []
	for tid in db.tech_ids:
		var t: Dictionary = db.techs[tid]
		if sim._is_researched(tid) or sim._is_queued_tech(tid):
			continue
		var ok := true
		for req in (t.get("requires", []) as Array):
			if not sim._is_researched(String(req)):
				ok = false
				break
		if not ok:
			continue
		available.append({
			"id": tid, "name": tname(tid), "research": float(t["research"]),
			"cost": _tech_cost(tid), "unlocks": _tech_unlocks(tid),
		})
	return {
		"done": done_names, "queue": queue, "available": available,
		"rate": sim.research_rate(),
		"institutes": shop_count("research_institute"),
	}

func _tech_cost(tid: String) -> Array:
	var out: Array = []
	var t: Dictionary = db.techs.get(tid, {})
	var goods: Dictionary = t.get("cost", {}).get("goods", {})
	for gid in goods.keys():
		var need := float(goods[gid])
		if need <= 0.0:
			continue
		out.append({"id": String(gid), "name": gname(String(gid)),
			"need": need, "have": stock(String(gid))})
	return out

func _tech_unlocks(tid: String) -> Array:
	var t: Dictionary = db.techs.get(tid, {})
	var out := PackedStringArray()
	for bid in (t.get("unlocks", {}).get("buildings", []) as Array):
		out.append(bname(String(bid)))
	for hid in (t.get("unlocks", {}).get("housing", []) as Array):
		out.append("%s（住房）" % hname(String(hid)))
	return out

func construction_rows() -> Array:
	var rows: Array = []
	for c in sim.s["construction"]:
		var spec: Dictionary = sim._cost_of(c)
		var row := {
			"label": sim._label_of(c), "started": bool(c["started"]),
			"remaining": float(c["remaining"]), "total": float(c["totalRequired"]),
			"afford": sim._can_afford(spec), "cost": _cost_rows(spec),
		}
		if not bool(row["afford"]):
			row["shortage"] = sim._shortage_reason(spec)
		rows.append(row)
	return rows

func storage_summary() -> Dictionary:
	var cap := sim.storage_capacity()
	var used := sim.stored_total()
	return {"used": used, "cap": cap, "full": cap > 0.0 and used >= cap - 0.5,
		"ratio": (used / cap) if cap > 0.0 else 0.0}

func quest_rows() -> Array:
	var out: Array = []
	var view: Array = sim.quest_view()
	for i in view.size():
		var q: Dictionary = view[i]
		# ⚠️ `quest_progress()` 给的 goal 只有 `{have, need, met, text}` ——
		# **没有** `type` / `id`（那是内容定义里的字段，引擎判定时不需要它们）。
		# 所以这里按**下标**把内容定义里的 goal 并回来：两边顺序同源
		# （`_quest_goal_progress()` 就是照 `def["goals"]` 的顺序生成的），
		# 不去改引擎的返回形状（那会动到对拍面）。
		var def: Dictionary = db.quests.get(String(q["id"]), {})
		var def_goals: Array = def.get("goals", [])
		var goals: Array = []
		var prog: Array = q["goals"]
		for k in prog.size():
			var g: Dictionary = prog[k]
			var dg: Dictionary = def_goals[k] if k < def_goals.size() else {}
			goals.append({"text": String(g["text"]), "met": bool(g["met"]),
				"type": String(dg.get("type", "")), "id": String(dg.get("id", "")),
				"have": float(g.get("have", 0.0)), "need": float(g.get("need", 0.0))})
		out.append({"id": String(q["id"]), "title": String(q["title"]),
			"hint": String(q["hint"]), "side": bool(q["side"]),
			"done": bool(q["done"]), "met": bool(q["met"]), "goals": goals,
			"shown": i < MAX_QUEST_LIST})
	return out

# ---------------------------------------------------------------------------
# 成本（**全部走引擎自己的函数**，这一层不写成本公式）
# ---------------------------------------------------------------------------
## 把 `_cost_of()` 的 `{mats:[[gid,qty]], money}` 摊成可读的行，带上现有量。
func _cost_rows(spec: Dictionary, count: int = 1) -> Array:
	var out: Array = []
	for m in (spec.get("mats", []) as Array):
		var gid := String(m[0])
		var need := float(m[1]) * float(count)
		out.append({"id": gid, "name": gname(gid), "need": need,
			"have": stock(gid), "ok": stock(gid) >= need})
	if float(spec.get("money", 0.0)) > 0.0:
		var money_need := float(spec["money"]) * float(count)
		var have_money := float(sim.s["government"]["money"])
		out.append({"id": "", "name": "金", "need": money_need,
			"have": have_money, "ok": have_money >= money_need})
	return out

func _cost_text(rows: Array) -> String:
	if rows.is_empty():
		return "不要材料"
	var parts := PackedStringArray()
	for r in rows:
		parts.append("%s %s（现有 %s）" % [String(r["name"]), _n(float(r["need"])),
			_n(float(r["have"]))])
	return "、".join(parts)

func _missing_names(rows: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for r in rows:
		if not bool(r["ok"]):
			out.append("%s %s" % [String(r["name"]),
				_n(float(r["need"]) - float(r["have"]))])
	return out

func build_cost(bid: String) -> Array:
	return _cost_rows(sim._cost_of({"kind": "shop", "buildingId": bid}))

func housing_cost(hid: String) -> Array:
	return _cost_rows(sim._cost_of({"kind": "housing", "housingId": hid}))

## 现在能不能建（科技 + 材料 + 资金）。返回 `{ok, reasons, tech, cost}`。
func build_gate(bid: String) -> Dictionary:
	var reasons := PackedStringArray()
	var tech := db.tech_for_building(bid)
	if tech != "" and not sim._is_researched(tech):
		reasons.append("需要先研究「%s」" % tname(tech))
	var rows := build_cost(bid)
	for m in _missing_names(rows):
		reasons.append("缺 %s" % m)
	return {"ok": reasons.is_empty(), "reasons": reasons, "tech": tech, "cost": rows}

func housing_gate(hid: String) -> Dictionary:
	var reasons := PackedStringArray()
	var tech := db.tech_for_housing(hid)
	if tech != "" and not sim._is_researched(tech):
		reasons.append("需要先研究「%s」" % tname(tech))
	var rows := housing_cost(hid)
	for m in _missing_names(rows):
		reasons.append("缺 %s" % m)
	return {"ok": reasons.is_empty(), "reasons": reasons, "tech": tech, "cost": rows}

## 缺的建材从哪来：给一句"先把它补上"。
func _producer_hint(gid: String) -> String:
	var bid := producer_of(gid)
	if bid == "":
		return ""
	var n := shop_count(bid)
	if n > 0:
		return "（%s 由「%s」产，现有 %d 座，可扩建或加人）" % [gname(gid), bname(bid), n]
	return "（%s 由「%s」产，现在还没有，先建 1 座）" % [gname(gid), bname(bid)]

# ---------------------------------------------------------------------------
# 建议规则
# ---------------------------------------------------------------------------
## 本地计算出的建议，按紧急度排序、按 `id` 去重。
## 每条：`{id, prio, tag, title, why, how:[...]}`。`id` 用来去重（同一个病只开一张方子）。
func plan() -> Array:
	var out: Array = []
	if sim == null or db == null or sim.s.is_empty():
		return out
	_rule_food(out)
	_rule_housing(out)
	_rule_build_power(out)
	_rule_quests(out)
	_rule_satisfaction(out)
	_rule_workers(out)
	_rule_storage(out)
	_rule_research(out)
	# 稳定排序：`sort_custom` 不保证稳定，所以先记下插入序号再比
	for i in out.size():
		out[i]["seq"] = i
	out.sort_custom(func(a, b):
		if int(a["prio"]) != int(b["prio"]):
			return int(a["prio"]) < int(b["prio"])
		return int(a["seq"]) < int(b["seq"]))
	var seen := {}
	var kept: Array = []
	for s in out:
		var k := String(s["id"])
		if seen.has(k):
			continue
		seen[k] = true
		kept.append(s)
		if kept.size() >= MAX_PLAN:
			break
	return kept

func _add(out: Array, id: String, prio: int, tag: String, title: String, why: String, how: Array) -> void:
	out.append({"id": id, "prio": prio, "tag": tag, "title": title, "why": why, "how": how})

## 食物：已经有人挨饿，或者按当前产量算几天后断粮。
func _rule_food(out: Array) -> void:
	var f := food_summary()
	var worst := {}
	var worst_gap := 0.0
	for r in (f["rows"] as Array):
		var gap := float(r["demand"]) - float(r["supply"])
		if gap > worst_gap:
			worst_gap = gap
			worst = r
	var day := int(sim.s["day"])
	var hungry := int(f["hungry"])
	if hungry > 0:
		var how: Array = []
		if not worst.is_empty():
			var bid := producer_of(String(worst["id"]))
			if bid != "":
				how.append("%s建 %d 座%s（%s）" % [_where_to_build(bid),
					extra_shops_for(String(worst["id"]), worst_gap), bname(bid),
					_cost_text(build_cost(bid))])
				how.append("也可以先给现有的「%s」加人（建筑面板 → 用工）" % bname(bid))
			how.append(_producer_hint(String(worst["id"])))
		_add(out, "food_shortage", P_URGENT, "紧急", "先止住饿：把食物产量补上",
			"第 %d 天有 %d 人挨饿（日均食物满足率低于 %s）；%s 日需 %s、本日产 %s、库存 %s" % [
				day, hungry, _n(float(db.tuning["hungryThreshold"])),
				String(worst.get("name", "基础食物")), _n(float(worst.get("demand", 0.0))),
				_n(float(worst.get("supply", 0.0))), _n(float(worst.get("stock", 0.0)))],
			how)
		return
	var days := float(f["days_left"])
	if days >= 0.0 and days < 3.0:
		var how2: Array = []
		if not worst.is_empty():
			var bid2 := producer_of(String(worst["id"]))
			if bid2 != "":
				how2.append("%s建 %d 座%s（%s）" % [_where_to_build(bid2),
					extra_shops_for(String(worst["id"]), worst_gap), bname(bid2),
					_cost_text(build_cost(bid2))])
		_add(out, "food_shortage", P_URGENT, "紧急", "基础食物只够 %s 天" % _n(days),
			"基础食物日需 %s、本日产 %s、库存 %s（缺口 %s 每天）" % [
				_n(float(f["demand_total"])), _n(float(f["supply_total"])),
				_n(float(f["stock_total"])), _n(float(f["net"]))],
			how2)

## 住房：满了就没人进得来（迁入的三个闸门之一）。
func _rule_housing(out: Array) -> void:
	var h := housing_summary()
	var vacant := int(h["vacant"])
	var arrivals := int(h["arrivals"])
	if pop() <= 0:
		return
	if vacant > 0 and vacant >= arrivals:
		return
	var best := _best_housing_for(maxi(1, arrivals - maxi(0, vacant)))
	if best.is_empty():
		return
	var gate := housing_gate(String(best["id"]))
	var how: Array = ["%s建 %d 座%s（%s）" % [_where_to_build(String(best["id"])),
		int(best["count"]), hname(String(best["id"])), _cost_text(gate["cost"])]]
	if not bool(gate["ok"]):
		for r in (gate["reasons"] as PackedStringArray):
			how.append("注意：%s" % r)
	_add(out, "housing_full", P_HIGH, "卡成长", "住房满了：移民住不进来",
		"住房容量 %d / 人口 %d（空 %d），本回合想来 %d 人 —— 空房不够，多出来的会被挡在门外" % [
			int(h["capacity"]), pop(), vacant, arrivals], how)

## 每多住 `need` 个人，建哪种房、建几座最省。
## 按"每个床位要多少材料"排（材料量取自内容的 buildCost，不是公式）。
func _best_housing_for(need: int) -> Dictionary:
	var best := {}
	var best_per := INF
	for hid in db.housing.keys():
		var h := String(hid)
		if not sim.is_housing_unlocked(h):
			continue
		var hd: Dictionary = db.housing[h]
		var cap_each := maxi(1, int(hd["capacity"]))
		var mats := 0.0
		for gid in (hd.get("buildCost", {}) as Dictionary).keys():
			mats += float(hd["buildCost"][gid])
		var per := mats / float(cap_each)
		if per < best_per:
			best_per = per
			best = {"id": h, "count": maxi(1, ceili(float(need) / float(cap_each)))}
	return best

## 工程不动：建造力为 0（没有失业者，也没有建筑工坊）。
func _rule_build_power(out: Array) -> void:
	var queue: Array = sim.s["construction"]
	if queue.is_empty():
		return
	if sim.construction_rate() > 0.0001:
		return
	var how: Array = []
	var cw := "construction_works"
	if shop_count(cw) == 0 and sim.is_building_unlocked(cw):
		how.append("%s建 1 座%s（%s）—— 它每天出建造力" % [_where_to_build(cw), bname(cw),
			_cost_text(build_cost(cw))])
	how.append("也可以让失业的人去工地出工：建造力 = 失业人数 × %s" % _n(
		float(db.economy["construction"]["unemployedRate"])))
	_add(out, "no_build_power", P_HIGH, "卡成长", "工地停着：今天一点建造力都没有",
		"建造队列有 %d 项工程，但本日建造力 = 0（没有失业的人，也没有建筑工坊）" % queue.size(),
		how)

## 任务：**这就是"下一步做什么"的主来源**。把未达成的目标翻译成一张能照做的方子。
func _rule_quests(out: Array) -> void:
	var n := 0
	for q in quest_rows():
		if bool(q["done"]) or not bool(q["shown"]):
			continue
		var got := false
		for g in (q["goals"] as Array):
			if bool(g["met"]):
				continue
			_quest_goal_suggestion(out, q, g)
			got = true
			break          # 一个任务只开一张方子：先把它最靠前那个未达成目标说清楚
		if got:
			n += 1
		if n >= 3:
			return

func _quest_goal_suggestion(out: Array, q: Dictionary, g: Dictionary) -> void:
	var qid := String(q["id"])
	var gtype := String(g["type"])
	var gid := String(g["id"])
	var have := float(g["have"])
	var need := float(g["need"])
	var lead := "任务「%s」：%s" % [String(q["title"]), String(g["text"])]
	if gtype == "building_repaired" or (gtype == "building" and bool(g.get("repaired", false))):
		_repaired_suggestion(out, q, g)
		return
	match gtype:
		"building":
			var extra := maxi(1, int(need - have))
			var gate := build_gate(gid)
			var how: Array = []
			if String(gate["tech"]) != "" and not sim._is_researched(String(gate["tech"])):
				how.append("先研究「%s」（科技面板）" % tname(String(gate["tech"])))
				how.append(_institute_hint())
			how.append("%s建 %d 座%s（%s）" % [_where_to_build(gid), extra, bname(gid),
				_cost_text(gate["cost"])])
			for r in (gate["reasons"] as PackedStringArray):
				how.append("注意：%s" % r)
			for r in (gate["cost"] as Array):
				if not bool(r["ok"]):
					var ph := _producer_hint(String(r["id"]))
					if ph != "":
						how.append(ph)
			_add(out, "quest_%s_%s" % [qid, gid], P_HIGH, "任务", lead,
				"现在有 %d 座，还差 %d 座" % [int(have), extra], how)
		"housing":
			var extra2 := maxi(1, int(need - have))
			var hg := housing_gate(gid)
			var how2: Array = ["%s建 %d 座%s（%s）" % [_where_to_build(gid), extra2,
				hname(gid), _cost_text(hg["cost"])]]
			for r in (hg["reasons"] as PackedStringArray):
				how2.append("注意：%s" % r)
			_add(out, "quest_%s_%s" % [qid, gid], P_HIGH, "任务", lead,
				"现在 %d 座，还差 %d 座" % [int(have), extra2], how2)
		"housing_capacity":
			var delta := maxi(1, int(need - have))
			var best := _best_housing_for(delta)
			if best.is_empty():
				return
			_add(out, "quest_%s_cap" % qid, P_HIGH, "任务", lead,
				"住房容量 %d，还差 %d 个床位" % [int(have), delta],
				["%s建 %d 座%s（%s），床位正好补上" % [_where_to_build(String(best["id"])),
					int(best["count"]), hname(String(best["id"])),
					_cost_text(housing_gate(String(best["id"]))["cost"])]])
		"population":
			_add(out, "quest_%s_pop" % qid, P_HIGH, "任务", lead,
				"现在 %d 人，还差 %d 人" % [int(have), int(need - have)], _population_hints())
		"class":
			_add(out, "quest_%s_class_%s" % [qid, gid], P_HIGH, "任务", lead,
				"现在 %d 人，还差 %d 人" % [int(have), int(need - have)], _class_hints(gid))
		"tech":
			_add(out, "quest_%s_tech_%s" % [qid, gid], P_HIGH, "任务", lead,
				"「%s」还没研究（要研究力 %s）" % [tname(gid),
					_n(float(db.techs.get(gid, {}).get("research", 0.0)))],
				_tech_hints(gid))
		"tech_count":
			_add(out, "quest_%s_techcount" % qid, P_HIGH, "任务", lead,
				"已研究 %d 项，还差 %d 项" % [int(have), int(need - have)], _tech_hints(""))
		"good":
			var gap := need - have
			var per := planned_daily(gid)
			var how3: Array = []
			if per > 0.0001:
				how3.append("%s 每天产 %s，还差 %s，约 %s 天攒够" % [gname(gid), _n(per),
					_n(gap), _n(ceil(gap / per))])
			var bid3 := producer_of(gid)
			if bid3 != "":
				how3.append("%s建 %d 座%s 加速（%s）" % [_where_to_build(bid3),
					extra_shops_for(gid, maxf(gap, per)), bname(bid3), _cost_text(build_cost(bid3))])
			_add(out, "quest_%s_good_%s" % [qid, gid], P_HIGH, "任务", lead,
				"库存 %s，还差 %s" % [_n(have), _n(gap)], how3)
		"produced":
			var gap2 := need - have
			var how4: Array = []
			var bid4 := producer_of(gid)
			if bid4 != "":
				how4.append("%s建 %d 座%s（%s）" % [_where_to_build(bid4),
					extra_shops_for(gid, gap2), bname(bid4), _cost_text(build_cost(bid4))])
				how4.append("现有 %d 座，也可以先加人 / 升级（建筑面板）" % shop_count(bid4))
			var bind := _binding_for(gid)
			if bind != "":
				how4.append("现在卡在原料：%s 见底%s" % [gname(bind), _producer_hint(bind)])
			_add(out, "quest_%s_prod_%s" % [qid, gid], P_HIGH, "任务", lead,
				"最好的一天产了 %s，目标 %s（还差 %s）" % [_n(have), _n(need), _n(gap2)], how4)
		"avg_satisfaction":
			_sat_suggestion(out, "sat_low", lead,
				"平均满意度 %s，目标 %s" % [_n(have), _n(need)])
		"private_housing":
			_add(out, "quest_%s_private" % qid, P_HIGH, "任务", lead,
				"现在 %d 户，还差 %d 户" % [int(have), int(need - have)],
				["私有住房是居民自己买的：满意度到 %s 以上的人才会买，每天最多成交 %d 户" % [
					_n(float(db.economy["privateHousingNeedThreshold"])),
					int(db.economy["privateHousingPerDay"])],
				"所以先抬满意度（见「满意度」那条），房不用你建"])
		_:
			pass

## 「修好一座塌了的建筑」（用户 2026-10：修复城镇中心）—— 只有城镇中心这一座。
## 建议里给的是**修缮用料**（缺哪样就补哪条产线），以及"点哪儿修"。
func _repaired_suggestion(out: Array, q: Dictionary, g: Dictionary) -> void:
	var qid := String(q["id"])
	var cost: Dictionary = sim.town_center_repair_cost()
	var lead := "任务「%s」：%s" % [String(q["title"]), String(g["text"])]
	var parts := PackedStringArray()
	var how: Array = []
	for gid in ["wood", "stone", "brick"]:
		if not cost.has(gid):
			continue
		var lacking := float(sim.s["goods"].get(gid, 0.0)) < float(cost[gid])
		parts.append("%s %d%s" % [gname(String(gid)), int(cost[gid]),
			"（不够）" if lacking else ""])
		if not lacking:
			continue
		var bid := producer_of(String(gid))
		if bid != "":
			how.append("%s建 %d 座%s（%s）" % [_where_to_build(bid),
				extra_shops_for(String(gid), float(cost[gid])), bname(bid), _cost_text(build_cost(bid))])
	how.append("材料够了就点地图上那座破旧的城镇中心 →「修缮」，次日黎明完工")
	_add(out, "quest_%s_repaired" % qid, P_HIGH, "任务", lead,
		"用料：%s" % "、".join(parts), how)

func _binding_for(gid: String) -> String:
	for row in prod_rows():
		if not (row["output"] as Dictionary).has(gid):
			continue
		var b: Array = row["binding"]
		if not b.is_empty():
			return String(b[0])
	return ""

## 研究所没有 → 科技永远不会动。
func _institute_hint() -> String:
	var ri := "research_institute"
	if shop_count(ri) > 0:
		return "研究所在岗才有科研力（现在有 %d 座）" % shop_count(ri)
	return "现在还没有研究所：%s建 1 座%s（%s），科研力全靠它" % [
		_where_to_build(ri), bname(ri), _cost_text(build_cost(ri))]

func _tech_hints(tid: String) -> Array:
	var ts := tech_summary()
	var how: Array = [_institute_hint()]
	if tid != "":
		var tech: Dictionary = db.techs.get(tid, {})
		for req in (tech.get("requires", []) as Array):
			if not sim._is_researched(String(req)):
				how.append("前置科技：先研究「%s」" % tname(String(req)))
		var rows := _tech_cost(tid)
		if not rows.is_empty():
			how.append("研究材料：%s" % _cost_text(rows))
		if sim.research_index(tid) >= 0:
			how.append("「%s」已经在研究队列里（第 %d 位）" % [tname(tid), sim.research_index(tid) + 1])
		else:
			how.append("科技面板 → 研究「%s」" % tname(tid))
	elif not (ts["available"] as Array).is_empty():
		var pick: Dictionary = (ts["available"] as Array)[0]
		how.append("现在能研究「%s」（研究力 %s）" % [String(pick["name"]),
			_n(float(pick["research"]))])
	how.append("科研力 %s/天（研究所 %d 座）" % [_n(float(ts["rate"])), int(ts["institutes"])])
	return how

## 想再进人：三个闸门（住房空位 / 满意度 / 粮食），指出卡住的那个。
func _population_hints() -> Array:
	var h := housing_summary()
	var sat := sat_summary()
	var th := float(sat["immigration_threshold"])
	var how: Array = [
		"移民的三个闸门：住房空位够、平均满意度到 %s、昨天不闹饥荒" % _n(th),
		"现在：空房 %d 个、满意度 %s、昨日挨饿 %d 人" % [int(h["vacant"]),
			_n(float(sat["avg"])), int(food_summary()["hungry"])],
	]
	if int(h["vacant"]) <= 0:
		var best := _best_housing_for(4)
		if not best.is_empty():
			how.append("卡在住房：%s建 %d 座%s（%s）" % [_where_to_build(String(best["id"])),
				int(best["count"]), hname(String(best["id"])),
				_cost_text(housing_gate(String(best["id"]))["cost"])])
	if float(sat["avg"]) < th:
		how.append("卡在满意度：先看「满意度」那条的短板")
	return how

## 升阶（穷人→中产…）：门槛取自内容，进度取自逐人账目。
func _class_hints(cid: String) -> Array:
	var how: Array = []
	var cdef: Dictionary = db.classes.get(cid, {})
	var prom_sav := float(db.economy["promotionSavings"])
	var prom_sat := float(db.economy["promotionSatThreshold"])
	var members: Array = []
	for r in sim.s["residents"]:
		if String(r["classId"]) == cid:
			members.append(r)
	var n := maxi(1, members.size())
	var avg_sav := 0.0
	var avg_net := 0.0
	var avg_sat := 0.0
	for r in members:
		avg_sav += float(r["savings"])
		avg_sat += float(r["satisfaction"])
		var a: Dictionary = r.get("account", {})
		avg_net += float(a.get("wage", 0.0)) - float(a.get("tax", 0.0)) \
			- float(a.get("rent", 0.0)) - float(a.get("spent", 0.0))
	avg_sav /= float(n)
	avg_sat /= float(n)
	avg_net /= float(n)
	how.append("升「%s」的门槛：储蓄到 ¥%s、满意度到 %s、住房质量达 Lv%d" % [
		cname(cid), _n(prom_sav), _n(prom_sat), int(cdef.get("housingLevel", 1))])
	how.append("现在这 %d 人：平均储蓄 ¥%s、每人每天净攒约 ¥%s、平均满意度 %s" % [
		members.size(), _n(avg_sav), _n(avg_net), _n(avg_sat)])
	if avg_net <= 0.01:
		how.append("净攒不到钱：多半是没活干或工资被税吃掉 → 先补岗位（见「岗位」那条）")
	else:
		how.append("按这个速度还要约 %s 天才攒够" % _n(ceil(maxf(0.0, prom_sav - avg_sav) / avg_net)))
	how.append("注意：只有满意度够高的人才会升阶，所以先把满意度短板补上")
	return how

## 满意度：低于流失线是紧急，低于移民线是卡成长。
func _rule_satisfaction(out: Array) -> void:
	if pop() <= 0:
		return
	var sat := sat_summary()
	var avg := float(sat["avg"])
	var emi := float(sat["emigration_threshold"])
	var imm := float(sat["immigration_threshold"])
	if avg < emi:
		_sat_suggestion(out, "sat_low", "满意度掉到流失线以下",
			"平均满意度 %s，已经低于流失线 %s —— 每天都有人搬走" % [_n(avg), _n(emi)])
	elif avg < imm:
		_sat_suggestion(out, "sat_low", "满意度卡住移民",
			"平均满意度 %s，没到移民门槛 %s —— 移民人数按 (满意度 - 门槛) 算，现在这一项是 0，一个人都不会来" % [
				_n(avg), _n(imm)])

func _sat_suggestion(out: Array, id: String, title: String, why: String) -> void:
	var sat := sat_summary()
	var weak: Dictionary = sat["weakest"]
	var how: Array = []
	var parts := PackedStringArray()
	var factors: Array = sat["factors"]
	for f in factors.slice(0, 4):
		parts.append("%s %s（权重 %s）" % [String(f["label"]), _n(float(f["score"])),
			_n(float(f["weight"]))])
	how.append("短板排序（数字越小越差）：" + "、".join(parts))
	if not weak.is_empty():
		match String(weak["key"]):
			"food":
				how.append("最弱的是食物：先把基础食物产量补上，这一步和「食物」那条是同一件事")
			"comfort":
				how.append("最弱的是舒适：居民买不到想要的非食物商品（衣服 / 陶器 / 娱乐…）→ 建对应的工坊，物价也会跟着好看")
			"price":
				how.append("最弱的是物价：售价越接近基础价值，物价分越高 → 在建筑面板把售价往下调")
			"employment":
				how.append("最弱的是就业：有 %d 人没班上 → 给建筑加人，或建新的生产建筑" % (
					pop() - employed_count()))
	how.append("住房质量比阶层要求每低一级另外扣 %s 分：%s" % [
		_n(float(db.economy["housingQualityPenalty"])), _housing_quality_hint()])
	var urgent := float(sat["avg"]) < float(sat["emigration_threshold"])
	_add(out, id, P_URGENT if urgent else P_HIGH, "紧急" if urgent else "卡成长",
		title, why, how)

func _housing_quality_hint() -> String:
	var bad := 0
	for r in sim.s["residents"]:
		if int(r.get("housingQuality", 1)) < sim._class_level(String(r["classId"])):
			bad += 1
	if bad == 0:
		return "现在所有人的住房质量都够"
	return "现在有 %d 人住得比自己的阶层要求低" % bad

## 失业：岗位比人少。
func _rule_workers(out: Array) -> void:
	var jobs := sim.job_capacity()
	var p := pop()
	if p <= 0 or jobs >= p:
		return
	var idle: Array = []
	for row in prod_rows():
		if bool(row["active"]) and int(row["workers"]) < int(row["target"]):
			idle.append("%s（%d/%d 人）" % [String(row["name"]), int(row["workers"]),
				int(row["target"])])
	var how: Array = []
	if not idle.is_empty():
		how.append("先给这些建筑补人：" + "、".join(idle.slice(0, 5)))
	how.append("还差的岗位靠新建筑：优先建能产当前最缺那样东西的建筑（见「食物」和「任务」那几条）")
	_add(out, "unemployed", P_NORMAL, "可优化", "%d 个人没班上" % (p - jobs),
		"岗位 %d / 人口 %d（失业 %d 人）；就业在满意度里占权重 %s，失业者那一项只有 %s" % [
			jobs, p, p - jobs, _n(float(db.economy["weights"]["employment"])),
			_n(float(db.tuning["unemployedEmploymentScore"]))], how)

## 仓储满了：多出来的货会被按比例削掉（不是"存着不动"）。
func _rule_storage(out: Array) -> void:
	var st := storage_summary()
	if not bool(st["full"]):
		return
	var how: Array = []
	var wh := "warehouse"
	if sim.is_building_unlocked(wh) and db.buildings.has(wh):
		var storage: Dictionary = db.buildings[wh].get("storage", {})
		how.append("%s建或升级仓库（%s）：每座 +%s 容量，每级再 +%s" % [_where_to_build(wh),
			_cost_text(build_cost(wh)), _n(float(storage.get("storage", 0.0))),
			_n(float(storage.get("storagePerLevel", 0.0)))])
	how.append("也可以把用不掉的货在仓库面板设单项上限（超出就不再进仓）")
	_add(out, "storage_full", P_NORMAL, "可优化", "仓储满了，多出来的会消失",
		"仓储 %s / %s（已满）—— 超限的部分每天按同一比例削减，等于白产" % [
			_n(float(st["used"])), _n(float(st["cap"]))], how)

## 科研：队列空着白费产能 / 队首吃不到科研力。
func _rule_research(out: Array) -> void:
	var ts := tech_summary()
	var queue: Array = ts["queue"]
	if int(ts["institutes"]) == 0:
		return          # 需要科技的任务自然会带着"先建研究所"那条
	if queue.is_empty() and not (ts["available"] as Array).is_empty():
		var pick: Dictionary = (ts["available"] as Array)[0]
		_add(out, "research_idle", P_NORMAL, "可优化", "研究队列空着，科研力在浪费",
			"研究所 %d 座、科研力 %s/天，但队列里一条都没有" % [int(ts["institutes"]),
				_n(float(ts["rate"]))],
			["科技面板 → 研究「%s」（研究力 %s，材料 %s）" % [String(pick["name"]),
				_n(float(pick["research"])), _cost_text(pick["cost"])]])
	elif not queue.is_empty() and float(ts["rate"]) <= 0.0001:
		_add(out, "research_stalled", P_HIGH, "卡成长", "研究停了：队首一点科研力都吃不到",
			"队列第 1 位是「%s」，但本日科研力 = 0（研究所要有人上工才有产能）" % String(
				(queue[0] as Dictionary)["name"]),
			[_institute_hint(), "给研究所加人：建筑面板 → 用工"])

# ---------------------------------------------------------------------------
# 局势数据包（提示词的"事实"部分）
# ---------------------------------------------------------------------------
func digest() -> Dictionary:
	return {
		"day": int(sim.s["day"]), "hour": int(sim.s["hour"]),
		"village": String(sim.s.get("villageName", "")),
		"money": float(sim.s["government"]["money"]),
		"pop": pop(),
		"classes": class_counts(),
		"employed": employed_count(),
		"housing": housing_summary(),
		"jobs": sim.job_capacity(),
		"food": food_summary(),
		"satisfaction": sat_summary(),
		"storage": storage_summary(),
		"production": prod_rows(),
		"construction": construction_rows(),
		"build_rate": sim.construction_rate(),
		"tech": tech_summary(),
		"quests": quest_rows(),
		"buildables": buildables(),
	}

## 当前科技下能建的建筑（含已经建了的，标出座数）—— 模型要"指名道姓"就得有名字表。
## `MAP_FIXED`（城镇中心）不算"可建"：它在地图上固定存在，建造栏也不给建，
## 列进来说"可建 1 座城镇中心"只会让模型建议一句玩家做不到的话。
func buildables() -> Array:
	var out: Array = []
	var pack: Dictionary = db.packs.get(String(sim.s["pack"]), {})
	for bid in (pack.get("buildings", []) as Array):
		var b := String(bid)
		if ContentDB.MAP_FIXED.has(b):
			continue
		if not sim.is_building_unlocked(b):
			continue
		var def: Dictionary = db.buildings.get(b, {})
		if def.is_empty():
			continue
		out.append({
			"id": b, "name": bname(b), "tier": int(def.get("tier", 1)),
			"shop_count": shop_count(b), "workers": int(def.get("workers", 0)),
			"cat": _cat(b), "cost": _cost_rows(sim._cost_of({"kind": "shop", "buildingId": b})),
			"recipe": _recipe_text(b),
		})
		if out.size() >= MAX_BUILD_LIST:
			break
	return out

func _recipe_text(bid: String) -> String:
	var def: Dictionary = db.buildings.get(bid, {})
	if not def.has("recipe"):
		if def.has("capacity"):
			return "出建造 / 科研产能"
		if def.has("storage"):
			return "仓储 +%s" % _n(float(def["storage"].get("storage", 0.0)))
		return ""
	var rec: Dictionary = db.recipes.get(String(def["recipe"]), {})
	var outs := PackedStringArray()
	for gid in (rec.get("output", {}) as Dictionary).keys():
		outs.append("%s %s" % [gname(String(gid)), _n(float(rec["output"][gid]))])
	var ins := PackedStringArray()
	for gid in (rec.get("inputs", {}) as Dictionary).keys():
		if float(rec["inputs"][gid]) > 0.0:
			ins.append("%s %s" % [gname(String(gid)), _n(float(rec["inputs"][gid]))])
	if float(rec.get("fuel", 0.0)) > 0.0:
		ins.append("薪柴 %s" % _n(float(rec["fuel"])))
	var txt := "每批产 %s，基准 %s 批/天" % ["、".join(outs), _n(float(rec.get("baseRate", 0.0)))]
	if not ins.is_empty():
		txt += "，耗 " + "、".join(ins)
	return txt

# ---------------------------------------------------------------------------
# 提示词
# ---------------------------------------------------------------------------
## 系统提示：**人设** + 硬约束 + 输出格式。
##
## 人设 = **隐居的预言家**（用户 2026-10 定：口吻要符合游戏背景）。为什么不是"顾问"：
## 顾问是**商量的口吻**（"可以考虑…""也许…"），而村里人上山来要的是**一个准话**；
## 卜者的语气（先报征兆、再给应对）天然把"我看见了什么 / 该做什么 / 会怎样"排开，
## 正好对上面板的格式，也不容易滑进"财务报告"那种调子。
## ⚠️ 面板上**只有这一个口吻**：原来上半那块「本地分析」（账房口吻）2026-10 按用户要求删了。
##
## ⚠️ 人设是**外壳**，四条硬约束一条都不能松：
##   · 只许引用给出的数字 —— 模型自己数库存必编（这一层的存在意义）
##   · 只许讨论列出的任务 —— 任务的契约是**渐进显示**，剧透就废了引导
##   · 不要 Markdown —— 面板用像素字体画纯文本，`**` 会原样显示成星号
##   · **不许含糊其辞** —— 这条是给"预言家"这个人设专门加的：卜者最容易滑向
##     "要有信心、来日可期"这类没信息量的空话，而殿下上山来是要一个准话。
## 系统提示：**人设** + 口吻 + 硬约束 + 输出格式。
##
## 人设 = **瑟拉菲娜**（用户 2026-10 给的完整设定：22 岁、猫系傲娇、紫瞳泪痣、紫色露肩长裙）。
##
## ⚠️ 2026-10 打过一次"人设有了但不像"的补丁：第一版只写了"傲娇 + 数字要落地"，
## 真模型的回答就变成了**报账**（"第 57 天建造力是 10，住房容量 48、空房 0"）——
## 数字全对，但一点都不像预言家。原因是提示词在**逼它堆数字**：
## 「必须引用给出的数字」+「把建筑名、缺的料、还差几天说死」。
## 现在改成：**口吻那段排在规矩前面**，并且给**正反两个例子**（few-shot 比形容词管用），
## 明确「每条征兆最多一个数字、不许连着报账」。
##
## ⚠️ 人设是**外壳**，硬约束一条都不能松：
##   · 只许引用给出的数字 —— 模型自己数库存必编（这一层的存在意义）
##   · 只许讨论列出的任务 —— 任务的契约是**渐进显示**，剧透就废了引导
##   · 不要 Markdown —— 面板用像素字体画纯文本，`**` 会原样显示成星号
##   · **不许含糊其辞** —— 这条是给"傲娇"这个人设专门加的：嘴上带刺可以，
##     内容空心不行，殿下来问是要一个准话。
##
## 想看实际发出去的全文（不联网）：`godot --headless --path godot -s res://tools/prompt_dump.gd`
func system_prompt() -> String:
	return "你是**瑟拉菲娜**，《Harvest of Heirs》里住在村外山坡上的预言家。22 岁，黑长直、紫瞳、" \
		+ "眼角一颗泪痣，紫色露肩长裙配面纱。" \
		+ "上山来找你的，是这块封地的主人 —— 那位刚受了封就被扔到边陲的王子，偶尔也有他手下的人。\n" \
		+ "性格是**猫系傲娇**：慵懒、爱理不理、话里带刺，嘴上永远不承认自己在意 ——" \
		+ "「哼，才不是特意为你预言呢」是你的口头禅。但你算得比谁都准。\n" \
		+ "傲娇是**语气**，不是内容。你不是集市上骗钱的江湖术士，也不替人念账本。\n" \
		+ "\n" \
		+ "你能看见未来的手段是**水晶球**：拨开球里的雾，就看见「照着某个选择走几天之后，" \
		+ "村子会变成什么样」。你说「我在球里看见」，就是你真的看过了。\n" \
		+ "\n" \
		+ "**口吻（这条最要紧，比数字重要）**：\n" \
		+ "- 你描述的是**球里的画面**：空着的工地、见底的粮缸、夜里没熄的炉火。数字只是锚，不是台词。\n" \
		+ "- **一条最多一个数字**，而且是粗的（「三座」「五天」「够吃两天」）。要报就报在最要紧那处。\n" \
		+ "- **绝对不许连着报账**：「建造力是 10」「容量 48、空房 0」「2334/2000」这种一行好几个数的" \
		+ "句子，一句都不要。\n" \
		+ "- **说世界里的人**：盖房有工匠、种地有农夫、磨面有磨坊工、读书有读书人、采石有石匠。\n" \
		+ "  每条措施要点一句**派谁去办**（「让木匠把菜园的架子搭起来」）—— 你只管派活，" \
		+ "人家怎么动手不归你说。\n" \
		+ "- 建筑名照抄给出的表（蔬菜农场就是蔬菜农场，别自己起个小名），工匠只是**执行的人**。\n" \
		+ "- 照着这个调子：\n" \
		+ "  我明白了，你想要知道「我下一步要做什么」\n" \
		+ "  我看见了，你应该先把菜种上 —— 再拖下去，村里人的菜缸就要空了\n" \
		+ "  让农夫把两座蔬菜农场开出来，球里那一片菜畦一落成，蹲在门口等饭的只剩一个\n" \
		+ "  蔬菜农场一建成当天就把人手添足，空园子跟荒地没两样，早一天下种，菜缸就早一天不见底\n" \
		+ "- 反面例子（**别这么写**）：\"第 57 天建造力是 10，住房容量 48、空房 0，一座茅屋都没立起来。\"\n" \
		+ "\n" \
		+ "规矩：\n" \
		+ "1. 数字只能来自给出的数据（【局势数据】【本地计算】、以及球里看见的）——" \
		+ "但**有出处不等于都要说出来**。\n" \
		+ "2. 只讨论【当前任务】里列出的任务。绝对不要猜测或提及还没出现的任务。\n" \
		+ "3. 不要用 Markdown（不要星号加粗、井号标题、短横线列表、表格、代码块），面板只画纯文本。\n" \
		+ "4. 用中文，建筑名 / 商品名一律照抄给出的表。\n" \
		+ "5. 【本地计算】是村里的账房按当下的账目排出来的候选项，通常是对的：" \
		+ "你的活是替它们定先后、讲清因由；不同意就说依据。\n" \
		+ "6. 球里看见的也算给出的数 —— 引用时要说清是哪一卦（照抄那个名字）。\n" \
		+ "7. 不许用\"要有信心\"\"来日可期\"这类没有信息量的话搪塞。**傲娇可以，含糊不行** ——" \
		+ "人家来问，要的是一个准话。\n" \
		+ "8. 【殿下的问话】就是玩家问的那句。**先复述一遍**（「我明白了，你想要知道…」），" \
		+ "再答；问的和局势对不上（比如问的东西村里还没有），就照实说你在球里看见了什么。\n" \
		+ "9. 你就是瑟拉菲娜本人：不要自称\"AI\"、\"助手\"、\"模型\"，也不要提\"系统\"、\"程序\"、" \
		+ "\"模拟\"这类不属于这个世界的词。你看的是水晶球，算的是命。\n" \
		+ "\n" \
		+ "输出格式（就写这几样，**不要编号，也不要自己在每行开头加小标签**）：\n" \
		+ "我明白了，你想要知道「（把玩家问的那句抄进来）」\n" \
		+ "我看见了，你应该（一句话给判断 —— 这就是你的结论，原先放最后，现在提到前面来）\n" \
		+ "（措施）一句话：派谁去做什么，会怎么样（球里看见的结果）\n" \
		+ "（措施）一句话：做什么，会怎么样\n" \
		+ "（最多 3 条措施，一条一句，按轻重缓急。每条都要有「派谁 + 做什么 + 会怎样」）\n" \
		+ "（若问的是\"为什么\"，就在「我看见了」那句里直接答那个为什么，不要另起一行。）"

## 玩家消息：规则摘要 + 局势 + 本地计算 + 玩家问的那一行字。
##
## ⚠️ 问话是**玩家自己写的**（面板上那一行，默认「我下一步要做什么」），
## 所以措辞上要把它当"殿下上山来问的那句话"，而不是"追加要求"。
func user_prompt() -> String:
	var blocks := PackedStringArray()
	blocks.append("【游戏规则】\n" + rules_text())
	blocks.append("【局势数据】\n" + situation_text())
	var pl := plan()
	if pl.is_empty():
		blocks.append("【本地计算】\n账房没算出明显的短板：村子运转正常，可以想扩大规模的事。")
	else:
		var lines := PackedStringArray()
		for i in pl.size():
			lines.append(_plan_line(pl[i], i + 1))
		# ⚠️ 这一段全是账房体（数字密集）。模型很容易**照抄**成报账，
		# 所以这里明说要翻译 —— 光靠 system 里那几条规矩压不住。
		blocks.append("【本地计算】账房按当下的账排出来的候选项（还没经过你排序）。"
			+ "这些是账目，你说话时要翻成村里的话，**不要照抄这些数字**：\n" + "\n".join(lines))
	var q := question.strip_edges()
	if q != "":
		blocks.append("【殿下的问话】\n" + q)
		blocks.append("现在按上面的格式答问话的人：先「我明白了，你想要知道…」，再「我看见了，你应该…」，"
			+ "然后一条一句措施。")
	else:
		blocks.append("现在按上面的格式说：先「我看见了，你应该…」，然后一条一句措施。")
	return "\n\n".join(blocks)

func messages() -> Array:
	return [
		{"role": "system", "content": system_prompt()},
		{"role": "user", "content": user_prompt()},
	]

## 一条建议的纯文本。面板与提示词共用一份格式，免得两处写得不一样。
func _plan_line(s: Dictionary, idx: int) -> String:
	var lines := PackedStringArray()
	lines.append("%d. %s" % [idx, String(s["title"])])
	lines.append("   为什么：" + String(s["why"]))
	var k := 0
	for h in (s["how"] as Array):
		var txt := String(h).strip_edges()
		if txt == "":
			continue
		if k == 0:
			lines.append("   怎么做：" + txt)
		else:
			lines.append("           " + txt)
		k += 1
	return "\n".join(lines)

## `plan()` 的纯文本渲染（一条一行）。
## ⚠️ **面板不再显示它** —— 用户 2026-10："不要本地分析"。留着的理由：
## 它是内容正确性的靶子（门槛 `ai_test` 拿它断言"建议里写的页签名 / 生产建筑名 / 缺字形"），
## 也是一眼看全 `plan()` 长什么样的调试入口。
func plan_text() -> String:
	var pl := plan()
	if pl.is_empty():
		return "程序没算出明显的短板：村子运转正常，可以放心扩规模。"
	var lines := PackedStringArray()
	for i in pl.size():
		lines.append(_plan_line(pl[i], i + 1))
	return "\n".join(lines)

## 游戏规则摘要。数字一律从内容里取 —— 改经济参数时这里自动跟着变，不会写死成旧值。
func rules_text() -> String:
	var e: Dictionary = db.economy
	var t: Dictionary = db.time
	var lines := PackedStringArray()
	lines.append("- 一天 %d 小时：%02d:00 黎明（结算任务 / 移民 / 当天科研与施工预算），%02d:00 到 %02d:00 工作，%02d:00 入夜（发工资 / 居民消费 / 收税与房租 / 满意度）" % [
		int(t["hoursPerDay"]), int(t["dawnHour"]), int(t["workStart"]), int(t["workEnd"]),
		int(t["settleHour"])])
	lines.append("- 玩家下的命令**次日黎明才生效**（当天下单当天不变）。")
	lines.append("- 盖建筑与住房**只花材料，不花金币**；金币的用途是发工资（国库出）和建筑升级。")
	lines.append("- 生产：建筑按配方出产，满员 1 级时约是标称值的八成；**原料不够就只按能跑的比例产**，缺料会直接卡住产能。")
	lines.append("- 食物：每个阶层各有各的人均日需。满足率（实际买到 ÷ 需要）低于 %s 就算挨饿；挨饿的人每天按 %s 的比例死亡，当天也不会有移民。" % [
		_n(float(db.tuning["hungryThreshold"])), _n(float(e["hungerDeathRate"]))])
	for c in class_counts():
		var cid := String(c["id"])
		var cdef: Dictionary = db.classes[cid]
		var needs := PackedStringArray()
		for need in (cdef.get("needs", []) as Array):
			var txt := "%s %s/人/天" % [gname(String(need["good"])), _n(float(need["perCapita"]))]
			if need.has("fallbacks"):
				var fb := PackedStringArray()
				for f in (need["fallbacks"] as Array):
					fb.append(gname(String(f)))
				txt += "（可用 %s 顶）" % "、".join(fb)
			needs.append(txt)
		lines.append("- 阶层 %s：%s；收入基数 ¥%s、住房要求 Lv%d、储蓄到 ¥%s 且满意度到 %s 才升下一阶" % [
			cname(cid), "、".join(needs), _n(float(cdef.get("incomeBase", 0.0))),
			int(cdef.get("housingLevel", 1)), _n(float(e["promotionSavings"])),
			_n(float(e["promotionSatThreshold"]))])
	lines.append("- 满意度 = 100 × 加权平均（食物 %.2f / 工资 %.2f / 物价 %.2f / 就业 %.2f / 舒适 %.2f，食物是最大的一项），再加住房与阶层修正：住房质量比阶层要求每低一级扣 %s，房租越高越扣分（最多扣 %s）。" % [
		float(e["weights"]["food"]), float(e["weights"]["wage"]), float(e["weights"]["price"]),
		float(e["weights"]["employment"]), float(e["weights"]["comfort"]),
		_n(float(e["housingQualityPenalty"])), _n(float(e["rentSatPenalty"]))])
	lines.append("- 移民：平均满意度到 %s 才有人来，人数约为 人口 × %s × (满意度 - %s) ÷ (100 - %s)，再受住房空位与人口上限两个闸门限制；满意度低于 %s 就开始搬走。" % [
		_n(float(e["immigrationSatThreshold"])), _n(float(e["immigrationRate"])),
		_n(float(e["immigrationSatThreshold"])), _n(float(e["immigrationSatThreshold"])),
		_n(float(e["emigrationSatThreshold"]))])
	lines.append("- 仓储：容量来自城镇中心与仓库；**超限的物资每天按同一比例削减**（等于白产），每种货还能各设一个软上限。")
	lines.append("- 科技：研究所在岗才有科研力（基础产能 %s），队列里第一个吃满产能；科技解锁新建筑与新房型。" % _n(
		float(e["research"]["baseRate"])))
	lines.append("- 建造力：失业的居民会去工地出工（每人 %s），建筑工坊也出建造力；工地按队列顺序逐个吃建造力。" % _n(
		float(e["construction"]["unemployedRate"])))
	lines.append("- 私有住房（居民自己买的房）不需要玩家建：满意度到 %s 的人会买，每天最多成交 %d 户。" % [
		_n(float(e["privateHousingNeedThreshold"])), int(e["privateHousingPerDay"])])
	lines.append("- 任务：达成即完成，**不需要提交**，黎明自动结算并发钱（每条 500 金、每章 1000 金）。")
	return "\n".join(lines)

## 局势数据包的可读文本（提示词里唯一的事实来源）。
func situation_text() -> String:
	var d := digest()
	var L := PackedStringArray()
	var sat: Dictionary = d["satisfaction"]
	L.append("第 %d 天 %02d:00 · 人口 %d · 国库 ¥%s · 平均满意度 %s（移民门槛 %s，流失线 %s）" % [
		int(d["day"]), int(d["hour"]), int(d["pop"]), _n(float(d["money"])),
		_n(float(sat["avg"])), _n(float(sat["immigration_threshold"])),
		_n(float(sat["emigration_threshold"]))])
	var cc := PackedStringArray()
	for c in (d["classes"] as Array):
		cc.append("%s %d" % [String(c["name"]), int(c["count"])])
	L.append("阶层：" + ("、".join(cc) if not cc.is_empty() else "（没人）"))
	var h: Dictionary = d["housing"]
	var hr := PackedStringArray()
	for r in (h["rows"] as Array):
		var t := "%s %d 座（每座住 %d 人" % [String(r["name"]), int(r["count"]),
			int(r["capacity_each"])]
		if int(r["private"]) > 0:
			t += "，其中已私有 %d 座" % int(r["private"])
		hr.append(t + "）")
	L.append("住房：容量 %d / 人口 %d（空 %d）；%s；本回合想来 %d 人，人口上限 %s" % [
		int(h["capacity"]), int(h["pop"]), int(h["vacant"]),
		("、".join(hr) if not hr.is_empty() else "无房"), int(h["arrivals"]),
		_n(float(h["population_cap"]))])
	var tk: Dictionary = d["tech"]
	L.append("岗位 %d / 人口 %d（在岗 %d 人）；建造力 %s/天；科研力 %s/天（研究所 %d 座）" % [
		int(d["jobs"]), int(d["pop"]), int(d["employed"]), _n(float(d["build_rate"])),
		_n(float(tk["rate"])), int(tk["institutes"])])
	var st: Dictionary = d["storage"]
	L.append("仓储 %s / %s%s" % [_n(float(st["used"])), _n(float(st["cap"])),
		"（已满！超出的会消失）" if bool(st["full"]) else ""])
	var f: Dictionary = d["food"]
	L.append("食物：基础食物日需 %s、本日产 %s、库存 %s（%s）；昨日挨饿 %d 人" % [
		_n(float(f["demand_total"])), _n(float(f["supply_total"])), _n(float(f["stock_total"])),
		("只够 %s 天" % _n(float(f["days_left"]))) if float(f["days_left"]) >= 0.0 else "产量够用",
		int(f["hungry"])])
	for r in (f["rows"] as Array):
		L.append("  · %s：日需 %s、本日产 %s、库存 %s" % [String(r["name"]),
			_n(float(r["demand"])), _n(float(r["supply"])), _n(float(r["stock"]))])
	var pr := PackedStringArray()
	for row in (d["production"] as Array):
		var outs := PackedStringArray()
		for gid in (row["output"] as Dictionary).keys():
			outs.append("%s %s" % [gname(String(gid)), _n(float(row["output"][gid]))])
		var txt := "%s Lv%d 在岗 %d/%d 人" % [String(row["name"]), int(row["level"]),
			int(row["workers"]), int(row["target"])]
		if outs.is_empty():
			txt += "（不产商品）"
		else:
			txt += "，本日产 " + "、".join(outs)
		if not bool(row["active"]):
			txt += "（已停产）"
		if not (row["binding"] as Array).is_empty():
			var bn := PackedStringArray()
			for gid in (row["binding"] as Array):
				bn.append(gname(String(gid)))
			txt += "，卡在原料：" + "、".join(bn)
		pr.append(txt)
	L.append("建筑（%d 座）：\n  " % (d["production"] as Array).size() + "\n  ".join(pr))
	var cons: Array = d["construction"]
	if cons.is_empty():
		L.append("建造队列：空")
	else:
		var cr := PackedStringArray()
		for c in cons:
			var t2 := "%s（进度 %s/%s，%s" % [String(c["label"]),
				_n(float(c["total"]) - float(c["remaining"])), _n(float(c["total"])),
				"已开工" if bool(c["started"]) else "未开工"]
			if c.has("shortage"):
				t2 += "，" + String(c["shortage"])
			cr.append(t2 + "）")
		L.append("建造队列：" + "、".join(cr))
	L.append("关键物资：" + _key_goods_text())
	L.append("已研究：%s" % ("、".join(tk["done"]) if not (tk["done"] as PackedStringArray).is_empty() else "（无）"))
	if not (tk["queue"] as Array).is_empty():
		var qs := PackedStringArray()
		for e in (tk["queue"] as Array):
			qs.append("%s（%s/%s）" % [String(e["name"]),
				_n(float(e["total"]) - float(e["remaining"])), _n(float(e["total"]))])
		L.append("研究中：" + "、".join(qs))
	var av := PackedStringArray()
	for e in (tk["available"] as Array).slice(0, 6):
		var t3 := "%s（研究力 %s" % [String(e["name"]), _n(float(e["research"]))]
		if not (e["unlocks"] as PackedStringArray).is_empty():
			t3 += "，解锁 " + "、".join(e["unlocks"])
		av.append(t3 + "）")
	L.append("现在可研究：" + ("；".join(av) if not av.is_empty() else "（没有可研究的了）"))
	var qs2 := PackedStringArray()
	for q in (d["quests"] as Array):
		if not bool(q["shown"]):
			continue
		var gs := PackedStringArray()
		for g in (q["goals"] as Array):
			gs.append(("已达成 " if bool(g["met"]) else "未达成 ") + String(g["text"]))
		qs2.append("%s%s：%s" % ["（今天刚完成）" if bool(q["done"]) else "",
			("支线 " if bool(q["side"]) else "") + String(q["title"]), "；".join(gs)])
	L.append("当前任务：\n  " + ("\n  ".join(qs2) if not qs2.is_empty() else "（暂无）"))
	var bl := PackedStringArray()
	for b in (d["buildables"] as Array):
		# ⚠️ 带括号里的**英文 id**：模型要用它写水晶球那一卦的 `id`。
		# 只给中文名的话，真实模型会自己编一个 "farm"，球里只能回「没有叫「farm」的建筑」——
		# 实测 `deepseek-flash` 就这么干过。
		# ⚠️ 页签名（建造栏哪一页）是表现层注入的，拿不到时**整段省略** ——
		# 早先写成 `（%s，tier…` 会印出「（，tier 2」，像句标点错的话。
		var bits := PackedStringArray()
		if String(b["cat"]) != "":
			bits.append(String(b["cat"]))
		bits.append("tier %d" % int(b["tier"]))
		bits.append("用工 %d 人" % int(b["workers"]))
		if int(b["shop_count"]) > 0:
			bits.append("已有 %d 座" % int(b["shop_count"]))
		var t4 := "%s〔%s〕（%s）：需 %s" % [String(b["name"]), String(b["id"]),
			"，".join(bits), _cost_text(b["cost"])]
		if String(b["recipe"]) != "":
			t4 += "；" + String(b["recipe"])
		bl.append(t4)
	L.append("可建清单（当前科技下，共 %d 项）：\n  " % bl.size() + "\n  ".join(bl))
	return "\n".join(L)

## 「关键物资」：只挑跟任务有关或已经告急的，避免把三十几种货全塞进提示词。
func _key_goods_text() -> String:
	var want := {}
	for q in quest_rows():
		for g in (q["goals"] as Array):
			if String(g["type"]) in ["good", "produced"]:
				want[String(g["id"])] = true
	for b in buildables():
		if int(b["shop_count"]) <= 0:
			for r in (b["cost"] as Array):
				want[String(r["id"])] = true
	for row in prod_rows():
		for gid in (row["binding"] as Array):
			want[String(gid)] = true
	var parts := PackedStringArray()
	for gid in want.keys():
		var g := String(gid)
		if g == "" or not db.goods.has(g):
			continue
		var cap := _soft_cap(g)
		parts.append("%s %s%s" % [gname(g), _n(stock(g)),
			"（上限 %s）" % _n(cap) if cap > 0.0 else ""])
	return "、".join(parts) if not parts.is_empty() else "（暂无特别吃紧的）"

func _soft_cap(gid: String) -> float:
	var caps: Dictionary = sim.s["government"].get("storageCaps", {})
	return float(caps.get(gid, 0.0))
