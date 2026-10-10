class_name SimUtil
extends RefCounted

# 与 TS 的 Math.round 行为一致（half 向 +Infinity 舍入），再保留 2 位小数。
static func r2(v: float) -> float:
	return floor(v * 100.0 + 0.5) / 100.0

static func clampf01(v: float) -> float:
	return clampf(v, 0.0, 1.0)
