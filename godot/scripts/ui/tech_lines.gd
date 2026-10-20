extends Control

# ---------------------------------------------------------------------------
# 科技树的连线层（画布的第一个子节点，所以永远在卡片**下面**）。
#
# 画直角折线：从左侧卡片右缘出来 → 平走到两列中间 → 竖折 → 平走进右侧卡片左缘。
# 这是戴森球计划 / 异星工厂那类科技树最常见的画法，比直线清楚得多 ——
# 直线在几十条交叉时会糊成一团，直角折线一眼能跟到底。
#
# 已研究的前置画绿线、未研究的画淡棕线，于是"我卡在哪"一眼可见。
#
# 「贸易」页按行分类之后，有一条**跨行**的干线：「常设商队」是后面四行第一档的前置，
# 而它自己也在第 0 列 —— 直接竖着画会**横穿中间那几张卡片**（还在卡片底下看不见，
# 看起来就像"加固货箱连着铁箍钱箱"）。所以这种"子节点在左边/正下方"的边改走
# 左边的干线：从父卡片左缘出发 → 往左到干线 → 竖着走 → 再向右进子卡片左缘。
# 边的形状由 `_refresh_lines()` 决定（`kind` 字段），这里只管画。
# ---------------------------------------------------------------------------

const C_DONE := Color(0.28, 0.56, 0.30, 0.90)
const C_TODO := Color(0.60, 0.48, 0.34, 0.55)

## 干线离最左那列卡片的横向距离（像素）。
const BUS_OFFSET := 14.0

var _segs: Array = []


## list: [{ "a": Vector2, "b": Vector2, "done": bool, "bus": bool }, ...]（画布坐标）
func set_edges(list: Array) -> void:
	_segs = list
	queue_redraw()


func _draw() -> void:
	for e in _segs:
		var a: Vector2 = e["a"]
		var b: Vector2 = e["b"]
		var pts: PackedVector2Array
		if bool(e.get("bus", false)):
			# 左边干线：a、b 都是卡片左缘中点，绕到左边再下来
			var busx := maxf(3.0, minf(a.x, b.x) - BUS_OFFSET)
			pts = PackedVector2Array([a, Vector2(busx, a.y), Vector2(busx, b.y), b])
		else:
			var midx := (a.x + b.x) * 0.5
			pts = PackedVector2Array([a, Vector2(midx, a.y), Vector2(midx, b.y), b])
		# antialiased = false：像素画风不要抗锯齿的灰边
		draw_polyline(pts, C_DONE if bool(e["done"]) else C_TODO, 2.0, false)
