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
var quests: Dictionary = {}     # id -> QuestDef（任务/引导系统，见 docs/quests.md）
var quest_ids: Array = []
var chapters: Array = []        # [{id, title, reward, outro}]
## `quests.json` 自己的 schema 版本（2 起有 giver / outro / building_repaired）。
## 与 `schema_version`（economy.json，还是 1）分开记，见 docs/quests.md §七。
var quests_schema_version: int = 0
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

	# 任务（引导系统）：字段原样保留（goal 的 type/id/min 由 sim_core 解释），
	# 只把 id 顺序与章节表拉出来。契约见 docs/quests.md。
	var q: Dictionary = _read_json("quests.json")
	quests_schema_version = int(q.get("schemaVersion", 0))
	for ch in q.get("chapters", []):
		# `outro` = 章节完成时那段 galgame 对话（说话人 + 立绘 + 逐行台词 + 可选选项）。
		# 结构与任务发布对话同形，所以这里**原样**留着，由 sim_core 摊给 UI。
		chapters.append({
			"id": int(ch["id"]),
			"title": String(ch["title"]),
			"reward": float(ch["reward"]),
			"outro": ch.get("outro", {}),
		})
	for it in q.get("quests", []):
		var qid := String(it["id"])
		quests[qid] = {
			"id": qid,
			"chapter": int(it["chapter"]),
			# 发布人 + 立绘（用户 2026-10）：任务一出现就弹一段对话，说话的就是这位。
			"giver": String(it.get("giver", "")),
			"giverPortrait": String(it.get("giverPortrait", "")),
			"title": String(it["title"]),
			"hint": String(it["hint"]),
			# 「为什么要做这一条」——任务面板右侧的描述（老臣塞巴斯蒂安的口吻）。
			# 与 `hint` 分工：`hint` 说怎么点，`brief` 说为什么值当。
			# ⚠️ 任务触发的那段对话也是拿它**逐句**说的，所以它得是能念的台词。
			"brief": String(it.get("brief", "")),
			"reward": float(it["reward"]),
			"requires": it.get("requires", []),
			"goals": it["goals"],
			"side": bool(it.get("side", false)),
		}
		quest_ids.append(qid)

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

# ---- 建造栏分组 -------------------------------------------------------------
# ⚠️ **唯一定义在这里**（原先是 `build_bar.gd::_category_of` 的私有实现）。
# 为什么搬过来：AI 辅助（`scripts/sim/advisor.gd`）要说出"在建造栏哪一页建"，
# 而它是 sim 层、**不许**引用 UI。同一套分组写两份必然漂 —— 于是把它做成
# 内容层的纯函数，`build_bar` 与 `advisor` 都调它。
#
# 分组规则（按顺序判，先中先得）：
#   · 住房 → 「住宅」
#   · 白名单 → 「娱乐」/「矿场」/「市政」（这三个靠 id，推不出来）
#   · `art.arch` = field → 「农场」，= extract → 「矿场」
#   · 主产出属于 food 类 → 「食品加工」
#   · 其余 → 「工业」

## 「娱乐」页：产出不是食物，但归到娱乐。
const CAT_ENTERTAINMENT := ["theater", "domestic_service"]
## 「矿场」页里的采集业（产出是原料，按 arch 也推得出来，但狩猎/捕鱼要显式归位）。
const CAT_MINING := ["lumberjack", "quarry", "clay_pit", "iron_mine", "coal_mine", "hunting_camp", "fishery"]
## 地形 key → 中文。建造栏 tooltip 的「需地形：…」用它（2026-10 加了铁矿）。
const TERRAIN_ZH := {"grass": "草地", "forest": "林地", "stone": "石矿", "clay": "粘土", "iron": "铁矿", "coal": "煤矿", "water": "水面"}
## 「市政」页：仓库 / 建筑工坊 / 研究所 —— 别让它们掉进「工业」。
const CAT_CIVIC := ["warehouse", "construction_works", "research_institute"]

## 地图上**固定存在**的建筑，不进建造列表。
##
## 城镇中心是开局就在地图中央的那一座（`world_view._build_town_center()` 画的），
## 它的 shop 实例在 world_view 的同步里被**专门跳过**（不然会多画一张精灵）。
## 于是"再建一座"会得到：材料照扣、精灵不画 —— 一个**看不见的建筑**。
## 所以建造栏把它挡掉；AI 辅助的"可建清单"也照这份挡
## （不然模型会建议"再建一座城镇中心"）。
const MAP_FIXED := ["town_center"]

func build_category(id: String) -> String:
	if housing.has(id):
		return "住宅"
	if CAT_ENTERTAINMENT.has(id):
		return "娱乐"
	if CAT_MINING.has(id):
		return "矿场"
	if CAT_CIVIC.has(id):
		return "市政"
	var b: Dictionary = buildings.get(id, {})
	var a: Dictionary = b.get("art", {})
	var arch := String(a.get("arch", ""))
	if arch == "field":
		return "农场"
	if arch == "extract":
		return "矿场"
	if primary_output_is_food(b):
		return "食品加工"
	return "工业"

## 主产出（产出量最大的那个商品）是不是食物类。
## 按产出商品判类，而不是靠建筑 id 白名单 —— 新增建筑只要配方对就自动归位。
func primary_output_is_food(b: Dictionary) -> bool:
	var rec: Dictionary = recipes.get(String(b.get("recipe", "")), {})
	var out: Dictionary = rec.get("output", {})
	var best := ""
	var best_q := 0.0
	for g in out.keys():
		if float(out[g]) > best_q:
			best_q = float(out[g])
			best = String(g)
	if best == "":
		return false
	var gd: Dictionary = goods.get(best, {})
	return String(gd.get("category", "")) == "food"

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
