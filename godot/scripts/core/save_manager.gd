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
	_sanitize(sim.s)
	return sim

# JSON 把整数读成 float；把需要为整数的字段还原（其余访问处已用 int()/float() 包裹）。
static func _sanitize(s: Dictionary) -> void:
	s["day"] = int(s["day"])
	s["hour"] = int(s["hour"])
	s["arrivals"] = int(s["arrivals"])
	s["seed"] = int(s["seed"])
	s["rngState"] = int(s.get("rngState", 0))
	if not (s.get("pending", null) is Array):
		s["pending"] = []
	for shop in s.get("shops", []):
		shop["level"] = int(shop["level"])
		shop["targetWorkers"] = int(shop["targetWorkers"])
	for c in s.get("construction", []):
		c["daysLeft"] = int(c["daysLeft"])
		c["totalDays"] = int(c["totalDays"])
