extends Node2D

# 入口：创建 SimRunner（仿真）+ WorldView（地图/建筑/小人）+ UI。
# 快捷键集中在 `_shortcut_input`（F7 快存 / F8 快读也在那里），ESC 走 `_unhandled_input`。

var runner: SimRunner
var world
var _hud
var _bar
var _inspector
var _stats: GameStats
var _panel_stats
var _panel_tech
var _music
var _daylight
var _sfx
var _minimap
var _esc_menu
var _new_game
var _save_dialog
var _panel_civic
var _panel_quest
var _ai_panel
var _dlg_layer: CanvasLayer
var _title
var _title_layer
var _intro
var _intro_layer: CanvasLayer
## 任务 / 章节的剧情对话（galgame 形式，见 scripts/ui/quest_talk.gd）
var _quest_talk
var _quest_talk_layer: CanvasLayer
## 正在播一段剧情对话（这段时间不许再弹下一段）
var _talking := false
## 这段对话的记账键（`q:<任务>` / `c:<章节>`）：播完要回引擎记一笔
var _talk_key := ""
## 是不是**我们**把时间暂停的（玩家本来按着暂停，播完就别动它）
var _talk_paused := false
var root_ui: Control

func _ready() -> void:
	# 窗口标题 = 游戏名（2026-10 换成 Harvest of Heirs）。
	# ⚠️ 故意**不改** `project.godot` 的 `config/name`：Godot 用它拼 `user://`
	# （Windows 下是 `%APPDATA%\Godot\app_userdata\<name>`），一改存档和
	# `user://ai.cfg`（API key）就全留在旧目录里、看起来像"丢了"。
	# 所以只改标题栏这一个显示位。
	get_window().title = "Harvest of Heirs"

	runner = SimRunner.new()
	runner.name = "SimRunner"
	add_child(runner)

	# 背景音乐：Shimmer Sill 两首轮流播放
	_music = load("res://scripts/ui/music.gd").new()
	_music.name = "Music"
	add_child(_music)

	# 菜单音效（Kenney UI SFX，CC0）。UIKit 是静态类，只能通过静态字段注入。
	_sfx = load("res://scripts/ui/sfx.gd").new()
	_sfx.name = "Sfx"
	add_child(_sfx)
	UIKit.sfx = _sfx

	world = load("res://scripts/world/world_view.gd").new()
	world.name = "World"
	world.setup(runner, 12345)
	add_child(world)

	# 昼夜光影：CanvasModulate 挂默认 canvas，只影响世界；UI 在 CanvasLayer 上不受影响
	_daylight = load("res://scripts/world/daylight.gd").new()
	_daylight.name = "Daylight"
	_daylight.setup(runner)
	add_child(_daylight)

	# 统计记录器：每过一个游戏日采样一次（只读仿真状态）
	_stats = GameStats.new()
	_stats.setup(runner)

	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	# 世界里的建筑名标签也在 CanvasLayer 上（layer=1），同层时先后顺序不可靠，
	# 会把字盖到统计面板上。UI 抬到 10，确保压在所有世界元素之上。
	canvas.layer = 10
	add_child(canvas)

	var theme := UIKit.make_theme()

	root_ui = Control.new()
	root_ui.name = "Root"
	root_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ui.theme = theme
	# 主题还要挂到 **window** 上：提示框（TooltipPanel）是独立弹出窗口，
	# 不在 root_ui 的子树里，只设 root_ui.theme 的话它拿不到。
	# 这就是"提示框改了样式却没变化"的原因。
	get_window().theme = theme
	canvas.add_child(root_ui)
	# 让世界知道 UI 根节点：鼠标落在 UI 面板上时不当作地图操作
	world.ui_root = root_ui

	var hud = load("res://scripts/ui/hud.gd").new()
	hud.name = "HUD"
	hud.runner = runner
	hud.world = world
	# 必须在 add_child 之前赋值：hud._ready() 里就会读 music 来刷新按钮文案
	hud.music = _music
	hud.sfx = _sfx
	hud.left_inset = 168.0      # 红巾宽 160 + 间隙
	root_ui.add_child(hud)
	_hud = hud

	# 任务追踪条（引导系统）：**顶栏下面的右侧**，只显示当前任务。
	# 判定与发钱都在仿真的黎明完成，这里只负责画（见 docs/quests.md）。
	var tracker = load("res://scripts/ui/quest_tracker.gd").new()
	tracker.name = "QuestTracker"
	tracker.setup(runner)
	root_ui.add_child(tracker)

	var bar = load("res://scripts/ui/build_bar.gd").new()
	bar.name = "BuildBar"
	bar.runner = runner
	bar.world = world
	root_ui.add_child(bar)
	_bar = bar

	_inspector = load("res://scripts/ui/inspector.gd").new()
	_inspector.name = "Inspector"
	_inspector.runner = runner
	_inspector.world = world
	root_ui.add_child(_inspector)

	_panel_stats = load("res://scripts/ui/panel_stats.gd").new()
	_panel_stats.name = "Stats"
	_panel_stats.setup(runner, world, _stats)
	root_ui.add_child(_panel_stats)
	hud.stats_panel = _panel_stats

	_panel_tech = load("res://scripts/ui/panel_tech.gd").new()
	_panel_tech.name = "Tech"
	_panel_tech.setup(runner, world)
	root_ui.add_child(_panel_tech)
	hud.tech_panel = _panel_tech

	# 城镇中心 / 仓库走**浮动对话框**（和点左侧圆钮出来的「统计」面板同一套形式），
	# 不再用右侧那条常驻面板（用户不喜欢那个形式）。
	_panel_civic = load("res://scripts/ui/panel_civic.gd").new()
	_panel_civic.name = "Civic"
	_panel_civic.setup(runner, world)
	root_ui.add_child(_panel_civic)

	# 任务面板（见 docs/town.md §十九）：左侧圆钮列第 5 个（F5）打开。
	# 读的是 `SimCore.quest_journal()`（全部已知任务：已完成 + 已解锁），
	# 所以做过的历史都能回头翻。
	_panel_quest = load("res://scripts/ui/panel_quest.gd").new()
	_panel_quest.name = "QuestPanel"
	_panel_quest.setup(runner, world)
	root_ui.add_child(_panel_quest)
	hud.quest_panel = _panel_quest

	# AI 辅助（见 docs/ai-assist.md）：ESC 菜单与顶栏按钮共用一个浮动对话框。
	# **必须建在 `_bar` 之后**并注入它 —— 建议里要写"在建造栏哪一页建"，
	# 而分组规则在 `build_bar` 那边（现在转发到 `ContentDB.build_category()`）。
	_ai_panel = load("res://scripts/ui/ai_panel.gd").new()
	_ai_panel.name = "AiPanel"
	_ai_panel.setup(runner, world, _bar)
	_ai_panel.hud = hud
	root_ui.add_child(_ai_panel)
	hud.ai_panel = _ai_panel

	world.select_building.connect(_on_select_building)
	world.select_housing.connect(_inspector.show_housing)
	world.select_resident.connect(_inspector.show_resident)
	world.select_none.connect(_inspector.clear)
	world.notice.connect(hud.set_notice)

	# 左上角小地图挂件（画在 HUD 之上）
	_minimap = load("res://scripts/ui/minimap_widget.gd").new()
	_minimap.name = "Minimap"
	_minimap.setup(runner, world)
	root_ui.add_child(_minimap)

	# ESC 菜单（最上层）
	_esc_menu = load("res://scripts/ui/esc_menu.gd").new()
	_esc_menu.name = "EscMenu"
	_esc_menu.setup(runner, world, hud)
	root_ui.add_child(_esc_menu)
	hud.esc_menu = _esc_menu
	_esc_menu.ai_panel = _ai_panel

	# 新游戏对话框（标题页与 ESC 菜单都会用它）
	_new_game = load("res://scripts/ui/new_game_dialog.gd").new()
	_new_game.name = "NewGame"
	_new_game.setup(runner, world)
	root_ui.add_child(_new_game)
	_esc_menu.new_game_dialog = _new_game

	# 存档 / 读档对话框（自绘，见 save_dialog.gd 顶部注释）。
	# ESC 菜单和标题页的「读取进度」都走它 —— 以前那三处各自 new 一个 FileDialog，
	# 于是弹出来是"一半像素游戏风、一半 Godot 默认灰 UI"。
	#
	# ⚠️ 挂在自己的 CanvasLayer（layer 30）上，**不能**放进 root_ui：
	# 标题页期间 `root_ui.visible = false`，放里面的话从标题页点「读取进度」
	# 根本看不到对话框（取消之后还会被留在游戏里，因为露 UI 是标题页那套流程干的）。
	_dlg_layer = CanvasLayer.new()
	_dlg_layer.name = "DialogLayer"
	_dlg_layer.layer = 30
	add_child(_dlg_layer)
	_save_dialog = load("res://scripts/ui/save_dialog.gd").new()
	_save_dialog.name = "SaveDialog"
	# 不显式给主题的话它用的是 Godot 默认主题（理由同下面的标题页）
	_save_dialog.theme = theme
	_save_dialog.setup(runner, world)
	_dlg_layer.add_child(_save_dialog)
	_esc_menu.save_dialog = _save_dialog
	# 读档成功：如果当时还在标题页，就读档结果直接进游戏
	_save_dialog.loaded.connect(func(_p):
		# 读档换的是**另一个 SimCore 对象**：顶栏平时只挂在 `hour_ticked` 上，
		# 不手动刷一次的话顶上还留着上一局（或标题页那局展示村庄）的钱和人。
		if _hud != null and _hud.has_method("refresh_now"):
			_hud.refresh_now()
		if _title_layer != null and _title_layer.visible:
			_end_title()
		# 读进来的这一局可能还有没播过的对话（比如存档是刚结算完黎明就退出的）
		call_deferred("_poll_quest_talks"))

	# 标题页：独立 CanvasLayer，压在整个游戏 UI 之上。
	# 展示期间把 root_ui 整个藏掉 —— 玩家看不到 HUD、点不到建造栏、也够不着 ESC 菜单，
	# 从玩家角度这局就是只读展示。开始游戏时再重新开局覆盖它。
	_title_layer = CanvasLayer.new()
	_title_layer.name = "TitleLayer"
	_title_layer.layer = 20
	add_child(_title_layer)
	_title = load("res://scripts/ui/title_screen.gd").new()
	_title.name = "Title"
	# 标题页挂在独立 CanvasLayer 上，**不在 root_ui 的子树里**，
	# 所以拿不到 root_ui.theme —— 不显式给的话它用的是 Godot 默认主题
	# （扁平灰按钮），和游戏内那套像素框完全不是一回事。
	_title.theme = theme
	_title.setup(runner, world, _new_game)
	_title.save_dialog = _save_dialog
	_title_layer.add_child(_title)
	_title.start_requested.connect(_end_title)
	root_ui.visible = false
	# 世界里的建筑名标签挂在 world 自己的 CanvasLayer 上（layer=1），不归 root_ui 管
	# —— 不单独藏的话，标题页上会有一堆「茅屋 / 砖房 / 仓库」飘在 logo 上。
	if world.label_layer != null:
		world.label_layer.visible = false
	# 标题页期间关掉世界的鼠标输入。
	# 标题页挂在独立 CanvasLayer 上、不是 root_ui 的子节点，所以 world_view 里
	# 那个"鼠标在 UI 上就不碰镜头"的守卫认不出它 —— 结果在标题页滚轮照样能缩放。
	# 标题页是展示，屏幕上不该有"能操作地图"的错觉。
	world.set_process_unhandled_input(false)
	_title.begin_showcase()

	# 开场剧情（第 1~5 幕，见 scripts/ui/intro.gd）。独立 CanvasLayer，压在标题页之上。
	# 只有**开新局**会触发（读档不该再放一遍）。
	_intro_layer = CanvasLayer.new()
	_intro_layer.name = "IntroLayer"
	_intro_layer.layer = 40
	add_child(_intro_layer)
	_intro = load("res://scripts/ui/intro.gd").new()
	_intro.name = "Intro"
	_intro.theme = theme
	_intro_layer.add_child(_intro)
	_intro.finished.connect(_end_intro)
	_new_game.started.connect(_begin_intro)

	# 任务 / 章节的剧情对话（用户 2026-10）：任务一出现、或者一章全绿，就弹一段。
	# 独立 CanvasLayer（layer 35）：压在所有面板之上、但**在开场剧情之下**（40）。
	_quest_talk_layer = CanvasLayer.new()
	_quest_talk_layer.name = "QuestTalkLayer"
	_quest_talk_layer.layer = 35
	add_child(_quest_talk_layer)
	_quest_talk = load("res://scripts/ui/quest_talk.gd").new()
	_quest_talk.name = "QuestTalk"
	_quest_talk.theme = theme
	_quest_talk_layer.add_child(_quest_talk)
	_quest_talk.finished.connect(_on_quest_talk_finished)
	# 每一小时都可能"顶"出新任务 / 结算完一章（黎明就在小时里），所以挂在 hour_ticked 上。
	# ⚠️ 用 `call_deferred`：这个信号是从仿真 tick 里发出来的，正在改状态，
	#    这时候去读 `quest_talks_pending()` 是干净的（tick 已收尾），但**别在信号里
	#    直接开层/暂停** —— 延到这一帧结束更安全。
	runner.hour_ticked.connect(func(): call_deferred("_poll_quest_talks"))
	# 面板**关掉之后**再看一眼：对话是黎明产出的，那一刻玩家可能正开着面板在读。
	# 有面板开着的时候 `_poll_quest_talks()` 会让路（见那段注释），所以关掉时补一次。
	for p in [_panel_stats, _panel_tech, _panel_civic, _panel_quest, _esc_menu,
			_new_game, _save_dialog, _ai_panel]:
		if p != null:
			(p as CanvasItem).visibility_changed.connect(func():
				if not (p as CanvasItem).visible:
					call_deferred("_poll_quest_talks"))

## 开新局 → 放开场剧情：藏起游戏 UI、暂停时间、换开场曲。
func _begin_intro() -> void:
	if _intro == null:
		return
	root_ui.visible = false
	if world.label_layer != null:
		world.label_layer.visible = false
	# 剧情期间时间暂停（用户："剧情中时间暂停"）—— 走 HUD 那条路，
	# 这样顶栏的暂停按钮和真实状态一致（虽然这时 UI 是藏着的）
	if _hud != null and _hud.has_method("set_paused_external"):
		_hud.set_paused_external(true)
	else:
		runner.set_paused(true)
	if _music != null:
		_music.play_intro()
	_intro.begin(runner.sim)

## 剧情结束（或玩家跳过）→ 露出游戏 UI、恢复时间。
func _end_intro() -> void:
	if _intro_layer != null:
		_intro_layer.visible = false
	root_ui.visible = true
	if world.label_layer != null:
		world.label_layer.visible = true
	if _intro != null:
		_intro.queue_free()
		_intro = null
	runner.set_paused(false)
	if _hud != null and _hud.has_method("refresh_now"):
		_hud.refresh_now()
	# 开场剧情放完，第一条任务对话（塞巴斯蒂安讲「粗面包链」）接着来
	call_deferred("_poll_quest_talks")

# ---------------------------------------------------------------------------
# 任务 / 章节的剧情对话
#
# 数据源是引擎：`SimCore.quest_talks_pending()`（见 docs/quests.md §七）。
# 这里只做四件事：**拿第一条 → 暂停时间 → 播 → 播完回引擎记一笔、拿下一条**。
#
# 除了 `hour_ticked`，`_process` 里还有一条**慢速重试**（0.75s）：对话在黎明产出，
# 而黎明那一刻玩家可能正开着面板在读 —— 那时候不该把一段剧情糊在他脸上。
# 所以有面板开着就先不播，等他关上，下一次重试自然会接着播。
# ---------------------------------------------------------------------------

## 有没播过的对话就播一条（一次只播一条；剩下的等这一条播完再取）。
func _poll_quest_talks() -> void:
	if _quest_talk == null or _talking:
		return
	if runner == null or runner.sim == null:
		return
	# 开场剧情 / 标题页期间不抢（那时候屏幕上不该出现第二套对话）
	if _intro != null and _intro.visible:
		return
	if _title_layer != null and _title_layer.visible:
		return
	# 玩家正在看面板 / 对话框：先不抢，等他关掉（`_process` 会重试）
	if _modal_open() or _fullscreen_panel_open():
		return
	if _ai_panel != null and (_ai_panel as CanvasItem).visible:
		return
	var pend: Array = runner.sim.quest_talks_pending()
	if pend.is_empty():
		return
	var talk: Dictionary = pend[0]
	_talking = true
	_talk_key = String(talk.get("key", ""))
	# 剧情期间时间暂停（用户："触发任务的时候，时间暂停"）。
	# 玩家本来就按着暂停的话，播完别替他恢复 —— 所以先记一笔。
	_talk_paused = false
	if not runner.paused:
		if _hud != null and _hud.has_method("set_paused_external"):
			_hud.set_paused_external(true)
		else:
			runner.set_paused(true)
		_talk_paused = true
	_quest_talk.play(talk)

## 一段对话播完（`action` = 选项的 action；没选项时空串）。
func _on_quest_talk_finished(action: String) -> void:
	_talking = false
	if runner != null and runner.sim != null and _talk_key != "":
		runner.sim.quest_talk_mark_shown(_talk_key)
	_talk_key = ""
	if _talk_paused:
		if _hud != null and _hud.has_method("set_paused_external"):
			_hud.set_paused_external(false)
		else:
			runner.set_paused(false)
		_talk_paused = false
	# 第一章收尾选了「……说下去」→ 她当场送一次免费预言（不吃 5 天冷却）
	if action == "free_prophecy" and _ai_panel != null and runner.sim.prophet_unlocked():
		_ai_panel.open_free_prophecy()
	# 同一次黎明可能顶出好几条（还可能有章节收尾）—— 接着来
	call_deferred("_poll_quest_talks")

## 点地图上的建筑：城镇中心 / 仓库 弹浮动对话框，其余走右侧建筑面板。
func _on_select_building(id: String) -> void:
	var def_id := ""
	for sh in runner.sim.s["shops"]:
		if String(sh["id"]) == id:
			def_id = String(sh["defId"])
			break
	if def_id == "town_center":
		# 右侧面板收起，免得两个东西同时讲同一件事
		_inspector.clear()
		_panel_civic.open_town_center()
		return
	if def_id == "warehouse":
		_inspector.clear()
		_panel_civic.open_warehouse(id)
		return
	_panel_civic.close_panel()
	_inspector.show_building(id)

## 标题页结束：露出游戏 UI（展示用的那局已被新游戏/读档覆盖）
func _end_title() -> void:
	root_ui.visible = true
	_title_layer.visible = false
	# 开新局 / 读档都会走到这里 —— 顶栏先按**现在这个** sim 刷一遍（见 loaded 那边的注释）
	if _hud != null and _hud.has_method("refresh_now"):
		_hud.refresh_now()
	if world.label_layer != null:
		world.label_layer.visible = true
	# 必须停掉 _process —— 它每帧都在改 camera.position，
	# 不停的话开局/读档之后镜头还会被标题页的环绕拉走。
	_title.set_process(false)
	world.set_process_unhandled_input(true)

func _process(_delta: float) -> void:
	if _stats == null:
		return
	# 只在真的采到新数据（跨天）时才重建面板。
	# 曾经写成"只要面板可见就 refresh()"，结果每帧销毁重建所有子节点，
	# 按钮永远点不动 —— 面板看起来正常，就是没反应。
	if _stats.poll() and _panel_stats != null and _panel_stats.visible:
		_panel_stats.refresh()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		# 标题页期间不弹游戏内菜单（那时 HUD 整个是隐藏的）
		if _title_layer != null and _title_layer.visible:
			return
		# 全屏面板开着时，Esc 先关面板（那是"当前一层"），不直接弹菜单 ——
		# 否则玩家想退出面板却弹出一个菜单盖上来。
		if _panel_stats != null and _panel_stats.visible:
			_panel_stats.visible = false
			return
		if _panel_tech != null and _panel_tech.visible:
			_panel_tech.visible = false
			return
		_esc_menu.toggle()

# ---- 快捷键 -----------------------------------------------------------------
#
# 全部集中在这里，**方法体都只调 UI 自己的函数**（`_hud.toggle_pause()` /
# `_bar.activate_card()` …），不在这里重抄一遍业务分支 —— 否则"点按钮"和
# "按快捷键"迟早会走出两种行为。
#
# 为什么挂在 `_shortcut_input` 而不是 `_unhandled_input`：
#   ① 它在 GUI **之后**、`_unhandled_input` **之前**跑，所以输入框在打字时
#      这些键根本到不了这里（我们不必跟 LineEdit 抢字符）；
#   ② 顺序上它也在 `world_view._unhandled_input` 之前，先吃掉就不会打架。
#   另外仍然显式挡一次文本框：F1 这类键 LineEdit 是不吃的，只靠 ① 会漏。
func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# 极早期（UI 还没建完）时什么都不做，别把键吃掉
	if _hud == null or _bar == null or world == null:
		return
	# 标题页是只读展示，不吃任何游戏快捷键
	if _title_layer != null and _title_layer.visible:
		return
	# 文本框优先（村名 / 存档名里打 "wasd"、按空格都不该有副作用）
	var fo := get_viewport().gui_get_focus_owner()
	if fo is LineEdit or fo is TextEdit:
		return
	# 模态对话框开着时（ESC 菜单 / 新游戏 / 存读档）不抢键
	if _modal_open():
		return
	# 剧情对话正在播：快捷键全部让路（空格是"翻页"，不是"暂停"）——
	# 这段话自己的 `_input` 已经吃掉了 Esc / 空格 / 回车。
	if _talking:
		return

	var k: int = event.keycode
	# 全屏面板（统计 / 科技）盖住了建造栏 → 建造栏的快捷键（Tab / 数字键）
	# 让路；时间控制（空格 / +/-）不受影响，顶栏一直是露着的。
	var bar_hidden := _fullscreen_panel_open()
	match k:
		KEY_SPACE:
			_hud.toggle_pause()
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			_hud.speed_step(1)
		KEY_MINUS, KEY_UNDERSCORE, KEY_KP_SUBTRACT:
			_hud.speed_step(-1)
		KEY_TAB:
			if bar_hidden:
				return
			_bar.cycle_tab(-1 if event.shift_pressed else 1)
		KEY_H:
			world.focus_town_center()
		KEY_F7:
			# 快存 / 快读走 HUD 自己的函数（和顶栏那两个按钮同一条路），
			# 目标路径也在 HUD 上（门槛会把它指到测试存档位）。
			_hud.quick_save()
		KEY_F8:
			_hud.quick_load()
		_:
			if k >= KEY_1 and k <= KEY_9:
				# 1..9 = 建造栏当前这一页的第 N 张卡片
				if bar_hidden:
					return
				var msg: String = _bar.activate_card(k - KEY_1)
				if msg != "":
					world.notice.emit(msg)
			elif k >= KEY_F1 and k <= KEY_F1 + int(_hud.NAV_MAX_KEY) - 1:
				# F1..F6 = 左侧圆钮。**F7 / F8 是快存 / 快读**（用户定的），
				# 不在这个区间里；没有那个按钮就原样放行这个键。
				if not _hud.activate_nav(k - KEY_F1):
					return
			else:
				return
	get_viewport().set_input_as_handled()

## 模态对话框是否开着（这些开着时快捷键让路）。
func _modal_open() -> bool:
	for d in [_esc_menu, _new_game, _save_dialog]:
		if d != null and (d as Control).visible:
			return true
	return false

## 全屏面板（统计 / 科技）是否开着 —— 它盖住了建造栏，所以建造栏的快捷键要让路。
func _fullscreen_panel_open() -> bool:
	return (_panel_stats != null and _panel_stats.visible) \
		or (_panel_tech != null and _panel_tech.visible)
