extends Control

# ESC 菜单：保存 / 读取 / 音效开关 / 音乐开关 / 设置资源 / 退出。
#
# 保存与读取用 **FileDialog**（真正的文件系统对话框，可以自己选路径）；
# 顶栏保留下来的「快存 / 快读」才是直接写默认存档位的那对。
#
# 菜单打开时会把世界层的 unhandled_input 关掉 —— 否则 ESC 会同时被
# world_view 当成"取消建造模式"，菜单一开就把手上的操作取消了。

var runner: SimRunner
var world: Node
var hud: Node

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
	var b_stats := UIKit.button("统计面板", false)
	b_stats.pressed.connect(func():
		close()
		if hud != null:
			hud._open_stats())
	vb.add_child(b_stats)

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
# 文件对话框
# ---------------------------------------------------------------------------
func _save_dialog() -> void:
	var d := FileDialog.new()
	d.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	d.access = FileDialog.ACCESS_USERDATA
	d.add_filter("*.json", "存档")
	d.current_file = "sovit-save.json"
	d.title = "保存到…"
	d.size = Vector2i(760, 520)
	add_child(d)
	d.file_selected.connect(func(path: String):
		var err := SaveManager.save_to(path, runner.sim)
		if err == OK:
			_toast("已保存：%s" % path.get_file())
		else:
			_toast("保存失败（错误码 %d）" % err)
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	d.popup_centered()

func _load_dialog() -> void:
	var d := FileDialog.new()
	d.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	d.access = FileDialog.ACCESS_USERDATA
	d.add_filter("*.json", "存档")
	d.title = "读取存档…"
	d.size = Vector2i(760, 520)
	add_child(d)
	d.file_selected.connect(func(path: String):
		close()
		# 走 world.load_from，它会把地图和仿真一起换掉并重绘
		if world != null and world.load_from(path):
			_toast("已读取：%s" % path.get_file())
		else:
			_toast("读取失败：%s" % path.get_file())
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	d.popup_centered()

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

func _open_resources() -> void:
	if hud != null and hud.has_method("_open_picker"):
		hud._open_picker()

func _quit() -> void:
	get_tree().quit()

func _toast(msg: String) -> void:
	if hud != null and hud.has_method("set_notice"):
		hud.set_notice(msg)
