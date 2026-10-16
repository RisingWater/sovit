extends Control

# 存档 / 读档对话框（**自绘**，不用 Godot 的 FileDialog）。
#
# 为什么自绘：`FileDialog` 自带一整套默认皮肤 —— 标题栏、路径栏、文件列表、
# 滚动条、下拉框、确认按钮。项目主题只覆盖 Button / Label / Panel / LineEdit，
# 剩下的全是 Godot 默认灰 UI，弹出来就是"一半像素游戏风、一半默认风"
# （用户原话）。而且存档都在 `user://` 下，玩家本来也没有路径可挑，
# 给一个文件浏览器纯属负担。
#
# 这里只做三件事：**列出 user:// 下的 *.json 存档 → 读取 / 保存 / 删除**。
# 顶栏的「快存 / 快读」不走这里（那对直接写默认位）。
#
# 两个安全设计：
#   1. 覆盖 / 删除都**要点两次**（第一次变成确认态并提示），不弹二级对话框 ——
#      二级对话框又是一套皮肤，而且挡视线。
#   2. 保存走 `world.save_to()`（**富存档**：地图/道路/地板/建筑位置都在里面），
#      不是 `SaveManager.save_to()`（只有仿真状态，读回来地图和摆位会丢）。

const DIR := "user://"
const EXT := ".json"

enum Mode { SAVE, LOAD }

## 读档成功。调用方负责切场景/收起标题页。
signal loaded(path: String)
## 关掉了（无论读、存还是取消）。
signal closed

var runner: SimRunner
var world: Node

var _mode := Mode.LOAD
var _panel: PanelContainer
var _title_lb: Label
var _sub_lb: Label
var _rows: VBoxContainer
var _name_box: VBoxContainer
var _name_edit: LineEdit
var _act_btn: Button
var _del_btn: Button
var _hint_lb: Label
var _row_btns := {}
var _selected := ""
## 二次确认标记："" / "save:<path>" / "del:<path>"
var _confirm := ""

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# 和标题页/ESC 菜单同一顶层层级：挂 canvas layer 由 main 负责，这里只管内容
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.09, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 16, 14, 16, 14))
	_panel.custom_minimum_size = Vector2(460, 0)
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	_title_lb = UIKit.label("读取存档", UIKit.FG_HEAD)
	_title_lb.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	_title_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title_lb)
	_sub_lb = UIKit.label("", UIKit.FG_DIM)
	_sub_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_sub_lb)
	vb.add_child(UIKit.hsep())

	# 列表：凹陷石板底 + 米黄行（亮件压暗底，和 HUD 顶栏同一个关系）
	var list_wrap := PanelContainer.new()
	list_wrap.add_theme_stylebox_override("panel", UIKit.pad(UIKit.inset_box(), 5, 5, 5, 5))
	vb.add_child(list_wrap)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 190)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_wrap.add_child(sc)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 3)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_rows)

	# 存档名（只有保存模式显示）
	_name_box = VBoxContainer.new()
	_name_box.add_theme_constant_override("separation", 4)
	_name_box.add_child(UIKit.label("存档名（写入 user:// 目录）", UIKit.FG_HEAD))
	_name_edit = UIKit.input("sovit-save", 48)
	_name_edit.text_changed.connect(func(_t): _confirm = "")
	_name_box.add_child(_name_edit)
	vb.add_child(_name_box)

	_hint_lb = UIKit.label("", UIKit.FG_DIM)
	_hint_lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_hint_lb)
	vb.add_child(UIKit.hsep())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_del_btn = UIKit.button("删除", true)
	_del_btn.pressed.connect(_on_delete)
	row.add_child(_del_btn)
	row.add_child(UIKit.spacer())
	var cancel := UIKit.button("取消", true)
	cancel.pressed.connect(close)
	row.add_child(cancel)
	_act_btn = UIKit.button("读取", true)
	_act_btn.pressed.connect(_on_act)
	row.add_child(_act_btn)
	vb.add_child(row)

# ---------------------------------------------------------------------------
# 打开 / 关闭
# ---------------------------------------------------------------------------
func open_load(r: SimRunner, w: Node) -> void:
	_open(Mode.LOAD, r, w)

func open_save(r: SimRunner, w: Node) -> void:
	_open(Mode.SAVE, r, w)

func _open(m: int, r: SimRunner, w: Node) -> void:
	_mode = m
	if r != null:
		runner = r
	if w != null:
		world = w
	_selected = ""
	_confirm = ""
	visible = true
	if world != null:
		world.set_process_unhandled_input(false)
	_title_lb.text = "保存存档" if _mode == Mode.SAVE else "读取存档"
	_sub_lb.text = "存档存在 user:// 目录下，按修改时间排序"
	_name_box.visible = _mode == Mode.SAVE
	_del_btn.visible = _mode == Mode.LOAD
	_act_btn.text = "保存" if _mode == Mode.SAVE else "读取"
	_name_edit.text = _default_name()
	_refresh()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	move_to_front()
	if _mode == Mode.SAVE:
		_name_edit.grab_focus()
		_name_edit.select_all()

func close() -> void:
	visible = false
	if world != null:
		world.set_process_unhandled_input(true)
	closed.emit()

# ---------------------------------------------------------------------------
# 列表
# ---------------------------------------------------------------------------
## 收集 `user://` 下的存档，按修改时间从新到旧。
## 返回 [{path, file, village, day, mtime, ok}]
static func list_saves() -> Array:
	var out := []
	var d := DirAccess.open(DIR)
	if d == null:
		return out
	for f in d.get_files():
		var name := String(f)
		if not name.ends_with(EXT) or name.ends_with(EXT + ".bak"):
			continue
		var path := DIR + name
		var meta := _meta(path)
		out.append({
			"path": path, "file": name,
			"village": meta["village"], "day": meta["day"],
			"mtime": FileAccess.get_modified_time(path), "ok": meta["ok"],
		})
	out.sort_custom(func(a, b): return int(a["mtime"]) > int(b["mtime"]))
	return out

## 读存档头（两种格式都认：世界富存档 `sim.state`，以及旧的扁平格式）。
static func _meta(path: String) -> Dictionary:
	var out := {"village": "?", "day": 0, "ok": false}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null or not (data is Dictionary):
		return out
	var st = data.get("state", null)
	if st == null and data.has("sim"):
		st = (data["sim"] as Dictionary).get("state", null)
	if st == null or not (st is Dictionary):
		return out
	out["village"] = String(st.get("villageName", "?"))
	out["day"] = int(st.get("day", 0))
	out["ok"] = true
	return out

func _refresh() -> void:
	for c in _rows.get_children():
		c.queue_free()
	_row_btns.clear()
	var saves := list_saves()
	if saves.is_empty():
		var none := UIKit.label("（还没有存档，先「保存」一个）", UIKit.FG_LABEL)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows.add_child(none)
		return
	for s in saves:
		var path := String(s["path"])
		var when := Time.get_datetime_dict_from_unix_time(int(s["mtime"]))
		var label := "%s　·　第 %d 天　·　%02d-%02d %02d:%02d" % [
			String(s["village"]), int(s["day"]),
			int(when["month"]), int(when["day"]), int(when["hour"]), int(when["minute"])]
		if not bool(s["ok"]):
			label = "！无法识别　·　" + String(s["file"])
		var b := UIKit.row_button(label)
		b.tooltip_text = String(s["file"])
		b.pressed.connect(_on_row.bind(path))
		_rows.add_child(b)
		_row_btns[path] = b
	_mark_selected()

func _on_row(path: String) -> void:
	_selected = path
	_confirm = ""
	if _mode == Mode.SAVE:
		_name_edit.text = path.get_file()
	_set_hint("")
	_mark_selected()

func _mark_selected() -> void:
	for p in _row_btns.keys():
		var b: Button = _row_btns[p]
		b.add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if p == _selected else UIKit.T_BTN))
	_act_btn.disabled = (_mode == Mode.LOAD and _selected == "")

# ---------------------------------------------------------------------------
# 动作
# ---------------------------------------------------------------------------
func _on_act() -> void:
	if _mode == Mode.SAVE:
		_do_save()
	else:
		_do_load()

func _target_path() -> String:
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = "sovit-save"
	# 只允许一个文件名，别让 "/" 之类跑出 user://
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		nm = nm.replace(bad, "-")
	if not nm.ends_with(EXT):
		nm += EXT
	return DIR + nm

func _do_save() -> void:
	var path := _target_path()
	if FileAccess.file_exists(path) and _confirm != "save:" + path:
		_confirm = "save:" + path
		_set_hint("同名存档已存在：再点一次「保存」就会覆盖它（旧档会留一份 .bak）")
		return
	_confirm = ""
	if world == null:
		_set_hint("保存失败：世界层没准备好")
		return
	var err: int = world.save_to(path)
	if err == OK:
		_refresh()
		_selected = path
		_mark_selected()
		_set_hint("已保存：%s" % path.get_file())
	else:
		_set_hint("保存失败（错误码 %d）" % err)

func _do_load() -> void:
	if _selected == "":
		_set_hint("先在上面选一个存档")
		return
	if world == null:
		_set_hint("读取失败：世界层没准备好")
		return
	var path := _selected
	if world.load_from(path):
		_set_hint("已读取：%s" % path.get_file())
		close()
		loaded.emit(path)
	else:
		_set_hint("读取失败（文件损坏或版本不符）：%s" % path.get_file())

func _on_delete() -> void:
	if _selected == "":
		_set_hint("先在上面选一个存档")
		return
	if _confirm != "del:" + _selected:
		_confirm = "del:" + _selected
		_set_hint("确认删除「%s」？再点一次「删除」就真的删掉" % _selected.get_file())
		return
	_confirm = ""
	DirAccess.remove_absolute(_selected)
	# .bak 一起带走，否则"删了又冒出来一份"
	if FileAccess.file_exists(_selected + ".bak"):
		DirAccess.remove_absolute(_selected + ".bak")
	var gone := _selected
	_selected = ""
	_refresh()
	_set_hint("已删除：%s" % gone.get_file())

func _set_hint(t: String) -> void:
	_hint_lb.text = t
	_hint_lb.add_theme_color_override("font_color",
		UIKit.FG_DIM if t == "" else UIKit.FG_HEAD)

func _default_name() -> String:
	var v := "sovit"
	if runner != null and runner.sim != null:
		v = String(runner.sim.s.get("villageName", "sovit"))
	var t := Time.get_datetime_dict_from_system()
	return "%s-%02d%02d-%02d%02d%s" % [
		v, int(t["month"]), int(t["day"]), int(t["hour"]), int(t["minute"]), EXT]
