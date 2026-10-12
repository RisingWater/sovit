extends SceneTree

# 昼夜光影门槛检查。
#
# 判据不是"颜色变化要慢"（日出本来就会变），而是：
#   1. 没有断层 —— 细采样下相邻步进要趋于 0，说明曲线连续（分段线性）
#   2. 白天必须是纯白 —— 用户要求"白天原色调"，一旦不是 1,1,1 就是整体偏色
#   3. 夜里必须真的压暗，且偏蓝
#   4. 日出 / 黄昏必须偏黄（红 > 绿 > 蓝）
#   5. 24 点接回 0 点，否则跨日会跳变

const EPS := 0.012      # 0.01 小时采样下的最大允许步进

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("DAYLIGHT TEST FAIL: ", msg)
	quit(1)

func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

func _run() -> void:
	var d = load("res://scripts/world/daylight.gd").new()
	root.add_child(d)
	await process_frame

	# 1. 连续性：0..24 细采样
	var max_jump := 0.0
	var steps := 2400
	for i in steps:
		var a: Color = d.color_at(24.0 * float(i) / float(steps))
		var b: Color = d.color_at(24.0 * float(i + 1) / float(steps))
		max_jump = maxf(max_jump, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	if max_jump > EPS:
		_fail("曲线有断层：0.01 小时采样下最大步进 %.4f > %.3f" % [max_jump, EPS])
		return

	# 2. 白天纯白（原色调）
	for h in [9.0, 12.0, 15.0]:
		var c: Color = d.color_at(h)
		if absf(c.r - 1.0) > 0.001 or absf(c.g - 1.0) > 0.001 or absf(c.b - 1.0) > 0.001:
			_fail("白天 %.0f 点不是原色调：%s" % [h, c])
			return

	# 3. 夜间明显更暗，且偏蓝
	var night: Color = d.color_at(2.0)
	var day: Color = d.color_at(12.0)
	if _lum(night) >= _lum(day) * 0.8:
		_fail("夜间没有明显压暗：夜亮度 %.3f vs 日亮度 %.3f" % [_lum(night), _lum(day)])
		return
	if night.b <= night.r:
		_fail("夜间应偏蓝：%s" % night)
		return

	# 4. 日出 / 黄昏偏黄
	for h in [6.5, 18.0]:
		var c: Color = d.color_at(h)
		if not (c.r > c.g and c.g > c.b):
			_fail("%.1f 点应偏黄（红>绿>蓝）：%s" % [h, c])
			return

	# 5. 24 点接回 0 点
	var a0: Color = d.color_at(0.0)
	var a24: Color = d.color_at(24.0)
	if maxf(absf(a0.r - a24.r), maxf(absf(a0.g - a24.g), absf(a0.b - a24.b))) > 0.001:
		_fail("24 点没有接回 0 点：%s vs %s" % [a0, a24])
		return

	print("DAYLIGHT TEST 最大步进=%.5f 夜亮度=%.2f 日亮度=%.2f" % [max_jump, _lum(night), _lum(day)])
	print("DAYLIGHT TEST RESULT: PASS")
	quit(0)
