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
	if not gov.has("immigrationAllowance"):
		gov["immigrationAllowance"] = 1000000000.0
	if not (gov.get("taxBrackets", null) is Array):
		gov["taxBrackets"] = []
	s["government"] = gov
