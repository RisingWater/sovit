extends PanelContainer

# 右侧详情面板：选中建筑 → 运营；选中居民 → 个人；选中住房 → 产权。
#
# **没选中任何东西时整个面板收起来**（用户要求）：
# 原来这里画的是"全局面板"（日期/人口/国库/库存/日志），但那些全局数字
# 顶栏已经全有了（人口/满意度/钱/建造力/科研/移民），再占一屏纯属重复。
# 其中两块各自搬到"那座楼"的检视面板里，点谁看谁：
#   - 城镇中心 → 人口（移民 / 上限 / 空房）＋公告（最近日志）
#   - 仓库     → 资源（每种货的数量 ＋ **上限就在这儿设**）
#
# 排版规则（游戏化，不再堆 key: value 文本）：
#   区块标题 = 深色窄条；数据 = 左标签右数值；比例 = 进度条；商品 = 图标 + 名称 + 数量

var runner: SimRunner
var world: Node

var _kind := ""      # "" | "building" | "resident" | "housing"
var _id := ""
## 拆除确认弹窗（懒建，只建一次）
var _confirm: PopupPanel
var _confirm_text: Label
## 当前查看的建筑的 defId，供弹窗写文案（`_id` 是 shop 实例 id，不是 defId）
var _demolish_def_id := ""
var _body: VBoxContainer
## 仓储面板里每种货的上限输入框（每次重建时重置）。见 `_cap_row()`。
var _cap_inputs: Dictionary = {}

## 拖动用工滑块期间置真。见 `_rebuild()` 里的说明。
var _dragging_slider := false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -300
	offset_top = UIKit.BAR_H + 2
	offset_bottom = -UIKit.BOT_H - 4
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 7, 6, 7, 6))

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 2)
	scroll.add_child(_body)

	if runner != null:
		runner.hour_ticked.connect(_rebuild)
	_rebuild()

func show_building(id: String) -> void:
	_kind = "building"
	_id = id
	_rebuild()

func show_resident(id: String) -> void:
	_kind = "resident"
	_id = id
	_rebuild()

func show_housing(uid: String) -> void:
	_kind = "housing"
	_id = uid
	_rebuild()

func clear() -> void:
	_kind = ""
	_id = ""
	_rebuild()

func _clear() -> void:
	for c in _body.get_children():
		c.queue_free()

# ---------------------------------------------------------------------------
# 排版小件
# ---------------------------------------------------------------------------
func _title(text: String, big: bool = false) -> void:
	var p := UIKit.panel(true)
	var l := UIKit.label(text, UIKit.FG_LABEL)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(l)
	_body.add_child(p)
	if big:
		_body.add_child(UIKit.hsep())

## 画一行「键 —— 值」。返回那个**值标签**，方便调用方（用工拖动条）原地改它。
func _kv(key: String, value: String, color: Color = UIKit.FG_DARK) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var k := UIKit.label(key, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := UIKit.label(value, color)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	_body.add_child(row)
	return v

func _bar_row(key: String, value: float, maxv: float, color: Color, suffix: String = "") -> void:
	_kv(key, "%.1f%s" % [value, suffix], color)
	var pb := ProgressBar.new()
	pb.max_value = maxf(0.001, maxv)
	pb.value = clampf(value, 0.0, maxv)
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(0, 6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.24, 0.17, 0.12, 0.35)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	pb.add_theme_stylebox_override("background", bg)
	pb.add_theme_stylebox_override("fill", fg)
	_body.add_child(pb)

func _gap(h: int = 4) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	_body.add_child(c)

func _icon_row(gid: String, right: String, color: Color = UIKit.FG_DARK) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var tr := TextureRect.new()
	tr.texture = GoodIcons.tex(gid)
	tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(tr)
	var nm = String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid
	var k := UIKit.label(nm, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	row.add_child(UIKit.label(right, color))
	_body.add_child(row)

## 按钮行。每项是 `[文案, 回调]`，可选的第三项 `true` = 禁用
## （用于"命令已排队、再点没意义"的情况，比如已经排着升级）。
func _buttons(items: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	for it in items:
		var b := UIKit.button(String(it[0]), true)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if it.size() > 2 and bool(it[2]):
			b.disabled = true
		b.pressed.connect(it[1])
		row.add_child(b)
	_body.add_child(row)

func _label(t: String, size: int = 10) -> Label:
	var l := UIKit.label(t)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _button(t: String, cb: Callable) -> Button:
	return UIKit.button(t, true)

# ---------------------------------------------------------------------------
func _rebuild() -> void:
	if _body == null or runner == null or runner.sim == null:
		return
	# 拖动中**真的**不重建。
	#
	# 原来这里只有 `_build_worker_slider` 上方的一行注释声称"拖动中不能 _rebuild()"，
	# 但代码里并没有任何东西挡住它 —— 注释不等于事实。而 `runner.hour_ticked`
	# **每个游戏小时**都会触发本函数（sim_runner.gd:51），于是拖到一半滑块就被
	# `_clear()` 销毁重建，拖动当场断掉。
	if _dragging_slider:
		return
	# 同理：仓储面板里正在填上限时也不重建，否则输入框被销毁、打字打到一半就断。
	if _cap_input_focused():
		return
	_clear()
	_cap_inputs.clear()
	match _kind:
		"building": _building_panel()
		"resident": _resident_panel()
		"housing": _housing_panel()
		_:
			# 没选中任何东西 → 面板整个收起来（见文件头注释：
			# 全局数字顶栏已经全有，不该再占一屏）。
			visible = false
			return
	visible = true

## 有没有上限输入框正在被编辑（`_rebuild()` 据此让路）。
func _cap_input_focused() -> bool:
	for c in _body.find_children("*", "LineEdit", true, false):
		if (c as LineEdit).has_focus():
			return true
	return false

## 面板该显示的上限表：优先取 pending 里的那条 `set_storage_caps`。
##
## 命令是"次日 06:00 生效"的，不这样处理的话玩家填完数字、下一个小时面板重建，
## 数字就被打回旧值 —— 看起来像"改了没生效"（和用工拖动条、人口上限同一个坑）。
## `set_storage_caps` 是**整表替换**，所以 pending 的那条就是权威值。
func _effective_caps() -> Dictionary:
	var caps: Dictionary = (runner.sim.s["government"] as Dictionary).get("storageCaps", {})
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_storage_caps":
			return (a.get("caps", {}) as Dictionary)
	return caps

## pending 里有没有排着上限修改（显示"（已排队）"用）。
func _caps_pending() -> bool:
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_storage_caps":
			return true
	return false

## 本店在 pending 队列里排着的 `set_workers`；-1 = 没排队。
##
## 为什么必须看 pending：命令是"次日 06:00 生效"的，在黎明之前
## `shop["targetWorkers"]` **不会变**。面板每小时都会 `_rebuild()`，
## 滑块初值若直接取 `targetWorkers`，用户拖完几秒就被打回原位
## —— 这就是"拖动之后会跳回去"那个 bug 的根。
##
## 与全局面板的人口上限（`_global_panel`）是同一套做法，那一格当初就修过这个问题。
## 引擎按 shopId 合并同名命令（`sim_core.gd` 的 `_dedup_key`），所以最多一条。
func _pending_workers() -> int:
	if runner == null or runner.sim == null:
		return -1
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "set_workers" and String(a.get("shopId", "")) == _id:
			return int(float(a["value"]))
	return -1

## 本店有没有排着「升级」（同样是次日生效，所以要标注出来）。
func _pending_expand() -> bool:
	if runner == null or runner.sim == null:
		return false
	for a in (runner.sim.s["pending"] as Array):
		if String(a.get("type", "")) == "expand" and String(a.get("shopId", "")) == _id:
			return true
	return false

## 用工提示文案：`实际在岗 / 目标`（排着队就缀上「已排队」）。
##
## 拖动时也走这个函数，保证"滑块拖到 12"和"文字写 6"不会同时出现。
func _worker_hint_text(assigned: int, target: int, queued: bool) -> String:
	return "%d / %d%s" % [assigned, target, "（已排队）" if queued else ""]

func _building_panel() -> void:
	var shop = null
	for s in runner.sim.s["shops"]:
		if String(s["id"]) == _id:
			shop = s
			break
	if shop == null:
		_kind = ""
		visible = false
		return
	var def_id := String(shop["defId"])
	# 两座"公共建筑"各有自己的面板，而不是通用的建筑运营面板：
	#   城镇中心 = 人口（村子的事都在这儿定：移民 / 上限 / 空房）＋公告
	#   仓库     = 资源（每种货的数量 ＋ 上限就在这里设）
	if def_id == "town_center":
		_population_panel(shop)
		return
	if def_id == "warehouse":
		_storage_panel(shop)
		return
	var def: Dictionary = runner.db.buildings[def_id]
	_demolish_def_id = def_id
	var assigned := 0
	for r in runner.sim.s["residents"]:
		if r.get("jobShopId", null) == _id:
			assigned += 1
	# 上限是**有效工位数**（含升级带来的工位），不是 maxWorkers 那个常数 ——
	# 研究所这类产能建筑升一级会 +slotsPerLevel 个工位。
	# 与引擎共用同一个口径（TS effectiveSlots / GDScript effective_slots）。
	var slots := runner.sim.effective_slots(def, int(shop["level"]))
	var active := bool(shop["active"])
	# 排着队的命令次日才生效，所以显示值要优先取 pending（见 _pending_workers 的说明）
	var pend_workers := _pending_workers()
	var queued_workers := pend_workers >= 0
	var eff_workers: int = pend_workers if queued_workers else int(shop["targetWorkers"])
	var exp_queued := _pending_expand()

	_title(String(def["nameZh"]), true)
	if exp_queued:
		_kv("等级", "Lv%d（升级已排队）" % int(shop["level"]), Color(0.72, 0.35, 0.15))
	else:
		_kv("等级", "Lv%d" % int(shop["level"]))
	_kv("状态", "生产中" if active else "已停产",
		Color(0.18, 0.45, 0.20) if active else Color(0.60, 0.20, 0.18))
	var worker_hint := _kv("用工", _worker_hint_text(assigned, eff_workers, queued_workers),
		Color(0.72, 0.35, 0.15) if queued_workers else UIKit.FG_DARK)
	var pb := ProgressBar.new()
	pb.max_value = maxf(1.0, float(slots))
	pb.value = float(assigned)
	pb.show_percentage = false
	pb.custom_minimum_size = Vector2(0, 6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.24, 0.17, 0.12, 0.35)
	var fg := StyleBoxFlat.new()
	fg.bg_color = Color(0.35, 0.55, 0.72)
	pb.add_theme_stylebox_override("background", bg)
	pb.add_theme_stylebox_override("fill", fg)
	_body.add_child(pb)
	_kv("今日计划", "%.2f 批" % float(shop["planned"]))
	_kv("利润", "¥%.1f" % float(shop["profit"]),
		Color(0.18, 0.45, 0.20) if float(shop["profit"]) >= 0.0 else Color(0.60, 0.20, 0.18))
	_gap()
	_title("用工（0 = 停产）")
	_build_worker_slider(slots, eff_workers, worker_hint, assigned)
	_gap()
	_buttons([["升级" if not exp_queued else "升级（已排队）", func(): _expand(), exp_queued],
		["移动", func(): _begin_move_shop()],
		["拆除", func(): _demolish()]])
	_gap(2)
	_body.add_child(_label("所有操作次日 06:00 生效" if not (queued_workers or exp_queued)
		else "已排队，次日 06:00 生效"))

## 用工拖动条。
##
## 为什么不用那四个 ±按钮：拖动条一眼能看出"满员是多少、现在开了多少"，
## 而且拖到 0 就是停产 —— 原来那个「停产/复工」开关就多余了，已删掉。
##
## 拖动期间 `_dragging_slider = true`，`_rebuild()` 会让路（否则滑块被销毁重建、
## 拖动断掉）；松手后再补一次重建，让面板与队列一致。
## 拖动中只更新提示文字 + 入队（引擎按 shopId 合并同名命令，连发也只留最后一条）。
func _build_worker_slider(slots: int, current: int, hint: Label, assigned: int) -> void:
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = float(maxi(1, slots))
	s.step = 1
	s.value = float(clampi(current, 0, slots))
	s.custom_minimum_size = Vector2(0, 18)
	s.tooltip_text = "开多少工位。拖到 0 = 停产；最大 = 满员 %d" % slots
	# 像素风：默认 HSlider 的圆角渐变很出戏，这里全部换成硬边纯色
	# （把手是一张 8x12 的木/金属像素贴图，与左侧圆钮同一套配色）
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.24, 0.17, 0.12, 0.55)
	track.content_margin_top = 5
	track.content_margin_bottom = 5
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.55, 0.72)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var grab := UIKit.slider_grabber()
	if grab != null:
		s.add_theme_icon_override("grabber", grab)
		s.add_theme_icon_override("grabber_highlight", grab)
	# 拖动起止：挡住 _rebuild()，松手后补一次
	s.drag_started.connect(func(): _dragging_slider = true)
	s.drag_ended.connect(func(_changed: bool):
		_dragging_slider = false
		_rebuild())
	s.value_changed.connect(func(v: float):
		var w := int(round(v))
		# 文字跟着滑块走，并且立刻标「已排队」——
		# 否则会出现"滑块 12、文字写 6"这种自相矛盾（文案由 _worker_hint_text 统一生成）
		hint.text = _worker_hint_text(assigned, w, true)
		hint.add_theme_color_override("font_color", Color(0.72, 0.35, 0.15))
		runner.enqueue([{"type": "set_workers", "shopId": _id, "value": w}]))
	_body.add_child(s)
	# 下面这行让"拖到 0"这件事一眼可见
	_body.add_child(_label("0 = 停产　·　最大 = 满员 %d 个工位" % slots))

func _demolish() -> void:
	# 二次确认**弹窗**（不是按钮文案变一下）：拆除不可撤销，得让玩家看清要拆哪一座。
	# 用项目既有的弹窗做法（PopupPanel + UIKit 框体），别自己造一套。
	# 主题：main.gd 已经设了 `get_window().theme`，popup 挂在 window 下能拿到；
	# 只设 root_ui.theme 的话 popup 是拿不到的（这个坑项目里踩过）。
	if _confirm == null:
		_confirm = PopupPanel.new()
		_confirm.add_theme_stylebox_override("panel",
			UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 10, 10, 10, 10))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 8)
		_confirm_text = UIKit.label("", UIKit.FG_DARK)
		_confirm_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_confirm_text.custom_minimum_size = Vector2(280, 0)
		vb.add_child(_confirm_text)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(UIKit.spacer())
		var no := UIKit.button("取消", true)
		no.pressed.connect(func(): _confirm.hide())
		row.add_child(no)
		var yes := UIKit.button("确定拆除", true)
		yes.pressed.connect(func():
			_confirm.hide()
			runner.enqueue([{"type": "demolish", "shopId": _id}])
			clear())   # 建筑马上就没了，面板回到全局视图
		row.add_child(yes)
		vb.add_child(row)
		_confirm.add_child(vb)
		add_child(_confirm)
	var nm := _id
	if runner.db.buildings.has(_demolish_def_id):
		nm = String(runner.db.buildings[_demolish_def_id]["nameZh"])
	_confirm_text.text = "确定拆除「%s」？\n退回建造材料，不退建造力。此操作不可撤销。" % nm
	_confirm.popup_centered(Vector2i(340, 150))

func _expand() -> void:
	# 已经排着升级就别再入队（按钮虽然会置灰，但别只靠 UI 拦）
	if _pending_expand():
		return
	runner.enqueue([{"type": "expand", "shopId": _id}])
	_rebuild()

func _begin_move_shop() -> void:
	if world != null:
		world.begin_move_shop(_id)

func _begin_move_housing() -> void:
	if world != null:
		world.begin_move_housing(_id)

func _resident_panel() -> void:
	var r = null
	for x in runner.sim.s["residents"]:
		if String(x["id"]) == _id:
			r = x
			break
	if r == null:
		_kind = ""
		visible = false
		return
	var cls := String(r["classId"])
	var hour = int(runner.sim.s["hour"])
	var activity := "在家休息"
	if hour >= 6 and hour < 18:
		activity = "在工作（或去仓库）"
	elif r.get("jobShopId", null) != null:
		activity = "下班回家"
	var work := "无业"
	if r.get("jobShopId", null) != null:
		var sid = String(r["jobShopId"])
		for s in runner.sim.s["shops"]:
			if String(s["id"]) == sid:
				work = String(runner.db.buildings[String(s["defId"])]["nameZh"])
				break

	# 头像：取该阶层精灵表的 S 向第 0 帧，放大 3 倍
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var av := TextureRect.new()
	var at := AtlasTexture.new()
	at.atlas = load("res://assets/actors/%s.png" % cls)
	at.region = Rect2(0, 0, 16, 16)
	av.texture = at
	av.custom_minimum_size = Vector2(48, 48)
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(av)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UIKit.label(Names.for_id(_id), UIKit.FG_DARK))
	col.add_child(UIKit.label("阶层 %s" % cls, UIKit.FG_HEAD))
	col.add_child(UIKit.label(activity, UIKit.FG_HEAD))
	head.add_child(col)
	_body.add_child(head)
	_body.add_child(UIKit.hsep())

	_bar_row("满意度", float(r["satisfaction"]), 100.0,
		Color(0.24, 0.55, 0.28) if float(r["satisfaction"]) >= 60.0 else Color(0.72, 0.45, 0.18), "")
	_bar_row("技能", float(r["skill"]), 100.0, Color(0.35, 0.50, 0.72))
	_kv("存款", "¥%.1f" % float(r["savings"]))
	var tenure := "国有"
	if bool(r.get("homeowner", false)):
		tenure = "自有"
	elif bool(r.get("privateTenant", false)):
		tenure = "私租"
	_kv("住宅", "%s·Lv%d" % [tenure, int(r.get("housingQuality", 0))])
	_kv("工作地点", work)
	_gap(2)
	_body.add_child(_label("编号 %s" % _id))

func _housing_panel() -> void:
	var inst = world.housing_instance(_id) if world != null else null
	if inst == null:
		_kind = ""
		visible = false
		return
	var def: Dictionary = runner.db.housing[inst["type"]]
	var occ: Array = inst["occupants"]
	_title(String(def["nameZh"]), true)
	_kv("产权", "私有" if bool(inst["private"]) else "国有",
		Color(0.55, 0.35, 0.15) if bool(inst["private"]) else UIKit.FG_DARK)
	_kv("等级", "Lv%d" % int(def["quality"]))
	_bar_row("入住", float(occ.size()), float(def["capacity"]), Color(0.35, 0.50, 0.72))
	_gap()
	_title("住户 %d/%d" % [occ.size(), int(def["capacity"])])
	if occ.is_empty():
		_body.add_child(_label("（空置）"))
	for rid in occ:
		_kv(Names.for_id(String(rid)), String(rid))
	_gap()
	_buttons([["移动", func(): _begin_move_housing()]])

func _set_population_cap(value: int) -> void:
	runner.enqueue([{"type": "set_population_cap", "value": value}])
	# 必须立刻重建：命令排到次日 06:00 才生效，不重建的话点完屏幕上
	# 一点变化都没有，看起来就像按钮没反应。
	_rebuild()

## 城镇中心面板：**人口 + 公告**。
##
## 为什么人口放在这儿：移民、人口上限、空房本来就是"村子级决策"，
## 玩家点村中心那栋楼时想看的就是它们。这几项原来和日期/国库/库存一起塞在
## "未选中"的默认面板里 —— 那个面板已按要求去掉（全局数字顶栏都有），
## 于是它们搬到这儿，判定逻辑一行没动。
func _population_panel(_shop: Dictionary) -> void:
	var s: Dictionary = runner.sim.s
	var residents: Array = s["residents"]

	_title("城镇中心 · 人口", true)
	# 仓储容量也是这座楼给的，顺手报一句（明细在仓库面板里）
	_kv("仓储容量", "%d / %d" % [
		int(round(runner.sim.stored_total())), int(round(runner.sim.storage_capacity()))])

	var arrivals = int(s["arrivals"])
	var cap = int(float(s["government"]["populationCap"]))
	# 命令是"次日 06:00 生效"的，所以点完按钮后状态里还是旧值 ——
	# 面板必须先看 pending 队列，否则点"不限"屏幕上一点变化都没有，像没反应。
	var pending_cap := -1
	for a in (s["pending"] as Array):
		if String(a.get("type", "")) == "set_population_cap":
			pending_cap = int(float(a["value"]))
	var eff_cap: int = pending_cap if pending_cap >= 0 else cap
	var cap_txt = "不限" if eff_cap >= 100000000 else str(eff_cap)
	_kv("本回合想来", "%d 人" % arrivals, Color(0.55, 0.35, 0.15) if arrivals > 0 else UIKit.FG_DARK)
	_kv("人口上限" + ("（已排队）" if pending_cap >= 0 else ""), cap_txt,
		Color(0.72, 0.35, 0.15) if pending_cap >= 0 else UIKit.FG_DARK)
	var popn = residents.size()
	var hcap = 0
	for gid in (s["housing"] as Dictionary).keys():
		if runner.db.housing.has(gid):
			hcap += int(runner.db.housing[gid]["capacity"]) * int(floor(float(s["housing"][gid])))
	_kv("当前人口", "%d" % popn)
	_kv("空房", "%d" % maxi(0, hcap - popn))
	# 这才是会真正发生的事：想来 ∩ 空房 ∩ (上限 − 人口)。
	# **不看岗位数** —— 岗位可以后补（见 docs/spec.md §8）。
	var cap_room: int = (eff_cap - popn) if eff_cap < 100000000 else arrivals
	var will_come: int = mini(arrivals, mini(cap_room, maxi(0, hcap - popn)))
	_kv("次日会来", "%d 人" % will_come,
		Color(0.18, 0.45, 0.20) if will_come > 0 else UIKit.FG_DARK)
	_buttons([["不限", func(): _set_population_cap(1000000000)],
		["停", func(): _set_population_cap(popn)],
		["+10", func(): _set_population_cap((popn + 10))]])
	_gap(2)
	if will_come <= 0 and arrivals > 0:
		var why = "空房不足" if (hcap - popn) <= 0 else ("已到人口上限" if eff_cap < 100000000 else "名额不足")
		_body.add_child(_label("想来 %d 人，但%s，一个也进不来。" % [arrivals, why]))
	elif pending_cap >= 0:
		_body.add_child(_label("已排队，次日 06:00 生效。"))
	else:
		_body.add_child(_label("次日 06:00 生效。没人来通常是空房不足或已到人口上限。"))

	_gap()
	# 公告 = 最近日志。原来挂在"全局面板"里，那个面板去掉之后得有个新家，
	# 村中心是它最自然的位置（村子这一级的事都记在这儿）。
	_title("公告")
	var logs: Array = runner.recent_logs
	if logs.is_empty():
		_body.add_child(_label("（暂无）"))
	var start = maxi(0, logs.size() - 8)
	for i in range(start, logs.size()):
		var e: Dictionary = logs[i]
		_body.add_child(_label("[D%d] %s" % [int(e.get("day", 0)), String(e.get("text", ""))]))


## 仓库面板：**等级 / 用工 / 本座容量 + 全村仓储余量 + 每种资源（数量 / 上限）**。
##
## 上限就在这里设（用户要求："数量和上限都在这里设置"）—— 原来它在 ESC 菜单的
## 「设置资源…」里，和"顶栏显示哪些资源"混在一起，两件事都不清楚。
##
## ⚠️ 仓库**要有在岗工人才算容量**（docs/town.md §3.2），所以这里明确写出来，
## 否则玩家会奇怪"我建了仓库，容量怎么没涨"。
func _storage_panel(shop: Dictionary) -> void:
	_demolish_def_id = "warehouse"
	var sim = runner.sim
	var s: Dictionary = sim.s
	var def: Dictionary = runner.db.buildings["warehouse"]
	var level := int(shop["level"])
	var st: Dictionary = def.get("storage", {})
	var own: float = float(st.get("storage", 0.0)) + float(st.get("storagePerLevel", 0.0)) * float(level - 1)
	var assigned := sim._assigned_workers(_id)
	var target := int(shop["targetWorkers"])
	var exp_queued := _pending_expand()

	_title("仓库 · 仓储", true)
	_kv("等级", "Lv%d（升级已排队）" % level if exp_queued else "Lv%d" % level,
		Color(0.72, 0.35, 0.15) if exp_queued else UIKit.FG_DARK)
	_kv("用工", "%d / %d" % [assigned, target],
		Color(0.72, 0.35, 0.15) if assigned < 1 else UIKit.FG_DARK)
	_kv("本座容量", "%d" % int(round(own)),
		UIKit.FG_DARK if assigned >= 1 else Color(0.60, 0.20, 0.18))
	if assigned < 1:
		_body.add_child(_label("没有工人在岗 → 这座仓库的容量不计入（docs/town.md §3.2）。"))
	_gap()
	_buttons([["升级" if not exp_queued else "升级（已排队）", func(): _expand(), exp_queued],
		["移动", func(): _begin_move_shop()],
		["拆除", func(): _demolish()]])

	# 全村余量：所有仓储建筑加起来的容量（城镇中心 1000 + 每座在岗仓库）
	_gap()
	var pending_caps := _caps_pending()
	_title("全村仓储" + ("（已排队）" if pending_caps else ""))
	var used := sim.stored_total()
	var total := sim.storage_capacity()
	_bar_row("已用", used, maxf(1.0, total),
		Color(0.72, 0.45, 0.18) if used >= total * 0.9 else Color(0.24, 0.55, 0.28),
		" / %d" % int(round(total)))
	if used >= total:
		_body.add_child(_label("已经满了：当晚超出上限的部分会被丢掉。"))
	_gap()

	# 资源列表：数量 ＋ 上限输入框。顺序用 pack 里商品的**固定顺序**，
	# 不按数量排 —— 数量每小时都在变，按它排行会跳来跳去，数字根本没法填。
	_title("资源（数量 / 上限）")
	var caps: Dictionary = _effective_caps()
	var goods: Dictionary = s["goods"]
	for gid in (runner.db.packs[String(s["pack"])]["goods"] as Array):
		_cap_row(String(gid), int(caps.get(String(gid), 0)), float(goods.get(String(gid), 0.0)))
	_gap(2)
	_body.add_child(_label("上限留空 = 不限。超过上限的部分当天夜里按价值从低到高丢掉，"
		+ "价值并列时按商品 id 排（docs/spec.md §2.4）。"))


## 一行「资源：图标 + 名称 + 数量 + 上限输入框」。
func _cap_row(gid: String, cap: int, amount: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var ic: Texture2D = GoodIcons.tex(gid)
	if ic != null:
		var tr := TextureRect.new()
		tr.texture = ic
		tr.custom_minimum_size = Vector2(18, 18)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(tr)
	var nm := UIKit.label(String(runner.db.goods[gid]["nameZh"]))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.clip_text = true
	row.add_child(nm)
	# 超了上限就标红 —— 玩家一眼看出"这批货今晚会被丢"
	var over := cap > 0 and amount > float(cap)
	var amt := UIKit.label("%.0f" % amount, Color(0.72, 0.25, 0.15) if over else UIKit.FG_DARK)
	amt.custom_minimum_size = Vector2(44, 0)
	amt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(amt)
	var le := UIKit.input("不限", 6)
	le.custom_minimum_size = Vector2(56, 0)
	le.text = "" if cap <= 0 else str(cap)
	le.tooltip_text = "「%s」最多存多少（留空 = 不限）" % String(runner.db.goods[gid]["nameZh"])
	le.text_changed.connect(_on_cap_text.bind(gid))
	row.add_child(le)
	_body.add_child(row)
	_cap_inputs[gid] = le

## 上限输入框改了 → 把**整张表**作为一条命令送进队列（次日 06:00 生效）。
## 输入框只收数字，留空 = 不限。
##
## ⚠️ 过滤完**必须接着推一次**：Godot 4.7 里 `LineEdit.text = x` 不会发
## `text_changed`（实测），所以"抹掉非数字"这一步不会自己再触发一次本函数。
func _on_cap_text(text: String, gid: String) -> void:
	var le: LineEdit = _cap_inputs.get(gid, null)
	if le == null:
		return
	var digits := ""
	for ch in text:
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits != text:
		le.text = digits
	var caps := {}
	for g in _cap_inputs.keys():
		var v := int((_cap_inputs[g] as LineEdit).text)
		if v > 0:
			caps[g] = v
	runner.enqueue([{"type": "set_storage_caps", "caps": caps}])
