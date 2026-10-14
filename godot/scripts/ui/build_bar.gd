extends PanelContainer

# 底栏：Tab 式建造目录。
#
#   [住宅][农场][矿场][工业][娱乐][其它]
#   <该分类的建筑按钮...>                  < 1/3 >
#
# 分类由建筑的 art.arch 推导，所以新增建筑只要填 art 就自动归类。

var runner: SimRunner
var world: Node

const TABS := ["住宅", "农场", "食品加工", "矿场", "工业", "娱乐", "其它"]
# 这两个虽然产出不是食物，但归到「娱乐」
const ENTERTAINMENT := ["theater", "domestic_service"]
# 采掘业白名单（现在与 art.arch == "extract" 重合，留作显式覆盖的口子）
const MINING := ["lumberjack", "quarry", "clay_pit", "hunting_camp", "fishery"]

var _tab: int = 0
var _page: int = 0
var _tab_btns: Array[Button] = []
var _items: HBoxContainer
var _page_label: Label
var _prev_btn: Button
var _next_btn: Button
var _size_box: OptionButton
var _size_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -UIKit.BOT_H
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_stylebox_override("panel", UIKit.pad(UIKit.hud_box(), 6, 4, 6, 4))

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	add_child(root)

	# --- Tab 行
	var tabrow := HBoxContainer.new()
	tabrow.add_theme_constant_override("separation", 2)
	root.add_child(tabrow)
	for i in TABS.size():
		var b := UIKit.button(TABS[i], true)
		b.pressed.connect(_select_tab.bind(i))
		tabrow.add_child(b)
		_tab_btns.append(b)
	tabrow.add_child(UIKit.spacer())
	# 笔刷尺寸只对「其它」Tab（道路 / 地板）有意义，平时藏起来
	_size_label = UIKit.label("笔刷尺寸", UIKit.FG_LABEL)
	tabrow.add_child(_size_label)
	_size_box = OptionButton.new()
	_size_box.add_theme_font_override("font", UIKit.pixel_font())
	_size_box.add_theme_font_size_override("font_size", UIKit.FS)
	for i in range(1, 6):
		_size_box.add_item("%dx%d" % [i, i], i)
	_size_box.selected = 0
	tabrow.add_child(_size_box)
	_size_label.visible = false
	_size_box.visible = false

	# --- 项目行
	var itemrow := HBoxContainer.new()
	itemrow.add_theme_constant_override("separation", 3)
	root.add_child(itemrow)
	_items = HBoxContainer.new()
	_items.add_theme_constant_override("separation", UIKit.GAP)
	itemrow.add_child(_items)
	itemrow.add_child(UIKit.spacer())
	_prev_btn = UIKit.button("◀", true)
	_prev_btn.pressed.connect(_turn_page.bind(-1))
	itemrow.add_child(_prev_btn)
	_page_label = UIKit.label("1/1", Color(0.78, 0.82, 0.89))
	itemrow.add_child(_page_label)
	_next_btn = UIKit.button("▶", true)
	_next_btn.pressed.connect(_turn_page.bind(1))
	itemrow.add_child(_next_btn)

	_select_tab(0)

func _select_tab(i: int) -> void:
	_tab = i
	UIKit.play_switch()
	_page = 0
	for k in _tab_btns.size():
		_tab_btns[k].add_theme_stylebox_override("normal",
			UIKit.box(UIKit.T_BTN_ACTIVE if k == i else UIKit.T_BTN))
	_rebuild()

func _turn_page(d: int) -> void:
	_page += d
	_rebuild()

# ---------------------------------------------------------------------------
func _category_of(id: String) -> String:
	if runner == null or runner.db == null:
		return "工业"
	if runner.db.housing.has(id):
		return "住宅"
	if ENTERTAINMENT.has(id):
		return "娱乐"
	if MINING.has(id):
		return "矿场"
	var b: Dictionary = runner.db.buildings.get(id, {})
	var a: Dictionary = b.get("art", {})
	var arch := String(a.get("arch", ""))
	if arch == "field":
		return "农场"
	if arch == "extract":
		return "矿场"
	# 食品加工 = 主产出属于 food 类，且不是采集业（渔场/狩猎营地走矿场）
	if _primary_output_is_food(b):
		return "食品加工"
	return "工业"

## 主产出（产出量最大的那个商品）是不是食物类。
## 按产出商品判类，而不是靠建筑 id 白名单 —— 新增建筑只要配方对就自动归位。
func _primary_output_is_food(b: Dictionary) -> bool:
	var rec: Dictionary = runner.db.recipes.get(String(b.get("recipe", "")), {})
	var out: Dictionary = rec.get("output", {})
	var best := ""
	var best_q := 0.0
	for g in out.keys():
		if float(out[g]) > best_q:
			best_q = float(out[g])
			best = String(g)
	if best == "":
		return false
	var gd: Dictionary = runner.db.goods.get(best, {})
	return String(gd.get("category", "")) == "food"

func _ids_of(cat: String) -> Array:
	var out := []
	if runner == null or runner.db == null:
		return out
	var pack: Dictionary = runner.db.packs[String(runner.sim.s["pack"])]
	for id in pack["buildings"]:
		if runner.db.buildings.has(id) and _category_of(String(id)) == cat:
			out.append(String(id))
	for hid in pack["housing"]:
		if runner.db.housing.has(hid) and _category_of(String(hid)) == cat:
			out.append(String(hid))
	return out

func _thumb_for(id: String) -> Texture2D:
	# 统一走 UIKit.thumb 的兜底链（thumbs/ 没有时退回 buildings/）
	return UIKit.thumb(id)

func _name_of(id: String) -> String:
	if runner.db.housing.has(id):
		return String(runner.db.housing[id]["nameZh"])
	return String(runner.db.buildings[id]["nameZh"])

func _cost_text(id: String) -> String:
	var parts := PackedStringArray()
	var b: Dictionary = runner.db.housing.get(id, runner.db.buildings.get(id, {}))
	var tstr := String(b.get("terrain", ""))
	if tstr != "":
		parts.append("需地形：" + tstr)
	for k in (b.get("buildCost", {}) as Dictionary).keys():
		var gid := String(k)
		# 原来直接打印商品 id（"wood x 20"），提示框里一半是英文。
		# 换成中文名；查不到才退回 id。
		var gname := gid
		if runner.db.goods.has(gid):
			gname = String((runner.db.goods[gid] as Dictionary).get("nameZh", gid))
		var amt := float(b["buildCost"][k])
		var amt_txt := str(int(amt)) if is_equal_approx(amt, round(amt)) else "%.1f" % amt
		parts.append("%s × %s" % [gname, amt_txt])
	return "\n".join(parts) if parts.size() > 0 else "无材料消耗"

func _rebuild() -> void:
	if _items == null:
		return
	for c in _items.get_children():
		c.queue_free()

	var cat: String = TABS[_tab]
	# 笔刷尺寸只在最后一个 Tab（其它 = 道路/地板）显示
	var is_brush: bool = cat == "其它"
	if _size_label != null:
		_size_label.visible = is_brush
		_size_box.visible = is_brush
	if cat == "其它":
		_page = 0
		_prev_btn.visible = false
		_next_btn.visible = false
		_page_label.visible = false
		for br in [["道路", "_road", "road", "铺路（免费）"],
				["地板", "_floor", "floor", "砖石铺装：1 石 = 100 格"],
				["清除", "_road", "erase", "把这一格的路面和地板抹掉，恢复成草地"]]:
			var b := UIKit.card(String(br[0]), load("res://assets/thumbs/%s.png" % br[1]))
			b.tooltip_text = String(br[3])
			b.pressed.connect(_on_brush.bind(String(br[2])))
			_items.add_child(b)
		return

	var ids := _ids_of(cat)
	# 每页放得下几张卡片
	var avail := (size.x - 130.0) if size.x > 300.0 else 1100.0
	var per: int = maxi(1, int(avail / float(UIKit.CARD_W + UIKit.GAP)))
	var pages: int = int(ceil(float(ids.size()) / float(per)))
	_page = clampi(_page, 0, maxi(0, pages - 1))
	# 只有一页时不需要翻页 —— 藏掉「◀ 1/1 ▶」，别占位置
	var paging: bool = pages > 1
	_prev_btn.visible = paging
	_next_btn.visible = paging
	_page_label.visible = paging

	for i in range(_page * per, mini(ids.size(), (_page + 1) * per)):
		var id: String = ids[i]
		var b := UIKit.card(_name_of(id), _thumb_for(id))
		if _locked(id):
			# 科技没研究出来：灰显 + 「（锁）」+ 说明缺哪项科技。
			# 刻意**不接** pressed —— 点了什么也不发生（不去跳科技面板，用户明确不要跳转）。
			b.modulate = Color(0.55, 0.55, 0.55, 1.0)
			b.tooltip_text = "需要科技：%s（未研究）\n研究完成后才能建造" % _tech_name(id)
			_mark_locked(b)
		else:
			b.tooltip_text = "%s\n%s" % [_name_of(id), _cost_text(id)]
			b.pressed.connect(_on_build.bind(id))
		_items.add_child(b)

	_page_label.text = "%d/%d" % [_page + 1, maxi(1, pages)]

## 该建筑 / 住房的科技是否还没研究出来。
func _locked(id: String) -> bool:
	if runner == null or runner.sim == null or runner.db == null:
		return false
	if runner.db.housing.has(id):
		return not runner.sim.is_housing_unlocked(id)
	if not runner.db.buildings.has(id):
		return false
	return not runner.sim.is_building_unlocked(id)

## 解锁它所需的科技中文名。
func _tech_name(id: String) -> String:
	var tid := ""
	if runner.db.housing.has(id):
		tid = runner.db.tech_for_housing(id)
	else:
		tid = runner.db.tech_for_building(id)
	if tid == "" or not runner.db.techs.has(tid):
		return "未知"
	return String(runner.db.techs[tid]["nameZh"])

## 在卡片名后面缀「（锁）」。短后缀是为了不撑破 CARD_W=112。
func _mark_locked(b: Button) -> void:
	for c in b.find_children("*", "Label", true, false):
		var l := c as Label
		l.text = "%s（锁）" % l.text
		return

func _on_build(id: String) -> void:
	if world != null:
		world.set_build(id)

func _on_brush(mode: String) -> void:
	if world != null:
		world.set_brush(mode, _brush_size())

func _brush_size() -> int:
	if _size_box == null:
		return 1
	return int(_size_box.get_selected_id())
