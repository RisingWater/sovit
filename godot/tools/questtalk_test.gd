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
	# ⚠️ headless 的 dummy 窗口只有 64×64，而所有布局都是按 `get_viewport_rect()` 算的
	# （headless 下它报 1600×1600）。不把窗口撑开的话，鼠标事件落在"窗口外面"，
	# GUI 拾取永远找不到任何控件 —— 那条"点文字框能翻页"的断言会假红。
	root.size = Vector2i(1600, 1600)
	await process_frame
	var font := UIKit.pixel_font()
	var db := ContentDB.load_all()
	# ---- 1. 内容：giver / giverPortrait / outro / schemaVersion 3 ----------
	if db.quests_schema_version != 3:
		_fail("quests.json 的 schemaVersion 应当是 3，实际 %d" % db.quests_schema_version)
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
		# 章 1–6 有收尾戏；章 7–17 的剧情在 C2 那一段里补（现在只有章节表）
		if outro.is_empty():
			if int(ch["id"]) <= 6:
				_fail("第 %d 章没有 outro（章节完成时该弹对话）" % int(ch["id"]))
				return
			continue
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
	# 用户 2026-10：第一章收尾那两个选项**删掉**了（她送的预言不许拒绝）——
	# 后面直接接 5 行固定预言，所以这里应该一个选项都没有、台词 11 页。
	var choices: Array = (ch1.get("outro", {}) as Dictionary).get("choices", [])
	if not choices.is_empty():
		_fail("第一章 outro 不该再有选项，实际 %d 个" % choices.size())
		return
	var ch1_lines: Array = (ch1.get("outro", {}) as Dictionary).get("lines", [])
	if ch1_lines.size() != 11:
		_fail("第一章 outro 应当是 6 行登场 + 5 行固定预言 = 11 行，实际 %d" % ch1_lines.size())
		return
	if String(ch1_lines[6]) != "我看见的都不清楚……" \
			or String(ch1_lines[10]) != "……别问我什么时候。我要是知道，就不会住在这种地方了。":
		_fail("第一章那条固定预言的头尾不对：%s / %s" % [String(ch1_lines[6]), String(ch1_lines[10])])
		return
	print("QUESTTALK TEST 内容：%d 条任务有发布人/立绘、%d 章有 outro、第一章 %d 个选项、缺字 0 ✅" % [
		db.quest_ids.size(), outro_count, choices.size()])

	# ---- 2. 引擎：pending 的顺序与记账 ------------------------------------
	var sim = SimCore.new(db)
	sim.new_game("v0.3", 20261016)
	var pend: Array = sim.quest_talks_pending()
	if pend.size() != 3:
		_fail("开局应当有 3 条任务对话（第 1 章两条 + 送物资支线），实际 %d" % pend.size())
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
	if not ((pend2[0] as Dictionary)["choices"] as Array).is_empty():
		_fail("第 1 章收尾不该再摊出选项（玩家不能拒绝）")
		return
	if String((pend2[1] as Dictionary)["kind"]) != "quest":
		_fail("第 1 章收尾之后应当是第 2 章的任务对话")
		return
	print("QUESTTALK TEST 引擎：开局 3 条 → 播过不再来 → 章节收尾排在下一章任务之前 ✅")

	# ---- 3. 界面：能播、能翻页、能选 --------------------------------------
	# ⚠️ `host` 必须是**铺满视口**的：对话是 `PRESET_FULL_RECT`，它的尺寸跟着父节点走；
	# 给一个 0×0 的 host，对话自己的 rect 就是 0×0 —— 真鼠标点上去谁也接不到
	# （GUI 拾取靠 rect，不靠 `_layout()` 里算出来的位置）。
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
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
	# 点鼠标也要能翻页（用户 2026-10："galgame 窗口点鼠标无法继续，只能按空格"）
	# ⚠️ 必须是**真事件**：`root.push_input` 走完整 GUI 拾取链 —— 框是 PanelContainer，
	# `mouse_filter` 默认 STOP 会把点击吃掉，父节点的 `_gui_input` 根本收不到。
	var page_before: int = talk.get("_page")
	var tbox: PanelContainer = talk.get("_box")
	var at: Vector2 = tbox.position + tbox.size * 0.5
	var mev := InputEventMouseButton.new()
	mev.button_index = MOUSE_BUTTON_LEFT
	mev.pressed = true
	mev.position = at
	mev.global_position = at
	root.push_input(mev)
	await process_frame
	if int(talk.get("_page")) == page_before:
		_fail("点在文字框上翻不了页（鼠标被框吃掉了 —— 用户报的「只能按空格」）")
		return
	print("QUESTTALK TEST 鼠标：点文字框能翻页 ✅")
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

	# 选项机制本身还得管用（后面几十场分支戏都要靠它）——
	# 所以这里喂一段**合成**的对话：内容里已经没有带选项的场次了
	# （用户 2026-10 把第一章那两个删了，见 docs/quests.md §十二）。
	got["n"] = 0
	got["action"] = "<none>"
	var synth := {
		"key": "t:choice", "kind": "outro", "id": "t", "chapter": 1,
		"speaker": "seraphina", "portrait": "seraphina_hooded",
		"lines": ["第一页。", "最后一页。"],
		"choices": [
			{"id": "accept", "text": "……说下去。", "action": "free_prophecy"},
			{"id": "decline", "text": "不必了。", "action": "close"},
		],
	}
	talk.play(synth)
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
	# 真鼠标点 accept 那个按钮 —— 按钮的爸爸（`_choice_row` / `_box`）都被设成了
	# MOUSE_FILTER_IGNORE（好让点在框上能翻页），必须确认**按钮本身**还点得动。
	# 真鼠标点 accept 那个按钮。
	# ⚠️ 先等两帧：选项按钮是**这一页才创建**的，尺寸要等下一次布局才落下来 ——
	# 立刻点的话 `get_global_rect()` 还是 0×0，真玩家那边不会有这个问题（人不会 16ms 内点完）。
	for _f in 3:
		await process_frame
	var accept: Button = row.get_child(0)
	var cr := accept.get_global_rect()
	# ⚠️ 按钮是在**松开**（按钮抬起）那一刻发 `pressed` 的，所以 press + release 都要发 ——
	# 只发 press 的话会看到 gui_input 收到了、`pressed` 不响（第一版就这么红的）。
	for pressed in [true, false]:
		var cev := InputEventMouseButton.new()
		cev.button_index = MOUSE_BUTTON_LEFT
		cev.pressed = pressed
		cev.position = cr.get_center()
		cev.global_position = cr.get_center()
		root.push_input(cev)
		await process_frame
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
	# ⚠️ 必须收起标题页：标题页期间 `root_ui` 整个是隐藏的，隐藏的子树**不做布局**
	# （量圆钮列会量到"全都叠在 0"—— 那不是排版坏了，是根本没排）。
	if node.has_method("_end_title"):
		node._end_title()
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

	# ---- 4b. 排版的"中间插进来一个按钮"------------------------------------
	# 出场顺序是：**预言先**（第一章收尾），**科技后**（研究所建起来），而科技在圆钮列里
	# 排在预言的**前面**（第 4 个 vs 第 6 个）—— 所以科技出现时等于往中间插了一个按钮。
	# 圆钮列是 VBoxContainer：隐藏的子节点**不占位**，所以既不许留洞、也不许重叠。
	# 这里两种状态各量一次（用户："中间插进去一个按钮，你 ui 没有排版吗？"）。
	var nav_col = hud.get_parent().get_node_or_null("NavCol")
	if nav_col == null:
		_fail("找不到左侧圆钮列 NavCol")
		return
	# ⚠️ 先把研究所全部拿掉：这一局是**标题页那局的展示村庄**，它本来就有一堆建筑，
	# 很可能已经带着研究所了 —— 不清掉就会直接量到"6 个"，然后误以为"5 个"那步是对的。
	# （用户第一版截图就是这么骗过我的：标题写着 5 个，图里其实是 6 个。）
	var shops_arr: Array = msim.s["shops"]
	for i in range(shops_arr.size() - 1, -1, -1):
		if String((shops_arr[i] as Dictionary)["defId"]) == "research_institute":
			shops_arr.remove_at(i)
	hud.refresh_nav_buttons()
	# ⚠️ 圆钮列的落位是**延后**的（Container 收到 queue_sort 之后要到下一帧才排），
	# 所以量尺寸之前先等几帧 —— 不等的话量到的是"全都叠在 0"的中间态。
	for _f in 3:
		await process_frame
	var tech_btn: Button = hud.get("_tech_nav_btn")
	if tech_btn.visible:
		_fail("研究所已经全部拿掉了，「科技」圆钮还露着")
		return
	if not _nav_layout_ok(nav_col, hud, 5):
		return
	# 加上研究所 → 科技圆钮出现在**中间**，其余整体下移一格，仍然不许留洞
	var d_inst: Dictionary = node.get("runner").db.buildings["research_institute"]
	shops_arr.append({
		"id": "inst#qtt", "defId": "research_institute", "owner": "state",
		"targetWorkers": int(d_inst["workers"]), "wage": 5.0, "wageCap": 30.0,
		"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
	})
	hud.refresh_nav_buttons()
	await process_frame
	await process_frame
	if not tech_btn.visible:
		_fail("研究所建起来之后「科技」圆钮没有出现")
		return
	if not _nav_layout_ok(nav_col, hud, 6):
		return
	print("QUESTTALK TEST 圆钮排版：先 5 个（含预言；贸易要市场才露）→ 科技插到第 4 位变 6 个，中间不留洞 ✅")

	# 城镇中心：贴图跟着**段位**走（三张：破旧 / 初步修缮 / 修好）
	var world = node.get_node("World")
	if msim.town_center_stage() != "ruined":
		_fail("新开局城镇中心画面上就该是破旧的（段位 %s）" % msim.town_center_stage())
		return
	world.refresh_town_center_sprite()
	var tex_ruined: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex_ruined == null or not tex_ruined.resource_path.contains("ruined"):
		_fail("新开局地图上那座城镇中心用的不是破旧素材（%s）"
			% ("null" if tex_ruined == null else tex_ruined.resource_path))
		return
	msim.s["townCenter"] = {"stage": "patched"}
	world.refresh_town_center_sprite()
	var tex_patch: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex_patch == null or not tex_patch.resource_path.contains("patched"):
		_fail("初步修缮之后用的不是 patched 那张（%s）"
			% ("null" if tex_patch == null else tex_patch.resource_path))
		return
	msim.s["townCenter"] = {"stage": "restored"}
	world.refresh_town_center_sprite()
	var tex_ok: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex_ok == null or tex_ok.resource_path.contains("ruined") \
			or tex_ok.resource_path.contains("patched"):
		_fail("修好之后用的不是好图（%s）"
			% ("null" if tex_ok == null else tex_ok.resource_path))
		return
	print("QUESTTALK TEST 城镇中心：破旧 → 初步修缮 → 修好，三张贴图各就各位 ✅")

	# ---- 5. 存档版本：2 起不兼容老档 -------------------------------------
	if SaveManager.SAVE_VERSION != 5:
		_fail("存档版本应当是 4（M4 游商；用户：版本更新，存档不跟之前兼容）")
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
	print("QUESTTALK TEST 存档：SAVE_VERSION=5，老档被拒 ✅")

	print("QUESTTALK TEST RESULT: PASS")
	quit(0)

## 圆钮列的排版自检：**可见的**那几个必须正好 `expect_count` 个、一个挨一个
## （间距 = `NAV_GAP`），而且顺序 = `NAV_ITEMS` 的顺序。
##
## 为什么要单拎出来：出场顺序是「预言先、科技后」，但科技在列里排在预言**前面**——
## 科技出现时等于往中间插了一个按钮。VBoxContainer 对隐藏子节点**不占位**，
## 所以正确表现是"整体下移一格"，不是"留个洞"或"两个压在一起"。
func _nav_layout_ok(nav_col, hud, expect_count: int) -> bool:
	var btns: Array = hud._nav_btns
	var vis: Array = []
	for c in nav_col.get_children():
		if c is Button and (c as Button).visible:
			vis.append(c)
	# ① 个数（别只信 print 里写死的数字 —— 第一条截图就是这么错的）
	if vis.size() != expect_count:
		_fail("圆钮列此刻可见 %d 个，应当是 %d 个（%s）" % [vis.size(), expect_count,
			" / ".join(vis.map(func(b): return String((b as Button).tooltip_text)))])
		return false
	# ② 列里可见的按钮 = HUD 记录里 visible 的那些，且**顺序一致**（不许重排）
	var want: Array = []
	for i in btns.size():
		if (btns[i] as Button).visible:
			want.append(i)
	var got: Array = []
	for b in vis:
		got.append(btns.find(b))
	if got != want:
		_fail("圆钮列可见按钮的下标是 %s，按 NAV_ITEMS 应当是 %s" % [str(got), str(want)])
		return false
	# ③ 一个挨一个：不许留洞、不许重叠
	var gap := float(hud.NAV_GAP)
	for i in range(1, vis.size()):
		var prev: Control = vis[i - 1]
		var cur: Control = vis[i]
		var want_y := prev.position.y + prev.size.y + gap
		if absf(cur.position.y - want_y) > 0.6:
			_fail("圆钮列第 %d 个（%s）的 y=%.1f，应当是 %.1f —— 中间留洞或压住了"
				% [i + 1, String((cur as Button).tooltip_text), cur.position.y, want_y])
			return false
	return true
