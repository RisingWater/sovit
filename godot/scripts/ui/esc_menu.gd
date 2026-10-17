extends Control

# ESC 菜单：保存 / 读取 / 音效开关 / 音乐开关 / 设置资源 / 退出。
#
# 保存与读取都走**自绘的存档对话框**（`save_dialog.gd`，由 main 注入）。
# 早先这里各自 `new` 一个 Godot `FileDialog` —— 它自带一整套默认皮肤，
# 弹出来是"一半像素游戏风、一半默认灰 UI"（用户反馈）。
# 顶栏保留下来的「快存 / 快读」才是直接写默认存档位的那对。
#
# 菜单打开时会把世界层的 unhandled_input 关掉 —— 否则 ESC 会同时被
# world_view 当成"取消建造模式"，菜单一开就把手上的操作取消了。

var runner: SimRunner
var world: Node
var hud: Node
var new_game_dialog: Node = null
var save_dialog: Node = null
## AI 辅助面板（由 main 注入）。这里只放一个入口 —— 配置界面在它自己的对话框里。
var ai_panel: Node = null

var _panel: PanelContainer
var _music_btn: Button
var _sfx_btn: Button

func setup(r: SimRunner, w: Node, h: Node) -> void:
	runner = r
	world = w
	hud = h

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	# 压暗背景
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 14, 12, 14, 12))
	_panel.custom_minimum_size = Vector2(240, 0)
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	var title := UIKit.label("菜单", UIKit.FG_HEAD)
	title.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	vb.add_child(UIKit.hsep())

	var b_new := UIKit.button("新游戏…", false)
	b_new.tooltip_text = "重新开局：设置村名与难度"
	b_new.pressed.connect(func():
		if new_game_dialog != null:
			close()
			new_game_dialog.open())
	vb.add_child(b_new)

	var b_save := UIKit.button("保存…", false)
	b_save.tooltip_text = "选择路径保存存档"
	b_save.pressed.connect(_save_dialog)
	vb.add_child(b_save)
	var b_load := UIKit.button("读取…", false)
	b_load.tooltip_text = "选择存档文件读取"
	b_load.pressed.connect(_load_dialog)
	vb.add_child(b_load)

	vb.add_child(UIKit.hsep())
	_sfx_btn = UIKit.button("", false)
	_sfx_btn.pressed.connect(_toggle_sfx)
	vb.add_child(_sfx_btn)
	_music_btn = UIKit.button("", false)
	_music_btn.pressed.connect(_toggle_music)
	vb.add_child(_music_btn)

	vb.add_child(UIKit.hsep())
	var b_res := UIKit.button("设置资源…", false)
	b_res.tooltip_text = "选择顶栏显示哪些资源"
	b_res.pressed.connect(_open_resources)
	vb.add_child(b_res)

	# AI 辅助：配置 base_url / api_key / model_name，并让 AI 告诉你下一步做什么。
	# 放在「设置资源」下面：同为"接入类"设置，且和存档 / 音效分开一组。
	# 图标是 workbuddy 那套面板图标里的（金色问号）—— 和顶栏那个按钮、面板标题上是同一张。
	# 这一行比别的宽（面板固定 240），Button 自带的 icon 属性会分成两截，
	# 所以走 `UIKit.icon_text_button()`（把图标与文字当成一组居中）。
	var b_ai := UIKit.icon_text_button("AI 辅助…", UIKit.panel_icon("ai_assist"))
	b_ai.tooltip_text = "接入大模型（OpenAI 兼容接口）：配置 base_url / api_key / model_name，" \
		+ "让它根据当前任务与资源告诉你下一步做什么。\n顶栏「AI 辅助」按钮也是这个面板。"
	b_ai.pressed.connect(_open_ai)
	vb.add_child(b_ai)

	var b_dbg := UIKit.button("建筑占地：关", false)
	b_dbg.tooltip_text = "调试：画出每座建筑的占格（同一座同色）。橙框＝门洞与门前通行格 —— 它们被永久保留，所以看着是空地、实际不能建"
	b_dbg.pressed.connect(func(): _toggle_debug_footprint(b_dbg))
	vb.add_child(b_dbg)

	vb.add_child(UIKit.hsep())
	var b_quit := UIKit.button("退出游戏", false)
	b_quit.pressed.connect(_quit)
	vb.add_child(b_quit)

	var hint := UIKit.label("ESC 关闭", Color(0.55, 0.42, 0.30))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)

	_refresh_labels()

func _refresh_labels() -> void:
	if _sfx_btn != null:
		_sfx_btn.text = "音效：%s" % ("关" if (hud != null and hud.sfx != null and hud.sfx.is_muted()) else "开")
	if _music_btn != null:
		_music_btn.text = "音乐：%s" % ("关" if (hud != null and hud.music != null and hud.music.is_muted()) else "开")

func open() -> void:
	_refresh_labels()
	visible = true
	if world != null:
		world.set_process_unhandled_input(false)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	move_to_front()

func close() -> void:
	visible = false
	if world != null:
		world.set_process_unhandled_input(true)

func toggle() -> void:
	if visible:
		close()
	else:
		open()

# ---------------------------------------------------------------------------
# 存档 / 读档
#
# 注意这里**不是** Godot 的 FileDialog，而是同款的像素自绘对话框
# （`save_dialog.gd`）。保存走 `world.save_to()`（富存档：地图/道路/地板/
# 建筑摆位都在），而不是 `SaveManager.save_to()`（只有仿真状态）。
# ---------------------------------------------------------------------------
func _save_dialog() -> void:
	if save_dialog == null:
		return
	close()
	save_dialog.open_save(runner, world)

func _load_dialog() -> void:
	if save_dialog == null:
		return
	close()
	save_dialog.open_load(runner, world)

# ---------------------------------------------------------------------------
func _toggle_sfx() -> void:
	if hud != null and hud.sfx != null:
		hud.sfx.toggle_mute()
		if hud.has_method("_refresh_sfx_btn"):
			hud._refresh_sfx_btn()
	_refresh_labels()

func _toggle_music() -> void:
	if hud != null and hud.music != null:
		hud.music.toggle_mute()
		if hud.has_method("_refresh_music_btn"):
			hud._refresh_music_btn()
	_refresh_labels()

## 调试开关：建筑占地方框。"这块地到底占没占"肉眼可查。
func _toggle_debug_footprint(btn: Button) -> void:
	if world == null or not world.has_method("set_debug_footprints"):
		return
	var on := not bool(world.debug_footprints)
	world.set_debug_footprints(on)
	btn.text = "建筑占地：%s" % ("开" if on else "关")

func _open_resources() -> void:
	if hud != null and hud.has_method("_open_picker"):
		hud._open_picker()

## ESC 菜单 → AI 辅助：**只打开面板、不问**（从菜单进来多半是来配 key 的；
## 想直接问就点顶栏那个按钮，或者面板里的「问 AI」）。
func _open_ai() -> void:
	if ai_panel == null:
		return
	close()
	if ai_panel.has_method("open"):
		ai_panel.open()

func _quit() -> void:
	get_tree().quit()

func _toast(msg: String) -> void:
	if hud != null and hud.has_method("set_notice"):
		hud.set_notice(msg)
