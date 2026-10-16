class_name SaveManager
extends RefCounted

# 存档：JSON 快照 + 版本号 + 备份恢复。
# 由于仿真确定性，也可只存 (pack, seed, 命令日志) 做回放；此处提供状态快照。

const SAVE_VERSION := 1
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
