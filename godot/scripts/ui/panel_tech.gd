extends PanelContainer

# ---------------------------------------------------------------------------
# 科技面板（见 docs/technology.md）
#
# 只做三件事：
#   1. 显示科研力产能构成（基础 + 研究所），让"该扩建研究所了"一眼可见
#   2. 显示研究队列与进度
#   3. 按纪元列出全部科技，给出「研究 / 取消 / 已完成 / 前置不足」四种状态
#
# 取数全部来自仿真层：科技表来自 ContentDB，状态来自 sim.s["research"]。
# 面板不判断"够不够钱/材料"以外的任何规则 —— 能不能研究由引擎决定，
# 这里只负责把引擎的判断显示出来（所以不会与仿真分叉）。
# ---------------------------------------------------------------------------

var runner: SimRunner
var world: Node

const PANEL_W := 880.0
const PANEL_H := 640.0
const CFG_PATH := "user://hud.cfg"
const KEEP_VISIBLE := 80.0

var _body: VBoxContainer
var _dragging := false
var _drag_off := Vector2.ZERO
var _last_day := -1

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 9, 8, 9, 8))

	var vp := get_viewport_rect().size
	var saved := _load_pos()
	position = ((vp - Vector2(PANEL_W, PANEL_H)) * 0.5).round() if saved == Vector2.INF else _clamp_pos(saved)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 5)
	add_child(root)

	# 标题行 + 拖动把手
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	root.add_child(head)
	head.add_child(UIKit.label("科技", UIKit.FG_HEAD))
	var dragbar := Control.new()
	dragbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dragbar.mouse_filter = Control.MOUSE_FILTER_STOP
	dragbar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	dragbar.tooltip_text = "按住拖动面板"
	var hint := UIKit.label("拖动此处移动面板", Color(0.66, 0.52, 0.36))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dragbar.add_child(hint)
	dragbar.gui_input.connect(_on_drag_input)
	head.add_child(dragbar)
	var close := UIKit.button("关闭", true)
	close.pressed.connect(func(): visible = false)
	head.add_child(close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 3)
	scroll.add_child(_body)

	visible = false
	_refresh()

## 面板范围内的鼠标事件一律吃掉（否则滚列表会把外面的地图也缩放了）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()

func _process(_dt: float) -> void:
	if not visible or runner == null or runner.sim == null:
		return
	# 只在**跨天**时重建：每帧重建会把按钮销毁重造，按钮就永远点不动。
	var d := int(runner.sim.s["day"])
	if d != _last_day:
		_last_day = d
		_refresh()

func open() -> void:
	visible = true
	_last_day = int(runner.sim.s["day"]) if runner != null and runner.sim != null else -1
	_refresh()

# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------
func _refresh() -> void:
	if _body == null:
		return
	for c in _body.get_children():
		c.queue_free()
	if runner == null or runner.sim == null:
		return
	var s: Dictionary = runner.sim.s
	var db: ContentDB = runner.db

	_rate_header(s, db)
	_queue_block(s, db)
	_body.add_child(UIKit.hsep())

	# 按纪元分组；eras 来自 content/technologies.json，顺序即展示顺序
	var by_era := {}
	for tid in db.tech_ids:
		var e := int(db.techs[tid]["era"])
		if not by_era.has(e):
			by_era[e] = []
		by_era[e].append(tid)
	var era_ids := by_era.keys()
	era_ids.sort()
	for e in era_ids:
		var era_name := "纪元 %d" % e
		for er in db.eras:
			if int(er["id"]) == e:
				era_name = "纪元 %d · %s" % [e, String(er["nameZh"])]
		_body.add_child(UIKit.label(era_name, UIKit.FG_HEAD))
		_body.add_child(UIKit.hsep())
		for tid in by_era[e]:
			_tech_row(s, db, String(tid))

func _rate_header(s: Dictionary, db: ContentDB) -> void:
	var rate := 0.0
	var n_inst := 0
	for shop in s["shops"]:
		var def = db.buildings.get(String(shop["defId"]), null)
		if def != null and def.has("capacity") and String(def["capacity"]["kind"]) == "research":
			n_inst += 1
	var sim = runner.sim
	var total := float(sim._research_rate())
	var base := float(db.economy["research"]["baseRate"])
	_body.add_child(UIKit.label(
		"科研力 %s/天　（基础 %s + 研究所 ×%d 提供 %s）" % [
			_fmt(total), _fmt(base), n_inst, _fmt(total - base)],
		UIKit.FG_DARK))
	var tool_rate := 0.0
	for shop in s["shops"]:
		if float(shop.get("toolBoost", 1.0)) > 1.0:
			tool_rate += 1.0
	if tool_rate > 0.0:
		_body.add_child(UIKit.label(
			"已装配工具的工坊：%d 座（产出 ×%s）" % [int(tool_rate), _fmt(1.0 + db.tool_bonus("stone_tools"))],
			Color(0.18, 0.45, 0.20)))

func _queue_block(s: Dictionary, db: ContentDB) -> void:
	var q: Array = s["research"]["queue"]
	if q.is_empty():
		_body.add_child(UIKit.label("研究队列：空闲", UIKit.FG_DIM))
		return
	var rate := float(runner.sim._research_rate())
	var head: Dictionary = q[0]
	var tech = db.techs.get(String(head["id"]), null)
	var name := String(tech["nameZh"]) if tech != null else String(head["id"])
	var left := float(head["remaining"])
	var days := (left / rate) if rate > 0.0 else INF
	_body.add_child(UIKit.label(
		"研究中：%s　%s/%s%s%s" % [
			name, _fmt(float(head["totalRequired"]) - left), _fmt(float(head["totalRequired"])),
			("　（%s，还需约 %d 天）" % ["已开工" if bool(head["started"]) else "等待开工", int(ceil(days))]) if days < 999.0 else "　（无科研力）"],
		Color(0.72, 0.35, 0.15)))
	if q.size() > 1:
		var rest := []
		for i in range(1, q.size()):
			var t2 = db.techs.get(String(q[i]["id"]), null)
			rest.append(String(t2["nameZh"]) if t2 != null else String(q[i]["id"]))
		_body.add_child(UIKit.label("排队中：" + "、".join(rest), UIKit.FG_DIM))

func _tech_row(s: Dictionary, db: ContentDB, tid: String) -> void:
	var tech: Dictionary = db.techs[tid]
	var done: bool = (s["research"]["done"] as Array).has(tid)
	var queued := false
	var queued_item := {}
	for p in s["research"]["queue"]:
		if String(p["id"]) == tid:
			queued = true
			queued_item = p
	# 前置
	var missing := []
	for r in tech["requires"]:
		if not (s["research"]["done"] as Array).has(String(r)):
			var rt = db.techs.get(String(r), null)
			missing.append(String(rt["nameZh"]) if rt != null else String(r))
	# 材料
	var cost_parts := []
	var afford := true
	for gid in (tech["cost"]["goods"] as Dictionary).keys():
		var need := float(tech["cost"]["goods"][gid])
		var have := float(s["goods"].get(gid, 0.0))
		if have < need:
			afford = false
		var gname := String(gid)
		if db.goods.has(String(gid)):
			gname = String(db.goods[String(gid)]["nameZh"])
		cost_parts.append("%s %s/%s" % [gname, _fmt(have), _fmt(need)])

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var name_lbl := UIKit.label(String(tech["nameZh"]), UIKit.FG_DARK)
	name_lbl.custom_minimum_size = Vector2(96, 0)
	row.add_child(name_lbl)
	var req_lbl := UIKit.label("科研力 %s" % _fmt(float(tech["research"])), UIKit.FG_DIM)
	req_lbl.custom_minimum_size = Vector2(78, 0)
	row.add_child(req_lbl)
	# 解锁的产品图标：一眼看出这项科技值不值得研究
	# （建筑用它的建造栏缩略图；住房同理）
	var unlocks: Array = []
	unlocks.append_array(tech["unlocks"]["buildings"])
	unlocks.append_array(tech["unlocks"]["housing"])
	for bid in unlocks:
		var ic := TextureRect.new()
		# prop 建筑的缩略图不在版本管理里，必须走带兜底链的 UIKit.thumb
		# （直接 load 会刷一屏 "Resource file not found" 并拿到 null）
		var bdef: Dictionary = db.buildings.get(String(bid), db.housing.get(String(bid), {}))
		ic.texture = UIKit.thumb(String(bid), UIKit.is_prop(bdef))
		ic.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ic.tooltip_text = "解锁：" + (String(db.goods[bid]["nameZh"]) if db.goods.has(String(bid)) else String(bid))
		row.add_child(ic)
	var cost_lbl := UIKit.label("、".join(cost_parts) if cost_parts.size() > 0 else "无",
		UIKit.FG_DARK if afford else Color(0.70, 0.25, 0.20))
	cost_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cost_lbl)

	if done:
		row.add_child(UIKit.label("已完成", Color(0.18, 0.45, 0.20)))
	elif queued:
		var left := float(queued_item["remaining"])
		row.add_child(UIKit.label("研究中 %s" % _fmt(float(queued_item["totalRequired"]) - left),
			Color(0.72, 0.35, 0.15)))
		var cancel := UIKit.button("取消", true)
		cancel.tooltip_text = "从队列移除（已扣的材料不退）"
		cancel.pressed.connect(func(): _act({"type": "cancel_research", "techId": tid}))
		row.add_child(cancel)
	elif missing.size() > 0:
		row.add_child(UIKit.label("需先研究：%s" % "、".join(missing), UIKit.FG_DIM))
	else:
		var b := UIKit.button("研究", true)
		b.tooltip_text = "加入研究队列（材料在开工时扣）"
		if not afford:
			b.disabled = true
			b.tooltip_text = "材料不足"
		b.pressed.connect(func(): _act({"type": "research", "techId": tid}))
		row.add_child(b)

	_body.add_child(row)

func _act(action: Dictionary) -> void:
	runner.enqueue([action])
	# 命令排到次日 06:00 才生效，但"已排队"要立刻可见，否则点完像没反应
	_last_day = int(runner.sim.s["day"])
	_refresh()

func _fmt(v: float) -> String:
	if absf(v - round(v)) < 0.005:
		return "%d" % int(round(v))
	return "%.1f" % v

# ---------------------------------------------------------------------------
# 拖动：按标题栏拖，位置存 user://hud.cfg
# ---------------------------------------------------------------------------
func _on_drag_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		_drag_off = get_global_mouse_position() - position
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		position = _clamp_pos(get_global_mouse_position() - _drag_off)
		accept_event()

func _clamp_pos(p: Vector2) -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(
		clampf(p.x, -PANEL_W + KEEP_VISIBLE, vp.x - KEEP_VISIBLE),
		clampf(p.y, 0.0, vp.y - KEEP_VISIBLE))

func _load_pos() -> Vector2:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return Vector2.INF
	var v = cf.get_value("tech", "pos", null)
	return v if v is Vector2 else Vector2.INF

func _save_pos() -> void:
	var cf := ConfigFile.new()
	cf.load(CFG_PATH)
	cf.set_value("tech", "pos", position)
	cf.save(CFG_PATH)

func _exit_tree() -> void:
	if visible:
		_save_pos()
