extends PanelContainer

# 外交 / 军事（B4，用户 2026-10）
#
#   ┌ 标题行：外交图标 + 「外交 / 军事」 + 国库 + 关闭 ──────────────────────┐
#   │ 页签：世界 / 军事                                                     │
#   │ ┌──────────── 世界地图 ────────────┐ ┌──── 13 个势力 ────────────────┐ │
#   │ │  王国地图那张底图 + 城市徽记      │ │ [徽记] 铁王城   阿尔伯特       │ │
#   │ │  （和我们自己的村子也画上）       │ │        关系「友善」            │ │
#   │ │                                  │ │  送礼 100 500 1000 5000        │ │
#   │ │                                  │ │  结盟（灰） 派兵进攻           │ │
#   │ └──────────────────────────────────┘ └───────────────────────────────┘ │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# 用户 2026-10 原话（这一页的准绳）：
#   "新增建筑使馆，修建后解锁新增面板外交/军事，第一个 tab 就是世界地图……
#    右侧是好感（只显示敌对，友善等状态）然后是送礼按钮（王都是进贡，其它是赠送礼物，
#    剧情到国王死了也变成赠送礼物），结盟按钮（好感度够才能亮起来，结盟要 2000 块钱），
#    派兵进攻。立绘是米拉"
#
# 三条口径：
#   · **好感只写档位名**（不写数字）—— 数字只进 tooltip
#   · 三条按钮全部走 `runner.enqueue()`，而它们在引擎里是 `IMMEDIATE_ACTIONS`
#     （送钱 / 立约 / 宣战都当场生效），所以点完立刻能看到变化
#   · 「派兵进攻」在 B4 **只宣战**（关系直接打到 -6000 敌对），真正的战斗是 B5 的讨伐战
#
# 数据来自 `SimCore.factions_snapshot()`（只读快照），地图换算全部借 `panel_map.gd` 的
# 静态函数（和贸易地图 / 王国地图**逐点一致**，见 docs/town.md §三十三·补二）。

var runner: SimRunner
var world: Node

const PMAP := preload("res://scripts/ui/panel_map.gd")

## 页签：世界（外交）/ 军事（B5）
const TAB_NAMES := ["世界", "军事"]
var _tab := 0
var _tab_btns: Array[Button] = []

## 我们的村子（地图上也要画一枚，和非贸易面板同一套取法）
const HOME_ID := "ashen_vale"

## 送礼的四档（用户 2026-10 定：100 / 500 / 1000 / 5000，最少 100）
const GIFT_STEPS := [100, 500, 1000, 5000]

## 势力徽记 / 关系牌的显示尺寸（原生 48 / 32，都用 1:1 或整除）
const CREST_PX := 48
const BADGE_PX := 32

## 徽记颜色（图是像素画，直接贴）
const C_HINT := Color(0.59, 0.41, 0.28)

var _title_lb: Label
var _sub: Label
var _world_box: HBoxContainer
var _mil_box: VBoxContainer
var _map_box: HBoxContainer
var _map_host: Control
var _map_tex: TextureRect
var _map_dots: Control
var _list_scroll: ScrollContainer
var _list_body: VBoxContainer
var _portrait: PanelPortrait
## 当前选中的势力（地图上点徽记 / 列表里点一行都改它）—— 只影响列表置顶那一张卡的高亮
var _sel := ""
var _cards: Dictionary = {}
## 地图上每枚徽记（`{id, fx, fy, mark}`）—— 位置按底图比例算，窗口缩放要重排
var _dots: Array = []


## 由 `main.gd` 注入（和统计 / 科技 / 贸易同一套）：runner 用来取快照与下命令，
## world 暂时没用到（B5 的出兵点地图时才会用）。
func setup(runner_ref: SimRunner, world_ref) -> void:
	runner = runner_ref
	world = world_ref


func _ready() -> void:
	# **全屏**（anchors 0..1），和统计 / 科技 / 贸易 / 任务同一个口径
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
	visibility_changed.connect(_on_visibility_changed)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# ---- 标题行
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	root.add_child(head)
	var ico := UIKit.stat_icon("diplomacy")
	if ico != null:
		var tr := TextureRect.new()
		tr.texture = ico
		tr.custom_minimum_size = Vector2(UIKit.CHIP_ICON, UIKit.CHIP_ICON)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tr)
	_title_lb = UIKit.label("外交 / 军事", UIKit.FG_HEAD)
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

	# ---- 「世界」页：左边地图，右边 13 个势力
	_world_box = HBoxContainer.new()
	_world_box.name = "WorldPage"
	_world_box.add_theme_constant_override("separation", 10)
	_world_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_world_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_world_box)

	_map_box = HBoxContainer.new()
	_map_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_world_box.add_child(_map_box)

	_map_host = Control.new()
	_map_host.name = "MapHost"
	_map_host.clip_contents = true
	_map_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_host.custom_minimum_size = Vector2(360, 240)
	_map_box.add_child(_map_host)

	_map_tex = TextureRect.new()
	_map_tex.name = "MapTex"
	_map_tex.texture = load(PMAP.MAP_PATH) if ResourceLoader.exists(PMAP.MAP_PATH) else null
	_map_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_map_tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_host.add_child(_map_tex)

	# 徽记层：和底图同尺寸、同锚点，位置按 `panel_map.gd` 的换算算（不自己写一套）
	_map_dots = Control.new()
	_map_dots.name = "Dots"
	_map_dots.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_host.add_child(_map_dots)
	_map_tex.resized.connect(_layout_dots)

	# 右侧：13 个势力的卡片（滚动）
	_list_scroll = ScrollContainer.new()
	_list_scroll.name = "FactionScroll"
	_list_scroll.custom_minimum_size = Vector2(520, 0)
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_map_box.add_child(_list_scroll)
	_list_body = VBoxContainer.new()
	_list_body.name = "FactionList"
	_list_body.add_theme_constant_override("separation", 8)
	_list_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(_list_body)

	# ---- 「军事」页：B5 才做（这里只写清楚"什么时候来"）
	_mil_box = VBoxContainer.new()
	_mil_box.name = "MilPage"
	_mil_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mil_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mil_box.add_theme_constant_override("separation", 8)
	_mil_box.visible = false
	_world_box.add_child(_mil_box)
	var mil_head := UIKit.label("军事", UIKit.FG_HEAD)
	mil_head.add_theme_font_size_override("font_size", UIKit.BIG_FS)
	_mil_box.add_child(mil_head)
	_mil_box.add_child(UIKit.label("兵营、征兵、讨伐战都在 B5。", C_HINT))
	_mil_box.add_child(UIKit.label(
		"现在这里能做的是：在「世界」页对某个势力「派兵进攻」—— 那一仗会直接开战，", C_HINT))
	_mil_box.add_child(UIKit.label(
		"但战报要等 B5。打赢之后，铁峰会自动和我们和好成「尊重」。", C_HINT))
	_mil_box.add_child(UIKit.spacer())

	# ---- 米拉（右下角）
	_portrait = PanelPortrait.new()
	_portrait.name = "Portrait"
	_portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait.height_ratio = 0.46
	add_child(_portrait)
	_portrait.setup("milla")


func close_panel() -> void:
	visible = false


## 打开面板（HUD 的圆钮 / 快捷键 D / 章 5 任务都走这里）
func open_war() -> void:
	visible = true
	move_to_front()
	_build_list()
	_refresh()
	if _portrait != null:
		_portrait.speak()


func _on_visibility_changed() -> void:
	UIKit.show_map_chrome(self, not UIKit.any_panel_open(self, visible))


func _select_tab(i: int) -> void:
	_tab = clampi(i, 0, TAB_NAMES.size() - 1)
	UIKit.play_switch()
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == _tab else UIKit.T_BTN))
	if _map_box != null:
		_map_box.visible = _tab == 0
	if _mil_box != null:
		_mil_box.visible = _tab == 1
	_refresh()


# ===========================================================================
# 数据
# ===========================================================================
func _snap() -> Dictionary:
	if runner == null or runner.sim == null:
		return {"relation": {}, "factions": [], "money": 0.0}
	return runner.sim.factions_snapshot()


func _faction_by_id(snap: Dictionary, fid: String) -> Dictionary:
	for f in (snap.get("factions", []) as Array):
		if String((f as Dictionary).get("id", "")) == fid:
			return f
	return {}


# ===========================================================================
# 列表（13 张卡）
# ===========================================================================
func _build_list() -> void:
	for c in _list_body.get_children():
		c.queue_free()
	_cards.clear()
	var snap := _snap()
	for f in (snap.get("factions", []) as Array):
		var card := _make_card(f as Dictionary)
		_list_body.add_child(card)
		_cards[String((f as Dictionary).get("id", ""))] = card


func _make_card(f: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "Faction_" + String(f.get("id", ""))
	card.add_theme_stylebox_override("panel",
		UIKit.pad(UIKit.box(UIKit.T_PANEL_CREAM, 6), 8, 6, 8, 6))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	card.add_child(v)

	# ---- 第 1 行：徽记 + 名字（领主）+ 关系牌 + 档位名
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	v.add_child(top)
	var crest := UIKit.faction_icon(String(f.get("glyph", "")))
	if crest != null:
		var tr := TextureRect.new()
		tr.texture = crest
		tr.custom_minimum_size = Vector2(CREST_PX, CREST_PX)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top.add_child(tr)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	top.add_child(names)
	var lb_name := UIKit.label(String(f.get("nameZh", "")), UIKit.FG_HEAD)
	names.add_child(lb_name)
	var lb_lord := UIKit.label("%s%s" % [
		"领主 " if String(f.get("lord", "")) != "" else "", String(f.get("lord", ""))],
		C_HINT)
	names.add_child(lb_lord)
	top.add_child(UIKit.spacer())
	# 关系牌 + 档位名（**只写档位名**，数值只进 tooltip —— 用户要求）
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_child(col)
	var badge := TextureRect.new()
	badge.texture = UIKit.relation_icon(String(f.get("id", "")), f)
	badge.custom_minimum_size = Vector2(BADGE_PX, BADGE_PX)
	badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(badge)
	var lb_band := UIKit.label(String(f.get("label", "")), UIKit.FG_DIM)
	lb_band.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(lb_band)

	# ---- 第 2 行：按钮（送礼 / 结盟 / 进攻）
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	v.add_child(row)
	# 送礼（王都是「进贡」）：四档一次摆出来，省一次点击
	var gift_verb := String(f.get("giftVerb", "送礼"))
	for amt in GIFT_STEPS:
		var gb := UIKit.icon_left_button(str(amt), UIKit.coin_icon())
		gb.tooltip_text = "%s %d 钱 → 好感 +%d" % [gift_verb, int(amt), int(amt)]
		gb.disabled = float(_snap().get("money", 0.0)) < float(amt) \
			or int(f.get("rep", 0)) >= int(f.get("cap", 0))
		gb.pressed.connect(_on_gift.bind(String(f.get("id", "")), int(amt)))
		row.add_child(gb)
	row.add_child(UIKit.spacer())
	var ally := UIKit.icon_left_button("结盟", UIKit.faction_icon("treaty"))
	ally.disabled = not bool(f.get("canAlly", false))
	if not bool(f.get("allyable", false)):
		ally.tooltip_text = "这个势力不与我们结盟"
	elif bool(f.get("ally", false)):
		ally.tooltip_text = "已经是盟友了"
	elif not bool(f.get("canAlly", false)):
		ally.tooltip_text = "好感要到满分才能结盟"
	ally.pressed.connect(_on_ally.bind(String(f.get("id", ""))))
	row.add_child(ally)
	var war := UIKit.icon_left_button("进攻", UIKit.faction_icon("war"))
	war.disabled = not bool(f.get("canAttack", false))
	war.tooltip_text = "宣战：关系直接变「敌对」" if bool(f.get("canAttack", false)) \
		else "不能打（附庸 / 盟友 / 已经在交战）"
	war.pressed.connect(_on_attack.bind(String(f.get("id", ""))))
	row.add_child(war)

	card.tooltip_text = "好感 %d（上限 %d）· 送过 %d 次礼" % [
		int(f.get("rep", 0)), int(f.get("cap", 0)), int(f.get("gifts", 0))]
	return card


# ===========================================================================
# 地图（徽记按城的位置摆）
# ===========================================================================
func _build_dots() -> void:
	for c in _map_dots.get_children():
		c.queue_free()
	_dots.clear()
	var marks: Dictionary = PMAP.effective_marks()
	var snap := _snap()
	# 每座城一枚徽记（城 → 势力 → 徽记）；没有城的势力只出现在右边列表里
	for f2 in (snap.get("factions", []) as Array):
		var fid2 := String((f2 as Dictionary).get("id", ""))
		for cid in ((f2 as Dictionary).get("cityIds", []) as Array):
			if not marks.has(String(cid)):
				continue
			var mark: Dictionary = marks[String(cid)]
			var tex: Texture2D = UIKit.faction_icon(String((f2 as Dictionary).get("glyph", fid2)))
			if tex == null:
				continue
			var tr := TextureRect.new()
			tr.name = "Dot_" + String(cid)
			tr.texture = tex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.mouse_filter = Control.MOUSE_FILTER_STOP
			tr.tooltip_text = "%s（%s）" % [String((f2 as Dictionary).get("nameZh", "")),
				String((mark as Dictionary).get("nameZh", ""))]
			var fid_copy := fid2
			tr.gui_input.connect(_on_dot_input.bind(tr, fid_copy))
			_map_dots.add_child(tr)
			_dots.append({"id": fid2, "mark": mark, "node": tr})
	# 我们自己的村子：用城镇中心那张图当标记（和贸易地图同一套）
	var home_mark = marks.get(HOME_ID, null)
	if home_mark != null:
		var home := TextureRect.new()
		home.name = "Dot_home"
		home.texture = UIKit.thumb("town_center")
		home.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		home.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		home.mouse_filter = Control.MOUSE_FILTER_IGNORE
		home.tooltip_text = "我们的村子"
		_map_dots.add_child(home)
		_dots.append({"id": "", "mark": home_mark, "node": home})
	_layout_dots()


func _layout_dots() -> void:
	if _map_tex == null or _map_dots == null:
		return
	var tex_size: Vector2 = _map_tex.texture.get_size() if _map_tex.texture != null \
		else PMAP.MAP_TEX_SIZE
	var rect: Rect2 = PMAP.map_rect(_map_tex.size, tex_size)
	for d in _dots:
		var mark: Dictionary = d["mark"]
		var node: TextureRect = d["node"]
		var is_home := String(d["id"]) == ""
		# 城标记：用 `icon_rect` 的同一套换算（底边居中锚点 + 每项 scale）
		var r: Rect2 = PMAP.icon_rect(mark, rect, _map_tex.texture)
		var side := CREST_PX
		if is_home:
			side = int(PMAP.ICON_H * rect.size.y * 1.2)
		else:
			side = int(PMAP.ICON_H * rect.size.y * float(mark.get("scale", 1.0)) * 1.35)
		side = maxi(20, side)
		node.size = Vector2(side, side)
		node.position = Vector2(r.position.x + r.size.x * 0.5 - side * 0.5,
			r.position.y + r.size.y - side)


func _on_dot_input(ev: InputEvent, node: TextureRect, fid: String) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_sel = fid
	_refresh()
	if _list_scroll != null:
		_list_scroll.scroll_vertical = 0


# ===========================================================================
# 三条命令
# ===========================================================================
func _on_gift(fid: String, amount: int) -> void:
	runner.enqueue([{"type": "faction_gift", "factionId": fid, "amount": float(amount)}])
	_flash("已送出 %d 钱" % amount)
	_refresh()


func _on_ally(fid: String) -> void:
	runner.enqueue([{"type": "faction_ally", "factionId": fid}])
	_refresh()


func _on_attack(fid: String) -> void:
	runner.enqueue([{"type": "faction_attack", "factionId": fid}])
	_refresh()


func _flash(text: String) -> void:
	if _sub != null:
		_sub.text = text


# ===========================================================================
# 刷新
# ===========================================================================
func _refresh() -> void:
	if runner == null or runner.sim == null:
		return
	var snap := _snap()
	if _sub != null:
		var n_ally := 0
		var n_vassal := 0
		for f in (snap.get("factions", []) as Array):
			if bool((f as Dictionary).get("ally", false)):
				n_ally += 1
			if bool((f as Dictionary).get("vassal", false)):
				n_vassal += 1
		_sub.text = "国库 ¥%.0f · 盟友 %d · 附庸 %d" % [
			float(snap.get("money", 0.0)), n_ally, n_vassal]
	if _cards.is_empty():
		_build_list()
	if _dots.is_empty():
		_build_dots()
	else:
		_layout_dots()
	# 卡片的按钮状态跟着钱 / 好感变：重建最省事（13 张卡，几十个控件）
	_build_list()
