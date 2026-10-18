class_name SaveManager
extends RefCounted

# 存档：JSON 快照 + 版本号 + 备份恢复。
# 由于仿真确定性，也可只存 (pack, seed, 命令日志) 做回放；此处提供状态快照。

## 存档版本。**3** = 住房加了**单体身份**（`housingUnits`：一栋一个 `h#N`，
## 改建换房型不换 id；`housing` / `privateHousing` 退化成派生计数）。
##
## 用户 2026-10："版本更新，存档不跟之前兼容" —— 这里**不做旧版迁移**，
## 老存档读进来直接拒（`load_into` 版本不符就返回 null，提示由 UI 说）。
## 历史：2 = 任务 schema 2（giver / outro / building_repaired）+ 剧情对话记账 + 城镇中心破旧标记。
const SAVE_VERSION := 4
const DEFAULT_PATH := "user://sovit_save.json"

static func save_to(path: String, sim: SimCore) -> Error:
	var data := {
		"saveVersion": SAVE_VERSION,
		"pack": String(sim.s["pack"]),
		"seed": int(sim.s["seed"]),
		"rngState": sim.rng.state,
		"state": sim.s,
	}
	var json := JSON.stringify(data)
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(json)
	f.close()
	return OK

static func has_save(path: String = DEFAULT_PATH) -> bool:
	return FileAccess.file_exists(path)

static func load_into(path: String, db: ContentDB) -> SimCore:
	if not FileAccess.file_exists(path):
		return null
	var txt := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(txt)
	if data == null or int(data.get("saveVersion", 0)) != SAVE_VERSION:
		push_error("SaveManager: 存档缺失或版本不符")
		return null
	if not data.has("state"):
		push_error("SaveManager: 存档损坏")
		return null
	var sim := SimCore.new(db)
	sim.s = data["state"]
	sim.rng = Rng.new(int(data["rngState"]))
	_sanitize(sim.s, db)
	return sim

# JSON 把整数读成 float；把需要为整数的字段还原（其余访问处已用 int()/float() 包裹）。
static func _sanitize(s: Dictionary, db: ContentDB) -> void:
	s["day"] = int(s.get("day", 0))
	s["hour"] = int(s.get("hour", 0))
	# 施工当日预算 + 已投累计（见 docs/spec.md §9.3）。旧存档没有这两个键：
	# 预算兜 0（黎明 `_plan_construction_day` 会立刻重算，白天不再每小时现算），
	# 累计兜 0（不然 tick 里第一次 += 会炸）。
	s["constructionRateToday"] = float(s.get("constructionRateToday", 0.0))
	s["constructionWorkToday"] = float(s.get("constructionWorkToday", 0.0))
	# 科研当日预算 + 已投累计（见 docs/spec.md §10.3）。旧存档没有这两个键：
	# 预算兜 0（黎明 `_plan_research_day` 会立刻重算），累计兜 0。
	s["researchRateToday"] = float(s.get("researchRateToday", 0.0))
	s["researchWorkToday"] = float(s.get("researchWorkToday", 0.0))
	s["arrivals"] = int(s.get("arrivals", 0))
	s["seed"] = int(s.get("seed", 0))
	s["rngState"] = int(s.get("rngState", 0))
	if not (s.get("pending", null) is Array):
		s["pending"] = []
	if not (s.get("reserved", null) is Dictionary):
		s["reserved"] = {}
	if not (s.get("goods", null) is Dictionary):
		s["goods"] = {}
	if not (s.get("housing", null) is Dictionary):
		s["housing"] = {}
	if not (s.get("privateHousing", null) is Dictionary):
		s["privateHousing"] = {}
	if not (s.get("prices", null) is Dictionary):
		s["prices"] = {}
	if not (s.get("shops", null) is Array):
		s["shops"] = []
	if not (s.get("residents", null) is Array):
		s["residents"] = []
	if not (s.get("construction", null) is Array):
		s["construction"] = []
	# 公告日志（`s["log"]`，逐小时累积，见 sim_core.tick_hour）。缺了的话公告页会读空。
	if not (s.get("log", null) is Array):
		s["log"] = []
	# JSON 把所有数字读成 float：`day` 还原成 int（否则公告页写出来是「[D3.0]」，两边实现也不一致）
	for entry in s["log"]:
		entry["day"] = int(entry.get("day", 0))
		entry["kind"] = String(entry.get("kind", ""))
		entry["text"] = String(entry.get("text", ""))
	for shop in s["shops"]:
		shop["level"] = int(shop.get("level", 1))
		shop["targetWorkers"] = int(shop.get("targetWorkers", 0))
		shop["planned"] = float(shop.get("planned", 0.0))
	for c in s["construction"]:
		# 旧存档是「逐项倒计时（daysLeft/totalDays）」，新模型是「队列 + 建造力（remaining）」
		if c.has("remaining"):
			c["remaining"] = float(c.get("remaining", 0.0))
		else:
			# 迁移：把剩余天数换成剩余建造力（用当前建筑的 buildWork 折算）
			var bwork = 0.0
			var bid = String(c.get("buildingId", ""))
			if bid != "" and db.buildings.has(bid) and db.buildings[bid].has("buildWork"):
				bwork = float(db.buildings[bid]["buildWork"])
			var hid = String(c.get("housingId", ""))
			if hid != "" and db.housing.has(hid) and db.housing[hid].has("buildWork"):
				bwork = float(db.housing[hid]["buildWork"])
			c["remaining"] = SimUtil.r2(bwork * maxf(0.0, float(c.get("daysLeft", 0))))
		c["totalRequired"] = float(c.get("totalRequired", c["remaining"]))
		c["started"] = bool(c.get("started", true))
		c.erase("daysLeft")
		c.erase("totalDays")
	var gov = s.get("government", {})
	gov["money"] = float(gov.get("money", 0.0))
	# 旧存档的「移民放行（每回合上限）」已换成「人口上限」。迁移时把旧上限当人口上限用：
	# 语义相近（都是"别再进人了"），且默认不限时两者都是 1e9。
	if gov.has("populationCap"):
		gov["populationCap"] = float(gov.get("populationCap", 1000000000.0))
	elif gov.has("immigrationAllowance"):
		gov["populationCap"] = float(gov["immigrationAllowance"])
	else:
		gov["populationCap"] = 1000000000.0
	gov.erase("immigrationAllowance")
	if not (gov.get("taxBrackets", null) is Array):
		gov["taxBrackets"] = []
	# 任务（引导系统，见 docs/quests.md）：2026-10 之前的存档没有这个字段。
	# `done` / `chapters` 的键是 id（字符串）、值是完成日（JSON 读回来是 float → 还原 int）。
	if not (s.get("quests", null) is Dictionary):
		s["quests"] = {"done": {}, "chapters": {}}
	var qst: Dictionary = s["quests"]
	if not (qst.get("done", null) is Dictionary):
		qst["done"] = {}
	if not (qst.get("chapters", null) is Dictionary):
		qst["chapters"] = {}
	# `shown` = 已经播过的剧情对话（`q:<id>` / `c:<章节>`，用户 2026-10）。
	# 缺了就当"一条都没播过" —— 那只会在读进来的这一局里补播一遍，不改任何数字。
	if not (qst.get("shown", null) is Dictionary):
		qst["shown"] = {}
	for qid in (qst["done"] as Dictionary).keys():
		qst["done"][qid] = int(qst["done"][qid])
	for cid in (qst["chapters"] as Dictionary).keys():
		qst["chapters"][cid] = int(qst["chapters"][cid])
	# 预言家（AI 辅助，见 docs/ai-assist.md §六）：2026-10 之前的存档没有这一段。
	# `lastAskDay` 是"上次问他话是第几天"（-1 = 还没问过），JSON 读回来是 float → 还原 int。
	if not (s.get("prophet", null) is Dictionary):
		s["prophet"] = {"lastAskDay": -1}
	else:
		var pr: Dictionary = s["prophet"]
		pr["lastAskDay"] = int(pr.get("lastAskDay", -1))
		s["prophet"] = pr
	# 城镇中心"破旧"标记（用户 2026-10）：**这条功能之前**的存档按"已经修好"处理 ——
	# 那时候的城镇中心本来就是好图，不该读进来突然变废墟。
	# ⚠️ 存档版本已经是 3（住房单体身份 + 剧情对话），旧档根本读不进来；
	# 这一行是给"同版本里手工塞的残缺存档"兜底的。
	if not (s.get("townCenter", null) is Dictionary):
		s["townCenter"] = {"ruined": true}

	# 住房单体（2026-10）：`housingUnits` 是唯一真源，`housing` / `privateHousing` 是派生计数。
	# 残缺存档没有这一段时按计数重建（栋数不会变，只是房号从 h#1 重新发）；
	# 有的话就把两个计数按 units 重算一遍 —— 免得存档里两个数字互相打架。
	if not (s.get("housingUnits", null) is Array):
		var units := []
		var seq := 0
		var counts: Dictionary = s.get("housing", {}) if (s.get("housing", null) is Dictionary) else {}
		for gid in counts.keys():
			var n := int(floor(float(counts[gid])))
			for i in n:
				seq += 1
				units.append({"id": "h#%d" % seq, "type": String(gid), "private": false})
		s["housingUnits"] = units
		s["housingSeq"] = seq
		if not (s.get("privateHousing", null) is Dictionary):
			s["privateHousing"] = {}
	s["housingSeq"] = int(s.get("housingSeq", 0))
	_resync_housing_counts(s)
	# 每种物资的软上限（见 docs/town.md §3.6）：老存档没有这个字段。
	if not (gov.get("storageCaps", null) is Dictionary):
		gov["storageCaps"] = {}
	s["government"] = gov

	# 科技（见 docs/technology.md）：旧存档没有这一段
	if not (s.get("research", null) is Dictionary):
		s["research"] = {"done": [], "queue": []}
	else:
		var r: Dictionary = s["research"]
		if not (r.get("done", null) is Array):
			r["done"] = []
		if not (r.get("queue", null) is Array):
			r["queue"] = []
		for p in r["queue"]:
			p["remaining"] = float(p.get("remaining", 0.0))
			p["totalRequired"] = float(p.get("totalRequired", p["remaining"]))
			p["started"] = bool(p.get("started", false))
			p["id"] = String(p.get("id", ""))
	for shop2 in s["shops"]:
		shop2["toolBoost"] = float(shop2.get("toolBoost", 1.0))

## 按 housingUnits 重算 housing / privateHousing（与 SimCore._sync_housing_counts() 同口径）。
## 存档读进来之后调一次：两个计数以 units 为准，别让存档里两组数字互相打架。
static func _resync_housing_counts(s: Dictionary) -> void:
	var counts: Dictionary = s.get("housing", {}) if (s.get("housing", null) is Dictionary) else {}
	var privs: Dictionary = s.get("privateHousing", {}) if (s.get("privateHousing", null) is Dictionary) else {}
	for gid in counts.keys():
		counts[gid] = 0.0
	for gid in privs.keys():
		privs[gid] = 0.0
	for u in (s.get("housingUnits", []) as Array):
		var t := String((u as Dictionary).get("type", ""))
		if t == "":
			continue
		counts[t] = float(counts.get(t, 0.0)) + 1.0
		if bool((u as Dictionary).get("private", false)):
			privs[t] = float(privs.get(t, 0.0)) + 1.0
	s["housing"] = counts
	s["privateHousing"] = privs