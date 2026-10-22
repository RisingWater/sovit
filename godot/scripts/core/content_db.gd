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
var chapters: Array = []        # [{id, title, reward, gapDays, outro}]
## 场次（"不挂任务的戏"，用户 2026-10 · A1）：[ {id, when, speaker, portrait, lines, choices} ]
## 数据源 `content/scenes.json`，判定与播放在 `sim_core.gd`（`_scene_ready` 等）。
var scenes: Array = []
var scene_ids: Array = []
## 商路（B3，用户 2026-10）：`content/routes.json` 的整份内容 ——
## `{distance: [...], caravan: {...}, market: {...}, cities: [...]}`。
## 判定与结算在 `sim_core.gd::_update_routes()`，与 TS `systems/routes.ts` 同口径。
var routes: Dictionary = {}
## 邦交（B4，用户 2026-10）：`content/factions.json` 的整份内容 ——
## `{relation: {bands, capByBand, ...}, factions: [{id, initial, cap, flip, defeat, ...}]}`。
## 判定在 `sim_core.gd` 末尾那段（`faction_band` / `faction_gift` / `_update_factions` 等），
## 与 TS `systems/factions.ts` 同口径。结构校验在 TS 侧（`validate.ts::parseFactions`）。
var factions: Dictionary = {}
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
		# 人口覆盖（2026-10 第二批）：诊所 / 医院 / 学校 / 治安所 / 瞭望台
		if it.has("coverage"):
			bdef["coverage"] = it["coverage"]
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
			# 贸易加成（可选，B3）：{caravans / cargo / purse / haggleBuy / haggleSell}。
			# 聚合方式见 sim_core.gd::tech_bonuses()（商队加法、载货/带钱取最高、议价加法）。
			"trade": it.get("trade", {}),
			# 外交（B4）：`tab: "diplomacy"` 决定进科技面板哪一页；
			# `diplomacy.range` 是外交范围（2 / 4 / 0=全图）。见 docs/diplomacy.md §4.5。
			"tab": String(it.get("tab", "")),
			"diplomacy": it.get("diplomacy", {}),
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
			# 剧情时钟（用户 2026-10 · B1）：上一章领奖那天起再隔几天才开这一章。
			# 缺省 0 = 不闸（章 1–5）；章 6 起填 3–5 的固定值。
			"gapDays": int(ch.get("gapDays", 0)),
			"outro": ch.get("outro", {}),
		})
	for it in q.get("quests", []):
		var qid := String(it["id"])
		# 任务种类（用户 2026-10 · B2）：`main` / `side` / `milestone`。
		# 老内容写的是 `"side": true` —— 两种写法都收，但只留一份真相（`kind`），
		# `side` 由它派生，免得引擎里两处判断打架（TS 校验器也这么归的）。
		var kind := String(it.get("kind", "side" if bool(it.get("side", false)) else "main"))
		quests[qid] = {
			"id": qid,
			"chapter": int(it["chapter"]),
			"kind": kind,
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
			"side": kind == "side",
		}
		quest_ids.append(qid)

	# 场次（用户 2026-10 · A1）：字段原样保留，判定在 sim_core。
	var sc: Dictionary = _read_json("scenes.json")
	for it in sc.get("scenes", []):
		scenes.append({
			"id": String(it["id"]),
			"when": it.get("when", {}),
			"speaker": String(it.get("speaker", "")),
			"portrait": String(it.get("portrait", "")),
			"lines": it.get("lines", []),
			"choices": it.get("choices", []),
		})
		scene_ids.append(String(it["id"]))

	var e: Dictionary = _read_json("economy.json")
	schema_version = int(e.get("schemaVersion", 0))
	economy = e["economy"]
	defaults = e["defaults"]
	tuning = e["tuning"]
	time = e["time"]

	# 商路（B3）：整份原样保留 —— 结构校验在 TS 侧（`validate.ts::parseRoutes`），
	# Godot 这边只需要读，不需要重复校验（`check:routes` 是那道闸）。
	var rt: Dictionary = _read_json("routes.json")
	routes = rt if rt != null else {}
	# 邦交（B4）：同上，整份原样保留（`validate.ts::parseFactions` + `check:factions` 是闸）。
	var fc: Dictionary = _read_json("factions.json")
	factions = fc if fc != null else {}
	routes = rt if rt != null else {}

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
#   · 白名单 → 「娱乐」/「矿场」/「市政」/「医疗」/「军事」/「民生工业」/「重工业」
#   · `art.arch` = field → 「农场」，= extract → 「矿场」
#   · 主产出属于 food 类 → 「食品加工」
#   · 其余 → 「民生工业」（消费者品类的兜底；建材/冶炼那种要显式进 CAT_HEAVY）
#
# ⚠️ 2026-10 用户："工业的建筑太多了，把民生工业（衣服、陶器、瓷器）和重工业（建材，
#    冶炼之类）分成两个 tab"。原来的「工业」页 13 座、要翻两页，于是拆成
#    「民生工业」8 座（布料 → 成衣 → 皮衣 → 陶器 / 瓷窑）与
#    「重工业」5 座（冶炼场 / 砖窑 / 木柴坊 / 石制·铁制工具作坊 —— 工具是别处的上游，
#    不是消费品，所以跟着建材走）。**「工业」这个分类名已经不存在了**：
#    分类名和 `build_bar.TABS` 里的 tab 名必须一一对上，改了这边就得改那边，
#    否则那几座建筑在建造栏里**静默消失**（门槛 `bartab` 会红）。

## 「娱乐」页：产出不是食物，但归到娱乐。
const CAT_ENTERTAINMENT := ["theater", "domestic_service"]
## 「矿场」页里的采集业（产出是原料，按 arch 也推得出来，但狩猎/捕鱼要显式归位）。
const CAT_MINING := ["lumberjack", "quarry", "clay_pit", "iron_mine", "coal_mine", "hunting_camp", "fishery"]
## 地形 key → 中文。建造栏 tooltip 的「需地形：…」用它（2026-10 加了铁矿）。
const TERRAIN_ZH := {"grass": "草地", "forest": "林地", "stone": "石矿", "clay": "粘土", "iron": "铁矿", "coal": "煤矿", "water": "水面"}
## 「医疗」页（2026-10 第二批）：草药 → 药水 → 诊所 / 医院 → 学校。
## 不靠 arch 推：这几座都是 sprite 工坊，按 arch 会掉进「工业」。（历史注释，「工业」已拆）
const CAT_MEDICAL := ["herbal_farm", "potion_workshop", "clinic", "hospital", "school"]
## 「军事」页（2026-10 第二批）：治安所 / 瞭望台 / 武器·盔甲·弓箭作坊。
const CAT_MILITARY := ["guard_station", "watchtower", "weapon_workshop", "armor_workshop", "bow_arrow_workshop"]
## 「市政」页：仓库 / 建筑工坊 / 研究所 / **贸易市场** / **使馆** —— 别让它们掉进工坊那两页。
## 贸易市场 2026-10 从「工业」挪过来：工业页有 14 座、要翻两页，它就藏在第 2 页最后一格，
## 用户的原话是"市场这个建筑没了，这样游商系统的入口在哪里？"—— 市政页只有 4 座，一眼看见。
## 使馆（B4）同理：它是"外交面板的钥匙"，藏在别的页里玩家就找不到面板了。
const CAT_CIVIC := ["warehouse", "construction_works", "research_institute", "trade_market", "embassy"]
## 「民生工业」页（2026-10 拆页）：卖给村民穿衣用饭的那几条链 ——
## 布料（粗织坊 / 细织坊）→ 成衣（粗布衣坊 / 常服坊 / 华服坊 / 皮衣坊），
## 加上陶器坊 / 瓷窑这两座"摆在家里"的。
const CAT_CONSUMER := [
	"coarse_weaver", "fine_weaver",
	"coarse_clothes_shop", "common_clothes_shop", "luxury_clothes_shop", "leather_shop",
	"pottery_works", "porcelain_works",
]
## 「重工业」页（2026-10 拆页）：建材与冶炼 —— 冶炼场 / 砖窑 / 木柴坊，
## 外加**给生产用的工具**（石制工具作坊 / 铁制工具作坊）。
## 工具不是消费品而是别处的上游，所以按"生产资料"归到这里，不跟衣服放一起。
const CAT_HEAVY := ["smeltery", "firewood_works", "brick_kiln", "tool_works", "iron_tool_workshop"]

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
	if CAT_MILITARY.has(id):
		return "军事"
	if CAT_MEDICAL.has(id):
		return "医疗"
	if CAT_CIVIC.has(id):
		return "市政"
	if CAT_CONSUMER.has(id):
		return "民生工业"
	if CAT_HEAVY.has(id):
		return "重工业"
	var b: Dictionary = buildings.get(id, {})
	var a: Dictionary = b.get("art", {})
	var arch := String(a.get("arch", ""))
	if arch == "field":
		return "农场"
	if arch == "extract":
		return "矿场"
	if primary_output_is_food(b):
		return "食品加工"
	return "民生工业"

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

## 公共事业（研究/建造产能 + 医疗/教育/治安/仓储）：工资统一，有补贴。
const PUBLIC_SERVICE := ["town_center", "warehouse", "research_institute", "construction_works",
	"clinic", "hospital", "school", "guard_station", "watchtower"]

## 私营按建筑档次给的默认工资。
const TIER_WAGE := {1: 3.0, 2: 3.6, 3: 4.5, 4: 6.0}

## 新建这座建筑时的默认岗位工资（2026-10 用户："公共事业的工资都一样"）。
## 与 TS `wages.ts::defaultWageFor()` 同口径。
func default_wage(def_id: String) -> float:
	if PUBLIC_SERVICE.has(def_id):
		return float(economy.get("publicServiceWage", 3.6))
	var b: Dictionary = buildings.get(def_id, {})
	var tier := int(b.get("tier", 2))
	return float(TIER_WAGE.get(tier, float(economy["refWage"])))