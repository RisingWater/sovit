extends PanelContainer

# 右侧详情面板：选中建筑 → 运营按钮；选中居民 → 个人详情；未选 → 全局（库存/日志）。

var runner: SimRunner

var _kind := ""      # "" | "building" | "resident"
var _id := ""
var _body: VBoxContainer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -350
	mouse_filter = Control.MOUSE_FILTER_PASS

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.11, 0.9)
	add_theme_stylebox_override("panel", bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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

func clear() -> void:
	_kind = ""
	_id = ""
	_rebuild()

func _clear() -> void:
	for c in _body.get_children():
		c.queue_free()

func _label(t: String, size: int = 14) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	return l

func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b

func _rebuild() -> void:
	if _body == null or runner == null or runner.sim == null:
		return
	_clear()
	match _kind:
		"building": _building_panel()
		"resident": _resident_panel()
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
	_body.add_child(_label("【%s】" % def["nameZh"], 18))
	_body.add_child(_label(String(shop["id"])))
	_body.add_child(_label("等级 Lv%d" % int(shop["level"])))
	_body.add_child(_label("用工  到岗 %d / 目标 %d / 上限 %d" % [assigned, int(shop["targetWorkers"]), maxw]))
	_body.add_child(_label("今日计划批次 %.2f" % float(shop["planned"])))
	_body.add_child(_label("利润 ¥%.1f" % float(shop["profit"])))
	_body.add_child(_label("状态：%s" % ("生产中" if bool(shop["active"]) else "已停产")))

	var row := HBoxContainer.new()
	row.add_child(_button("-10", func(): _set_workers(int(shop["targetWorkers"]) - 10, maxw)))
	row.add_child(_button("-1", func(): _set_workers(int(shop["targetWorkers"]) - 1, maxw)))
	row.add_child(_button("+1", func(): _set_workers(int(shop["targetWorkers"]) + 1, maxw)))
	row.add_child(_button("+10", func(): _set_workers(int(shop["targetWorkers"]) + 10, maxw)))
	_body.add_child(row)

	var row2 := HBoxContainer.new()
	row2.add_child(_button("停产" if bool(shop["active"]) else "复工", func(): _toggle(not bool(shop["active"]))))
	row2.add_child(_button("升级", func(): _expand()))
	_body.add_child(row2)

	_body.add_child(_label("提示：所有操作次日 06:00 生效", 12))

func _set_workers(value: int, maxw: int) -> void:
	var v = clampi(value, 0, maxw)
	runner.enqueue([{"type": "set_workers", "shopId": _id, "value": v}])

func _toggle(active: bool) -> void:
	runner.enqueue([{"type": "toggle", "shopId": _id, "active": active}])

func _expand() -> void:
	runner.enqueue([{"type": "expand", "shopId": _id}])

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
	_body.add_child(_label("【%s】" % Names.for_id(_id), 18))
	_body.add_child(_label("%s  阶层：%s" % [_id, String(r["classId"])]))
	_body.add_child(_label("账户（存款）：¥%.1f" % float(r["savings"])))
	_body.add_child(_label("技能：%.1f" % float(r["skill"])))
	_body.add_child(_label("满意度：%.1f" % float(r["satisfaction"])))
	_body.add_child(_label("住宅：%s" % ("自有" if bool(r.get("homeowner", false)) else ("私租" if bool(r.get("privateTenant", false)) else "国有")) + "  等级 %d" % int(r.get("housingQuality", 0))))
	_body.add_child(_label("工作地点：%s" % work))
	_body.add_child(_label("此刻：%s" % activity))

func _global_panel() -> void:
	var s: Dictionary = runner.sim.s
	_body.add_child(_label("全局", 18))
	_body.add_child(_label("第 %d 天 %02d:00" % [int(s["day"]), int(s["hour"])]))
	_body.add_child(_label("— 库存（含已预留）—", 13))
	var goods: Dictionary = s["goods"]
	var keys := goods.keys()
	keys.sort_custom(func(a, b): return float(goods[a]) > float(goods[b]))
	var shown := 0
	for gid in keys:
		if float(goods[gid]) < 0.01:
			continue
		var name = String(runner.db.goods[gid]["nameZh"]) if runner.db.goods.has(gid) else gid
		var reserved = float((s.get("reserved", {}) as Dictionary).get(gid, 0.0))
		var extra = ("  锁定 %.1f" % reserved) if reserved > 0.01 else ""
		_body.add_child(_label("%s：%.1f%s" % [name, float(goods[gid]), extra], 13))
		shown += 1
		if shown >= 16:
			break
	_body.add_child(_label("— 最近日志 —", 13))
	var logs: Array = runner.recent_logs
	var start = maxi(0, logs.size() - 12)
	for i in range(start, logs.size()):
		var e: Dictionary = logs[i]
		_body.add_child(_label("[%d] %s" % [int(e.get("day", 0)), String(e.get("text", ""))], 12))
