extends SceneTree

# 施工进度门槛：**白天要能看见进度在爬**。
#
# 这条门槛是专门防"施工退回一天一跳"的。曾经的实现（以及之后任何一次手滑）
# 会把整个白天的产能堆到 settleHour(18:00) 一次性投进队列，于是玩家按生产的
# 节奏看工地，一整个白天都是 0/N、到晚上直接跳到 N/N。
# 现在施工与生产同一节奏（workStart ≤ h < workEnd，逐小时投 产能/工作小时数），
# **一天的总量不变**，但白天必须能看见中间值。
#
# 验三件事：
#   1. 只推进 6 个工作小时 → 进度 ∈ (0, 当日产能)      —— 中间值存在
#   2. 推完当天                → 进度继续增加，且 ≈ 当日产能（总量不变，r4 累积）
#   3. 日志节奏：开工每天最多一条（只在 started 翻转时写）；
#      「等待材料」诊断每天最多一条（留在入夜那一步，不逐小时刷屏）
#
# 为什么不用表现层（工地提示）来验：那验的是 `site_tip_at` 的文案
# （见 sitetip_test.gd）。这里验的是**仿真节奏**本身，所以直接喂 SimCore。

var _fail_msg := ""
## 内容库：`_run` 里赋值，A/B/C 那几个助手函数也要用（GDScript 没有闭包）。
var db = null

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("CONSTRUCTION TEST FAIL: ", msg)
	quit(1)

## 只解锁「不带建造力加成」的科技：产能就不会被起重架/脚手架/预制件放大，
## 期望值可以手算（v0.3 开局 = 12 失业人口 × 1.0 = 12 人·天/日）。
func _unlock_non_build_techs(sim) -> void:
	var done: Array = []
	for tid in sim.db.tech_ids:
		var t: Dictionary = sim.db.techs[tid]
		var eff: Dictionary = t.get("effects", {})
		if float(eff.get("build", 0.0)) <= 0.0:
			done.append(tid)
	sim.s["research"]["done"] = done

## 挑一座「buildWork 明显大于当日产能」且材料够的普通建筑。
## 工期太短的话，6 个小时就能完工，断言会变成薛定谔的。
## 城镇中心是地图固定建筑（正常玩放不出来），跳过。
func _pick_site(sim) -> String:
	var rate: float = sim.construction_rate()
	var best := ""
	var best_work := 0.0
	for bid in sim._pack()["buildings"]:
		var b := String(bid)
		if b == "town_center":
			continue
		var def: Dictionary = sim.db.buildings[b]
		var work := float(def.get("buildWork", 0.0))
		if work <= best_work:
			continue
		if not sim.is_building_unlocked(b):
			continue
		var spec: Dictionary = sim._cost_of({"kind": "shop", "buildingId": b})
		if spec.is_empty() or not sim._can_afford(spec):
			continue
		best = b
		best_work = work
	if best_work <= 2.0 * rate:
		return ""	# 内容里没有"明显大于当日产能"的候选，测不了
	return best

## 建造队列里这座建筑已经投进去多少建造力（没有条目返回 -1）。
func _invested(sim, bid: String) -> float:
	for c in (sim.s["construction"] as Array):
		if String(c["kind"]) == "shop" and String(c.get("buildingId", "")) == bid:
			return float(c["totalRequired"]) - float(c["remaining"])
	return -1.0

func _run() -> void:
	db = ContentDB.load_all()
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 20261014)
	_unlock_non_build_techs(sim)

	var rate: float = sim.construction_rate()
	if rate <= 0.0:
		_fail("开局建造力为 0，测不了")
		return
	var bid := _pick_site(sim)
	if bid == "":
		_fail("找不到 buildWork 明显大于当日产能（%.1f）的可建建筑" % rate)
		return
	var need := float(db.buildings[bid]["buildWork"])
	var name_zh := String(db.buildings[bid]["nameZh"])
	print("CONSTRUCTION TEST 建造力 %.1f 人·天/日；测 %s（需 %.0f）→ 工期 %.1f 天" % [
		rate, name_zh, need, need / rate])

	# ---- 1. 05:00 下单 → 06:00 黎明生效：当天 06:00 就是第一个工作小时
	while int(sim.s["hour"]) != 5:
		sim.tick_hour([])
	sim.tick_hour([{"type": "build", "buildingId": bid}])

	# 推进到 12:00：正好过了 6 个工作小时（06,07,08,09,10,11）
	var samples: Array = []
	while int(sim.s["hour"]) != 12:
		sim.tick_hour([])
		samples.append(_invested(sim, bid))
	var mid := _invested(sim, bid)
	if mid <= 0.0:
		_fail("6 个工作小时后进度还是 %s —— 白天的产能没有按小时投入（退回一天一跳了）" % str(mid))
		return
	if mid >= rate:
		_fail("6 个工作小时就投完了当日产能（%.4f ≥ %.1f）—— 不是摊在工作小时里" % [mid, rate])
		return
	# 逐小时都要涨：不是"前 5 个小时 0、第 6 个小时一次跳上去"
	for i in range(1, samples.size()):
		if float(samples[i]) <= float(samples[i - 1]):
			_fail("第 %d 个工作小时进度没涨：%s → %s" % [i + 1, str(samples[i - 1]), str(samples[i])])
			return
	print("CONSTRUCTION TEST 6 个工作小时后：%s（0 < %.4f < 当日产能 %.1f）" % [
		_hourly_trace(samples), mid, rate])

	# ---- 2. 推完当天（12:00 → 次日 00:00）：进度继续涨，且一天总量 = 当日产能
	while int(sim.s["hour"]) != 0:
		sim.tick_hour([])
	var full := _invested(sim, bid)
	if full <= mid:
		_fail("推完当天进度没继续增加：%.4f → %.4f" % [mid, full])
		return
	if absf(full - rate) > 1e-3:
		_fail("一天投入 %.4f ≠ 当日产能 %.4f（总量必须不变，r4 累积）" % [full, rate])
		return
	print("CONSTRUCTION TEST 推完当天：%.4f → %.4f（一天总量 = 产能 %.1f，偏差 %.6f）" % [
		mid, full, rate, absf(full - rate)])

	# ---- 3. 日志节奏：开工一条；等待材料每天最多一条
	#
	# 材料压到**只够一座**：两份订单在下单时都能通过检查（同一份料），
	# 但第一座开工把料吃光后，第二座就停在队首等材料 —— 正是要验的那条诊断。
	var sim2 = SimCore.new(db)
	sim2.new_game("v0.3", 7)
	_unlock_non_build_techs(sim2)
	for gid in ["wood", "stone", "clay", "brick", "firewood"]:
		sim2.s["goods"][gid] = 0.0
	sim2.s["government"]["money"] = 0.0
	var spec: Dictionary = sim2._cost_of({"kind": "shop", "buildingId": bid})
	if (spec["mats"] as Array).is_empty():
		sim2.s["government"]["money"] = float(spec["money"])	# 金钱成本：只够一座
	else:
		for m in spec["mats"]:
			sim2.s["goods"][String(m[0])] = float(m[1])
	sim2.tick_hour([
		{"type": "build", "buildingId": bid},
		{"type": "build", "buildingId": bid},
	])
	var counts := {"starts": 0, "waits_by_day": {}}
	# 命令在 06:00（第 6 个 tick）生效：这时队列里应该正好两条（材料够，都进得来），
	# 而这一小时的日志（开工）也要收进统计里
	for i in 6:
		_count_invest_logs(sim2.tick_hour([]), counts)
	if sim2.s["construction"].size() != 2:
		_fail("两份订单没都进队列（%d 条）—— 场景没搭起来" % sim2.s["construction"].size())
		return

	var days := 6
	for i in days * 24:
		_count_invest_logs(sim2.tick_hour([]), counts)
	var starts := int(counts["starts"])
	var waits_by_day: Dictionary = counts["waits_by_day"]
	if starts != 1:
		_fail("「开工」日志 %d 条（期望 1：只在 started 翻转时写一次）" % starts)
		return
	for d in waits_by_day.keys():
		if int(waits_by_day[d]) > 1:
			_fail("第 %d 天写了 %d 条「等待材料」（每天最多一条，别逐小时刷屏）" % [d, int(waits_by_day[d])])
			return
	if waits_by_day.is_empty():
		_fail("材料不足 %d 天，一条「等待材料」诊断都没写" % days)
		return
	print("CONSTRUCTION TEST 日志节奏：开工 %d 条；等待材料 %d 条（%d 天，每天 ≤ 1）" % [
		starts, waits_by_day.size(), days])

	# =====================================================================
	# A/B/C：中途完成 / 剩余产能不丢 / 不结转
	# =====================================================================
	#
	# 用户口径（施工与科研同一条）：
	#   每个工作小时投入的量 = 当天产能 / 工作小时数，**是个常数**
	#   （不是"把队首剩下的需求摊到当天剩下的小时里"）；
	#   队首中途跑完时，那一格剩下的产能不能丢，继续投给队列的下一条（同格、串行）；
	#   队列空了就作废，**不结转到第二天**。
	# 每小时的量 = **新局**的日产能 / 工作小时数（`sim` 已经被前几段跑到很远，
	# 它现在的失业人口不再是 12，别拿它当基准）
	var rate_hour := 12.0 / float(_work_hours())
	var built := _make_pair(rate_hour * 0.4, rate_hour * 20.0)
	if built.is_empty():
		_fail("A/B 场景搭不起来（排不进两条工程）")
		return
	var sim_ab = built["sim"]
	var mq: Array = sim_ab.s["construction"]
	# `_make_pair` 已经走过 06:00 那一格（黎明 + 今天第一个工作小时）：
	# 队列里的两条都按期望量被消耗过一点，`constructionWorkToday` 也已经有值。
	var used_ab := float(sim_ab.s.get("constructionWorkToday", 0.0))
	var spill_m := 0.0
	var finish_hour := -1
	# 队首可能就在**黎明那一格**跑完了（它只剩 0.4 小时的量）—— 那一格的溢出量
	# 只能从"下一条已经被投进去多少"反推：`_make_pair` 里 tail 的初始值是已知的。
	if float(mq[0]["remaining"]) <= 0.0:
		finish_hour = int(db.time["workStart"])
		spill_m = float(mq[1]["totalRequired"]) - float(mq[1]["remaining"])
	while int(sim_ab.s["hour"]) != 0:
		var h0 := float(mq[0]["remaining"])
		var t0 := float(mq[1]["remaining"])
		sim_ab.tick_hour([])
		var hd := h0 - float(mq[0]["remaining"])
		var td := t0 - float(mq[1]["remaining"])
		used_ab += hd + td
		if finish_hour < 0 and float(mq[0]["remaining"]) <= 0.0:
			finish_hour = int(sim_ab.s["hour"]) - 1
			spill_m = td	# 同一格里溢给下一条的量
	if finish_hour < 0:
		_fail("队首一天下来都没跑完 —— 每小时的量不是常数？")
		return
	if int(db.time["workEnd"]) <= finish_hour:
		_fail("队首拖到 %02d:00 才跑完（workEnd 是 %02d:00）—— 不是中途完成" % [
			finish_hour, int(db.time["workEnd"])])
		return
	if spill_m <= 0.0:
		_fail("队首中途跑完那一格，下一条一分进度都没拿到（剩余产能被丢了）")
		return
	print("CONSTRUCTION TEST A 中途完成：队首只剩 0.4 小时的量，在 %02d:00（workEnd=%02d:00 之前）就跑完 ✅" % [
		finish_hour, int(db.time["workEnd"])])
	# 当天总量 == 当天产能：`used_ab` = 黎明那一格已投的 + 后面逐格实测的增量
	#（不能用 `constructionWorkToday`：它在入夜那一步就被折成工资并清零了）
	if absf(used_ab - rate_hour * float(_work_hours())) > 1e-3:
		_fail("这天投入 %.6f ≠ 每小时的量 %.6f × %d 个小时 = %.6f（剩余产能丢了？）" % [
			used_ab, rate_hour, _work_hours(), rate_hour * float(_work_hours())])
		return
	print("CONSTRUCTION TEST B 剩余产能不丢：队首跑完那格溢给下一条 %.6f；当天总量 %.4f = 每小时的量 %.6f × %d 小时 ✅" % [
		spill_m, used_ab, rate_hour, _work_hours()])

	# C：队列清空后不再投入（不结转）
	var built_c := _make_pair(rate_hour * 0.4, rate_hour * 0.4)
	if built_c.is_empty():
		_fail("C 场景搭不起来")
		return
	var cs = built_c["sim"]
	# 两条各 0.4 小时的量：第一个工作日的前两格就跑完，次日黎明都出队
	while int(cs.s["hour"]) != 0:
		cs.tick_hour([])
	for i in 24:
		cs.tick_hour([])
	if not (cs.s["construction"] as Array).is_empty():
		_fail("C 场景：队列应该已经清空（跑完的工程在黎明启用），实际 %d 项" % (cs.s["construction"] as Array).size())
		return
	var work_before := float(cs.s.get("constructionWorkToday", -1.0))
	for i in 24:
		cs.tick_hour([])
	if absf(float(cs.s.get("constructionWorkToday", -1.0)) - work_before) > 1e-9:
		_fail("队列空着的时候还在投建造力（workToday %s → %s）—— 结转到第二天了？" % [
			str(work_before), str(cs.s.get("constructionWorkToday", -1.0))])
		return
	print("CONSTRUCTION TEST C 不结转：队列清空后推满一天，当日投入量 %s → %s（不变）✅" % [
		str(work_before), str(cs.s.get("constructionWorkToday", -1.0))])

	print("CONSTRUCTION TEST RESULT: PASS")
	quit(0)

## 工作小时数（workEnd − workStart）。
func _work_hours() -> int:
	return int(db.time["workEnd"]) - int(db.time["workStart"])

## 在 06:00 的那一格**起点**下 `actions`：先推到 05:00，再 tick 两次。
##
## ⚠️ 时间语义：`tick_hour` 是"先结算 `state.hour` 那一刻、再把 hour +1"，
## 所以"06:00 的黎明"要发生，必须让某一格的**起点**是 6。
func _boot_dawn(sim, actions: Array) -> void:
	while int(sim.s["hour"]) != int(db.time["workStart"]) - 1:
		sim.tick_hour([])
	sim.tick_hour(actions)	# 起点 05:00：动作进队列，hour → 06
	sim.tick_hour([])	# 起点 06:00：黎明执行动作 + 投出第一个工作小时

## 每工作小时投入的**常数**（引擎口径：日产能 × 1/工作小时数，r4）。
func _hour_rate(sim) -> float:
	var wh := _work_hours()
	if wh <= 0:
		return 0.0
	return floor((float(sim.construction_rate()) / float(wh)) * 10000.0 + 0.5) / 10000.0

## 造一对"同一座建筑排两次"的工程，返回时**停在 05:00、动作还在 pending**。
##
## ⚠️ 时序（踩过两次，注意）：`tick_hour` 是"先结算 `state.hour` 那一刻、再把 hour +1"，
## 而黎明（workStart=6）那一格会**先把当天的产能投出去**。所以调用方要分两步走：
##   ① `sim.tick_hour([])`（起点 05:00）→ hour 推到 06，黎明在这里应用动作
##   ② 接着 `sim.tick_hour([])`（起点 06:00）→ 黎明已经应用过动作、投出第一个工作小时
## 这里先把两条 `remaining` 改成期望值，正是为了让②那一格按期望量消耗。
##
## 返回 `{sim}`；动作已入 pending（两条都排得进去）才返回，否则 `{}`。
func _make_pair(need0: float, need1: float) -> Dictionary:
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 20261014)
	# 人口上限钉在开局人口：失业人口就是建造力的唯一来源，产能才不会被移民动摇
	sim.s["government"]["populationCap"] = float((sim.s["residents"] as Array).size())
	# 材料管够：这里只验节奏，不想被"材料不足停在队首"干扰
	for gid in (sim.s["goods"] as Dictionary).keys():
		sim.s["goods"][gid] = 9999.0
	# 推到 05:00 再下单：动作在这一格进 pending
	while int(sim.s["hour"]) != int(db.time["workStart"]) - 1:
		sim.tick_hour([])
	sim.tick_hour([
		{"type": "build", "buildingId": "wheat_farm"},
		{"type": "build", "buildingId": "wheat_farm"},
	])
	# 走一格：起点 05:00 → hour 推到 06，黎明在这里把两条建出来（队列在 `sim.s["construction"]` 里）
	sim.tick_hour([])
	var q: Array = sim.s["construction"]
	if q.size() < 2:
		return {}
	# 都当成**已开工**：材料不参与，这里只验节奏与产能分配
	q[0]["started"] = true
	q[0]["remaining"] = need0
	q[0]["totalRequired"] = need0
	q[1]["started"] = true
	q[1]["remaining"] = need1
	q[1]["totalRequired"] = need1
	# 值设好了，再走**黎明那一格**（起点 06:00：投出今天第一个工作小时）
	sim.tick_hour([])
	return {"sim": sim}

## 把一个 tick 的日志并进统计：开工次数 + 每天的「等待材料」条数。
## （GDScript 没有出参，所以用 Dictionary 累积。）
func _count_invest_logs(logs: Array, counts: Dictionary) -> void:
	for l in logs:
		if String(l["kind"]) != "invest":
			continue
		var text := String(l["text"])
		if text.contains("开工"):
			counts["starts"] = int(counts.get("starts", 0)) + 1
		if text.contains("等待材料"):
			var by_day: Dictionary = counts.get("waits_by_day", {})
			var d := int(l["day"])
			by_day[d] = int(by_day.get(d, 0)) + 1
			counts["waits_by_day"] = by_day

## 逐小时进度串（形如 "1.00 → 2.00 → ..."），一眼能看出是"在爬"而不是"跳"。
func _hourly_trace(samples: Array) -> String:
	var parts := []
	for v in samples:
		parts.append("%.4f" % float(v))
	return " → ".join(parts)
