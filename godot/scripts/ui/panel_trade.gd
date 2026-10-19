extends PanelContainer

# 贸易市场（M4，2026-10；2026-10 第三版）
#
# 版式：全屏米黄面板（与统计 / 科技 / 任务同口径），页签「游商 / 商路」，右下角薇拉立绘。
#
#   ┌ 标题行：通商图标 + 「贸易市场」 + 副标题 + 关闭 ───────────────────────┐
#   │ 页签：游商 / 商路                                                     │
#   │ 「马库斯 来自 圣火城」 · 还能待 5 天 · 他手里还有 ⛁447                │
#   │   他可收购（你卖给他）            他可出售（你买）                    │
#   │   物资   已收购  单价             物资   存货  单价                   │
#   │   [图]草药  6    ⛁3.84 [出售]     [图]小麦  21  ⛁1.30 [购买]          │
#   │ 国库 ⛁5218.04                                                        │
#   └──────────────────────────────────────────────────────────────────────┘
#
# 用户 2026-10 的几条返工意见（都落到这里了）：
#   · "cv#2-1 是啥" → 游商现在有**名字 + 来历**（`NAME_POOL` / `ORIGIN_POOL`，按 id 哈希取值，
#     所以同一个游商永远同一个名字；纯表现层，不进存档、不动引擎，见文件末尾的说明）
#   · "表格应该有表头：物资 / 存货（出售叫做已收购）/ 单价"
#   · "1 和 5 的按钮什么意思" → 换成「出售 / 购买」按钮 + **数量对话框**（滑块选数量、
#     实时显示总价；卖的上限是未锁定数量与他现金能收的，买的上限是钱够买与他的存货取小）
#   · "价格用 @ 也太傻了，金币图标为什么不用" → 金额一律「⛁图标 + 数字」
#   · "所有的物资前面要加物资自己的图标" → 走 `GoodIcons.tex()`
#
# 数据来自 `SimCore.trade_snapshot()`（只读快照）+ `s["goods"] / s["reserved"]`（算未锁定数量）。
# 命令走 `runner.enqueue()`（次日黎明生效），副标题里写明，否则玩家会以为点了没反应。

var runner: SimRunner
var world: Node

## 金额 / 数量行的图标显示尺寸：硬币 16（面板图标原生 32，÷2 不糊）、物资 16（同）。
const ICON_SM := 16
## 表格各列的固定宽度（表头与数据行共用同一组，保证列对齐）
const W_NAME := 150.0
const W_QTY := 56.0
const W_PRICE := 84.0
## 每个游商这一趟"最多收多少"（引擎 `caravan.ts::QTY_PER_OFFER` 的镜像）。
## 只用来算收购侧的「已收购」= 这个数 − 他还没收的配额。
const FULL_QUOTA := 20

## 游商名字池（用户 2026-10 给的 20 个）。**纯表现层**：按 `cv#<批>-<序>` 的哈希取，
## 同一个 id 永远同一个名字，读档 / 换机器都一样。不进存档、不进引擎，
## 所以 TS 与 GDScript 的黄金轨迹一点不受影响。
const NAME_POOL := [
	"马库斯", "科林", "巴托", "雷米", "奥托",
	"达里奥", "塞缪尔", "格里姆", "卢卡斯", "哈维",
	"莉迪亚", "玛莎", "塞琳娜", "罗莎", "艾格尼丝",
	"诺拉", "贝拉", "凯瑟琳", "黛西", "伊芙琳",
]
## 来历池（用户给的 4 个国 + 5 座城）。名字与来历用**两个不同的哈希**，
## 否则"名字序号 i 的永远来自第 i 个地方"，20 个名字会被 9 个地方绑死。
const ORIGIN_POOL := [
	"圣辉教国", "铁峰公国", "翡翠王国", "沙海汗国",
	"铁王城", "圣火城", "金穗城", "曙光城", "黑石堡",
]

var _title_lb: Label
var _sub: Label
var _body: VBoxContainer
var _scroll: ScrollContainer
var _portrait: PanelPortrait

## 页签：0 = 游商（M4 已做），1 = 商路（B3 的系统，只有占位）
const TAB_NAMES := ["游商", "商路"]
var _tab := 0
var _tab_btns: Array[Button] = []
var _page_box: VBoxContainer
var _road_box: VBoxContainer

## 数量对话框（购买 / 出售共用一套）
var _dlg: PopupPanel
var _dlg_head: HBoxContainer
var _dlg_meta: HBoxContainer
var _dlg_title: Label
var _dlg_slider: HSlider
var _dlg_total: Label
var _dlg_money: Label
var _dlg_ok: Button
var _dlg_action := ""
var _dlg_caravan := ""
var _dlg_good := ""
var _dlg_price := 0.0

const C_HINT := Color(0.42, 0.32, 0.22)
const C_MONEY := Color(0.55, 0.36, 0.10)

func setup(r: SimRunner, w: Node) -> void:
	runner = r
	world = w

func _ready() -> void:
	# **全屏**（anchors 0..1），和统计 / 科技 / 任务同一个口径：不拖动、不跟内容改高度，
	# 顶栏留着（它们都从 BAR_H 往下铺）。
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_right = 0.0
	offset_top = float(UIKit.BAR_H)
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 16, 12, 16, 12))
	visible = false

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# ---- 标题行
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	# 标题图标用**面板图标目录**里那张 32×32 的通商图（用户专门给了小尺寸版）。
	# ⚠️ 别用 `tech_icon("trade")` —— 科技树那张现在是 64×64，塞进 32 的位子会溢出。
	var ico := UIKit.stat_icon("trade")
	if ico == null:
		ico = UIKit.panel_icon("resource")
	if ico != null:
		var tr := TextureRect.new()
		tr.texture = ico
		tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tr)
	_title_lb = UIKit.label("贸易市场", UIKit.FG_HEAD)
	_title_lb.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(_title_lb)
	head.add_child(UIKit.spacer())
	_sub = UIKit.label("")
	_sub.add_theme_color_override("font_color", C_HINT)
	head.add_child(_sub)
	head.add_child(UIKit.spacer())
	var close := UIKit.button("关闭", true)
	close.tooltip_text = "回到地图（Esc 也行）"
	close.pressed.connect(close_panel)
	head.add_child(close)

	root.add_child(UIKit.hsep())

	# ---- 页签
	var tabrow := HBoxContainer.new()
	tabrow.name = "TabRow"
	tabrow.add_theme_constant_override("separation", 5)
	root.add_child(tabrow)
	for i in TAB_NAMES.size():
		var b := UIKit.button(String(TAB_NAMES[i]), true)
		b.pressed.connect(_select_tab.bind(i))
		tabrow.add_child(b)
		_tab_btns.append(b)
	tabrow.add_child(UIKit.spacer())
	root.add_child(UIKit.hsep())

	# ---- 「游商」页：可滚动
	_page_box = VBoxContainer.new()
	_page_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_page_box)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page_box.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	_scroll.add_child(_body)

	# ---- 「商路」页：占位（B3 的系统）
	_road_box = VBoxContainer.new()
	_road_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_road_box.add_theme_constant_override("separation", 6)
	_road_box.visible = false
	root.add_child(_road_box)
	_road_box.add_child(UIKit.label("商路：还没开通", UIKit.FG_HEAD))
	_road_box.add_child(UIKit.label(
		"常驻商路要等「米拉」带来的那套系统（车队、关税、跨城价）。现在能做生意的地方是"
		+ "「游商」这一页 —— 他们每周来一批、停七天，带的货和手里的钱都有限。"))
	_road_box.add_child(UIKit.label("（建造栏 → 市政 → 贸易市场 建好之后，这个面板才能打开。）"))

	# ---- 右下角顾问立绘：薇拉（兼管贸易）
	_portrait = PanelPortrait.new()
	_portrait.name = "Portrait"
	add_child(_portrait)
	_portrait.setup("vera", runner.sim if runner != null else null)

	visibility_changed.connect(_on_visibility_changed)
	if runner != null and runner.has_signal("hour_ticked"):
		runner.hour_ticked.connect(_on_hour)
	_select_tab(0)


# ---------------------------------------------------------------------------
# 打开 / 关闭
# ---------------------------------------------------------------------------
func close_panel() -> void:
	visible = false
	if _dlg != null:
		_dlg.hide()

func open_trade() -> void:
	visible = true
	move_to_front()
	_last_hour = int(runner.sim.s["hour"]) if runner != null and runner.sim != null else -1
	_refresh()
	if _portrait != null:
		_portrait.speak()

## 打开时把地图那一侧的常驻件（小地图 + 左侧圆钮）藏起来 —— 和统计 / 科技同一套。
func _on_visibility_changed() -> void:
	UIKit.show_map_chrome(self, not UIKit.any_panel_open(self, visible))

func _on_hour() -> void:
	if not visible:
		return
	var h := int(runner.sim.s["hour"])
	if h == _last_hour:
		return
	_last_hour = h
	_refresh()

var _last_hour := -1


# ---------------------------------------------------------------------------
# 页签
# ---------------------------------------------------------------------------
func _select_tab(i: int) -> void:
	_tab = clampi(i, 0, TAB_NAMES.size() - 1)
	UIKit.play_switch()
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == _tab else UIKit.T_BTN))
	if _page_box != null:
		_page_box.visible = _tab == 0
	if _road_box != null:
		_road_box.visible = _tab == 1
	if _sub != null:
		_sub.text = ("买卖次日 06:00 生效；他带的货有限，钱也有限" if _tab == 0
			else "常驻商路还没做（下一版）")


# ---------------------------------------------------------------------------
# 小工具：图标 / 金额 / 名字
# ---------------------------------------------------------------------------
## 「⛁ 12.34」——金币图标 + 数字。项目里没有内联图标的 Label，所以统一用 HBox 拼。
func _money(amount: float, color: Color = C_MONEY) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var coin := UIKit.coin_icon()
	if coin != null:
		var tr := TextureRect.new()
		tr.texture = coin
		tr.custom_minimum_size = Vector2(ICON_SM, ICON_SM)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tr)
	var lb := UIKit.label(_fmt(amount), color)
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lb)
	return row

## 物资图标（用户："所有的物资前面要加物资自己的图标"）
func _good_icon(gid: String) -> Control:
	var tex := GoodIcons.tex(gid)
	if tex == null:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(ICON_SM, ICON_SM)
		return pad
	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = Vector2(ICON_SM, ICON_SM)
	# 手绘图标 32、程序化兜底 16；统一按 16 显示（整数倍 / 整除，不糊）
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

## 游商名字：按 id 哈希从池里取（同一个 id 永远同名）。
func caravan_name(cv_id: String) -> String:
	return String(NAME_POOL[_hash(cv_id) % NAME_POOL.size()])

## 来历：**另一个**哈希（否则名字与地方会被同一个序号绑死）。
func caravan_origin(cv_id: String) -> String:
	return String(ORIGIN_POOL[_hash(cv_id + "/origin") % ORIGIN_POOL.size()])

func _hash(s: String) -> int:
	var h := 7
	for i in s.length():
		h = (h * 131 + s.unicode_at(i)) % 1000003
	return h

func _fmt(v: float) -> String:
	return "%.2f" % v if not is_equal_approx(v, round(v)) else "%.0f" % v


# ---------------------------------------------------------------------------
# 正文
# ---------------------------------------------------------------------------
func _clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()

func _refresh() -> void:
	if not visible or runner == null or runner.sim == null:
		return
	_clear(_body)
	var snap: Dictionary = runner.sim.trade_snapshot()
	var caravans: Array = snap.get("caravans", [])
	if caravans.is_empty():
		var left := int(snap.get("daysToNext", 0))
		var hint := "还没有游商。"
		if int(snap.get("waveSize", 0)) == 0:
			hint = "完成第 3 章之后，游商会开始上门（每周一批、停留 7 天）。"
		elif left > 0:
			hint = "下一位游商还有 %d 天到达。" % left
		_body.add_child(UIKit.label(hint))
	else:
		for cv in caravans:
			_body.add_child(_caravan_block(cv))

	_body.add_child(_sep())
	var money_row := HBoxContainer.new()
	money_row.add_theme_constant_override("separation", 4)
	money_row.add_child(UIKit.label("国库"))
	money_row.add_child(_money(float(snap.get("money", 0.0))))
	_body.add_child(money_row)

func _sep() -> Control:
	var s := ColorRect.new()
	s.color = Color(0.62, 0.54, 0.40)
	s.custom_minimum_size = Vector2(0, 1)
	return s

## 表格里的一列：给控件一个固定宽度（表头与数据行共用，保证对齐）。
func _cell(node: Control, width: float) -> Control:
	node.custom_minimum_size = Vector2(width, node.custom_minimum_size.y)
	node.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return node

func _caravan_block(cv: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var cv_id := String(cv.get("id", ""))

	# ---- 抬头：「名字 来自 地方」· 还能待几天 · 他手里还有多少钱
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var nm := UIKit.label("%s 来自 %s" % [caravan_name(cv_id), caravan_origin(cv_id)], UIKit.FG_HEAD)
	nm.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	head.add_child(nm)
	head.add_child(UIKit.label("还能待 %d 天" % int(cv.get("daysLeft", 0)), C_HINT))
	head.add_child(UIKit.label("他手里还有", C_HINT))
	head.add_child(_money(float(cv.get("cash", 0.0))))
	head.add_child(UIKit.label("可以收你的货", C_HINT))
	head.add_child(UIKit.spacer())
	box.add_child(head)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(cols)

	cols.add_child(_offer_column(cv, "buy", "他可收购（你卖给他）", "已收购", "出售"))
	cols.add_child(_offer_column(cv, "sell", "他可出售（你买）", "存货", "购买"))
	box.add_child(_sep())
	return box

func _offer_column(cv: Dictionary, key: String, title: String, qty_head: String, verb: String) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tl := UIKit.label(title, UIKit.FG_HEAD)
	col.add_child(tl)

	# 表头：物资 / 存货（或"已收购"）/ 单价
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(_cell(UIKit.label("物资", UIKit.FG_DIM), W_NAME))
	head.add_child(_cell(UIKit.label(qty_head, UIKit.FG_DIM), W_QTY))
	head.add_child(_cell(UIKit.label("单价", UIKit.FG_DIM), W_PRICE))
	col.add_child(head)

	var offers: Array = cv.get(key, [])
	if offers.is_empty():
		col.add_child(UIKit.label("（这次没有）", UIKit.FG_DIM))
		return col

	var full := FULL_QUOTA   # 他这一趟"最多收多少"，用来算"已收购"
	for o in offers:
		col.add_child(_offer_row(cv, key, o, verb))
	return col

func _offer_row(cv: Dictionary, key: String, o: Dictionary, verb: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var gid := String(o.get("good", ""))
	var left := int(ceil(float(o.get("qty", 0.0))))

	# 物资：图标 + 名字
	var name_box := HBoxContainer.new()
	name_box.add_theme_constant_override("separation", 3)
	name_box.add_child(_good_icon(gid))
	name_box.add_child(UIKit.label(runner.sim.good_name(gid)))
	row.add_child(_cell(name_box, W_NAME))

	# 数量列：收购侧显示「已收购 x / 20」（这一趟他累计收了多少，分母是配额），
	# 出售侧显示「存货」（他还剩多少）。
	var qty_txt := str(left) if key == "sell" else "%d / %d" % [maxi(0, FULL_QUOTA - left), FULL_QUOTA]
	row.add_child(_cell(UIKit.label(qty_txt), W_QTY))

	# 单价：金币图标 + 数字（不再用 @）
	row.add_child(_cell(_money(float(o.get("price", 0.0))), W_PRICE))

	var b := UIKit.button(verb, true)
	b.custom_minimum_size = Vector2(56, 0)
	var maxq := _max_qty(cv, key, o)
	if maxq <= 0:
		b.disabled = true
		b.tooltip_text = _max_reason(cv, key, o)
	else:
		b.tooltip_text = "选数量（最多 %d）" % maxq
		b.pressed.connect(_open_dialog.bind(key, String(cv.get("id", "")), o, verb))
	row.add_child(b)
	return row


# ---------------------------------------------------------------------------
# 数量对话框（拖动滑块选数量，实时显示总价）
# ---------------------------------------------------------------------------
## 这一单**最多能成交几个**：
##   卖给他 → 未锁定的库存（goods − reserved）、他还肯收的配额、他现金买得起的量，三者取小
##   从他买 → 他的存货、国库买得起的量，两者取小
func _max_qty(cv: Dictionary, key: String, o: Dictionary) -> int:
	var price := maxf(0.01, float(o.get("price", 0.0)))
	var stock_left := int(ceil(float(o.get("qty", 0.0))))
	if key == "buy":
		var unlocked := _unlocked(String(o.get("good", "")))
		var cash_afford := int(floor(float(cv.get("cash", 0.0)) / price))
		return maxi(0, mini(unlocked, mini(stock_left, cash_afford)))
	var money := float(runner.sim.s["government"]["money"])
	return maxi(0, mini(stock_left, int(floor(money / price))))

## 不能成交时给玩家一句人话。
func _max_reason(cv: Dictionary, key: String, o: Dictionary) -> String:
	var price := maxf(0.01, float(o.get("price", 0.0)))
	if int(ceil(float(o.get("qty", 0.0)))) <= 0:
		return "他这一档没了" if key == "sell" else "他收满了"
	if key == "buy":
		if _unlocked(String(o.get("good", ""))) <= 0:
			return "这类物资都被预定了（未锁定的数量是 0）"
		return "他的钱不够收了（手里只有 %s）" % _fmt(float(cv.get("cash", 0.0)))
	return "国库不够（单价 %s）" % _fmt(price)

## 未锁定数量 = 库存 − 预定量（建造待扣的那部分不能拿去卖）。
func _unlocked(gid: String) -> int:
	var s: Dictionary = runner.sim.s
	var have := float((s["goods"] as Dictionary).get(gid, 0.0))
	var reserved := float((s["reserved"] as Dictionary).get(gid, 0.0))
	return maxi(0, int(floor(have - reserved)))

func _open_dialog(key: String, cv_id: String, o: Dictionary, verb: String) -> void:
	_ensure_dialog()
	var gid := String(o.get("good", ""))
	_dlg_action = "sell_to_caravan" if key == "buy" else "buy_from_caravan"
	_dlg_caravan = cv_id
	_dlg_good = gid
	_dlg_price = float(o.get("price", 0.0))
	# 找到这位游商（拿现金 / 存货上限）
	var cv: Dictionary = {}
	for c in (runner.sim.trade_snapshot().get("caravans", []) as Array):
		if String((c as Dictionary).get("id", "")) == cv_id:
			cv = c
	var maxq := _max_qty(cv, key, o)
	if maxq <= 0:
		return
	_dlg_title.text = "%s「%s」" % [verb, runner.sim.good_name(gid)]
	# 标题行最前面补一张物资图标（否则对话框里只有名字、没有"这是哪种货"的视觉锚点）
	for c in _dlg_head.get_children():
		if c != _dlg_title:
			_dlg_head.remove_child(c)
			c.queue_free()
	var gi := _good_icon(gid)
	_dlg_head.add_child(gi)
	_dlg_head.move_child(gi, 0)

	# 说明行：单价（金币图标）+ 上限（说清"为什么是这个上限"）
	_clear(_dlg_meta)
	_dlg_meta.add_child(UIKit.label("每件"))
	_dlg_meta.add_child(_money(_dlg_price))
	if key == "buy":
		_dlg_meta.add_child(UIKit.label(
			" · 你最多少卖 %d 个（未锁定 %d）" % [maxq, _unlocked(gid)]))
	else:
		_dlg_meta.add_child(UIKit.label(" · 他还有 %d 个" % maxq))
	_dlg_slider.min_value = 1
	_dlg_slider.max_value = float(maxq)
	_dlg_slider.value = float(maxq)
	_dlg_slider.visible = maxq > 1
	_update_dialog_total()
	_dlg_ok.text = "确定" + verb
	_dlg.popup_centered(Vector2i(380, 200))

func _ensure_dialog() -> void:
	if _dlg != null:
		return
	_dlg = PopupPanel.new()
	_dlg.add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM), 12, 12, 12, 12))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_dlg.add_child(vb)

	_dlg_title = UIKit.label("", UIKit.FG_HEAD)
	_dlg_title.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	# 标题行：物资图标 + 「出售「粗面粉」」
	_dlg_head = HBoxContainer.new()
	_dlg_head.add_theme_constant_override("separation", 4)
	_dlg_head.add_child(_dlg_title)
	vb.add_child(_dlg_head)
	# 说明行：金币图标 + 单价 / 上限（每次打开按报价重建）
	_dlg_meta = HBoxContainer.new()
	_dlg_meta.add_theme_constant_override("separation", 4)
	vb.add_child(_dlg_meta)

	# 像素风滑块：硬边纯色轨道 + 木/金属把手（与建筑面板的用工滑块同一套）
	_dlg_slider = HSlider.new()
	_dlg_slider.min_value = 1
	_dlg_slider.max_value = 2
	_dlg_slider.step = 1
	_dlg_slider.custom_minimum_size = Vector2(300, 20)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.24, 0.17, 0.12, 0.55)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.72, 0.55, 0.22)
	fill.content_margin_top = 6
	fill.content_margin_bottom = 6
	_dlg_slider.add_theme_stylebox_override("slider", track)
	_dlg_slider.add_theme_stylebox_override("grabber_area", fill)
	_dlg_slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	var grab := UIKit.slider_grabber()
	if grab != null:
		_dlg_slider.add_theme_icon_override("grabber", grab)
		_dlg_slider.add_theme_icon_override("grabber_highlight", grab)
	_dlg_slider.value_changed.connect(func(_v: float): _update_dialog_total())
	vb.add_child(_dlg_slider)

	var total_row := HBoxContainer.new()
	total_row.add_theme_constant_override("separation", 4)
	total_row.add_child(UIKit.label("数量"))
	_dlg_total = UIKit.label("", UIKit.FG_HEAD)
	total_row.add_child(_dlg_total)
	_dlg_money = UIKit.label("", UIKit.FG_HEAD)
	var coin := UIKit.coin_icon()
	if coin != null:
		var tr := TextureRect.new()
		tr.texture = coin
		tr.custom_minimum_size = Vector2(ICON_SM, ICON_SM)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		total_row.add_child(tr)
	total_row.add_child(_dlg_money)
	vb.add_child(total_row)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	btns.add_child(UIKit.spacer())
	var no := UIKit.button("取消", true)
	no.pressed.connect(func(): _dlg.hide())
	btns.add_child(no)
	_dlg_ok = UIKit.button("确定", true)
	_dlg_ok.pressed.connect(_confirm_dialog)
	btns.add_child(_dlg_ok)
	vb.add_child(btns)
	add_child(_dlg)

func _update_dialog_total() -> void:
	if _dlg_total == null:
		return
	var n := int(round(_dlg_slider.value))
	_dlg_total.text = "%d 个　共" % n
	if _dlg_money != null:
		_dlg_money.text = _fmt(_dlg_price * n)

func _confirm_dialog() -> void:
	var n := int(round(_dlg_slider.value))
	_dlg.hide()
	if n <= 0:
		return
	_send(_dlg_action, _dlg_caravan, _dlg_good, n)

## 发命令（走 runner.enqueue，次日黎明生效）。研究队列那套口径：命令不会马上成交，
## 所以别在这里改任何状态，等 `hour_ticked` 回来 `_refresh()`。
func _send(action: String, caravan_id: String, good_id: String, qty: int) -> void:
	runner.enqueue([{"type": action, "caravanId": caravan_id, "goodId": good_id, "qty": qty}])
	_refresh()

## 面板范围内的鼠标事件一律吃掉（全屏面板，别让点击穿到地图上）。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		accept_event()
