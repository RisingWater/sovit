class_name ContentDB
extends RefCounted

# 加载 res://content/*.json（由 `npm run sync:content` 从仓库根同步），
# 组装成与 TS 引擎一致的内容表。

var goods: Dictionary = {}      # id -> GoodDef
var buildings: Dictionary = {}  # id -> BuildingDef（recipe = "r_<id>"）
var recipes: Dictionary = {}    # id -> RecipeDef
var classes: Dictionary = {}    # id -> ClassDef
var housing: Dictionary = {}    # id -> HousingDef
var packs: Dictionary = {}      # id -> ContentPack
var techs: Dictionary = {}      # id -> TechDef
var tech_ids: Array = []
var eras: Array = []            # [{id, nameZh}]
var economy: Dictionary = {}
var defaults: Dictionary = {}
var tuning: Dictionary = {}
var time: Dictionary = {}
var schema_version: int = 0

static func load_all() -> ContentDB:
	var db := ContentDB.new()
	db._load()
	return db

func _read_json(name: String) -> Variant:
	var path := "res://content/" + name
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("ContentDB: 无法打开 " + path)
		return null
	var txt := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(txt)
	if v == null:
		push_error("ContentDB: JSON 解析失败 " + path)
	return v

func _load() -> void:
	var g: Dictionary = _read_json("goods.json")
	for it in g["goods"]:
		goods[String(it["id"])] = it

	var b: Dictionary = _read_json("buildings.json")
	for it in b["buildings"]:
		var bdef := {
			"id": String(it["id"]),
			"nameZh": String(it["nameZh"]),
			"tier": int(it["tier"]),
			"workers": int(it["workers"]),
			"maxWorkers": int(it.get("maxWorkers", it["workers"])),
			"buildCost": it.get("buildCost", {}),
			# 外观规格：UI 分类与占地都靠它，必须保留
			"art": it.get("art", {}),
		}
		# 配方：产商品的建筑必有；「建筑工坊」这类产出*建造产能*的建筑没有配方
		# （其产出由 docs/construction.md 的产能公式给出），故 recipe 只在存在时写入。
		if it.has("recipe"):
			var rec: Dictionary = it["recipe"]
			var rid := "r_" + String(it["id"])
			recipes[rid] = {
				"id": rid,
				"building": String(it["id"]),
				"inputs": rec.get("inputs", {}),
				"output": rec["output"],
				"baseRate": float(rec["baseRate"]),
				"fuel": float(rec.get("fuel", 0.0)),
			}
			bdef["recipe"] = rid
		# 施工工时（建造力 / 人·天）。设计见 docs/construction.md
		if it.has("buildWork"):
			bdef["buildWork"] = int(it["buildWork"])
		# 产能参数（建筑工坊 / 研究所）：不产商品、只产每日产能。见 docs/technology.md §6.2
		if it.has("capacity"):
			bdef["capacity"] = it["capacity"]
		# terrain 只在存在时写入，避免 has("terrain") 永远为真
		if it.has("terrain"):
			bdef["terrain"] = String(it["terrain"])
		buildings[String(it["id"])] = bdef

	var c: Dictionary = _read_json("classes.json")
	for it in c["classes"]:
		classes[String(it["id"])] = it

	var h: Dictionary = _read_json("housing.json")
	for it in h["housing"]:
		housing[String(it["id"])] = it

	var p: Dictionary = _read_json("packs.json")
	for it in p["packs"]:
		packs[String(it["id"])] = it

	# 科技树（见 docs/technology.md）。era 只是 UI 分组用的标签。
	var t: Dictionary = _read_json("technologies.json")
	for it in t["eras"]:
		eras.append({"id": int(it["id"]), "nameZh": String(it["nameZh"])})
	for it in t["technologies"]:
		var tid := String(it["id"])
		var cost: Dictionary = it.get("cost", {})
		var unlocks: Dictionary = it.get("unlocks", {})
		techs[tid] = {
			"id": tid,
			"nameZh": String(it["nameZh"]),
			"era": int(it["era"]),
			"research": float(it["research"]),
			"cost": {"goods": cost.get("goods", {})},
			"requires": it.get("requires", []),
			"unlocks": {
				"buildings": unlocks.get("buildings", []),
				"housing": unlocks.get("housing", []),
			},
		}
		tech_ids.append(tid)

	var e: Dictionary = _read_json("economy.json")
	schema_version = int(e.get("schemaVersion", 0))
	economy = e["economy"]
	defaults = e["defaults"]
	tuning = e["tuning"]
	time = e["time"]

func is_luxury(gid: String) -> bool:
	var g = goods.get(gid, null)
	return g != null and bool(g.get("luxury", false))

## 解锁某建筑的科技 id；返回 "" 表示没有科技锁（开局即可建）。
func tech_for_building(bid: String) -> String:
	for tid in tech_ids:
		if (techs[tid]["unlocks"]["buildings"] as Array).has(bid):
			return tid
	return ""

## 解锁某种住房的科技 id；"" = 开局即可建。
func tech_for_housing(hid: String) -> String:
	for tid in tech_ids:
		if (techs[tid]["unlocks"]["housing"] as Array).has(hid):
			return tid
	return ""

## 某商品的工具加成；0 = 不是工具商品。
func tool_bonus(gid: String) -> float:
	var g = goods.get(gid, null)
	if g == null:
		return 0.0
	return float(g.get("toolBonus", 0.0))
