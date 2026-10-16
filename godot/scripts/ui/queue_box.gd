class_name QueueBox
extends VBoxContainer

# 施工队列 / 研究队列的**同一套行** —— 城镇中心「建造队列」页、建筑工坊与研究所的面板
# 都用它（见 docs/town.md §十五 / §十六）。
#
# 两条队列是同构的（先进先出、队首先吃到当日产能、材料在**开工那一刻**才扣），所以行也
# 一样：
#
#     [缩略图] 1. 石作   研究内容/效果              [↑][↓][×]
#              已用 8 / 需要 20 科研力（40%）
#
#   · 左：缩略图（建筑 / 住房走 `UIKit.thumb()`，科技走 `UIKit.tech_icon()`）
#   · 中：序号 + 名字 + 状态；研究队列多一行「研究内容/效果」
#   · 右：↑ 提前一位 / ↓ 推后一位 / × 撤单
#
# ⚠️ **画的是显示副本**：命令次日 06:00 才生效，不把 `s["pending"]` 里的调序 / 取消先算
#    进去的话，点完 ↑ 屏幕上一动不动，玩家会以为没点上（与"人口上限（已排队）"同一套办法）。
#
# ⚠️ 撤单是**两步**（和"拆除"同一套）：第一下只亮出"会退回什么"（走 sim 的
#    `construction_refund_preview()` / `research_cancel_preview()`，**只算不改**，
#    与真退同一份口径），第二下才真的撤。
#
# ⚠️ 二次确认的状态记在**面板传进来的 `state` 字典**里，不记在本控件上：面板每个游戏
#    小时重建一次内容，记在本控件上的话"点了一下 ×"会被下一次重建抹掉。

enum Kind { BUILD, RESEARCH }

## 缩略图尺寸。用户："缩略图太小了，放大一点"（34 → 48）；试过"×3"（= 144）之后
## 用户拍板**改回去** —— ×3 一屏只看得到三四条，不值。
##
## ⚠️ 两条队列的**源图不一样**，所以不能给同一个数：
##   · 建筑 / 住房缩略图是 `assets/thumbs/*.png`：**固定 100×72 的画布**，里面是
##     按整数倍缩小居中的原图（`scripts/gen-art.ts::thumbOf()`）。画布 72 的整数倍
##     （72 / 144）是**像素级干净**的；48 是 0.67× 的非整数倍（最近邻下细节会丢一点），
##     换来的是行矮、一屏条数多 —— 现在取的就是它。想更清楚就改 72（行高 80，一屏 7 条）。
##   · 科技图标原生 **32**（`UIKit.TECH_ICON_SIZE`："只做 1 倍，整数倍才不糊"）→ 2× = 64。
const THUMB_BUILD := 48.0
const THUMB_TECH := 64.0
## 行高 = 缩略图 + 这点上下留白
const ROW_PAD := 8.0
## 三个按钮的高度（`BTN_H_SM` 是 21，行变高之后按钮居中、不再被拉到整行高）
const BTN_V := 34.0

var runner: SimRunner
var world: Node                  # 施工侧要借它的 `_sim_label()` / `_why_waiting_at()`
var kind := Kind.BUILD
## 面板持有的可变状态袋：`{"confirm": ""}`（"q:<id>" = 已点亮、等第二次点击）
var state: Dictionary = {}


func _thumb_size() -> float:
	return THUMB_BUILD if kind == Kind.BUILD else THUMB_TECH

## 缩略图的**框**（TextureRect 的最小尺寸）。
##
## ⚠️ 框不能给正方形：建筑 / 住房缩略图源图是 **100×72（横的）**，塞进 48×48 的方框里
## 等比缩放会被**宽度**卡住 —— 画出来是 48×34.5，"放大"了个寂寞（第一版就是这样，
## 行变高了、图还是原来那么大）。框按源图长宽比给：宽 = 高 × 100/72 ≈ 67。
## 科技图标是 32×32 的正方形，框就给正方形。
func _thumb_box() -> Vector2:
	if kind == Kind.BUILD:
		return Vector2(THUMB_BUILD * 100.0 / 72.0, THUMB_BUILD)
	return Vector2(THUMB_TECH, THUMB_TECH)


func setup(r: SimRunner, w: Node, k: int, st: Dictionary) -> void:
	runner = r
	world = w
	kind = k
	state = st
	add_theme_constant_override("separation", 2)
	refresh()


func refresh() -> void:
	for c in get_children():
		c.queue_free()
	if runner == null or runner.sim == null:
		return
	var view := _view()
	var rows: Array = view["rows"]
	var waiting := _pending_orders()
	# 那条工程要是已经不在队列里了（别处撤掉了 / 完工了），把确认状态收掉
	var cid_armed := String(state.get("confirm", ""))
	if cid_armed.begins_with("q:") and _row_index(rows, cid_armed.substr(2)) < 0:
		state["confirm"] = ""

	if rows.is_empty():
		_note("队列是空的。%s" % _empty_hint(waiting))
		return
	_note("从上往下依次%s：队首先吃到%s %s/天。命令次日 06:00 生效。" % [
		"施工" if kind == Kind.BUILD else "研究",
		"建造力" if kind == Kind.BUILD else "科研力", _rate_text()])
	_gap(2)
	for i in rows.size():
		_row(i, rows, view)
	if waiting > 0:
		_gap(2)
		_note("另有 %d 项刚下的单，次日 06:00 才进队列。" % waiting)
	if int(view["cancelled"]) > 0:
		_note("%d 项已排队取消，次日 06:00 生效（材料那时才退）。" % int(view["cancelled"]))


func _empty_hint(waiting: int) -> String:
	if waiting > 0:
		return "刚下的 %d 项要等次日 06:00 才进队列。" % waiting
	if kind == Kind.BUILD:
		return "在底下建造栏点一座建筑 / 住房就能下单。"
	return "在科技面板点一张卡片就能排研究。"


# ---------------------------------------------------------------------------
# 队列的读取（施工 / 研究共用一套形状）
# ---------------------------------------------------------------------------
## 队列的**显示副本**：把 `pending` 里还没生效的调序 / 取消先算进去（**只用来画界面**，
## 真状态由 sim 在黎明改）。返回 `{"rows": Array, "moved": Dictionary, "cancelled": int}`。
func _view() -> Dictionary:
	var rows := []
	for c in _queue():
		rows.append(c)
	var moved := {}
	var cancelled := 0
	for a in (runner.sim.s["pending"] as Array):
		var t := String(a.get("type", ""))
		var cid := String(_action_id(a))
		if t == _move_type():
			var i := _row_index(rows, cid)
			var j := i + int(a.get("delta", 0))
			if i < 0 or j < 0 or j >= rows.size():
				continue
			var tmp = rows[i]
			rows[i] = rows[j]
			rows[j] = tmp
			moved[cid] = int(moved.get(cid, 0)) + int(a.get("delta", 0))
		elif t == _cancel_type():
			var k := _row_index(rows, cid)
			if k >= 0:
				rows.remove_at(k)
				cancelled += 1
	return {"rows": rows, "moved": moved, "cancelled": cancelled}

func _queue() -> Array:
	if kind == Kind.BUILD:
		return runner.sim.s["construction"]
	return runner.sim.s["research"]["queue"]

## 队列条目的唯一键：施工是 `id`，研究是科技 id（两种动作用的名字不一样）。
func _row_id(c: Dictionary) -> String:
	if kind == Kind.BUILD:
		return String(c["id"])
	return String(c["id"])

func _action_id(a: Dictionary) -> String:
	if kind == Kind.BUILD:
		return String(a.get("id", ""))
	return String(a.get("techId", ""))

func _move_type() -> String:
	return "move_construction" if kind == Kind.BUILD else "move_research"

func _cancel_type() -> String:
	return "cancel_construction" if kind == Kind.BUILD else "cancel_research"

func _row_index(rows: Array, cid: String) -> int:
	for i in rows.size():
		if _row_id(rows[i]) == cid:
			return i
	return -1

## 刚点下去、还没到黎明的单子（它们在 `pending` 里，队列里还看不见）。
func _pending_orders() -> int:
	var n := 0
	var wanted := ["build", "build_housing", "upgrade_housing", "expand"] if kind == Kind.BUILD \
		else ["research"]
	for a in (runner.sim.s["pending"] as Array):
		if wanted.has(String(a.get("type", ""))):
			n += 1
	return n

func _rate_text() -> String:
	if kind == Kind.BUILD:
		return _num(float(runner.sim.construction_rate()))
	return _num(float(runner.sim.research_rate()))

## 数字：整数不带小数点（12 而不是 12.0），有小数才留一位。
func _num(v: float) -> String:
	return "%.0f" % v if absf(v - round(v)) < 0.05 else "%.1f" % v


# ---------------------------------------------------------------------------
# 行
# ---------------------------------------------------------------------------
func _row(i: int, rows: Array, view: Dictionary) -> void:
	var c: Dictionary = rows[i]
	var cid := _row_id(c)
	var side := _thumb_size()
	# 行 = [HBox: 缩略图 | 文字 | 三个按钮]（+ 二次确认时**横跨整行**的红色提示）
	# ⚠️ 二次确认那句要单独占一行、用**整行宽度**：它长（"再点一次「取消」：退回 木材×5.44、
	#    石块×2.72"），挤在"名字 + 状态"那一格（缩略图 144 之后只剩 ~270px）会被
	#    `clip_text` 直接切掉后半句（实测：石块那截没了）。
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 2)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0, side + ROW_PAD)

	var tex := _thumb(c)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.custom_minimum_size = _thumb_box()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.tooltip_text = _label(c)
		row.add_child(tr)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 缩略图比文字高时，文字整块**垂直居中**，不要顶在上边（否则行看着像空的）
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	# 序号跟着显示副本走（调序后立刻能看见名次变了）
	head.add_child(UIKit.label("%d. %s" % [i + 1, _label(c)], UIKit.FG_HEAD))
	var st := UIKit.label(_status(c, i, view), UIKit.FG_DIM)
	st.clip_text = true
	st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(st)
	col.add_child(head)
	col.add_child(UIKit.label(_work_text(c), UIKit.FG_DARK))
	var sub := _sub_text(c)
	if sub != "":
		var sl := UIKit.label(sub, UIKit.FG_DIM)
		sl.clip_text = true
		col.add_child(sl)
	row.add_child(col)

	# 三个按钮：**上三角 / 下三角 / 取消**（用户："上箭头改成上三角形，下箭头改成下三角形，
	# 叉改成取消两个汉字"）。三角形用 U+25B2 / U+25BC —— **字体里真有这两个字形**
	# （`↑` 也有，但用户要三角；`✗` 那种缺字形画出来是空的，见门槛 `glyph`）。
	var up := UIKit.button("▲", true)
	up.custom_minimum_size = Vector2(30, BTN_V)
	up.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	up.tooltip_text = "提前一位（更早吃到%s）" % _power_word()
	up.disabled = i <= 0
	up.pressed.connect(_move.bind(cid, -1))
	row.add_child(up)
	var dn := UIKit.button("▼", true)
	dn.custom_minimum_size = Vector2(30, BTN_V)
	dn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dn.tooltip_text = "推后一位"
	dn.disabled = i >= rows.size() - 1
	dn.pressed.connect(_move.bind(cid, 1))
	row.add_child(dn)
	# 「取消」是**两个汉字**，比图标宽，按钮跟着文字走（不给固定宽度，让样式内边距自己撑）
	var xx := UIKit.button("取消", true)
	xx.custom_minimum_size = Vector2(0, BTN_V)
	xx.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 已经完工的那条**不能撤**：料早就投完了，退 0；不想要它应该等建成 / 解锁之后另作处置。
	# （不挡的话，玩家会以为"撤掉能把料拿回来"，实际上是白白扔了一座建好的房子 / 一项科技。）
	var done: bool = float(c["remaining"]) <= 0.0
	xx.tooltip_text = "%s，等次日黎明生效" % _done_word() if done \
		else "取消%s（退回还没干完的那份材料）" % ("建造" if kind == Kind.BUILD else "研究")
	xx.disabled = done
	xx.pressed.connect(_cancel.bind(cid))
	row.add_child(xx)

	wrap.add_child(row)
	if String(state.get("confirm", "")) == "q:" + cid:
		# 二次确认：**横跨整行**摆一句红字（再点一次同一行的「取消」才真的撤）。
		# 状态位保持原样（"排队中 / 已投入"那些信息不该被顶掉），确认语另起一行。
		var arm := UIKit.label("再点一次「取消」：" + _preview_text(cid), Color(0.72, 0.25, 0.15))
		arm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wrap.add_child(arm)
		xx.add_theme_stylebox_override("normal", UIKit.box(UIKit.T_BTN_ACTIVE))
	add_child(wrap)

func _power_word() -> String:
	return "建造力" if kind == Kind.BUILD else "科研力"

func _done_word() -> String:
	return "已完工" if kind == Kind.BUILD else "已完成"

## 「已用 12.4 / 需要 40 建造力（31%）」—— 已用 = 总需求 − 还差的（与地图提示同口径）。
func _work_text(c: Dictionary) -> String:
	var need := float(c["totalRequired"])
	var left := float(c["remaining"])
	var used := maxf(0.0, need - left)
	var pct := 0 if need <= 0.0 else int(round(used / need * 100.0))
	return "已用 %s / 需要 %s %s（%d%%）" % [_num(used), _num(need), _power_word(), pct]

## 这一条现在什么状态。
##
## ⚠️ "完工"和"在建"是两回事：`remaining` 归零的条目要**等到次日黎明**才从队列里移走，
## 白天它和"下一条正在建"会同时在队列里 —— 都写"建造中"会让人以为两处一起动。
func _status(c: Dictionary, i: int, view: Dictionary) -> String:
	var s := ""
	if float(c["remaining"]) <= 0.0:
		s = "%s（次日黎明生效）" % _done_word()
	elif bool(c.get("started", false)):
		s = "施工中" if kind == Kind.BUILD else "研究中"
	elif i > 0:
		s = "排队中（前面还有 %d 项）" % i
	else:
		s = _head_status(c)
	var mv := int((view["moved"] as Dictionary).get(_row_id(c), 0))
	if mv != 0:
		s += "（调序已排队）"
	return s

## 队首还没开工：是在攒材料，还是产能为 0 / 还没到下一个 06:00。
## 施工侧复用 world 的 `_why_waiting_at()`（工地悬停提示读的是同一支）。
func _head_status(c: Dictionary) -> String:
	if kind == Kind.BUILD:
		if world != null and world.has_method("_why_waiting_at"):
			return String(world._why_waiting_at(c, 0))
		return "排队中"
	var tech = runner.db.techs.get(String(c["id"]), null)
	if tech == null:
		return "等待开工（科技定义缺失）"
	if float(runner.sim.research_rate()) <= 0.0:
		return "等待开工（没有科研力：建研究所、派人进去）"
	var gap := String(runner.sim._research_shortage(tech))
	if gap != "":
		return "等待材料（缺 %s）" % gap
	return "等待开工（下一个工作小时开工，届时扣材料）"

func _label(c: Dictionary) -> String:
	if kind == Kind.BUILD:
		if world != null and world.has_method("_sim_label"):
			return String(world._sim_label(c))
		return String(c.get("buildingId", c.get("housingId", c["id"])))
	var tech = runner.db.techs.get(String(c["id"]), null)
	return String(tech["nameZh"]) if tech != null else String(c["id"])

## 研究队列多一行「效果 / 解锁」—— 用户要的"研究内容/效果"。
func _sub_text(c: Dictionary) -> String:
	if kind == Kind.BUILD:
		return ""
	var tech = runner.db.techs.get(String(c["id"]), null)
	if tech == null:
		return ""
	var parts := []
	var eff: Dictionary = tech.get("effects", {})
	if not eff.is_empty():
		var ep := []
		for k in eff.keys():
			ep.append("%s +%d%%" % [UIKit.EFFECT_NAMES.get(String(k), String(k)),
				int(round(float(eff[k]) * 100.0))])
		parts.append("效果 " + "、".join(ep))
	var un: Dictionary = tech.get("unlocks", {})
	var names := []
	for bid in (un.get("buildings", []) as Array):
		names.append(_bname(String(bid)))
	for hid in (un.get("housing", []) as Array):
		names.append(_hname(String(hid)))
	if not names.is_empty():
		parts.append("解锁 " + "、".join(names))
	return "　".join(parts)

func _bname(bid: String) -> String:
	return String(runner.db.buildings[bid]["nameZh"]) if runner.db.buildings.has(bid) else bid

func _hname(hid: String) -> String:
	return String(runner.db.housing[hid]["nameZh"]) if runner.db.housing.has(hid) else hid

func _thumb(c: Dictionary) -> Texture2D:
	if kind == Kind.BUILD:
		var k := String(c["kind"])
		var tid := String(c.get("buildingId", ""))
		if k == "housing" or k == "housing_upgrade":
			tid = String(c.get("toHousingId", c.get("housingId", "")))
		return UIKit.thumb(tid)
	return UIKit.tech_icon(String(c["id"]))


# ---------------------------------------------------------------------------
# 操作（两步撤单 + 调序）
# ---------------------------------------------------------------------------
## 撤单二次确认时那句"会退回什么"（只算不改，走 sim 的预览函数 —— 与真退同一份口径）。
func _preview_text(cid: String) -> String:
	var pv: Dictionary = runner.sim.construction_refund_preview(cid) if kind == Kind.BUILD \
		else runner.sim.research_cancel_preview(cid)
	if not bool(pv["ok"]):
		return "这条已经不在队列里了"
	if not bool(pv["started"]):
		return "它还没开工，材料一分都没扣，退了也不返还"
	var t := String(pv["text"])
	var cut := t.find("，")
	return t.substr(cut + 1) if cut >= 0 else t

func _move(cid: String, delta: int) -> void:
	state["confirm"] = ""
	runner.enqueue([{"type": _move_type(), "id": cid, "delta": delta}])
	refresh()

func _cancel(cid: String) -> void:
	if String(state.get("confirm", "")) != "q:" + cid:
		state["confirm"] = "q:" + cid
		refresh()
		return
	state["confirm"] = ""
	var a := {"type": "cancel_construction", "id": cid} if kind == Kind.BUILD \
		else {"type": "cancel_research", "techId": cid}
	runner.enqueue([a])
	refresh()


# ---------------------------------------------------------------------------
# 排版小件
# ---------------------------------------------------------------------------
func _note(t: String) -> void:
	# ⚠️ 不开自动换行：`AUTOWRAP_WORD_SMART` 在宽度还没定下来时报的 min-height 巨大
	#    （实测 320px），会把"内容自适应高度"的面板撑出一个大空档。
	var l := UIKit.label(t, UIKit.FG_DIM)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(l)

func _gap(h: int = 6) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	add_child(c)
