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
var recent_logs: Array = []
var _accum := 0.0

func _ready() -> void:
	db = ContentDB.load_all()
	sim = SimCore.new(db)
	sim.new_game("v0.3", 12345)

func set_speed(value: float) -> void:
	speed = value

func set_paused(value: bool) -> void:
	paused = value

func enqueue(actions: Array) -> void:
	sim.enqueue(actions)

func time_string() -> String:
	return "第 %d 天  %02d:00" % [int(sim.s["day"]), int(sim.s["hour"])]

func _process(delta: float) -> void:
	if paused:
		return
	_accum += delta * speed
	var guard := 0
	while _accum >= tick_sec and guard < 128:
		_accum -= tick_sec
		guard += 1
		var prev_day = int(sim.s["day"])
		var logs: Array = sim.tick_hour([])
		for entry in logs:
			recent_logs.append(entry)
		if recent_logs.size() > 60:
			recent_logs = recent_logs.slice(recent_logs.size() - 60)
		hour_ticked.emit()
		if int(sim.s["day"]) != prev_day:
			var hist: Array = sim.s["history"]
			if not hist.is_empty():
				day_settled.emit(hist[hist.size() - 1])
