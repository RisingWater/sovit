class_name SimRunner
extends Node

# 表现层的仿真驱动：固定步长累加器，把「界面帧」与「仿真小时」解耦。
# 只持有 SimCore，不含任何经济逻辑。

signal hour_ticked
signal day_settled(snapshot: Dictionary)

@export var tick_sec := 5.0
@export var speed := 1.0
@export var paused := false

var db: ContentDB
var sim: SimCore
var _accum := 0.0

func _ready() -> void:
	db = ContentDB.load_all()
	sim = SimCore.new(db)
	sim.new_game("v0.3", 12345)
	tick_sec = float(db.time.get("tickSec", 5.0))

func set_speed(value: float) -> void:
	speed = value

func set_paused(value: bool) -> void:
	paused = value

func enqueue(actions: Array) -> void:
	sim.enqueue(actions)

## 顶栏 / tooltip 用的时间字符串（用户 2026-10 · B0：改成 AE 纪元日期）。
## ⚠️ **一个字都不在这里拼**：历法的唯一实现在 `sim_core.gd::date_time_label()`。
func time_string() -> String:
	return sim.date_time_label(int(sim.s["day"]), int(sim.s["hour"]))

func _process(delta: float) -> void:
	if paused:
		return
	_accum += delta * speed
	var guard := 0
	while _accum >= tick_sec and guard < 128:
		_accum -= tick_sec
		guard += 1
		var prev_day = int(sim.s["day"])
		# 公告的日志由仿真自己攒（`sim.s["log"]`，进存档）—— 这里不再抄一份影子副本。
		# 见 `SimCore.tick_hour()` / `SimCore.log_tail()`。
		sim.tick_hour([])
		hour_ticked.emit()
		if int(sim.s["day"]) != prev_day:
			var hist: Array = sim.s["history"]
			if not hist.is_empty():
				day_settled.emit(hist[hist.size() - 1])
