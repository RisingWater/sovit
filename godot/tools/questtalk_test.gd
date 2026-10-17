extends SceneTree

# 剧情对话（任务触发 / 章节收尾）与「预言家解锁」的门槛。
#
# 用户 2026-10 要的四件事，这里逐条钉住：
#   1. 内容：任务都有**发布人 + 立绘**，每章都有 **outro**（说话人 / 立绘 / 逐行台词），
#      第一章那个 outro 带两个选项（accept → 免费预言 / decline → 关闭）
#   2. 引擎：`quest_talks_pending()` 按内容顺序给出没播过的对话 ——
#      本章任务在前、本章收尾在后；播过的记进 `quests.shown` 不再来
#   3. 界面：`quest_talk.gd` 能播（名字 / 立绘 / 翻页 / 选项 → 发 `finished(action)`）
#   4. 解锁：**第一章收尾之前**左侧「预言」圆钮与顶栏水晶球都藏着，之后出现；
#      城镇中心的贴图也是「修复城镇中心那条任务结算之后」才换新图
#
# 红了说明什么：玩家会在"该有对话的地方什么都没有"、"任务静静地出现"、
# "瑟拉菲娜提前现身（剧透）"、"城镇中心自己变新房"里挑一个撞上。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("QUESTTALK TEST FAIL: ", msg)
	quit(1)

## 塞一座"已经建成"的建筑（任务判定看 shops，在途工地不算）。
func _add_shop(sim, def_id: String) -> void:
	var d: Dictionary = sim.db.buildings[def_id]
	(sim.s["shops"] as Array).append({
		"id": "%s#qtt%d" % [def_id, (sim.s["shops"] as Array).size() + 1],
		"defId": def_id, "owner": "state", "targetWorkers": int(d["workers"]),
		"wage": 5.0, "wageCap": 30.0, "level": 1, "active": true,
		"profit": 0.0, "skill": 50.0, "planned": 0.0,
	})

func _run() -> void:
	var font := UIKit.pixel_font()
	var db := ContentDB.load_all()

	# ---- 1. 内容：giver / giverPortrait / outro / schemaVersion 2 ----------
	if db.quests_schema_version != 2:
		_fail("quests.json 的 schemaVersion 应当是 2，实际 %d" % db.quests_schema_version)
		return
	for qid in db.quest_ids:
		var q: Dictionary = db.quests[qid]
		var giver := String(q.get("giver", ""))
		if giver == "":
			_fail("任务「%s」没有 giver（触发对话时没人说话）" % qid)
			return
		var pid := String(q.get("giverPortrait", ""))
		if pid == "":
			_fail("任务「%s」没有 giverPortrait" % qid)
			return
		if Cast.speaker_name(giver) == giver:
			_fail("giver「%s」没有中文名（Cast.NAME 里缺一条）" % giver)
			return
		if Cast.portrait(pid) == null:
			_fail("giverPortrait「%s」找不到立绘（任务「%s」）" % [pid, qid])
			return
	var outro_count := 0
	for ch in db.chapters:
		var outro: Dictionary = ch.get("outro", {})
		if outro.is_empty():
			_fail("第 %d 章没有 outro（章节完成时该弹对话）" % int(ch["id"]))
			return
		outro_count += 1
		var sp := String(outro.get("speaker", ""))
		if Cast.speaker_name(sp) == sp:
			_fail("outro 说话人「%s」没有中文名" % sp)
			return
		if Cast.portrait(String(outro.get("portrait", ""))) == null:
			_fail("outro 立绘「%s」找不到" % String(outro.get("portrait", "")))
			return
		var lines: Array = outro.get("lines", [])
		if lines.is_empty():
			_fail("第 %d 章的 outro 没有台词" % int(ch["id"]))
			return
		# 台词是**直接画在屏幕上**的：像素字体里没有的字会静默变空白
		for l in lines:
			for ch2 in String(l):
				if not font.has_char(ch2.unicode_at(0)):
					_fail("第 %d 章 outro 有像素字体画不出的字：%s（「%s」）" % [int(ch["id"]), ch2, l])
					return
	var ch1: Dictionary = db.chapters[0]
	var choices: Array = (ch1.get("outro", {}) as Dictionary).get("choices", [])
	if choices.size() != 2:
		_fail("第一章 outro 应当有 2 个选项，实际 %d" % choices.size())
		return
	if String((choices[0] as Dictionary).get("id", "")) != "accept" \
			or String((choices[0] as Dictionary).get("action", "")) != "free_prophecy":
		_fail("第一章第一个选项应当是 accept → free_prophecy")
		return
	if String((choices[1] as Dictionary).get("id", "")) != "decline" \
			or String((choices[1] as Dictionary).get("action", "")) != "close":
		_fail("第一章第二个选项应当是 decline → close")
		return
	print("QUESTTALK TEST 内容：%d 条任务有发布人/立绘、%d 章有 outro、第一章 %d 个选项、缺字 0 ✅" % [
		db.quest_ids.size(), outro_count, choices.size()])

	# ---- 2. 引擎：pending 的顺序与记账 ------------------------------------
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 20261016)
	var pend: Array = sim.quest_talks_pending()
	if pend.size() != 2:
		_fail("开局应当有 2 条任务对话（第 1 章两条），实际 %d" % pend.size())
		return
	var first: Dictionary = pend[0]
	if String(first["key"]) != "q:q01_bread_chain":
		_fail("第一条应当是 q:q01_bread_chain，实际「%s」" % first["key"])
		return
	if String(first["speaker"]) != String(db.quests["q01_bread_chain"]["giver"]):
		_fail("说话人没取内容里的 giver")
		return
	if (first["lines"] as Array).is_empty():
		_fail("任务对话的台词是空的（brief 没切出来）")
		return
	for t in pend:
		sim.quest_talk_mark_shown(String(t["key"]))
	if not sim.quest_talks_pending().is_empty():
		_fail("播过的对话又被返回了（读档会重播）")
		return
	if not bool((sim.s["quests"]["shown"] as Dictionary).has("q:q01_bread_chain")):
		_fail("播过的对话没有记进 quests.shown")
		return

	# 第一章真的全绿 → 收尾对话（瑟拉菲娜）排在第二章任务之前
	for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(sim, bid)
	sim._run_dawn()
	if not bool(sim.quest_chapter_done(1)):
		_fail("第 1 章那四条任务都建好了，章节还没结算")
		return
	var pend2: Array = sim.quest_talks_pending()
	if pend2.is_empty() or String((pend2[0] as Dictionary)["key"]) != "c:1":
		_fail("第 1 章收尾对话没有排在第一条（瑟拉菲娜会插在第 2 章任务后面）")
		return
	if String((pend2[0] as Dictionary)["speaker"]) != "seraphina":
		_fail("第 1 章收尾的说话人应当是 seraphina，实际「%s」"
			% String((pend2[0] as Dictionary)["speaker"]))
		return
	if ((pend2[0] as Dictionary)["choices"] as Array).size() != 2:
		_fail("第 1 章收尾没有把 choices 摊给界面")
		return
	if String((pend2[1] as Dictionary)["kind"]) != "quest":
		_fail("第 1 章收尾之后应当是第 2 章的任务对话")
		return
	print("QUESTTALK TEST 引擎：开局 2 条 → 播过不再来 → 章节收尾排在下一章任务之前 ✅")

	# ---- 3. 界面：能播、能翻页、能选 --------------------------------------
	var host := Control.new()
	root.add_child(host)
	var talk = load("res://scripts/ui/quest_talk.gd").new()
	host.add_child(talk)
	await process_frame
	var got := {"action": "<none>", "n": 0}
	talk.finished.connect(func(a):
		got["action"] = a
		got["n"] = int(got["n"]) + 1)
	talk.play(first)
	if not talk.visible:
		_fail("play() 之后对话框没显示")
		return
	if String(talk.get("_name_lb").text) != Cast.speaker_name(String(first["speaker"])):
		_fail("名字位是「%s」，应当是「%s」" % [
			String(talk.get("_name_lb").text), Cast.speaker_name(String(first["speaker"]))])
		return
	if (talk.get("_portrait") as TextureRect).texture == null:
		_fail("立绘没加载出来")
		return
	# 一路点到最后一页之后
	for i in 20:
		if int(got["n"]) > 0:
			break
		talk._lock = 0.0
		talk._advance()
	if int(got["n"]) == 0:
		_fail("翻到底没有发 finished（玩家会被关在对话里）")
		return
	if String(got["action"]) != "":
		_fail("没有选项的对话，finished 的 action 应当是空串，实际「%s」" % got["action"])
		return
	if talk.visible:
		_fail("对话结束之后还看得见")
		return

	# 带选项的那条：最后一页出两个按钮，点 accept → finished("free_prophecy")
	got["n"] = 0
	got["action"] = "<none>"
	talk.play(pend2[0])
	var row: HBoxContainer = talk.get("_choice_row")
	for i in 20:
		if row.visible:
			break
		talk._lock = 0.0
		talk._advance()
	if not row.visible:
		_fail("最后一页没有出现选项按钮")
		return
	if row.get_child_count() != 2:
		_fail("选项按钮应当有 2 个，实际 %d" % row.get_child_count())
		return
	var arrow: Label = talk.get("_arrow")
	if arrow.visible:
		_fail("有选项时不该还挂着「▼」（玩家会以为点空白就行）")
		return
	# 点空白**不算选**（还在等玩家做决定）
	talk._lock = 0.0
	talk._advance()
	if int(got["n"]) != 0:
		_fail("有选项的最后一页，点空白就把对话关掉了")
		return
	(row.get_child(0) as Button).pressed.emit()
	if int(got["n"]) == 0 or String(got["action"]) != "free_prophecy":
		_fail("点 accept 没有发 finished(\"free_prophecy\")（免费预言不会触发）")
		return
	talk.queue_free()
	host.queue_free()
	print("QUESTTALK TEST 界面：名字/立绘在位、翻页到底会收尾、选项 accept → free_prophecy ✅")

	# ---- 4. 解锁：第一章收尾之前，预言家与城镇中心都还是"旧的" -------------
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var hud = node.get_node_or_null("UI/Root/HUD")
	if hud == null:
		_fail("找不到 HUD")
		return
	var prop_btn: Button = hud.get("_prophecy_nav_btn")
	if prop_btn == null:
		_fail("HUD 里没有记下「预言」那个圆钮（_prophecy_nav_btn）")
		return
	var ai_btn: Button = hud.get("_ai_btn")
	if ai_btn == null:
		_fail("HUD 里没有顶栏那个水晶球按钮（_ai_btn）")
		return
	var msim = node.get("runner").sim
	if msim.prophet_unlocked():
		_fail("新开局预言家就已经解锁了（她该是第一章结尾才登场）")
		return
	if prop_btn.visible or ai_btn.visible:
		_fail("第一章收尾之前就露出了预言入口（左侧圆钮 %s / 顶栏 %s）"
			% [prop_btn.visible, ai_btn.visible])
		return
	# 第一章收尾
	msim.s["quests"]["chapters"]["1"] = int(msim.s["day"])
	hud.refresh_nav_buttons()
	hud.refresh_ai_btn()
	await process_frame
	if not msim.prophet_unlocked():
		_fail("第一章收尾之后 prophet_unlocked() 还是 false")
		return
	if not prop_btn.visible or not ai_btn.visible:
		_fail("第一章收尾之后预言入口没有出现（左侧圆钮 %s / 顶栏 %s）"
			% [prop_btn.visible, ai_btn.visible])
		return
	print("QUESTTALK TEST 预言家：第一章之前藏着 → 收尾之后出现 ✅")

	# 城镇中心：换图要等**修复城镇中心那条任务**结算
	var world = node.get_node("World")
	if not msim.town_center_ruined_visual():
		_fail("新开局城镇中心画面上就该是破旧的")
		return
	world.refresh_town_center_sprite()
	var tex_ruined: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex_ruined == null or not tex_ruined.resource_path.contains("ruined"):
		_fail("新开局地图上那座城镇中心用的不是破旧素材（%s）"
			% ("null" if tex_ruined == null else tex_ruined.resource_path))
		return
	msim.s["quests"]["done"]["q10f_townhall_repair"] = int(msim.s["day"])
	if msim.town_center_ruined_visual():
		_fail("修复任务记过完成之后，画面判据还是「破旧」")
		return
	world.refresh_town_center_sprite()
	var tex_ok: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex_ok == null or tex_ok.resource_path.contains("ruined"):
		_fail("修复任务完成之后地图上还是破旧素材（%s）"
			% ("null" if tex_ok == null else tex_ok.resource_path))
		return
	print("QUESTTALK TEST 城镇中心：修复任务之前用破旧素材 → 之后换新图 ✅")

	# ---- 5. 存档版本：2 起不兼容老档 -------------------------------------
	if SaveManager.SAVE_VERSION != 2:
		_fail("存档版本应当是 2（用户：版本更新，存档不跟之前兼容）")
		return
	var path := "user://qtt_v1.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("写不进临时存档 %s" % path)
		return
	f.store_string(JSON.stringify({"saveVersion": 1, "state": {}}))
	f.close()
	if SaveManager.load_into(path, db) != null:
		_fail("v1 老存档居然还能读进来（用户要求不兼容）")
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("QUESTTALK TEST 存档：SAVE_VERSION=2，v1 老档被拒 ✅")

	print("QUESTTALK TEST RESULT: PASS")
	quit(0)
