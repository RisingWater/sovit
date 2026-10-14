extends PanelContainer

# 右侧详情面板：选中建筑 → 运营；选中居民 → 个人；选中住房 → 产权；未选 → 全局。
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
	_clear()
	match _kind:
		"building": _building_panel()
		"resident": _resident_panel()
		"housing": _housing_panel()
		_: _global_panel()

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
		_global_panel()
		return
	var def: Dictionary = runner.db.buildings[String(shop["defId"])]
	_demolish_def_id = String(shop["defId"])
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
		_global_panel()
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
		_global_panel()
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

func _global_panel() -> void:
	var s: Dictionary = runner.sim.s
	var residents: Array = s["residents"]
	var employed := 0
	var sat := 0.0
	for r in residents:
		if bool(r["employed"]):
			employed += 1
		sat += float(r["satisfaction"])
	sat = sat / float(residents.size()) if not residents.is_empty() else 0.0

	_title("全局", true)
	_kv("日期", "第 %d 天 %02d:00" % [int(s["day"]), int(s["hour"])])
	_kv("人口", "%d 人" % residents.size())
	_kv("就业", "%d 人" % employed)
	_bar_row("平均满意", sat, 100.0,
		Color(0.24, 0.55, 0.28) if sat >= 60.0 else Color(0.72, 0.45, 0.18))
	_kv("国库", "¥%.0f" % float(s["government"]["money"]),
		Color(0.18, 0.45, 0.20) if float(s["government"]["money"]) >= 0.0 else Color(0.60, 0.20, 0.18))

	_gap()
	_title("人口")
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
	_title("库存（含已预留）")
	var goods: Dictionary = s["goods"]
	var keys := goods.keys()
	keys.sort_custom(func(a, b): return float(goods[a]) > float(goods[b]))
	var shown := 0
	for gid in keys:
		if float(goods[gid]) < 0.01:
			continue
		var reserved = float((s.get("reserved", {}) as Dictionary).get(gid, 0.0))
		var txt = "%.1f" % float(goods[gid])
		if reserved > 0.01:
			txt += "  (锁 %.0f)" % reserved
		_icon_row(String(gid), txt)
		shown += 1
		if shown >= 14:
			break

	_gap()
	_title("最近日志")
	var logs: Array = runner.recent_logs
	var start = maxi(0, logs.size() - 10)
	for i in range(start, logs.size()):
		var e: Dictionary = logs[i]
		_body.add_child(_label("[D%d] %s" % [int(e.get("day", 0)), String(e.get("text", ""))]))
