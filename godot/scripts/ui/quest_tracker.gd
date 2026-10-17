class_name QuestTracker
extends PanelContainer

# 任务追踪条（WoW 风格）：**顶栏下面的右侧**，只显示"当前任务"。
#
# 契约见 docs/quests.md。三件事必须守住：
#   1. **渐进显示**：没解锁的任务（`requires` 没全完成）引擎根本不会通过
#      `SimCore.quest_view()` 给出来 —— 玩家看不到后面还有什么
#   2. **判定与发钱都在黎明**由仿真完成，不需要玩家"提交"：这里只负责画
#   3. 进度数字与文案都由**引擎**拼（`goal.text`），UI 一个字都不自己拼 ——
#      TS 与 GDScript 必须显示成同一个样子
#
# 完成态：今天刚完成的还留在条上（标题变绿 + 「已完成」），隔天自动收掉。
# 达成但还没到黎明的，标一句「已达成 · 次日 06:00 结算」，免得玩家以为钱飞了。

const W := 252.0          # 面板宽（固定：让它别随文字抖）
const TOP_GAP := 6.0      # 离顶栏的间距
const MAX_SHOWN := 5      # 最多画几条：多了会顶到屏幕外（剩下的用一行「还有 N 条」交代）
const C_OK := Color(0.19, 0.45, 0.16)     # 达标/完成（奶油底上的深绿）

var runner: SimRunner

var _body: VBoxContainer
var _sig := ""            # 上一次画的内容签名：没变就不重建（每小时都会 tick 一次）

func setup(r: SimRunner) -> void:
	runner = r

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_top = UIKit.BAR_H + TOP_GAP
	offset_left = -(W + 10.0)
	offset_right = -10.0
	offset_bottom = offset_top
	custom_minimum_size = Vector2(W, 0)
	# 不吃鼠标：地图上的点击必须照常穿过去（这条只是"看"的）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 8, 6, 8, 6))
	# ⚠️ 必须套一层 VBox：`PanelContainer` 会把**每一个**子节点都拉到自己的内容区里
	# （两个直接子节点会叠在一起）。标题行与任务块要上下排，所以先放进 VBox 再交给面板。
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.add_child(_build_header())
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 3)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_body)
	resized.connect(_fit)
	if runner != null:
		runner.hour_ticked.connect(_refresh)
	_refresh()

## 标题行：图标 + 「任务」。图标是 workbuddy 那套面板图标里的（剪贴板 + 星）。
##
## 为什么要有它：这条以前直接从第一条任务开始画，玩家看不出"这一块是任务列表"。
## 用 **16px**（源图 32 的一半，整数倍、不糊）：32 会把这个窄条顶得很高。
func _build_header() -> Control:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ico := UIKit.panel_icon("quest_panel")
	if ico != null:
		var tr := TextureRect.new()
		tr.texture = ico
		tr.custom_minimum_size = Vector2(UIKit.PANEL_ICON_BTN, UIKit.PANEL_ICON_BTN)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_child(tr)
	head.add_child(UIKit.label("任务", UIKit.FG_HEAD))
	return head

## 面板高度跟着内容走（锚在右上角，所以要自己把 offset_bottom 钉到 min size 上）。
## `resized` 会回调这里：换行后的高度要等宽度定下来才算得准，所以让它迭代几次收敛。
func _fit() -> void:
	var want := UIKit.BAR_H + TOP_GAP + maxf(1.0, get_combined_minimum_size().y)
	if absf(want - offset_bottom) > 0.5:
		offset_bottom = want

func _refresh() -> void:
	if runner == null or runner.sim == null:
		return
	var view: Array = runner.sim.quest_view()
	# 内容签名：只有"该显示的东西"变了才重建节点（每小时 tick 都重建会闪）
	var parts := PackedStringArray()
	for q in view:
		parts.append("%s|%s|%s" % [String(q["id"]), str(bool(q["done"])), str(bool(q["met"]))])
		for g in (q["goals"] as Array):
			parts.append(String(g["text"]))
	var sig := " / ".join(parts)
	if sig == _sig:
		return
	_sig = sig

	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	if view.is_empty():
		_body.add_child(UIKit.label("（暂无任务）", UIKit.FG_DIM))
	else:
		var shown := mini(view.size(), MAX_SHOWN)
		for i in shown:
			_body.add_child(_quest_block(view[i]))
		if view.size() > shown:
			_body.add_child(UIKit.label("…还有 %d 条（做完会自己顶上来）" % (view.size() - shown),
				UIKit.FG_DIM))
	_fit.call_deferred()

func _quest_block(q: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 标题：完成变绿 + 「已完成」；支线加个「支线」标记
	var title := String(q["title"])
	if bool(q["done"]):
		title += "（已完成）"
	if bool(q.get("side", false)):
		title = "支线 · " + title
	var head := UIKit.label(title, C_OK if bool(q["done"]) else UIKit.FG_HEAD)
	head.clip_text = true
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(head)

	# 怎么做（引擎给的 hint）：两行以内，长了就让它换行
	var hint := UIKit.label(String(q["hint"]), UIKit.FG_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(W - 18.0, 0)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(hint)

	# 目标行：达标变绿（数字是引擎拼的）
	for g in (q["goals"] as Array):
		var met := bool(g["met"])
		var row := UIKit.label("· " + String(g["text"]), C_OK if met else UIKit.FG_DARK)
		row.clip_text = true
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(row)

	if bool(q["met"]) and not bool(q["done"]):
		var pend := UIKit.label("已达成 · 次日 06:00 结算", UIKit.FG_DIM)
		pend.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(pend)

	return box
