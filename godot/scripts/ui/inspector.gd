extends PanelContainer

# 右侧详情面板：选中建筑 → 运营；选中居民 → 个人；选中住房 → 产权；未选 → 全局。
#
# 排版规则（游戏化，不再堆 key: value 文本）：
#   区块标题 = 深色窄条；数据 = 左标签右数值；比例 = 进度条；商品 = 图标 + 名称 + 数量

var runner: SimRunner
var world: Node

var _kind := ""      # "" | "building" | "resident" | "housing"
var _id := ""
var _body: VBoxContainer

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

func _kv(key: String, value: String, color: Color = UIKit.FG_DARK) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var k := UIKit.label(key, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	var v := UIKit.label(value, color)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(v)
	_body.add_child(row)

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
	tr.texture = load("res://assets/goods/%s.png" % gid)
	tr.custom_minimum_size = Vector2(16, 16)
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(tr)
	var nm = String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid
	var k := UIKit.label(nm, UIKit.FG_HEAD)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(k)
	row.add_child(UIKit.label(right, color))
	_body.add_child(row)

func _buttons(items: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	for it in items:
		var b := UIKit.button(String(it[0]), true)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	_clear()
	match _kind:
		"building": _building_panel()
		"resident": _resident_panel()
		"housing": _housing_panel()
		_: _global_panel()

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
	var assigned := 0
	for r in runner.sim.s["residents"]:
		if r.get("jobShopId", null) == _id:
			assigned += 1
	var maxw = int(def["maxWorkers"])
	var active := bool(shop["active"])

	_title(String(def["nameZh"]), true)
	_kv("等级", "Lv%d" % int(shop["level"]))
	_kv("状态", "生产中" if active else "已停产",
		Color(0.18, 0.45, 0.20) if active else Color(0.60, 0.20, 0.18))
	_kv("用工", "%d / %d" % [assigned, int(shop["targetWorkers"])])
	var pb := ProgressBar.new()
	pb.max_value = maxf(1.0, float(maxw))
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
	_title("调整用工")
	_buttons([["-10", func(): _set_workers(int(shop["targetWorkers"]) - 10, maxw)],
		["-1", func(): _set_workers(int(shop["targetWorkers"]) - 1, maxw)],
		["+1", func(): _set_workers(int(shop["targetWorkers"]) + 1, maxw)],
		["+10", func(): _set_workers(int(shop["targetWorkers"]) + 10, maxw)]])
	_gap()
	_buttons([["停产" if active else "复工", func(): _toggle(not active)],
		["升级", func(): _expand()],
		["移动", func(): _begin_move_shop()]])
	_gap(2)
	_body.add_child(_label("所有操作次日 06:00 生效"))

func _set_workers(value: int, maxw: int) -> void:
	var v = clampi(value, 0, maxw)
	runner.enqueue([{"type": "set_workers", "shopId": _id, "value": v}])
	_rebuild()   # 同上：命令次日生效，不重建就看不到变化

func _toggle(active: bool) -> void:
	runner.enqueue([{"type": "toggle", "shopId": _id, "active": active}])
	_rebuild()

func _expand() -> void:
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

func _set_immigration(value: int) -> void:
	runner.enqueue([{"type": "set_immigration", "value": value}])
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
	_title("移民")
	var arrivals = int(s["arrivals"])
	var allow = int(float(s["government"]["immigrationAllowance"]))
	# 命令是"次日 06:00 生效"的，所以点完按钮后状态里还是旧值 ——
	# 面板必须先看 pending 队列，否则点"全收"屏幕上一点变化都没有，像没反应。
	var pending_allow := -1
	for a in (s["pending"] as Array):
		if String(a.get("type", "")) == "set_immigration":
			pending_allow = int(float(a["value"]))
	var eff_allow: int = pending_allow if pending_allow >= 0 else allow
	var allow_txt = "不限" if eff_allow >= 100000000 else str(eff_allow)
	_kv("本回合想来", "%d 人" % arrivals, Color(0.55, 0.35, 0.15) if arrivals > 0 else UIKit.FG_DARK)
	_kv("当前允许" + ("（已排队）" if pending_allow >= 0 else ""), allow_txt,
		Color(0.72, 0.35, 0.15) if pending_allow >= 0 else UIKit.FG_DARK)
	var popn = residents.size()
	var hcap = 0
	for gid in (s["housing"] as Dictionary).keys():
		if runner.db.housing.has(gid):
			hcap += int(runner.db.housing[gid]["capacity"]) * int(floor(float(s["housing"][gid])))
	var jcap = 0
	for sh in s["shops"]:
		if bool(sh["active"]):
			var defx = runner.db.buildings.get(String(sh["defId"]), null)
			if defx != null:
				jcap += int(minf(float(sh["targetWorkers"]), float(defx["maxWorkers"])))
	var room := maxi(0, mini(hcap - popn, jcap - popn))
	_kv("空房", "%d" % maxi(0, hcap - popn))
	_kv("空岗", "%d" % maxi(0, jcap - popn))
	# 这才是会真正发生的事：想来 ∩ 允许 ∩ 空房空岗
	var will_come: int = mini(arrivals, mini(eff_allow if eff_allow < 100000000 else arrivals, room))
	_kv("次日会来", "%d 人" % will_come,
		Color(0.18, 0.45, 0.20) if will_come > 0 else UIKit.FG_DARK)
	_buttons([["全收", func(): _set_immigration(1000000000)],
		["暂停", func(): _set_immigration(0)],
		["+10", func(): _set_immigration((allow if allow < 100000000 else 0) + 10)]])
	_gap(2)
	if will_come <= 0 and arrivals > 0:
		_body.add_child(_label("想来 %d 人，但空房或空岗不足，一个也进不来。" % arrivals))
	elif pending_allow >= 0:
		_body.add_child(_label("已排队，次日 06:00 生效。"))
	else:
		_body.add_child(_label("次日 06:00 生效。没人来通常是空房或空岗不足。"))

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
