extends PanelContainer

# ---------------------------------------------------------------------------
# 科技树面板（见 docs/technology.md）
#
# **不是列表，是树**：
#   · x 轴 = 「最长前置链长度」（不是 era）。era 是内容标签，同一个 era 里的科技
#     深浅可能差好几层，用 era 当列号会画出横跨好几列的连线。
#     用最长链长度天然满足两条硬要求：x 严格大于所有前置的 x；
#     最左是最初始科技、最右是最高级科技。
#   · y 轴 = 同列内按 (era, 内容顺序) 依次往下堆，所以同列不重叠。
#   · 前置之间用**直角折线**连接（见 tech_lines.gd）。
#
# 画面可以**鼠标按住自由拖动**（拖的是画布，不是面板；面板本身拖标题栏）。
# 卡片只在跨天或有动作时更新状态，**不重建** —— 重建会把按钮销毁重造、点不动。
#
# 取数全部来自仿真层：科技表来自 ContentDB，状态来自 sim.s["research"]。
# 面板不自己判断"能不能研究"以外的规则 —— 只把引擎的判断显示出来，所以不会与仿真分叉。
# ---------------------------------------------------------------------------

var runner: SimRunner
var world: Node

const PANEL_W := 900.0
const PANEL_H := 740.0
const CFG_PATH := "user://hud.cfg"
const KEEP_VISIBLE := 80.0

# --- 树布局 ---------------------------------------------------------------
const CARD_W := 108
const CARD_H := 86
const COL_GAP := 104          # 列间距（连线拐弯要有地方走）
const ROW_GAP := 26
const LAYOUT_PAD := 20

# 超过这个位移就算"拖动"而不是"点击"。借鉴 world_view 的 _press_pos 判断。
const DRAG_SLOP := 6.0

# 卡片状态色
const C_DONE := Color(0.22, 0.52, 0.24)
const C_QUEUED := Color(0.86, 0.50, 0.10)
const C_PENDING := Color(0.70, 0.58, 0.14)
const C_READY := Color(0.62, 0.36, 0.16)
const C_LOCKED := Color(0.55, 0.53, 0.50)

var _top: VBoxContainer
var _view: Control
var _canvas: Control
var _lines: Control
var _cards: Dictionary = {}       # techId -> TechCard
var _pos: Dictionary = {}         # techId -> Vector2（画布坐标）
var _canvas_size := Vector2.ZERO
var _built := false

# 画布平移
var _pan := Vector2.ZERO
# 指针状态机（区分"拖动画布"和"点击卡片"）
var _ptr_down := false
var _ptr_moved := false
var _ptr_press := Vector2.ZERO
var _ptr_card: Node = null

# 面板自身拖动（标题栏）
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

	# ---------------- 标题行：烧瓶图标 + 「科技」+ 拖动把手 + 关闭
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	root.add_child(head)
	var tico := UIKit.panel_icon("research")
	if tico != null:
		var tir := TextureRect.new()
		tir.texture = tico
		tir.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		tir.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		head.add_child(tir)
	head.add_child(UIKit.label("科技", UIKit.FG_HEAD))
	var dragbar := Control.new()
	dragbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dragbar.mouse_filter = Control.MOUSE_FILTER_STOP
	dragbar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	dragbar.tooltip_text = "按住拖动面板（面板内部按住可平移科技树）"
	var hint := UIKit.label("拖动此处移动面板　·　面板内按住可平移科技树", Color(0.66, 0.52, 0.36))
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

	# ---------------- 顶部两行：科研力速率 + 研究队列
	_top = VBoxContainer.new()
	_top.add_theme_constant_override("separation", 2)
	root.add_child(_top)
	root.add_child(UIKit.hsep())

	# ---------------- 树视口
	_view = Control.new()
	_view.name = "TreeView"
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.clip_contents = true
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.tooltip_text = ""
	_view.gui_input.connect(_on_view_input)
	_view.resized.connect(_on_view_resized)
	root.add_child(_view)

	# 画布：被平移的那一层。mouse_filter=IGNORE —— 自己不收事件，
	# 但子节点（卡片）照收，空白处的事件冒泡给 _view。
	_canvas = Control.new()
	_canvas.name = "TreeCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.add_child(_canvas)

	visible = false
	# ⚠️ 这里**不**建树：29 张卡片 + 37 条连线不算便宜，而面板默认是隐藏的。
	# 建树推迟到第一次 open()（_refresh 里的 _built 判断），
	# 这样"从没打开过科技面板"的玩家和那些只实例化 main.tscn 的头less 测试都不用付这份钱。
	_refresh_top()


## 面板范围内的鼠标事件一律吃掉（否则拖画布会把外面的地图也缩放了）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()


func _process(_dt: float) -> void:
	if not visible or runner == null or runner.sim == null:
		return
	# 只在**跨天**时更新卡片状态：每帧重建会把卡片销毁重造，就永远点不动了。
	var d := int(runner.sim.s["day"])
	if d != _last_day:
		_last_day = d
		_refresh()


func open() -> void:
	visible = true
	_last_day = int(runner.sim.s["day"]) if runner != null and runner.sim != null else -1
	_pan = _clamp_pan(_pan)
	if _canvas != null:
		_canvas.position = _pan
	_refresh()


# ===========================================================================
# 布局
# ===========================================================================

## 算每项科技的画布坐标。
## x = 最长前置链长度（父节点 x + 1 的最大值），所以**严格大于所有前置的 x**。
## y = 同列内按 (era, 内容顺序) 依次往下堆。
func _compute_layout() -> Dictionary:
	var db := runner.db
	var order := {}                      # id -> 内容顺序
	for i in db.tech_ids.size():
		order[String(db.tech_ids[i])] = i

	var depth := {}
	for tid in db.tech_ids:
		depth[String(tid)] = 0
	# 反复松弛到稳定。科技图已由内容校验保证无环，所以一定会收敛；
	# guard 只是防御性的上限，避免将来内容出错时死循环。
	var changed := true
	var guard := 0
	while changed and guard < 64:
		changed = false
		guard += 1
		for tid in db.tech_ids:
			var t := String(tid)
			var d := 0
			for r in db.techs[t]["requires"]:
				d = maxi(d, int(depth.get(String(r), 0)) + 1)
			if d != int(depth[t]):
				depth[t] = d
				changed = true

	var cols := {}
	for tid in db.tech_ids:
		var t := String(tid)
		var c := int(depth[t])
		if not cols.has(c):
			cols[c] = []
		cols[c].append(t)
	for c in cols.keys():
		var arr: Array = cols[c]
		arr.sort_custom(func(a, b):
			var ea := int(db.techs[a]["era"])
			var eb := int(db.techs[b]["era"])
			if ea != eb:
				return ea < eb
			return int(order[a]) < int(order[b]))

	var pos := {}
	for c in cols.keys():
		var arr: Array = cols[c]
		for i in arr.size():
			pos[arr[i]] = Vector2(
				LAYOUT_PAD + int(c) * (CARD_W + COL_GAP),
				LAYOUT_PAD + i * (CARD_H + ROW_GAP))
	return pos


func _build_tree() -> void:
	var db := runner.db
	_pos = _compute_layout()

	var maxx := 0.0
	var maxy := 0.0
	for tid in _pos.keys():
		var p: Vector2 = _pos[tid]
		maxx = maxf(maxx, p.x + CARD_W)
		maxy = maxf(maxy, p.y + CARD_H)
	_canvas_size = Vector2(maxx + LAYOUT_PAD, maxy + LAYOUT_PAD)
	_canvas.size = _canvas_size

	# 连线层**先**加，所以永远在卡片下面
	_lines = load("res://scripts/ui/tech_lines.gd").new()
	_lines.name = "Lines"
	_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines.size = _canvas_size
	_canvas.add_child(_lines)

	for tid in db.tech_ids:
		var t := String(tid)
		var card = load("res://scripts/ui/tech_card.gd").new()
		card.name = "T_" + t
		card.setup(self, t, String(db.techs[t]["nameZh"]), UIKit.tech_icon(t))
		card.position = _pos[t]
		card.size = Vector2(CARD_W, CARD_H)
		_canvas.add_child(card)
		_cards[t] = card


# ===========================================================================
# 刷新
# ===========================================================================
func _refresh() -> void:
	if _view == null or runner == null or runner.sim == null:
		return
	if not _built:
		_build_tree()
		_built = true
	_refresh_top()
	_refresh_states()


func _refresh_top() -> void:
	for c in _top.get_children():
		c.queue_free()
	var s: Dictionary = runner.sim.s
	var db := runner.db
	var n_inst := 0
	for shop in s["shops"]:
		var def = db.buildings.get(String(shop["defId"]), null)
		if def != null and def.has("capacity") and String(def["capacity"]["kind"]) == "research":
			n_inst += 1
	var total := float(runner.sim._research_rate())
	var base := float(db.economy["research"]["baseRate"])
	_top.add_child(UIKit.label(
		"科研力 %s/天　（基础 %s + 研究所 ×%d 提供 %s）" % [
			_fmt(total), _fmt(base), n_inst, _fmt(total - base)],
		UIKit.FG_DARK))
	var boosted := 0
	for shop in s["shops"]:
		if float(shop.get("toolBoost", 1.0)) > 1.0:
			boosted += 1
	if boosted > 0:
		_top.add_child(UIKit.label(
			"已装配工具的工坊：%d 座（产出 ×%s）" % [boosted, _fmt(1.0 + db.tool_bonus("stone_tools"))],
			Color(0.18, 0.45, 0.20)))

	var q: Array = s["research"]["queue"]
	if q.is_empty():
		_top.add_child(UIKit.label("研究队列：空闲", UIKit.FG_DIM))
		return
	var rate := float(runner.sim._research_rate())
	var head: Dictionary = q[0]
	var tech = db.techs.get(String(head["id"]), null)
	var nm := String(tech["nameZh"]) if tech != null else String(head["id"])
	var left := float(head["remaining"])
	var days := (left / rate) if rate > 0.0 else INF
	# 4 个占位符对 4 个实参（多写一个会报 String formatting error，踩过）
	_top.add_child(UIKit.label(
		"研究中：%s　%s/%s%s" % [
			nm, _fmt(float(head["totalRequired"]) - left), _fmt(float(head["totalRequired"])),
			("　（%s，还需约 %d 天）" % ["已开工" if bool(head["started"]) else "等待开工", int(ceil(days))]) if days < 999.0 else "　（无科研力）"],
		C_QUEUED))
	if q.size() > 1:
		var rest := []
		for i in range(1, q.size()):
			var t2 = db.techs.get(String(q[i]["id"]), null)
			rest.append(String(t2["nameZh"]) if t2 != null else String(q[i]["id"]))
		_top.add_child(UIKit.label("排队中：" + "、".join(rest), UIKit.FG_DIM))


func _refresh_states() -> void:
	for tid in _cards.keys():
		var st := _state_of(String(tid))
		var card = _cards[tid]
		card.set_state(String(st["text"]), st["color"], bool(st["enabled"]))
	_refresh_lines()


func _refresh_lines() -> void:
	if _lines == null:
		return
	var done: Array = runner.sim.s["research"]["done"]
	var edges: Array = []
	var db := runner.db
	for tid in _pos.keys():
		var t := String(tid)
		var tp: Vector2 = _pos[t]
		for r in db.techs[t]["requires"]:
			var rt := String(r)
			if not _pos.has(rt):
				continue
			var rp: Vector2 = _pos[rt]
			edges.append({
				"a": Vector2(rp.x + CARD_W, rp.y + CARD_H * 0.5),
				"b": Vector2(tp.x, tp.y + CARD_H * 0.5),
				"done": done.has(rt),
			})
	_lines.set_edges(edges)


## 一项科技当前处于什么状态。返回 {key, text, color, enabled}
func _state_of(tid: String) -> Dictionary:
	var s: Dictionary = runner.sim.s
	if (s["research"]["done"] as Array).has(tid):
		return {"key": "done", "text": "已完成", "color": C_DONE, "enabled": true}
	for p in s["research"]["queue"]:
		if String(p["id"]) == tid:
			var tot := float(p["totalRequired"])
			var left := float(p["remaining"])
			var pct := 0.0 if tot <= 0.0 else (tot - left) / tot * 100.0
			return {"key": "queued", "text": "研究中 %.0f%%" % pct, "color": C_QUEUED, "enabled": true}
	if _pending_research(tid):
		return {"key": "pending", "text": "已排队", "color": C_PENDING, "enabled": true}
	if not _missing_requires(tid).is_empty():
		return {"key": "locked", "text": "需先研究", "color": C_LOCKED, "enabled": false}
	return {"key": "ready", "text": "可研究", "color": C_READY, "enabled": true}


## 有没有一条"次日生效"的研究指令；若同时排了撤销，就算没有。
func _pending_research(tid: String) -> bool:
	var found := false
	var canceled := false
	for a in (runner.sim.s["pending"] as Array):
		var ty := String(a.get("type", ""))
		if String(a.get("techId", "")) != tid:
			continue
		if ty == "research":
			found = true
		elif ty == "cancel_research":
			canceled = true
	return found and not canceled


func _missing_requires(tid: String) -> Array:
	var out: Array = []
	var done: Array = runner.sim.s["research"]["done"]
	for r in runner.db.techs[tid]["requires"]:
		if not done.has(String(r)):
			out.append(String(r))
	return out


# ===========================================================================
# 交互：拖动画布 / 点击卡片
# ===========================================================================
func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pointer_down(event.global_position, null)
		else:
			_pointer_up(event.global_position)
		_view.accept_event()
	elif event is InputEventMouseMotion:
		_pointer_move(event.global_position, event.relative)
		_view.accept_event()


## 卡片把事件转进来（同一条状态机，所以从卡片上开始拖也能平移画布）。
func card_input(card: Node, event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pointer_down(event.global_position, card)
		else:
			_pointer_up(event.global_position)
		card.accept_event()
	elif event is InputEventMouseMotion:
		_pointer_move(event.global_position, event.relative)
		card.accept_event()


func _pointer_down(pos: Vector2, card: Node) -> void:
	_ptr_down = true
	_ptr_moved = false
	_ptr_press = pos
	_ptr_card = card


func _pointer_move(pos: Vector2, rel: Vector2) -> void:
	if not _ptr_down:
		return
	if not _ptr_moved and pos.distance_to(_ptr_press) > DRAG_SLOP:
		_ptr_moved = true
	if _ptr_moved:
		_pan = _clamp_pan(_pan + rel)
		_canvas.position = _pan


func _pointer_up(_pos: Vector2) -> void:
	var card := _ptr_card
	var moved := _ptr_moved
	_ptr_down = false
	_ptr_card = null
	_ptr_moved = false
	if moved or card == null:
		return
	_activate(String(card.tech_id))


func _activate(tid: String) -> void:
	var st := _state_of(tid)
	var nm := String(runner.db.techs[tid]["nameZh"]) if runner.db.techs.has(tid) else tid
	match String(st["key"]):
		"ready":
			runner.enqueue([{"type": "research", "techId": tid}])
			_notify("已排队：%s（次日 06:00 生效）" % nm)
		"queued":
			runner.enqueue([{"type": "cancel_research", "techId": tid}])
			_notify("已取消研究：%s" % nm)
		"pending":
			# 待生效的那条还没进队列，但命令是按顺序在黎明应用的 ——
			# 所以补一条 cancel 就能把同一回合的 research 抵消掉。
			runner.enqueue([{"type": "cancel_research", "techId": tid}])
			_notify("已撤销排队：%s" % nm)
		"done":
			_notify("%s 已完成" % nm)
		_:
			var names := []
			for r in _missing_requires(tid):
				var t2 = runner.db.techs.get(r, null)
				names.append(String(t2["nameZh"]) if t2 != null else r)
			_notify("需要先研究：%s" % "、".join(names))
	_last_day = int(runner.sim.s["day"])
	_refresh_states()


func _notify(msg: String) -> void:
	if world != null and world.has_signal("notice"):
		world.emit_signal("notice", msg)


# ===========================================================================
# 平移夹取
# ===========================================================================
func _on_view_resized() -> void:
	_pan = _clamp_pan(_pan)
	if _canvas != null:
		_canvas.position = _pan


func _clamp_pan(p: Vector2) -> Vector2:
	var vs := _view.size
	var lo := Vector2(minf(0.0, vs.x - _canvas_size.x), minf(0.0, vs.y - _canvas_size.y))
	var hi := Vector2.ZERO
	# 画布比视口小的时候，允许把它摆进视口里（否则会永远贴在左上角）
	if _canvas_size.x < vs.x:
		lo.x = 0.0
		hi.x = vs.x - _canvas_size.x
	if _canvas_size.y < vs.y:
		lo.y = 0.0
		hi.y = vs.y - _canvas_size.y
	return Vector2(clampf(p.x, lo.x, hi.x), clampf(p.y, lo.y, hi.y))


# ===========================================================================
# tooltip（带图标的 Control —— 默认 tooltip 只有文字，做不到）
# ===========================================================================
func build_tooltip(tid: String) -> Control:
	var db := runner.db
	if not db.techs.has(tid):
		return UIKit.label(tid, UIKit.FG_DARK)
	var tech: Dictionary = db.techs[tid]
	var s: Dictionary = runner.sim.s

	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 9, 7, 9, 7))
	wrap.custom_minimum_size = Vector2(300, 0)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	wrap.add_child(vb)

	# --- 标题：图标 + 名字 + 纪元
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 7)
	var ic := TextureRect.new()
	ic.texture = UIKit.tech_icon(tid)
	ic.custom_minimum_size = Vector2(UIKit.TECH_ICON_SIZE, UIKit.TECH_ICON_SIZE)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	head.add_child(ic)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.add_child(UIKit.label(String(tech["nameZh"]), UIKit.FG_HEAD))
	col.add_child(UIKit.label(_era_name(int(tech["era"])), UIKit.FG_DIM))
	head.add_child(col)
	vb.add_child(head)
	vb.add_child(UIKit.hsep())

	# --- 状态 + 操作提示
	var st := _state_of(tid)
	var hint := ""
	match String(st["key"]):
		"ready": hint = "　（点卡片开始研究）"
		"queued": hint = "　（点卡片取消研究）"
		"pending": hint = "　（点卡片撤销排队）"
		"locked": hint = "　（点卡片看还缺什么）"
		"done": hint = ""
	vb.add_child(UIKit.label(String(st["text"]) + hint, st["color"]))

	# --- 科研力
	vb.add_child(UIKit.label("科研力 %s" % _fmt(float(tech["research"])), UIKit.FG_DARK))

	# --- 材料（带图标）
	var cost: Dictionary = tech["cost"]["goods"]
	if cost.is_empty():
		_tip_kv(vb, "材料", "无")
	else:
		_tip_kv(vb, "材料", "")
		for gid in cost.keys():
			var g := String(gid)
			var need := float(cost[g])
			var have := float(s["goods"].get(g, 0.0))
			var ok := have >= need
			var gname := g
			if db.goods.has(g):
				gname = String(db.goods[g]["nameZh"])
			vb.add_child(_tip_icon_row(GoodIcons.tex(g),
				"　" + gname, UIKit.FG_DARK if ok else Color(0.72, 0.24, 0.18),
				"%s / %s" % [_fmt(have), _fmt(need)]))

	# --- 前置（带图标 + 已研究/未研究着色）
	var reqs: Array = tech["requires"]
	if not reqs.is_empty():
		_tip_kv(vb, "前置", "")
		var done: Array = s["research"]["done"]
		for r in reqs:
			var rt := String(r)
			var rd = db.techs.get(rt, null)
			var rn := String(rd["nameZh"]) if rd != null else rt
			var has_it: bool = done.has(rt)
			vb.add_child(_tip_icon_row(UIKit.tech_icon(rt),
				"　" + rn, Color(0.20, 0.48, 0.22) if has_it else Color(0.72, 0.24, 0.18),
				"已研究" if has_it else "未研究"))

	# --- 解锁（带图标）
	var unlocks: Array = []
	unlocks.append_array(tech["unlocks"]["buildings"])
	unlocks.append_array(tech["unlocks"]["housing"])
	if unlocks.is_empty():
		_tip_kv(vb, "解锁", "无（只解锁科技本身）")
	else:
		_tip_kv(vb, "解锁", "")
		for bid in unlocks:
			var b := String(bid)
			vb.add_child(_tip_icon_row(_unlock_icon(b), "　" + _thing_name(b), UIKit.FG_DARK, ""))
	return wrap


func _tip_kv(vb: VBoxContainer, k: String, v: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(UIKit.label(k, UIKit.FG_HEAD))
	if v != "":
		row.add_child(UIKit.label(v, UIKit.FG_DARK))
	vb.add_child(row)


## 一行：小图标 + 文字（+ 右侧数值）
func _tip_icon_row(tex: Texture2D, text: String, color: Color, right: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	if tex != null:
		var t := TextureRect.new()
		t.texture = tex
		t.custom_minimum_size = Vector2(24, 24)
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(t)
	var l := UIKit.label(text, color)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	if right != "":
		row.add_child(UIKit.label(right, color))
	return row


## 解锁项可能是建筑（走建造栏缩略图）也可能是住房（商品图标里就有）。
func _unlock_icon(id: String) -> Texture2D:
	var t := GoodIcons.tex(id)
	if t != null:
		return t
	var def: Dictionary = {}
	if runner.db.buildings.has(id):
		def = runner.db.buildings[id]
	elif runner.db.housing.has(id):
		def = runner.db.housing[id]
	return UIKit.thumb(id, UIKit.is_prop(def))


func _thing_name(id: String) -> String:
	if runner.db.goods.has(id):
		return String(runner.db.goods[id]["nameZh"])
	if runner.db.buildings.has(id):
		return String(runner.db.buildings[id]["nameZh"])
	if runner.db.housing.has(id):
		return String(runner.db.housing[id]["nameZh"])
	return id


func _era_name(era: int) -> String:
	for er in runner.db.eras:
		if int(er["id"]) == era:
			return "纪元 %d · %s" % [era, String(er["nameZh"])]
	return "纪元 %d" % era


func _fmt(v: float) -> String:
	if absf(v - round(v)) < 0.005:
		return "%d" % int(round(v))
	return "%.1f" % v


# ===========================================================================
# 面板自身拖动（标题栏）：位置存 user://hud.cfg
# ===========================================================================
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
