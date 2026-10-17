class_name Trial
extends RefCounted

# ===========================================================================
# 沙盘（"把游戏模拟引擎当工具交给 AI" 的那件工具）
#
# 一件事：拿**当前村子的一份克隆**，按方案下达命令，往前跑 N 天，报结果。
#
# 四条硬要求：
#
#   1. **不碰真实状态**：只读 `source.s`（`duplicate(true)` 出副本），跑完当着没跑过。
#      门槛 `ai_test` 会拿"跑完全套之后 sim.s 逐字节不变"来钉这一条。
#   2. **命令走引擎自己的命令**：翻译成 `_apply_actions()` 认的那几种动作，交给
#      `tick_hour()` → 黎明 `_apply_actions()`。**绝不另写一套规则**：
#      缺料、科技没解锁、没有那座建筑、材料不够 —— 都由引擎自己拒，我们如实报告。
#   3. **确定性**：同一份状态 + 同一个方案 = 同一个结果（rng 状态一起复制）。
#      所以同一个方案跑两遍结果必须逐位相同。
#   4. **省着花**：天数 ≤ `MAX_DAYS`、命令 ≤ `MAX_MANDATES` —— 这是给模型用的工具，
#      不能让它一次把 CPU 吃光（实测：克隆 0.1~0.4 ms，跑 5 天 6~15 ms，5 个方案 <100 ms）。
#
# ⚠️ 与 `Advisor` 的关系：汇总**复用 `Advisor` 的那些口径函数**（食物/住房/满意度/
#    规则引擎），所以沙盘报出来的数、提示词里给的数、面板上画的数是**同一套定义** ——
#    不然模型会看到两套数字。
# ===========================================================================

## 一次最多跑几天。用户定的是"5 日的决策"。
const MAX_DAYS := 5
## 一个方案里最多几条命令（防它一口气下单一整条产业链）。
const MAX_MANDATES := 12

## 沙盘能执行的命令类型。**刻意收窄**：只给"建设 / 研究 / 用工"这三类 ——
## 拆房、改税、改价这些会把村子搞乱的操作不开放给模型试（它可以建议，但不能在沙盘里乱试）。
const KINDS := ["build", "build_housing", "expand", "research", "set_workers"]

## 克隆一份可以随便跑的仿真核心（rng 状态一起带上，保证与真实村子同一起跑线）。
static func clone_core(source: SimCore) -> SimCore:
	var c := SimCore.new(source.db)
	c.s = source.s.duplicate(true)
	c.rng = Rng.new(source.rng.state)
	return c


## 把一个方案翻译成"第几天 → 引擎动作数组"。
##
## 方案（模型给的形状）：
##   {"label":"先补粮", "days":5, "actions":[
##        {"day":1, "type":"build", "id":"wheat_farm", "count":2},
##        {"day":3, "type":"research", "id":"stonework"}]}
##
## 返回 `{"by_day": {1: [动作...]}, "days": n, "rejected": ["为什么没下成", ...]}`。
static func translate(source: SimCore, plan: Dictionary) -> Dictionary:
	var days := clampi(int(plan.get("days", MAX_DAYS)), 1, MAX_DAYS)
	var by_day := {}
	var rejected := PackedStringArray()
	var used := 0
	var acts: Array = plan.get("actions", []) if plan.get("actions", []) is Array else []
	for raw in acts:
		if not (raw is Dictionary):
			rejected.append("方案里有一项不是对象：%s" % str(raw).substr(0, 40))
			continue
		var a: Dictionary = raw
		if used >= MAX_MANDATES:
			rejected.append("命令超过 %d 条，后面的没下" % MAX_MANDATES)
			break
		var kind := String(a.get("type", ""))
		var id := String(a.get("id", ""))
		var day := clampi(int(a.get("day", 1)), 1, days)
		if not KINDS.has(kind):
			rejected.append("不认的命令类型「%s」（只支持 %s）" % [kind, "、".join(KINDS)])
			continue
		var out := _one_command(source, kind, id, a, rejected)
		for act in out:
			var list: Array = by_day.get(day, [])
			list.append(act)
			by_day[day] = list
			used += 1
	return {"by_day": by_day, "days": days, "rejected": rejected}


## 把模型写的 id 认成真 id：先按英文 id 找，找不到再按**中文名**找。
##
## 为什么认中文名：实测 `deepseek-flash` 拿到的是「小麦农场〔wheat_farm〕」这种行，
## 一半的时候照用了英文 id，另一半写成"小麦农场"甚至自己编个 "farm"。
## 中文名认了（它和内容里的一字不差），编出来的名字照实拒 —— 拒的时候把真 id 也告诉它。
static func resolve_id(collection: Dictionary, raw: String) -> String:
	if collection.has(raw):
		return raw
	var want := raw.strip_edges()
	if want == "":
		return ""
	for k in collection.keys():
		var d: Variant = collection[k]
		if d is Dictionary and String((d as Dictionary).get("name", "")).strip_edges() == want:
			return String(k)
	return ""


## 一条命令 → 0..N 个引擎动作。认不出来就往 `rejected` 里写一句人话。
static func _one_command(source: SimCore, kind: String, id: String, a: Dictionary, rejected: PackedStringArray) -> Array:
	var out := []
	var db := source.db
	match kind:
		"build":
			var bid := resolve_id(db.buildings, id)
			if bid == "":
				rejected.append("没有叫「%s」的建筑（id 用可建清单里〔〕中的英文 id）" % id)
				return out
			if not source.is_building_unlocked(bid):
				var t := db.tech_for_building(bid)
				rejected.append("「%s」还锁着：要先研究「%s」" % [id, t])
				return out
			for _i in clampi(int(a.get("count", 1)), 1, 6):
				out.append({"type": "build", "buildingId": bid})
		"build_housing":
			var hid := resolve_id(db.housing, id)
			if hid == "":
				rejected.append("没有叫「%s」的住房" % id)
				return out
			if not source.is_housing_unlocked(hid):
				var t2 := db.tech_for_housing(hid)
				rejected.append("「%s」还锁着：要先研究「%s」" % [id, t2])
				return out
			for _i in clampi(int(a.get("count", 1)), 1, 6):
				out.append({"type": "build_housing", "goodId": hid})
		"expand":
			var sid := _first_shop(source, id)
			if sid == "":
				rejected.append("村里还没有「%s」，没法升级" % id)
				return out
			out.append({"type": "expand", "shopId": sid})
		"research":
			var tid := resolve_id(db.techs, id)
			if tid == "":
				rejected.append("没有叫「%s」的科技（id 用「现在可研究」里〔〕中的英文 id）" % id)
				return out
			if source._is_researched(tid):
				rejected.append("「%s」已经研究过了" % id)
				return out
			out.append({"type": "research", "techId": tid})
		"set_workers":
			var sid2 := _first_shop(source, id)
			if sid2 == "":
				rejected.append("村里还没有「%s」，没法派人" % id)
				return out
			# `value` 是文档里的名字，`count` 是一些模型顺手写的（实测 deepseek-flash）—— 都认
			var n := int(a.get("value", a.get("count", 0)))
			out.append({"type": "set_workers", "shopId": sid2, "value": clampi(n, 0, 99)})
	return out


## 某种建筑的第一座（`expand` / `set_workers` 用建筑 id 指名，模型不必背 `xxx#1` 这种实例 id）。
static func _first_shop(source: SimCore, raw: String) -> String:
	var def_id := resolve_id(source.db.buildings, raw)
	for shop in source.s["shops"]:
		if String(shop["defId"]) == def_id:
			return String(shop["id"])
	return ""


## 跑一条方案。返回 `{ok, summary, delta, rejected, days, label}`。
##
## `baseline` 由调用方（`ProphetAgent`）算一次传进来 —— 所有方案都跟同一个"什么都不做"
## 的 5 天对照，delta 才有意义。
static func run(source: SimCore, plan: Dictionary, baseline: Dictionary) -> Dictionary:
	var tr := translate(source, plan)
	var core := clone_core(source)
	var by_day: Dictionary = tr["by_day"]
	var days := int(tr["days"])
	# 从**现在**起跑满 days × 24 小时；每小时的第 0 小时投当天要下的命令。
	# ⚠️ 用"第几个模拟小时"而不是绝对 `day` 来排期：现在若是傍晚，绝对日期与
	#    "第 1 天"差一天，按绝对日期排期会让第 1 天的命令永远下不出去。
	for i in days * 24:
		if i % 24 == 0:
			core.tick_hour(by_day.get(i / 24 + 1, []))
		else:
			core.tick_hour([])
	var sum := summarize(core)
	return {
		"ok": true,
		"label": String(plan.get("label", "")),
		"days": days,
		"summary": sum,
		"delta": delta(baseline, sum),
		"rejected": Array(tr["rejected"]),
		# 沙盘里**新完成**的任务（跟真实状态比）—— 这是玩家最关心的一类结果
		"new_quests": new_quests(source, core),
	}


## 跑"什么都不做"的同样天数（所有方案的对照）。只算一次。
static func run_baseline(source: SimCore, days: int) -> Dictionary:
	var core := clone_core(source)
	for _i in clampi(days, 1, MAX_DAYS) * 24:
		core.tick_hour([])
	return summarize(core)


## 沙盘的一屏汇总。给模型看，也要短（15 个方案的结果都要塞进上下文）。
##
## 数字一律取整/一位小数：模型要照着念，太多小数位只会占 token。
static func summarize(core: SimCore) -> Dictionary:
	var ad := Advisor.new(core)
	var f := ad.food_summary()
	var h := ad.housing_summary()
	var sat := ad.sat_summary()
	var st := ad.storage_summary()
	var food := {}
	var problems := PackedStringArray()
	for r in (f["rows"] as Array):
		var demand := float(r["demand"])
		var supply := float(r["supply"])
		var stock := float(r["stock"])
		# `daysLeft`：库存 ÷（日需 − 日产）。**产量已经够吃 → 99**（不是 -1）：
		# -1 会被模型读成"负的天数"，99 一眼就是"不愁"。上限也压到 99，省 token。
		var left := 99.0
		if demand > supply:
			left = stock / (demand - supply)
		food[String(r["name"])] = {
			"stock": _r0(stock), "perDay": _r1(supply), "daysLeft": _r1(minf(left, 99.0)),
		}
		if left < 2.0:
			problems.append("%s 只够 %s 天" % [String(r["name"]), _r1(left)])
	if int(f["hungry"]) > 0:
		problems.append("昨天有 %d 人挨饿" % int(f["hungry"]))
	var mats := {}
	for gid in ["wood", "stone", "clay", "brick", "firewood"]:
		mats[ad.gname(gid)] = _r0(ad.stock(gid))
	# 规则引擎在沙盘上再跑一遍：它报的"最该做什么"就是这份沙盘的短板
	var top := PackedStringArray()
	for s in (ad.plan() as Array).slice(0, 3):
		top.append(String(s["title"]))
	return {
		"day": int(core.s["day"]),
		"pop": int(core.s["residents"].size()),
		"classes": _class_counts(ad),
		"sat": _r1(float(sat["avg"])),
		"hungry": int(f["hungry"]),
		"money": _r0(float(core.s["government"]["money"])),
		"housing": {"cap": int(h["capacity"]), "vacant": int(h["vacant"])},
		"jobs": core.job_capacity(),
		"employed": ad.employed_count(),
		"storage": {"used": _r0(float(st["used"])), "cap": _r0(float(st["cap"])),
			"full": bool(st["full"])},
		"food": food,
		"materials": mats,
		"construction": (core.s["construction"] as Array).size(),
		"shops": (core.s["shops"] as Array).size(),		"questsDone": (core.s["quests"]["done"] as Dictionary).size(),
		"problems": Array(problems) + Array(top),
	}


## 沙盘里**新完成**的任务标题（与真实状态比）。任务完成是玩家最关心的事件之一。
static func new_quests(source: SimCore, core: SimCore) -> Array:
	var before: Dictionary = source.s["quests"]["done"]
	var after: Dictionary = core.s["quests"]["done"]
	var out := []
	for qid in after.keys():
		if before.has(qid):
			continue
		var def: Dictionary = core.db.quests.get(String(qid), {})
		out.append(String(def.get("title", qid)))
	return out


static func _class_counts(ad: Advisor) -> Dictionary:
	var out := {}
	for c in (ad.class_counts() as Array):
		if int(c["count"]) > 0:
			out[String(c["name"])] = int(c["count"])
	return out


## 与对照的差（模型的决策主要看这一列）。
static func delta(base: Dictionary, now: Dictionary) -> Dictionary:
	var out := {
		"pop": int(now["pop"]) - int(base["pop"]),
		"sat": _r1(float(now["sat"]) - float(base["sat"])),
		"money": _r0(float(now["money"]) - float(base["money"])),
		"hungry": int(now["hungry"]),
		"jobs": int(now["jobs"]) - int(base["jobs"]),
		# 「建成 / 在建」是判断"这一手到底落没落地"的关键：5 天里可能只排上队、没盖完
		"shops": int(now["shops"]) - int(base["shops"]),
		"construction": int(now["construction"]) - int(base["construction"]),
	}
	var food := {}
	for name in (now["food"] as Dictionary).keys():
		var a: Dictionary = (base["food"] as Dictionary).get(name, {})
		var b: Dictionary = (now["food"] as Dictionary)[name]
		food[String(name)] = {
			"stock": _r0(float(b["stock"]) - float(a.get("stock", 0.0))),
			"perDay": _r1(float(b["perDay"]) - float(a.get("perDay", 0.0))),
			"daysLeft": b["daysLeft"],
		}
	out["food"] = food
	var mats := {}
	for name in (now["materials"] as Dictionary).keys():
		mats[String(name)] = _r0(float((now["materials"] as Dictionary)[name])
			- float((base["materials"] as Dictionary).get(name, 0.0)))
	out["materials"] = mats
	return out


static func _r0(x: float) -> float:
	return roundf(x)


static func _r1(x: float) -> float:
	return roundf(x * 10.0) / 10.0
