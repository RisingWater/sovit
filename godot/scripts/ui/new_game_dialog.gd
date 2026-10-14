extends Control

# 新游戏对话框：村名 + 难度（影响初始资源倍率）。
#
# 村名上限 6 字 —— 不是随便定的：小地图红巾宽 160px，村名用 24px 像素字，
# 6 个汉字正好 144px，再长就顶出红巾了（RIB 那块的 NAME_MAX 是同一个数）。
#
# 难度只缩放**开局库存与国库**，不参与任何后续公式，
# 所以 1.0 倍时结果与从前逐位相同（golden 不受影响）。

const NAME_MAX := UIKit.NAME_MAX
const DIFFICULTIES := [
	["简单（资源 x2）", 2.0],
	["普通（资源 x1）", 1.0],
	["困难（资源 x0.5）", 0.5],
]

var runner: SimRunner
var world: Node

var _name_edit: LineEdit
var _diff_btns: Array = []
var _diff_idx := 1
var _panel: PanelContainer
var _custom := 1.0          # 由外部（标题页）指定的倍率；-1 表示用难度按钮

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 16, 14, 16, 14))
	_panel.custom_minimum_size = Vector2(320, 0)
	add_child(_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	var title := UIKit.label("开始新游戏", UIKit.FG_HEAD)
	title.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	vb.add_child(UIKit.hsep())

	vb.add_child(UIKit.label("村庄名称（最多 %d 字）" % NAME_MAX, UIKit.FG_HEAD))
	_name_edit = UIKit.input("sovit", NAME_MAX)
	_name_edit.text = "sovit"
	_name_edit.custom_minimum_size = Vector2(280, 0)
	vb.add_child(_name_edit)

	# 难度：**三个并排的像素按钮**，不用 OptionButton。
	# OptionButton 的箭头是主题 icon（默认素材），弹出来的 PopupMenu 又是另一套
	# Godot 默认皮肤 —— 那就是用户说的"一半游戏风、一半默认风"。
	# 三档并排既躲开了这两样，也比下拉框少一次点击。
	vb.add_child(UIKit.label("难度（初始资源倍率）", UIKit.FG_HEAD))
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 4)
	vb.add_child(drow)
	for i in DIFFICULTIES.size():
		var b := UIKit.button(String(DIFFICULTIES[i][0]), true)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_pick_diff.bind(i))
		drow.add_child(b)
		_diff_btns.append(b)
	_mark_diff()

	vb.add_child(UIKit.hsep())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(UIKit.spacer())
	var cancel := UIKit.button("取消", true)
	cancel.pressed.connect(close)
	row.add_child(cancel)
	var ok := UIKit.button("开始", true)
	ok.pressed.connect(_start)
	row.add_child(ok)
	vb.add_child(row)

func open() -> void:
	visible = true
	if world != null:
		world.set_process_unhandled_input(false)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	move_to_front()
	_name_edit.grab_focus()
	_name_edit.select_all()

func close() -> void:
	visible = false
	if world != null:
		world.set_process_unhandled_input(true)

## 三档难度按钮的选中态：选中的那格换成"按下"底纹。
func _pick_diff(i: int) -> void:
	_diff_idx = i
	_custom = -1.0        # 玩家手动选了难度 → 不再用外部指定的倍率
	_mark_diff()

func _mark_diff() -> void:
	for i in _diff_btns.size():
		(_diff_btns[i] as Button).add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if i == _diff_idx else UIKit.T_BTN))

## 当前选中的资源倍率
func resource_mult() -> float:
	if _custom > 0.0:
		return _custom
	return float(DIFFICULTIES[_diff_idx][1])

## 外部（标题页）可以直接指定倍率，绕开下拉框
func set_resource_mult(v: float) -> void:
	_custom = v

func _start() -> void:
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = "sovit"
	if nm.length() > NAME_MAX:
		nm = nm.substr(0, NAME_MAX)
	if world == null or runner == null:
		close()
		return
	# 随机种子，但地图与开局内容都由它决定
	var seed_value := int(Time.get_unix_time_from_system()) % 2147483647
	world.start_new_game(seed_value, resource_mult(), nm)
	close()
