extends SceneTree

# 科研进度门槛：**白天要能看见进度在爬**，而且中途完成时**剩余的产能不许丢**。
#
# 这条门槛是专门防"科研退回一天一跳"的（与 construction_test.gd 同一套思路）。
# 曾经（以及之后任何一次手滑）科研力会在 settleHour(18:00) 一次性投进队首，
# 于是研究所头顶的进度条一整个白天都是 0/N、到晚上直接跳到 N/N。
# 现在科研与生产 / 施工同一节奏（workStart ≤ h < workEnd，逐小时投**固定的一份**），
# **一天的总量不变**，但白天必须能看见中间值。
#
# 验七件事：
#   1. 只推进 6 个工作小时 → 进度 ∈ (0, 当日科研力)，且正好 = 6 × 每小时的量
#   2. 推完当天 → 进度增量**恰好**等于当日科研力（r4 累积，偏差只到浮点误差）
#   A. **中途完成**：队首 remaining < 每小时的量 → 它在**工作小时之内**跑完
#      （不是拖到 workEnd，也不是一次性跳）
#   B. **剩余产能不丢**：队首中途跑完时，**同一小时**里下一条也拿到了进度，
#      且当天投入总量仍 == 当日科研力
#   C. **不结转**：队列清空后剩下的工作小时不再产生任何投入；「完成」日志只 1 条
#   3. 队首当天跑完 → 剩下的产能溢给下一条，当天投完，不结转
#   4. 日志节奏：一个科技一天最多一条「研究完成」
#   D. **黎明钉住当日预算**（防回退）：当天中途改一个影响 `_research_rate()` 的量
#      （加一座在岗 3 人的研究所）→ 当天每小时的量**不变**、总量**精确**等于黎明
#      钉住的值；次日黎明按新编制重新钉（每小时的量可以变）
#
# 为什么直接喂 `SimCore`（不实例化 main.tscn）：`SimRunner` 自带 `tickSec`
# （内容里 2.5s）的自动推进，会跟本测试手动 `tick_hour` **抢时间** ——
# 那种情况下"第 6 个工作小时"根本对不上（实测小时会在断言之间被 runner 抢跑）。
# 这条门槛验的是仿真节奏，时间必须由测试独占；纯 SimCore 还完全确定。
#
# ⚠️ 期望值一律用**当日预算** `researchRateToday`（黎明钉死的那个数）。
# 实测同一天里 `research_rate()` 不会变（`shop.skill` 只在黎明/入夜变），
# 但契约上"一天总量 = 当日预算"，所以断言抵着预算写，而不是现算的速率。

var _db = null

## 浮点比较容差：`remaining` 是 r4 累积、每小时一份又带除法，
## 断言只吸收这种累加误差（1e-6 远小于任何语义差异）。
const EPS := 1e-6

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("RESEARCH TEST FAIL: ", msg)
	quit(1)

## 把仿真推进到 `target` 点（0 ≤ target < 24），`sink` 非空时把每小时日志并进去。
##
## ⚠️ 时间语义（这里踩过一次，写在门槛里免得下次再踩）：`tick_hour` 是"**先结算
## `state.hour` 那一刻、再把 hour +1**"。所以"06:00 的黎明"要发生，必须让某一格的
## **起点**是 6。直接写 `while hour != 5: tick` 还有另一个坑：`hour` 已经越过 5 时
## 会绕一整天。
func _to_hour(sim, target: int, sink: Array = []) -> void:
	var hours_per_day := int(sim.db.time["hoursPerDay"])
	var guard := 0
	while int(sim.s["hour"]) != target:
		sink.append_array(sim.tick_hour([]))
		guard += 1
		if guard > hours_per_day:
			break

## 在 06:00 的那一格**起点**下 `actions`：先推到 05:00，再 tick 两次。
##
## 第一次（起点 05:00）把 pending 收下、hour 推到 06；第二次（起点 06:00）才跑
## `_run_dawn`（应用动作 + 投出今天第一个工作小时）。返回这两格的日志。
func _boot_dawn(sim, actions: Array) -> Array:
	_to_hour(sim, int(sim.db.time["dawnHour"]) - 1)
	var logs: Array = []
	logs.append_array(sim.tick_hour(actions))
	logs.append_array(sim.tick_hour([]))
	return logs

## 造一局：开局 + 一座研究所 + 6 个在岗工人，**并把研究所的 perWorker 钉成 2.0**。
##
## 钉死产能是为了让期望值能**手算**。注意：黎明 `_assign_labor` 会把
## `shop["skill"]` 重算成**在岗者的 skill 平均**（开局居民 ~46，不是我们摆的 50），
## 所以实际的科研力/日约 6 × 2.0 × (0.6 + 0.4×0.46) ≈ 9.4 —— 测试一律用
## 运行时读到的 `rate_today` / `_hour_rate`，不写死数字。
##
## 只摆场景、**不碰研究队列**：队列由 `_boot_queue` 在 05:00 用真动作下，
## 命令在 06:00 黎明生效。
func _place_institute() -> Variant:
	var sim = SimCore.new(_db)
	sim.new_game("v0.3", 20261014)
	# 人口上限钉在开局人口：不接移民，"6 个在岗工人"这个前提才不会被人口变化动摇
	sim.s["government"]["populationCap"] = float((sim.s["residents"] as Array).size())
	(sim.s["shops"] as Array).append({
		"id": "research_institute#t", "defId": "research_institute", "owner": "state",
		"targetWorkers": 6, "wage": 3.0, "wageCap": 6.0, "level": 1,
		"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	# 手动派人（不走 `_assign_labor`：本测试只关心科研节奏，不关心排产）
	for i in range(mini(6, (sim.s["residents"] as Array).size())):
		(sim.s["residents"] as Array)[i]["employed"] = true
		(sim.s["residents"] as Array)[i]["jobShopId"] = "research_institute#t"
	_db.buildings["research_institute"]["capacity"]["perWorker"] = 2.0
	return sim

## 起一局，把 `techs` 里的科技按下单顺序入队（`needs` 是它们的科研需求）。
##
## 返回时停在**次日的工作时间**（次日 07:00）：**次日黎明（06:00 起点那一格）刚跑过**，
## 所以"第一天跑完的科技已经出队"、`researchWorkToday` 也已归零 —— 后面 A/B/C
## 三个边界场景可以直接动队列、再从当天的工作小时里推一整天，语义干净。
##
## 返回 `{sim, rate_today, per_hour, day1_used, day1_logs}`：
##   rate_today = 第一天黎明钉死的当日科研力（全天不变，见 `_plan_research_day`）
##   per_hour   = 每工作小时投入的常数（引擎口径，见 `_hour_rate`）
##   day1_used  = **第一天实际投进去的科研力总量**（队列里消耗 + 当天完成的）
##   day1_logs  = 第一天所有 tick 的日志
func _boot_queue(techs: Array, needs: Array) -> Dictionary:
	var sim = _place_institute()
	if sim == null:
		return {}
	# 先改需求/补材料（动作在黎明才校验材料），再在 05:00 下单
	for i in range(techs.size()):
		_prime_tech(sim, String(techs[i]), float(needs[i]))
	var actions: Array = []
	for tid in techs:
		actions.append({"type": "research", "techId": tid})
	var logs: Array = _boot_dawn(sim, actions)
	var rate_today := float(sim.s.get("researchRateToday", 0.0))
	# 推完第一天 + 次日黎明：先到当天最后一个工作小时，再走 24 格（必然穿过
	# 次日 06:00 的黎明），跑完的科技在那里出队
	var work_start := int(_db.time["workStart"])
	var work_hours := int(_db.time["workEnd"]) - work_start
	_to_hour(sim, work_start + 1, logs)
	# 先量**第一天**的投入（下面那 24 格会跨进第二天，`_day_used` 就不再是单日口径）
	var day1_used := _day_used(sim)
	for i in 24:
		logs.append_array(sim.tick_hour([]))
	return {
		"sim": sim, "rate_today": rate_today,
		"per_hour": _hour_rate(sim),
		"day1_used": day1_used, "day1_logs": logs,
		"work_hours": work_hours,
		"hour_now": int(sim.s["hour"]),
	}
## 挑一项**无前置**的科技，把它的科研需求改成 `need`，材料补足（让开工不卡材料）。
## 直接改已载入的 db 内容字典：本测试只关心节奏，不关心内容本身。
func _prime_tech(sim, tid: String, need: float) -> void:
	_db.techs[tid]["research"] = need
	for gid in (_db.techs[tid]["cost"]["goods"] as Dictionary).keys():
		sim.s["goods"][gid] = 999.0

## 当日科研力**预算**（黎明钉死的那个数）。
func _budget(sim) -> float:
	return float(sim.s.get("researchRateToday", 0.0))

## 每工作小时投入的**常数**（引擎口径：`researchRateToday × 1/工作小时数`，r4）。
## 断言拿它当基准，而不是自己手算 rateToday/12 —— 引擎里那份会做 r4 取整。
func _hour_rate(sim) -> float:
	var work_hours := int(_db.time["workEnd"]) - int(_db.time["workStart"])
	if work_hours <= 0:
		return 0.0
	return _r4f(_budget(sim) / float(work_hours))

## 与 `sim_core._r4` 同口径的四位取整（只用于本测试的期望值）。
func _r4f(v: float) -> float:
	return floor(v * 10000.0 + 0.5) / 10000.0

## 队首还差多少科研力（没有条目返回 -1）。
func _left(sim) -> float:
	var q: Array = sim.s["research"]["queue"]
	if q.is_empty():
		return -1.0
	return float(q[0]["remaining"])

## 队列里所有条目已消耗的科研力 + 已完成的科技需求 = 这一天实际投了多少。
##
## 只用于单日场景（这一天队列里恰好只有开局入队的那几项）。
func _day_used(sim) -> float:
	var used := _done_need(sim)
	for p in (sim.s["research"]["queue"] as Array):
		used += float(p["totalRequired"]) - float(p["remaining"])
	return used

## 已研究完成那些科技的科研需求之和（它们已经出队了，不在 queue 里）。
func _done_need(sim) -> float:
	var total := 0.0
	for tid in (sim.s["research"]["done"] as Array):
		total += float(_db.techs[String(tid)]["research"])
	return total

## 把一个 tick 的日志里的「研究完成」按 **(科技名, 天)** 计数。
##
## 按**科技**分组而不是全局按天：一天里可以跑完两项不同的科技（那是正常的，各 1 条），
## 要防的是**同一项科技**一天里被写多条（重复结算）。
func _count_done_logs(logs: Array, by_tech_day: Dictionary) -> void:
	for l in logs:
		if String(l["kind"]) != "invest":
			continue
		var text := String(l["text"])
		if not text.contains("研究完成"):
			continue
		var tech_name := text.replace("研究完成：", "").strip_edges()
		var key := "%d|%s" % [int(l["day"]), tech_name]
		by_tech_day[key] = int(by_tech_day.get(key, 0)) + 1

func _run() -> void:
	_db = ContentDB.load_all()

	# =====================================================================
	# 1：只推进 6 个工作小时 → 进度 ∈ (0, 当日科研力)（中途看得见在爬）
	# =====================================================================
	var sim = _place_institute()
	if sim == null:
		_fail("SimCore 造不出来")
		return
	# 需求远大于当日科研力：一整天都跑不完，所以"投了多少"= "队首消耗了多少"
	_prime_tech(sim, "stonework", 100.0)
	# 05:00 下单 → 06:00 的起点那一格跑黎明（同时投出今天第一个工作小时）
	_boot_dawn(sim, [{"type": "research", "techId": "stonework"}])
	var rate_today := _budget(sim)
	if rate_today <= 0.0:
		_fail("黎明钉死的当日科研力为 0（研究所没起作用？）")
		return
	if _left(sim) < 0.0:
		_fail("06:00 黎明之后研究队列里应该有刚下单的那一项")
		return
	var work_start := int(_db.time["workStart"])
	var samples: Array = [100.0 - _left(sim)]	# 06:00 那一小时已经投过
	while int(sim.s["hour"]) != work_start + 6:
		sim.tick_hour([])
		samples.append(100.0 - _left(sim))
	var mid := 100.0 - _left(sim)
	if mid <= 0.0:
		_fail("6 个工作小时后进度还是 %s —— 白天的科研力没有按小时投入（退回一天一跳了）" % str(mid))
		return
	if mid >= rate_today:
		_fail("6 个工作小时就投完了当日科研力（%.4f ≥ %.1f）—— 不是摊在工作小时里" % [mid, rate_today])
		return
	# 逐小时都要涨：不是"前 5 个小时 0、第 6 个小时一次跳上去"
	for i in range(1, samples.size()):
		if float(samples[i]) <= float(samples[i - 1]):
			_fail("第 %d 个工作小时进度没涨：%s → %s" % [i + 1, str(samples[i - 1]), str(samples[i])])
			return
	var per_hour := _hour_rate(sim)
	# 每小时增量**恒定**（固定小时增量）：6 个小时的投入 = 6 × 每小时的量
	if absf(mid - per_hour * 6.0) > EPS:
		_fail("6 小时投入 %.10f ≠ 6 × 每小时的量 %.10f —— 每小时增量不是常数" % [mid, per_hour * 6.0])
		return
	print("RESEARCH TEST 6 个工作小时后：%s（0 < %.4f < 当日科研力 %.1f，每小时 %.6f）" % [
		_hourly_trace(samples), mid, rate_today, per_hour])

	# =====================================================================
	# 2：推完当天 → 进度继续涨，且一天总量**恰好**等于当日科研力
	# =====================================================================
	_to_hour(sim, 0)
	var full := 100.0 - _left(sim)
	if full <= mid:
		_fail("推完当天进度没继续增加：%.4f → %.4f" % [mid, full])
		return
	if absf(full - rate_today) > EPS:
		_fail("一天投入 %.10f ≠ 当日科研力 %.10f（总量必须不变）" % [full, rate_today])
		return
	print("RESEARCH TEST 推完当天：%.4f → %.4f（一天总量 = 当日科研力 %.1f，偏差 %.10f）" % [
		mid, full, rate_today, absf(full - rate_today)])

	# =====================================================================
	# A：**中途完成** —— 队首 remaining < 每小时的量 → 在工作小时之内跑完
	# =====================================================================
	#
	# 场景：需求都大于当日科研力（24 / 100）→ 第一天两条都跑不完、队列保持 2 项过夜。
	# 第二天开始前把队首剩下的量改成 0.4 小时的量；它必须在**第一个工作小时**里跑完，
	# 而不是拖到 workEnd(18:00)，也不是被"摊到当天剩下的小时里"。
	var ra := _boot_queue(["stonework", "digging"], [24.0, 100.0])
	if ra.is_empty():
		_fail("SimCore 造不出来")
		return
	var sim_a = ra["sim"]
	var per_hour_a := _hour_rate(sim_a)
	# ⚠️ 期望值只能用 `_hour_rate(第二天 06:00 的预算)` 这种**同口径**的估法：
	# 研究所熟练度每天会长一点（实测 ~0.16%/天），所以第二天引擎自己的"每小时的量"
	# 会比第一天的 9.41/12 大一丝（r4 取整）。这条断言要抓的是"把队首剩下的
	# 十几点需求摊进一小时"那种量级（差 20 倍），不是千分之几的漂移。
	var tol := EPS + maxf(1e-6, absf(per_hour_a) * 5e-3)
	var hoa: Array = sim_a.s["research"]["queue"]
	if hoa.size() != 2:
		_fail("A 场景队列应有 2 项，实际 %d" % hoa.size())
		return
	hoa[0]["remaining"] = per_hour_a * 0.4
	hoa[0]["started"] = true
	if float(hoa[0]["remaining"]) <= 0.0 or float(hoa[1]["remaining"]) <= 0.0:
		_fail("A 场景：两条的 remaining 都应该 > 0")
		return
	var budget_a := _budget(sim_a)
	var used_a := 0.0
	var finish_hour := -1
	var tail_gain := 0.0
	var finish_hour_spend := 0.0
	var head_need := 0.0	# 队首在"跑完那一小时"真正需要的量（= 它当时的 remaining）
	while int(sim_a.s["hour"]) != 0:
		var head_before := float(hoa[0]["remaining"])
		var tail_before := float(hoa[1]["remaining"])
		sim_a.tick_hour([])
		var head_done := head_before - float(hoa[0]["remaining"])
		var tail_done := tail_before - float(hoa[1]["remaining"])
		used_a += head_done + tail_done
		if finish_hour < 0 and float(hoa[0]["remaining"]) <= 0.0:
			finish_hour = int(sim_a.s["hour"]) - 1	# tick 之后 hour 已经 +1
			tail_gain = tail_done	# 同一小时里溢给下一条的量
			finish_hour_spend = head_done + tail_done
			head_need = head_before
	if finish_hour < 0:
		_fail("队首一天下来都没跑完 —— 每小时的量不是常数？")
		return
	if int(_db.time["workEnd"]) <= finish_hour:
		_fail("队首拖到 %02d:00 才跑完（workEnd 是 %02d:00）—— 不是中途完成" % [
			finish_hour, int(_db.time["workEnd"])])
		return
	if finish_hour < work_start:
		_fail("队首在第一个工作小时之前就跑完了（%02d:00）—— 时间点不对" % finish_hour)
		return
	# 队首**不是**被"剩下的需求摊到当天剩下的小时"跑完的：它按常数一份走，
	# 所以这一小时的投入量（队首 + 溢出给下一条）恰好是"每小时的量"
	if absf(finish_hour_spend - per_hour_a) > tol:
		_fail("队首跑完那一小时共投了 %.6f ≠ 每小时的量 %.6f（把剩余需求摊进一小时了？）" % [
			finish_hour_spend, per_hour_a])
		return
	print("RESEARCH TEST A 中途完成：队首只剩 0.4 小时的量，在第一个工作小时 %02d:00 内就跑完（workStart=%02d:00 ≤ %02d:00 < workEnd=%02d:00）；这一小时共投 %.6f = 每小时的量 ✅" % [
		finish_hour, work_start, finish_hour, int(_db.time["workEnd"]), finish_hour_spend])

	# =====================================================================
	# B：**剩余产能不丢** —— 队首中途跑完时，同一小时里下一条也拿到进度
	# =====================================================================
	#
	# 队首只需 0.4 小时的量 → 那一小时剩下的继续投给第二条（同小时、串行）。
	# 如果实现是"每小时只投一条、剩下的丢掉"，下一条就一分都拿不到。
	if tail_gain <= 0.0:
		_fail("队首中途跑完那一小时，下一条一分进度都没拿到（剩余产能被丢了）")
		return
	# 精确口径：那一小时引擎投出的总量 = `finish_hour_spend`；
	# 队首只该吃掉它需要的 `head_need`，**剩下的全部**归下一条 —— 一分都不许丢。
	if absf(tail_gain - (finish_hour_spend - head_need)) > EPS:
		_fail("队首跑完那一小时溢给下一条的量 %.10f ≠ 这一小时的量 %.10f − 队首需要的 %.10f（产能丢了）" % [
			tail_gain, finish_hour_spend, head_need])
		return
	# 当天总量仍然 == 当天的科研力。基准用**当天实测的每小时的量**
	# （`finish_hour_spend`）乘**今天还剩几个工作小时** —— `_boot_queue` 返回时停在
	# 次日的某个工作小时，今天还剩（workEnd − 当前小时）格。
	# （不用第一天钉死的 `budget_a`：研究所熟练度每天涨，第二天引擎自己的日产能
	#  会比第一天大一丝，实测 +0.2%。）
	var hours_left_today := maxi(0, int(_db.time["workEnd"]) - int(ra["hour_now"]))
	var day_total_target := finish_hour_spend * float(hours_left_today)
	if hours_left_today <= 0:
		_fail("A/B 场景起手就不在工作时间（hour=%d）" % int(ra["hour_now"]))
		return
	if absf(used_a - day_total_target) > maxf(tol, 1e-3):
		_fail("A/B 那天投入 %.6f ≠ 实测日产能 %.6f（剩余产能丢了？）" % [used_a, day_total_target])
		return
	print("RESEARCH TEST B 剩余产能不丢：同一小时共投 %.6f，队首吃掉 %.6f，下一条拿到剩下 %.6f（= 两者之差）✅" % [
		finish_hour_spend, head_need, tail_gain])

	# =====================================================================
	# C：**不结转** —— 队列清空后剩下的工作小时不再产生任何投入；日志只 1 条
	# =====================================================================
	# 需求只要**不到一个工作小时的量**（0.4 × 每小时的量）：第 1 个工作日里
	# 第一个工作小时就跑完，那天剩下的 11 个小时空着 —— 正是"不许结转"要验的场景
	var rc := _boot_queue(["stonework"], [0.4 * per_hour_a])
	if rc.is_empty():
		_fail("SimCore 造不出来")
		return
	var sim_c = rc["sim"]
	# 跑完的科技在次日黎明出队；`_boot_queue` 返回时已过次日黎明，队列应为空
	if not (sim_c.s["research"]["queue"] as Array).is_empty():
		_fail("C 场景：队列应该已经清空（跑完的科技在黎明出队）；队列 %s" % str(sim_c.s["research"]["queue"]))
		return
	var work_before := float(sim_c.s.get("researchWorkToday", -1.0))
	var done_by_day: Dictionary = {}
	_count_done_logs(rc["day1_logs"], done_by_day)
	# 再推一整天：队列空着，一分都不该投（不结转到第二天）
	for i in 24:
		_count_done_logs(sim_c.tick_hour([]), done_by_day)
	var work_after := float(sim_c.s.get("researchWorkToday", -1.0))
	if absf(work_after - work_before) > EPS:
		_fail("队列空着的时候还在投科研力（workToday %s → %s）—— 结转到第二天了？" % [
			str(work_before), str(work_after)])
		return
	var total_done := 0
	for key in done_by_day.keys():
		total_done += int(done_by_day[key])
		if int(done_by_day[key]) > 1:
			_fail("同一项科技在 %s 被写了 %d 条「研究完成」（最多一条）" % [String(key), int(done_by_day[key])])
			return
	if total_done != 1:
		_fail("C 场景「研究完成」应该正好 1 条，实际 %d 条" % total_done)
		return
	print("RESEARCH TEST C 不结转：队列清空后推满一天，当日投入量 %s → %s（不变）；「研究完成」日志 %d 条 ✅" % [
		str(work_before), str(work_after), total_done])

	# =====================================================================
	# 3：队首当天跑完 → 剩下的产能溢给下一条，当天投完，不结转
	# =====================================================================
	#
	# 队首只要 4：它在前几个工作小时跑完，**那一小时剩下的产能立刻接着投下一条**，
	# 所以当天总投入仍然 = 当日科研力（不结转、不丢）。
	#
	# ⚠️ 引擎在**黎明那一刻就已经投过当天第一个工作小时**（`_run_dawn` 与
	# `_apply_research_hours` 在同一格里），所以这里先把"今天已经投了多少"从
	# `researchWorkToday` 读出来当基准，再加上后面逐小时量到的增量。
	var sim3 = _place_institute()
	_prime_tech(sim3, "stonework", 4.0)
	_prime_tech(sim3, "digging", 100.0)
	_boot_dawn(sim3, [
		{"type": "research", "techId": "stonework"},
		{"type": "research", "techId": "digging"},
	])
	var budget3 := _budget(sim3)
	var q3: Array = sim3.s["research"]["queue"]
	if budget3 <= 4.0 or q3.size() != 2:
		_fail("场景不对：当日科研力 %.1f / 队列 %d 项" % [budget3, q3.size()])
		return
	var used3 := float(sim3.s.get("researchWorkToday", 0.0))	# 黎明那一格已经投进去的
	var finish3 := -1
	var spill3 := 0.0
	while int(sim3.s["hour"]) != 0:
		var h0 := float(q3[0]["remaining"])
		var d0 := float(q3[1]["remaining"])
		sim3.tick_hour([])
		var hd := h0 - float(q3[0]["remaining"])
		var dd := d0 - float(q3[1]["remaining"])
		used3 += hd + dd
		if finish3 < 0 and float(q3[0]["remaining"]) <= 0.0:
			finish3 = int(sim3.s["hour"]) - 1
			spill3 = dd	# 同一格里溢给下一条的量
	if finish3 < 0 or int(_db.time["workEnd"]) <= finish3:
		_fail("队首（需求 4）应该在当天的工作小时里跑完，实际 finish=%d" % finish3)
		return
	if spill3 <= 0.0:
		_fail("队首跑完那一格里，下一条一分进度都没拿到（剩余产能丢了）")
		return
	if absf(used3 - budget3) > EPS:
		_fail("这天投入 %.10f ≠ 当日科研力 %.10f（要么结了转，要么溢给了已完成的那条）" % [used3, budget3])
		return
	if float(q3[1]["remaining"]) <= 0.0:
		_fail("队首跑完后下一条应该也拿到了进度（remaining 应 > 0）")
		return
	print("RESEARCH TEST 队首当天跑完：这天投入 %.4f = 当日科研力 %.1f（%02d:00 跑完后同格溢给下一条 %.4f，不结转）✅" % [
		used3, budget3, finish3, spill3])

	# =====================================================================
	# 4：日志节奏 —— 一个科技一天最多一条「研究完成」
	# =====================================================================
	var r4 := _boot_queue(["stonework", "digging", "firewood"], [3.0, 3.0, 3.0])
	if r4.is_empty():
		_fail("SimCore 造不出来")
		return
	var sim4 = r4["sim"]
	var by_tech_day: Dictionary = {}
	var days := 4
	# 先收 `_boot_queue` 那两天的日志（那里已经跨过第一个黎明，完成日志就在里面）
	_count_done_logs(r4["day1_logs"], by_tech_day)
	for i in days * 24:
		_count_done_logs(sim4.tick_hour([]), by_tech_day)
	# 每个科技每天**最多一条**「研究完成」（防重复结算刷屏）；
	# 同一天跑完两项不同的科技是正常的（各一条）。
	for key in by_tech_day.keys():
		if int(by_tech_day[key]) > 1:
			_fail("同一项科技在 %s 被写了 %d 条「研究完成」（每天最多一条）" % [String(key), int(by_tech_day[key])])
			return
	if by_tech_day.is_empty():
		_fail("%d 天里一条「研究完成」都没有 —— 场景没搭起来" % days)
		return
	# 三项各 3（当日预算 ~9.4）：都该在头几天里跑完
	if by_tech_day.size() < 3:
		_fail("只有 %d 条（科技,天）「研究完成」记录（三项各 3，%d 天里应该都跑完）" % [
			by_tech_day.size(), days])
		return
	print("RESEARCH TEST 日志节奏：%d 天里「研究完成」分布 %s（每个科技每天 ≤ 1）" % [
		days, str(by_tech_day)])

	# =====================================================================
	# D：**黎明钉住当日预算**（防回退：科研已经钉了，这条守住它）
	# =====================================================================
	#
	# 与 construction_test.gd 的 D 段同一套：当天中途改一个会影响**现算值**
	# `_research_rate()` 的量（给村里再加一座研究所、在岗 3 人），然后把这天
	# 剩下的小时推完 ——
	#   ① 之后每个工作小时的投入量**不变**（= 黎明钉住的预算 / 工作小时数），
	#      若实现退回"每小时现算"，下午每格就会跳到新速率/12
	#   ② 当天总量**精确**等于钉住的预算（偏差 0；最后一格由预算兜底截断）
	# 次日黎明按**当时的编制**重新钉 → 第二天的每小时量可以变。
	var sim_d = _place_institute()
	if sim_d == null:
		_fail("SimCore 造不出来")
		return
	_prime_tech(sim_d, "stonework", 100.0)	# 远大于当日科研力：队首一整天都跑不完
	_boot_dawn(sim_d, [{"type": "research", "techId": "stonework"}])
	var budget_d := _budget(sim_d)
	if budget_d <= 0.0:
		_fail("D 场景：黎明钉住的当日科研力为 0（研究所没起作用？）")
		return
	var per_hour_d := _hour_rate(sim_d)	# 引擎口径的"每小时的量"（r4）
	var wh_d := int(_db.time["workEnd"]) - int(_db.time["workStart"])
	var q_d: Array = sim_d.s["research"]["queue"]
	if q_d.size() != 1:
		_fail("D 场景：队列里应有刚下单的那一项，实际 %d" % q_d.size())
		return
	# —— 当天中途改一个**会影响现算值**的量：再加一座研究所在岗 3 人 ——
	#（为什么用"加研究所"而不是"给现有研究所多派几个人"：`_assign_labor` 每天黎明
	#  按 targetWorkers 重排，多派的人活不到第二天，就验不了"次日重新钉"这半条。）
	(sim_d.s["shops"] as Array).append({
		"id": "research_institute#d", "defId": "research_institute", "owner": "state",
		"targetWorkers": 3, "wage": 3.0, "wageCap": 6.0, "level": 1,
		"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	var staffed_d := 0
	for r in (sim_d.s["residents"] as Array):
		if staffed_d >= 3:
			break
		if not bool(r["employed"]):
			r["employed"] = true
			r["jobShopId"] = "research_institute#d"
			staffed_d += 1
	if staffed_d < 3:
		_fail("D 场景：没有 3 个失业居民可以派进新研究所（只派了 %d 个）" % staffed_d)
		return
	var live_d: float = sim_d.research_rate()
	if live_d <= budget_d + 1e-9:
		_fail("D 场景：加了一座在岗 3 人的研究所，现算值却没涨（%.4f → %.4f）—— 证不了任何事" % [
			budget_d, live_d])
		return
	if absf(_budget(sim_d) - budget_d) > 1e-9:
		_fail("D 场景：中途动了人事，钉住的预算被改写了（%.4f → %.4f）—— 它只该在黎明改" % [
			budget_d, _budget(sim_d)])
		return
	# 把这天剩下的小时推完（推到 18:00 —— 起点 18 那一格才入夜）
	var hours_d := 0
	var work_end := int(_db.time["workEnd"])
	while int(sim_d.s["hour"]) != work_end:
		var cur := int(sim_d.s["hour"])
		var w0 := float(sim_d.s.get("researchWorkToday", 0.0))
		sim_d.tick_hour([])
		var delta := float(sim_d.s.get("researchWorkToday", 0.0)) - w0
		if delta <= 0.0:
			continue
		hours_d += 1
		# 绝不超过"每小时的量"：超过了就是退回每小时现算了
		if delta > per_hour_d + 1e-9:
			_fail("D ①：中途动了人事之后，%02d:00 那一格投了 %.6f > 每小时的量 %.6f —— 退回每小时现算了？" % [
				cur, delta, per_hour_d])
			return
		# 当天最后一个工作小时由预算兜底截断（§10.3：总投入恰好等于预算），其余每格必须一样
		if cur != work_end - 1 and absf(delta - per_hour_d) > 1e-4:
			_fail("D ①：%02d:00 那一格投了 %.6f ≠ 钉住的预算/工作小时数 %.6f（r4 误差内）—— 当天的量被中途的改动带跑了" % [
				cur, delta, per_hour_d])
			return
	if hours_d != wh_d - 1:
		_fail("D 场景：这天只剩 %d 个满格可推（期望 %d）—— 场景没搭对" % [
			hours_d, wh_d - 1])
		return
	# ② 当天总量 = 钉住值（偏差 0）
	var total_d := float(sim_d.s.get("researchWorkToday", 0.0))
	var drift_d := absf(total_d - budget_d)
	if drift_d > 1e-9:
		_fail("D ②：当天总量 %.6f ≠ 钉住的预算 %.6f（偏差 %.6f）—— 当天的量被中途的改动带跑了" % [
			total_d, budget_d, drift_d])
		return
	print("RESEARCH TEST D 钉住预算：中途在岗 +3 人（现算 %.4f → %.4f），当天每格仍投 %.6f = 预算 %.1f / %d；当天总量 %.4f（偏差 %.6f）✅" % [
		budget_d, live_d, per_hour_d, budget_d, wh_d, total_d, drift_d])

	# 次日黎明：预算按**当时的编制**重新钉 → 第二天的每小时量可以变
	#
	# ⚠️ 停在 06:00 那一格的**起点**时黎明还没跑（`tick_hour` 是"先结算起点那一刻、
	# 再把 hour +1"），所以预算要**推过这一格之后再读** —— 那一格里黎明重钉
	# （`researchWorkToday` 归零）并紧接着投出第二天第一个工作小时。
	while int(sim_d.s["hour"]) != int(_db.time["workStart"]):
		sim_d.tick_hour([])
	sim_d.tick_hour([])	# 起点 06:00：黎明（重钉）+ 第二天第一个工作小时
	var budget_d2 := _budget(sim_d)
	var live_d2: float = sim_d.research_rate()
	if absf(budget_d2 - live_d2) > 1e-9:
		_fail("D：第二天黎明的预算 %.6f ≠ 那一刻现算的科研力 %.6f —— 黎明没有重新钉" % [
			budget_d2, live_d2])
		return
	if absf(budget_d2 - budget_d) <= 1e-6:
		_fail("D：第二天黎明的预算还是 %.4f（与第一天一模一样）—— 没按新的编制重钉？" % budget_d2)
		return
	# 黎明把 `researchWorkToday` 归零过了，所以它现在就是第二天第一个工作小时的投入量
	var per_hour_d2 := float(sim_d.s.get("researchWorkToday", 0.0))
	if absf(per_hour_d2 - _hour_rate(sim_d)) > 1e-4:
		_fail("D：第二天第一个工作小时投了 %.6f ≠ 新预算 %.4f / %d = %.6f —— 每小时的量没跟着新预算走？" % [
			per_hour_d2, budget_d2, wh_d, _hour_rate(sim_d)])
		return
	print("RESEARCH TEST D 次日重钉：黎明预算 %.4f → %.4f，每小时的量 %.6f → %.6f（可以变）✅" % [
		budget_d, budget_d2, per_hour_d, per_hour_d2])

	print("RESEARCH TEST RESULT: PASS")
	quit(0)

## 逐小时进度串（形如 "1.0000 → 2.0000 → ..."），一眼能看出是"在爬"而不是"跳"。
func _hourly_trace(samples: Array) -> String:
	var parts := []
	for v in samples:
		parts.append("%.4f" % float(v))
	return " → ".join(parts)
