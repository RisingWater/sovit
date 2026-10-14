extends Control

# ---------------------------------------------------------------------------
# 科技树的连线层（画布的第一个子节点，所以永远在卡片**下面**）。
#
# 画直角折线：从左侧卡片右缘出来 → 平走到两列中间 → 竖折 → 平走进右侧卡片左缘。
# 这是戴森球计划 / 异星工厂那类科技树最常见的画法，比直线清楚得多 ——
# 直线在几十条交叉时会糊成一团，直角折线一眼能跟到底。
#
# 已研究的前置画绿线、未研究的画淡棕线，于是"我卡在哪"一眼可见。
# ---------------------------------------------------------------------------

const C_DONE := Color(0.28, 0.56, 0.30, 0.90)
const C_TODO := Color(0.60, 0.48, 0.34, 0.55)

var _segs: Array = []


## list: [{ "a": Vector2, "b": Vector2, "done": bool }, ...]（画布坐标）
func set_edges(list: Array) -> void:
	_segs = list
	queue_redraw()


func _draw() -> void:
	for e in _segs:
		var a: Vector2 = e["a"]
		var b: Vector2 = e["b"]
		var midx := (a.x + b.x) * 0.5
		var pts := PackedVector2Array([
			a, Vector2(midx, a.y), Vector2(midx, b.y), b,
		])
		# antialiased = false：像素画风不要抗锯齿的灰边
		draw_polyline(pts, C_DONE if bool(e["done"]) else C_TODO, 2.0, false)
