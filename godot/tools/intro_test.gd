extends SceneTree

# 开场剧情（第 1~5 幕）与「科技圆钮藏起来」的门槛。
#
# 查四件事：
#   1. 剧本本身：5 幕、每幕至少一页、**逐字查像素字体有没有那个字**（缺字 = 屏幕上空一块）
#   2. 说话人：2~5 幕的 `who` 都在立绘表里，名字表里也有中文名
#   3. 播完会发 `finished`：`begin()` → 一路翻 → 收到信号；`_finish()`（跳过）也能收
#   4. 新开局之后「科技」圆钮是**藏着的**，建起研究所才出现

const INTRO := "res://scripts/ui/intro.gd"

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("INTRO TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	# ⚠️ headless 的 dummy 窗口只有 64×64，而剧情框的位置是按 `get_viewport_rect()` 算的
	# （headless 下它报 1600×1600）。不撑开窗口，鼠标事件就落在"窗口外面"、
	# GUI 拾取找不到任何控件 —— "点文字框能翻页"那条断言会假红。
	root.size = Vector2i(1600, 1600)
	await process_frame
	var font := UIKit.pixel_font()
	var script: Array = load(INTRO).SCRIPT
	if script.size() != 5:
		_fail("开场应当是 5 幕，实际 %d 幕" % script.size())
		return
	var ids := ["sebastian", "vera", "reynard", "luna", "alvin", "serafina", "isabella"]
	for i in script.size():
		var act: Dictionary = script[i]
		var pages: Array = act.get("pages", [])
		if pages.is_empty():
			_fail("第 %d 幕没有台词" % (i + 1))
			return
		var who := String(act.get("who", ""))
		if i > 0 and who == "":
			_fail("第 %d 幕没有指定说话人（第 1 幕才是旁白）" % (i + 1))
			return
		if who != "" and not ids.has(who):
			_fail("第 %d 幕的说话人「%s」不在立绘表里" % [i + 1, who])
			return
		if who != "" and not (Cast.NAME as Dictionary).has(who):
			_fail("第 %d 幕的说话人「%s」没有中文名" % [i + 1, who])
			return
		if who != "" and Cast.portrait(who) == null:
			_fail("说话人「%s」的立绘不存在" % who)
			return
		for page in pages:
			for line in (page as Array):
				var t := String(line)
				if t.strip_edges() == "":
					_fail("第 %d 幕有一行是空的" % (i + 1))
					return
				# 占位符不算字，先剥掉再逐字查
				t = t.replace("{money}", "").replace("{pop}", "")
				for ch in t:
					if not font.has_char(ch.unicode_at(0)):
						_fail("第 %d 幕有像素字体画不出的字：%s（「%s」）" % [i + 1, ch, line])
						return
	print("INTRO TEST 剧本 5 幕、说话人/立绘/中文名齐、缺字 0")

	# ---- 播完会发 finished（含"跳过"那条路）
	# ⚠️ `host` 要铺满视口：剧情是 `PRESET_FULL_RECT`，尺寸跟着父节点走。
	# 给 0×0 的 host，剧情自己的 rect 就是 0×0，真鼠标点上去 GUI 拾取找不到它。
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var intro = load(INTRO).new()
	host.add_child(intro)
	await process_frame
	var got := [false]
	intro.finished.connect(func(): got[0] = true)
	intro.begin(null)
	# 一路翻到最后一页之后
	for i in 40:
		if got[0]:
			break
		intro._advance()
	if not got[0]:
		_fail("一路翻完没有发 finished（玩家会被关在剧情里）")
		return
	if intro.visible:
		_fail("剧情结束之后还看得见")
		return
	# 跳过
	got[0] = false
	intro.begin(null)
	intro._finish()
	if not got[0]:
		_fail("点「跳过」没有发 finished")
		return
	# 点鼠标也要能翻页（和任务对话同一个坑：文字框是 PanelContainer，
	# `mouse_filter` 默认 STOP 会把点击吃掉，父节点收不到 `_gui_input`）
	intro.begin(null)
	intro.jump_to_act(1)          # 第 2 幕才有文字框（第 1 幕是黑屏旁白）
	await process_frame
	var p0: int = intro.get("_page")
	var ibox: PanelContainer = intro.get("_box")
	var at: Vector2 = ibox.position + ibox.size * 0.5
	var mev := InputEventMouseButton.new()
	mev.button_index = MOUSE_BUTTON_LEFT
	mev.pressed = true
	mev.position = at
	mev.global_position = at
	root.push_input(mev)
	await process_frame
	if int(intro.get("_page")) == p0:
		_fail("点在开场剧情的文字框上翻不了页（鼠标被框吃掉了）")
		return
	print("INTRO TEST 鼠标：点文字框能翻页 ✅")
	intro._finish()
	intro.queue_free()
	host.queue_free()
	print("INTRO TEST 翻页到底 / 跳过 都会收尾 ✅")

	# ---- 科技圆钮：研究所建起来之前不出现
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var hud = node.get_node_or_null("UI/Root/HUD")
	if hud == null:
		_fail("找不到 HUD")
		return
	var tech_btn: Button = hud.get("_tech_nav_btn")
	if tech_btn == null:
		_fail("HUD 里没有记下「科技」那个圆钮（_tech_nav_btn）")
		return
	var has_inst := false
	for sh in (node.get("runner").sim.s["shops"] as Array):
		if String((sh as Dictionary)["defId"]) == "research_institute":
			has_inst = true
	if not has_inst and tech_btn.visible:
		_fail("还没研究所，「科技」圆钮就已经露出来了")
		return
	# 造一座研究所 → 刷一次就该出现
	if not has_inst:
		var d: Dictionary = node.get("runner").db.buildings["research_institute"]
		(node.get("runner").sim.s["shops"] as Array).append({
			"id": "inst#introtest", "defId": "research_institute", "owner": "state",
			"targetWorkers": int(d["workers"]), "wage": 5.0, "wageCap": 30.0,
			"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		})
		hud.refresh_nav_buttons()
		await process_frame
		if not tech_btn.visible:
			_fail("研究所建起来之后「科技」圆钮没有出现")
			return
	print("INTRO TEST 科技圆钮：研究所之前藏着、之后出现 ✅")

	# ---- 城镇中心：三段（破旧 → 初步修缮 → 修好），换图跟着**段位**走（用户 2026-10）
	var sim = node.get("runner").sim
	if sim.town_center_stage() != "ruined":
		_fail("新开局的城镇中心应当是破旧的（用户：初始城镇中心是破旧的）")
		return
	sim.s["goods"]["wood"] = 200.0
	sim.s["goods"]["stone"] = 200.0
	sim.s["goods"]["brick"] = 200.0
	var world = node.get_node("World")
	world.refresh_town_center_sprite()
	var tex0: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex0 == null or not tex0.resource_path.contains("ruined"):
		_fail("开局地图上那座城镇中心用的不是破旧素材")
		return
	var wood0 := float(sim.s["goods"]["wood"])
	# 第一步：初步修缮（第三章那条任务的目标段）
	sim.enqueue([{"type": "repair_town_center", "stage": "patched"}])
	sim._run_dawn()
	if sim.town_center_stage() != "patched":
		_fail("下了初步修缮命令、过一个黎明之后段位是「%s」" % sim.town_center_stage())
		return
	if float(sim.s["goods"]["wood"]) >= wood0:
		_fail("初步修缮没有扣材料（木 %.0f → %.0f）" % [wood0, float(sim.s["goods"]["wood"])])
		return
	world.refresh_town_center_sprite()
	var tex1: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex1 == null or not tex1.resource_path.contains("patched"):
		_fail("初步修缮之后地图上应当换成 patched 那张（实际 %s）"
			% ("null" if tex1 == null else tex1.resource_path))
		return
	# 第二步：修好（第四章那条任务的目标段）
	sim.enqueue([{"type": "repair_town_center", "stage": "restored"}])
	sim._run_dawn()
	if sim.town_center_stage() != "restored":
		_fail("下了修缮命令之后段位还是「%s」" % sim.town_center_stage())
		return
	world.refresh_town_center_sprite()
	var tex2: Texture2D = (world.town_center_sprite as Sprite2D).texture
	if tex2 == null or tex2.resource_path.contains("ruined") or tex2.resource_path.contains("patched"):
		_fail("修好之后地图上应当换成好图（实际 %s）"
			% ("null" if tex2 == null else tex2.resource_path))
		return
	print("INTRO TEST 城镇中心：破旧 → 初步修缮（换 patched 图）→ 修好（换好图）✅")
	print("INTRO TEST RESULT: PASS")
	quit(0)
