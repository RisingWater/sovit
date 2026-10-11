extends PanelContainer

# 底栏：Tab 式建造目录。
#
#   [住宅][农场][矿场][工业][娱乐][其它]
#   <该分类的建筑按钮...>                  < 1/3 >
#
# 分类由建筑的 art.arch 推导，所以新增建筑只要填 art 就自动归类。

var runner: SimRunner
var world: Node

const TABS := ["住宅", "农业", "矿场", "工业", "娱乐", "其它"]
# 这两个虽然 arch=workshop，但归到「娱乐」
const ENTERTAINMENT := ["theater", "domestic_service"]
# 矿场（采掘业）：图集里没有对应建筑的产业也走这里
const MINING := ["lumberjack", "quarry", "clay_pit", "hunting_camp", "fishery"]

var _tab: int = 0
var _page: int = 0
var _tab_btns: Array[Button] = []
var _items: HBoxContainer
var _page_label: Label
var _prev_btn: Button
var _next_btn: Button
var _size_box: OptionButton

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
	tabrow.add_child(UIKit.label("笔刷尺寸", UIKit.FG_LABEL))
	_size_box = OptionButton.new()
	_size_box.add_theme_font_override("font", UIKit.pixel_font())
	_size_box.add_theme_font_size_override("font_size", UIKit.FS)
	for i in range(1, 6):
		_size_box.add_item("%dx%d" % [i, i], i)
	_size_box.selected = 0
	tabrow.add_child(_size_box)

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
	var a: Dictionary = runner.db.buildings[id].get("art", {})
	match String(a.get("arch", "")):
		"field":
			return "农业"
		"extract":
			return "矿场"
		_:
			return "工业"

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
	var t: Texture2D = load("res://assets/thumbs/%s.png" % id)
	if t == null:
		t = load("res://assets/buildings/%s.png" % id)
	return t

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
		parts.append("%s x %s" % [k, str(b["buildCost"][k])])
	return "\n".join(parts) if parts.size() > 0 else "无材料消耗"

func _rebuild() -> void:
	if _items == null:
		return
	for c in _items.get_children():
		c.queue_free()

	var cat: String = TABS[_tab]
	if cat == "其它":
		_page = 0
		_prev_btn.visible = false
		_next_btn.visible = false
		_page_label.visible = false
		for br in [["道路", "_road", "road", "铺路（免费）"],
				["地板", "_floor", "floor", "砖石铺装：1 石 = 100 格"]]:
			var b := UIKit.card(String(br[0]), load("res://assets/thumbs/%s.png" % br[1]))
			b.tooltip_text = String(br[3])
			b.pressed.connect(_on_brush.bind(String(br[2])))
			_items.add_child(b)
		return

	_prev_btn.visible = true
	_next_btn.visible = true
	_page_label.visible = true

	var ids := _ids_of(cat)
	# 每页放得下几张卡片
	var avail := (size.x - 130.0) if size.x > 300.0 else 1100.0
	var per: int = maxi(1, int(avail / float(UIKit.CARD_W + UIKit.GAP)))
	var pages: int = int(ceil(float(ids.size()) / float(per)))
	_page = clampi(_page, 0, maxi(0, pages - 1))

	for i in range(_page * per, mini(ids.size(), (_page + 1) * per)):
		var id: String = ids[i]
		var b := UIKit.card(_name_of(id), _thumb_for(id))
		b.tooltip_text = "%s\n%s" % [_name_of(id), _cost_text(id)]
		b.pressed.connect(_on_build.bind(id))
		_items.add_child(b)

	_page_label.text = "%d/%d" % [_page + 1, maxi(1, pages)]

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
