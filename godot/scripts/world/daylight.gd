extends Node

# 昼夜光影：用一个 CanvasModulate 给整个世界调色。
#
# 关键点：CanvasModulate 只影响**它所在的 canvas**。本节点挂在 main（默认 canvas，
# 也就是世界所在的那层），而 UI 和建筑名标签在各自的 CanvasLayer 上 ——
# 所以夜里世界变暗、UI 与标签保持原样，不会看不清。
#
# 过渡是连续的：sim 的 hour 是整数，但 SimRunner._accum / tick_sec 给出"当前这个
# 游戏小时走了多少"，加起来就是 0..24 的连续时间，据此在关键帧之间插值。
# 暂停时不推进（时间冻结，光照也冻结）。

## [游戏小时, 颜色] 关键帧，必须按小时升序，首尾各有一个哨兵。
## 颜色是**乘算**的：白色 = 原色调。
const KEYS: Array = [
	[0.0, Color(0.44, 0.49, 0.72)],    # 深夜：偏蓝紫压暗
	[4.0, Color(0.44, 0.49, 0.72)],    # 仍是深夜
	[5.5, Color(0.62, 0.56, 0.74)],    # 拂晓：冷紫过渡
	[6.5, Color(1.00, 0.86, 0.62)],    # 日出：金黄
	[8.0, Color(1.00, 1.00, 1.00)],    # 白天：原色调
	[16.0, Color(1.00, 1.00, 1.00)],   # 白天
	[17.5, Color(1.00, 0.88, 0.64)],   # 黄昏：金黄
	[19.0, Color(0.94, 0.72, 0.56)],   # 日落：偏橙
	[20.5, Color(0.66, 0.58, 0.72)],   # 入夜：冷暖交界
	[22.0, Color(0.44, 0.49, 0.72)],   # 深夜
	[24.0, Color(0.44, 0.49, 0.72)],   # 回到 0 点
]

var runner: SimRunner
var _mod: CanvasModulate

func setup(r: SimRunner) -> void:
	runner = r

func _ready() -> void:
	_mod = CanvasModulate.new()
	_mod.name = "DaylightModulate"
	_mod.color = KEYS[0][1]
	add_child(_mod)

## 供测试 / 外部查询：给定连续小时（0..24）返回该时刻的色调
func color_at(hour: float) -> Color:
	var h := fposmod(hour, 24.0)
	for i in range(KEYS.size() - 1):
		var a: Array = KEYS[i]
		var b: Array = KEYS[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var span := float(b[0]) - float(a[0])
			var t := 0.0 if span <= 0.0 else (h - float(a[0])) / span
			return (a[1] as Color).lerp(b[1] as Color, t)
	return KEYS[0][1]

## 当前连续小时：整数小时 + 本小时已走的比例
func current_hour() -> float:
	if runner == null or runner.sim == null:
		return 0.0
	var h := float(int(runner.sim.s["hour"]))
	if not runner.paused and runner.tick_sec > 0.0:
		h += clampf(runner._accum / runner.tick_sec, 0.0, 1.0)
	return fposmod(h, 24.0)

func _process(_delta: float) -> void:
	if _mod == null or runner == null or runner.sim == null:
		return
	_mod.color = color_at(current_hour())
