class_name Chart
extends Control

# 折线图控件。用 Control._draw() 画，不依赖任何外部资源。
#
#   var c := Chart.new()
#   c.custom_minimum_size = Vector2(0, 90)
#   c.set_data("人口", [{"name": "人口", "color": Color(...), "values": [1,2,3]}])
#
# 支持多条线、0 基线、面积填充、最小/最大值标注。

const PAD_L := 44.0
const PAD_R := 6.0
## 顶部留白要放得下"标题 + 图例"那一行：标题基线在 y=11（字高到 ~14 像素），
## y 轴**第一个刻度数字**画在 `plot.y + 3.5`。原来 PAD_T=16 → 那个数字落在 y≈19.5，
## 字的上半截直接压到标题上（实测截图里 "69" 与「人口 / 就业」撞在一起）。
const PAD_T := 28.0
const PAD_B := 12.0

var title := ""
var series: Array = []        # [{name: String, color: Color, values: Array, fill: bool}]
var show_zero := false        # 金额/净额类：画 0 基线
var fmt := "%.0f"
var y_min := 0.0
var y_max := 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false

func set_data(t: String, s: Array, zero_line: bool = false, value_fmt: String = "%.0f") -> void:
	title = t
	series = s
	show_zero = zero_line
	fmt = value_fmt
	_recalc()
	queue_redraw()

func _recalc() -> void:
	var lo := INF
	var hi := -INF
	for se in series:
		for v in (se.get("values", []) as Array):
			lo = minf(lo, float(v))
			hi = maxf(hi, float(v))
	if lo == INF:
		lo = 0.0
		hi = 1.0
	if show_zero:
		lo = minf(lo, 0.0)
		hi = maxf(hi, 0.0)
	if is_equal_approx(lo, hi):
		hi = lo + 1.0
	# 上下留 8% 余量
	var pad := (hi - lo) * 0.08
	y_min = lo - pad
	y_max = hi + pad

func _font() -> Font:
	return UIKit.pixel_font()

func _y2px(v: float, top: float, h: float) -> float:
	return top + h - (v - y_min) / maxf(0.0001, y_max - y_min) * h

func _draw() -> void:
	var f := _font()
	var fs := 10
	var full := Rect2(Vector2.ZERO, size)

	# 底
	draw_rect(full, Color(0.16, 0.13, 0.11, 0.30))
	draw_rect(full, Color(0.36, 0.26, 0.18, 0.55), false, 1.0)

	var plot := Rect2(PAD_L, PAD_T, maxf(1.0, size.x - PAD_L - PAD_R), maxf(1.0, size.y - PAD_T - PAD_B))

	# 水平网格 + y 轴刻度
	for i in 3:
		var v := y_min + (y_max - y_min) * (float(i) / 2.0)
		var y := _y2px(v, plot.position.y, plot.size.y)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y),
			Color(0.5, 0.42, 0.34, 0.25), 1.0)
		var txt := fmt % v
		var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2(plot.position.x - 4.0 - tw, y + 3.5), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.85, 0.80, 0.72))

	# 0 基线（金额类）
	if show_zero and y_min < 0.0 and y_max > 0.0:
		var yz := _y2px(0.0, plot.position.y, plot.size.y)
		draw_line(Vector2(plot.position.x, yz), Vector2(plot.end.x, yz),
			Color(0.85, 0.70, 0.45, 0.55), 1.0)

	# 曲线
	for se in series:
		var vals: Array = se.get("values", [])
		if vals.is_empty():
			continue
		var pts := PackedVector2Array()
		var n := vals.size()
		for i in n:
			var x := plot.position.x if n == 1 else plot.position.x + plot.size.x * (float(i) / float(n - 1))
			pts.append(Vector2(x, _y2px(float(vals[i]), plot.position.y, plot.size.y)))
		var col: Color = se.get("color", Color.WHITE)
		if bool(se.get("fill", false)) and pts.size() >= 2:
			var poly := PackedVector2Array(pts)
			poly.append(Vector2(pts[pts.size() - 1].x, plot.end.y))
			poly.append(Vector2(pts[0].x, plot.end.y))
			draw_colored_polygon(poly, Color(col.r, col.g, col.b, 0.20))
		if pts.size() >= 2:
			draw_polyline(pts, col, 1.6, true)
		else:
			draw_circle(pts[0], 2.0, col)

	# 标题 + 图例
	draw_string(f, Vector2(4, 11), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.98, 0.94, 0.86))
	var lx := 4.0 + f.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 10.0
	for se in series:
		var vals: Array = se.get("values", [])
		var cur := fmt % float(vals[vals.size() - 1]) if not vals.is_empty() else "--"
		var name := String(se.get("name", ""))
		var col: Color = se.get("color", Color.WHITE)
		draw_rect(Rect2(lx, 4, 6, 6), col)
		var txt := "%s %s" % [name, cur]
		draw_string(f, Vector2(lx + 9, 11), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.88, 0.84, 0.76))
		lx += 9.0 + f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 12.0
