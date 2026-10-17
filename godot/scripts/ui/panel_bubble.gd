class_name PanelBubble
extends PanelContainer

# 面板里那位顾问的一句话（用户 2026-10："在立绘的左边冒个气泡，说一下话，有个叉可以点掉"）。
#
# 样式和别的面板一致（米黄纸框 + 像素字），右上角一个「×」。
# 尺寸**跟着文字走**：宽度固定，高度由 autowrap 之后的文字撑开 —— 那个得等一帧才知道，
# 所以 `_fit()` 是 `await` 出来的（和 ai_panel 的设置页同一套写法）。

const W := 340.0
const PAD_L := 12
const PAD_T := 8
const PAD_R := 8
const PAD_B := 8

signal closed

var _label: Label
var _box: VBoxContainer

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), PAD_L, PAD_T, PAD_R, PAD_B))
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 2)
	add_child(_box)

	# 一行：撑开 + 「×」。X 放在右上角，和文字分开，免得误点。
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	_box.add_child(row)
	row.add_child(UIKit.spacer())
	var x := UIKit.button("×", true)
	x.tooltip_text = "知道了"
	x.custom_minimum_size = Vector2(22, UIKit.BTN_H_SM)
	x.pressed.connect(func():
		visible = false
		closed.emit())
	row.add_child(x)

	_label = UIKit.label("", UIKit.FG_DARK)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(W, 0)
	_box.add_child(_label)

	visible = false

func say(text: String) -> void:
	if _label == null or text.strip_edges() == "":
		visible = false
		return
	_label.text = text
	visible = true
	_fit()

func _fit() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	# 宽度锁死在 W + 内边距；高度按文字量
	var w := W + float(PAD_L + PAD_R)
	var h := _box.get_combined_minimum_size().y + float(PAD_T + PAD_B)
	custom_minimum_size = Vector2(w, h)
	size = Vector2(w, h)
