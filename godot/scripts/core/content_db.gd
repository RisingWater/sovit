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
		# 仓储容量（城镇中心 / 仓库）：{storage, storagePerLevel}。见 docs/town.md §3。
		# 只挑固定键组装 bdef，所以漏了这一句就会静默丢掉 —— 容量会变成 0，货被丢光。
		if it.has("storage"):
			bdef["storage"] = it["storage"]
		# 产业归属（agri / goods / material）：效率科技按它给产出加成。
		# 见 docs/spec.md §2.5 与 docs/technology.md。有配方的建筑校验器强制要写。
		if it.has("sector"):
			bdef["sector"] = String(it["sector"])
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
			# 效率加成（可选）：{agri/goods/material/research/build: 加成小数}。
			# 语义与聚合方式见 docs/spec.md（**加法**叠加，不是连乘）。
			"effects": it.get("effects", {}),
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

## 商品 category 的中文名。
##
## category 是**引擎用的英文键**（raw / food / material …），不是给玩家看的词。
## 任何要显示给玩家的地方都必须过这个函数 —— 直接把键印出来会得到「（raw）」这种。
const CATEGORY_ZH := {
	"raw": "原料",
	"food": "食物",
	"material": "材料",
	"clothing": "衣物",
	"household": "家用",
	"fuel": "燃料",
	"service": "服务",
	"entertainment": "娱乐",
	"tool": "工具",
	"housing": "住房",
}

## 取 category 的中文名；未知的 category 原样返回（宁可露出键，也不要显示空白）。
func category_zh(cat: String) -> String:
	return String(CATEGORY_ZH.get(cat, cat))

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

# ---- 门洞声明（art.doors）---------------------------------------------------
## 校验一栋建筑 / 住房的 `art.doors`；返回错误信息数组，空 = 合法。
##
## 语义（与 `src/engine/content/validate.ts::parseArt` 同一份契约）：
##   · `doors` 是一串 `[dx, dy]`，相对**占地左上角**的格偏移；
##   · **第一项是主门** —— 居民实际进出的那一格，屋内落脚格由它推出来；
##   · 缺省（不写）= 占地底边横向居中那一格（`world_view._default_door_offset`）。
##
## 为什么在这里而不是在 world_view 里顺手判：门槛要能**单独**遍历全部内容跑一遍
## 这个校验（包含贴图缺失、占地推导不出来的情况），所以把它做成纯函数。
## `fp` = 该建筑的占地（格），由 `world_view._footprint()` 推出来。
static func validate_doors(art: Dictionary, fp: Vector2i) -> Array:
	var errs: Array = []
	if not art.has("doors"):
		return errs
	var v: Variant = art["doors"]
	if not (v is Array):
		errs.append("art.doors 必须是数组，形如 [[dx, dy], [dx, dy], ...]")
		return errs
	var list: Array = v
	if list.is_empty():
		errs.append("art.doors 不能是空数组（不要门洞就整条省掉）")
		return errs
	var seen := {}
	for i in list.size():
		var d: Variant = list[i]
		if not (d is Array) or (d as Array).size() != 2:
			errs.append("art.doors[%d] 必须是 [dx, dy] 两个整数" % i)
			continue
		var pair: Array = d
		# ⚠️ JSON 里的数字统统是 float：不能只判 `is int`，要看 int() 之后是否等值。
		var ok_num := true
		var xy := Vector2i.ZERO
		for k in 2:
			var n: Variant = pair[k]
			if typeof(n) != TYPE_INT and typeof(n) != TYPE_FLOAT:
				errs.append("art.doors[%d][%d] 必须是整数格偏移" % [i, k])
				ok_num = false
				break
			var f := float(n)
			if float(int(f)) != f:
				errs.append("art.doors[%d][%d] = %s 不是整数格偏移" % [i, k, str(n)])
				ok_num = false
				break
			if k == 0:
				xy.x = int(f)
			else:
				xy.y = int(f)
		if not ok_num:
			continue
		if xy.x < 0 or xy.y < 0 or xy.x >= fp.x or xy.y >= fp.y:
			errs.append("art.doors[%d] = [%d, %d] 越界：占地是 %dx%d，偏移必须落在 0..%d / 0..%d"
				% [i, xy.x, xy.y, fp.x, fp.y, fp.x - 1, fp.y - 1])
			continue
		if seen.has(xy):
			errs.append("art.doors[%d] = [%d, %d] 与前面的门格重复" % [i, xy.x, xy.y])
			continue
		seen[xy] = true
	return errs
