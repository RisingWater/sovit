extends SceneTree

# 场次（"不挂任务的戏"）门槛 —— 用户 2026-10 · A1/A2。
#
# 契约见 docs/quests.md §八。与 TS 侧 `scripts/check-scenes.ts` **同口径、同数字**：
#   1. 内容：五场戏都在、说话人 / 立绘 / 台词都不空
#   2. **状态比对**：播过的记在 `s["scenes"]["shown"]`（不是队列），读档不重播
#   3. 触发条件：`{ chapter, afterDays }` 的闸按"那一章领奖那天"起算
#   4. 排序：场次排在**下一章任务之前**（章与章之间那段戏）
#   5. 只记事不演化：一场戏播不播，村子的数字一个都不动
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/scene_test.gd

const SEED := 20261018

var db = null
var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("SCENE TEST FAIL: ", msg)
	print("SCENE TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _fresh() -> SimCore:
	var sim := SimCore.new(db)
	sim.new_game("v0.3", SEED)
	for g in db.goods.keys():
		sim.s["goods"][g] = 5000.0
	sim.s["government"]["money"] = 10000.0
	return sim

## 把第 1..n 章的"已经收尾"和"任务都做过"一起摆好（只为让后面的场次到点）。
func _stage_chapters(sim, upto: int) -> void:
	for ch in db.chapters:
		var cid := int(ch["id"])
		if cid > upto:
			continue
		sim.s["quests"]["chapters"][str(cid)] = 1
		for qid in db.quest_ids:
			if int(db.quests[qid]["chapter"]) == cid:
				sim.s["quests"]["done"][qid] = 1

func _talk_keys(sim) -> Array:
	var out := []
	for t in sim.quest_talks_pending():
		out.append(String(t["key"]))
	return out

func _scene_ids_from(sim, chapter_id: int) -> Array:
	# `_scenes_after_chapter` 是引擎内部的判定；这里走公开入口（按整张列表过滤）
	var out := []
	for t in sim.quest_talks_pending():
		if String(t["kind"]) == "scene" and int(t["chapter"]) >= 0:
			out.append(String(t["id"]))
	return out

func _run() -> void:
	db = ContentDB.load_all()
	print("=== 场次（不挂任务的戏）门槛 ===")

	# ---- 1. 内容齐不齐
	if db.scene_ids.size() != 5:
		_fail("应该有 5 场戏，实际 %d" % db.scene_ids.size())
	for need in ["sc_serafina_friend", "sc_elise_meet", "sc_milla_arrive",
			"sc_gareth_nightwatch", "sc_bandit"]:
		if not db.scene_ids.has(need):
			_fail("缺场次：%s" % need)
	for sc in db.scenes:
		if String(sc["speaker"]) == "" or String(sc["portrait"]) == "":
			_fail("场次 %s 缺说话人或立绘" % String(sc["id"]))
		if (sc["lines"] as Array).size() < 2:
			_fail("场次 %s 台词少于两页" % String(sc["id"]))
		if not (sc["choices"] as Array).is_empty():
			_fail("场次 %s 不该有选项（戏就是戏）" % String(sc["id"]))
	_ok("五场戏都在，说话人 / 立绘 / 台词齐全，且都没有选项")

	# ---- 2. 触发条件：那一章收尾 + afterDays
	var sim := _fresh()
	sim.s["day"] = 9
	if not sim.quest_talks_pending().filter(func(t): return String(t["id"]) == "sc_serafina_friend").is_empty():
		_fail("章 2 还没收尾，她不该来提「朋友」")
	sim.s["quests"]["chapters"]["2"] = 9
	if not sim.quest_talks_pending().filter(func(t): return String(t["id"]) == "sc_serafina_friend").is_empty():
		_fail("章 2 当天还不该播（afterDays = 1）")
	sim.s["day"] = 10
	if sim.quest_talks_pending().filter(func(t): return String(t["id"]) == "sc_serafina_friend").is_empty():
		_fail("章 2 收尾第二天该播了")
	_ok("场次的闸按「那一章领奖那天 + afterDays」算")

	# 章 4 收尾之后三场戏按 afterDays 陆续到（11 / 12 / 13）
	var sim2 := _fresh()
	sim2.s["quests"]["chapters"]["4"] = 10
	for pair in [[10, 0], [11, 1], [12, 2], [13, 3]]:
		sim2.s["day"] = int(pair[0])
		var n := 0
		for t in sim2.quest_talks_pending():
			if String(t["kind"]) == "scene":
				n += 1
		if n != int(pair[1]):
			_fail("第 %d 天该有 %d 场戏，实际 %d" % [int(pair[0]), int(pair[1]), n])
	_ok("艾莉丝 / 米拉 / 加雷斯按 afterDays 1/2/3 陆续到")

	# ---- 3. 状态比对：播过记在 scenes.shown，不记在 quests.shown
	var sim3 := _fresh()
	sim3.s["quests"]["chapters"]["2"] = 1
	sim3.s["day"] = 2
	var key := "s:sc_serafina_friend"
	if not _talk_keys(sim3).has(key):
		_fail("还没播过，该在待播列表里")
	sim3.quest_talk_mark_shown(key)
	if not bool((sim3.s["scenes"]["shown"] as Dictionary).get(key, false)):
		_fail("播过之后应该记在 scenes.shown")
	if (sim3.s["quests"]["shown"] as Dictionary).has(key):
		_fail("场次不该记进 quests.shown")
	if _talk_keys(sim3).has(key):
		_fail("播过就不该再返回（读档不重播）")
	_ok("播过的场次记在 `scenes.shown`，不重播也不串到 `quests.shown`")

	# ---- 4. 排序：场次排在下一章任务之前
	var sim4 := _fresh()
	_stage_chapters(sim4, 2)
	sim4.s["quests"]["shown"]["c:1"] = true
	sim4.s["quests"]["shown"]["c:2"] = true
	sim4.s["quests"]["chapters"]["2"] = 1
	sim4.s["day"] = 2
	var keys := _talk_keys(sim4)
	if keys.is_empty() or String(keys[0]) != "s:sc_serafina_friend":
		_fail("场次该排在第一条，实际顺序：%s" % str(keys))
	if not String(keys[1]).begins_with("q:"):
		_fail("场次后面该跟第 3 章的任务，实际：%s" % str(keys))
	var dup := 0
	for k in keys:
		if String(k) == "s:sc_serafina_friend":
			dup += 1
	if dup != 1:
		_fail("同一场只该出现一次，实际 %d 次" % dup)
	_ok("场次排在第 3 章任务之前，且只出现一次")

	# ---- 5. 只记事、不演化
	var sim5 := _fresh()
	sim5.s["quests"]["chapters"]["2"] = 1
	sim5.s["day"] = 2
	var before := JSON.stringify({
		"goods": sim5.s["goods"],
		"money": sim5.s["government"]["money"],
		"residents": (sim5.s["residents"] as Array).size(),
		"shops": (sim5.s["shops"] as Array).size(),
		"done": sim5.s["quests"]["done"],
		"chapters": sim5.s["quests"]["chapters"],
	})
	sim5.quest_talks_pending()
	sim5.quest_talk_mark_shown("s:sc_serafina_friend")
	var after := JSON.stringify({
		"goods": sim5.s["goods"],
		"money": sim5.s["government"]["money"],
		"residents": (sim5.s["residents"] as Array).size(),
		"shops": (sim5.s["shops"] as Array).size(),
		"done": sim5.s["quests"]["done"],
		"chapters": sim5.s["quests"]["chapters"],
	})
	if before != after:
		_fail("判定 / 记账不该动村子的任何数字")
	_ok("判定 / 取列表 / 记账，村子的数字一个都不动")

	# ---- 6. 存档：scenes.shown 与 gifts 都要进存档（v5）
	var path := "user://sovit_scene_test.json"
	sim5.s["gifts"] = {"serafina": {"coarse_bread": 20.0}}
	if SaveManager.save_to(path, sim5) != OK:
		_fail("存档写入失败")
	var back = SaveManager.load_into(path, db)
	if back == null:
		_fail("存档读回失败（版本应当一致）")
	if not bool((back.s["scenes"]["shown"] as Dictionary).get("s:sc_serafina_friend", false)):
		_fail("读回来之后 scenes.shown 丢了")
	if float((back.s["gifts"]["serafina"] as Dictionary).get("coarse_bread", 0.0)) != 20.0:
		_fail("读回来之后 gifts 丢了")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_ok("存档 v5 带上了 scenes.shown 与 gifts")

	print("SCENE TEST RESULT: PASS（%d 条）" % _checks)
	quit(0)
