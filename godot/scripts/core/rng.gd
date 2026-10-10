class_name Rng
extends RefCounted

# mulberry32 —— 与 TS 的 src/engine/rng.ts 逐位一致。
# GDScript 的 int 是 64 位有符号且无无符号移位，故全程 & 0xFFFFFFFF 掩码。

var state: int

func _init(seed_value: int) -> void:
	state = seed_value & 0xFFFFFFFF

func next() -> float:
	state = (state + 0x6d2b79f5) & 0xFFFFFFFF
	var t: int = state
	t = _imul(t ^ (t >> 15), t | 1)
	t = (t ^ ((t + _imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF
	return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0

# 32 位乘法（低 32 位）；Math.imul 的等价物。
static func _imul(a: int, b: int) -> int:
	return (a * b) & 0xFFFFFFFF
