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
		buildings[String(it["id"])] = {
			"id": String(it["id"]),
			"nameZh": String(it["nameZh"]),
			"tier": int(it["tier"]),
			"workers": int(it["workers"]),
			"maxWorkers": int(it.get("maxWorkers", it["workers"])),
			"recipe": rid,
			"buildCost": it.get("buildCost", {}),
		}

	var c: Dictionary = _read_json("classes.json")
	for it in c["classes"]:
		classes[String(it["id"])] = it

	var h: Dictionary = _read_json("housing.json")
	for it in h["housing"]:
		housing[String(it["id"])] = it

	var p: Dictionary = _read_json("packs.json")
	for it in p["packs"]:
		packs[String(it["id"])] = it

	var e: Dictionary = _read_json("economy.json")
	schema_version = int(e.get("schemaVersion", 0))
	economy = e["economy"]
	defaults = e["defaults"]
	tuning = e["tuning"]
	time = e["time"]

func is_luxury(gid: String) -> bool:
	var g = goods.get(gid, null)
	return g != null and bool(g.get("luxury", false))
