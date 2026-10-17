class_name PanelPortrait
extends Control

# 面板右下角的顾问立绘（用户 2026-10："立绘添加到所有面板上，放在右下角。
# 高度一半面板高度，比例不动。"）。
#
# 为什么是"自绘的 Control"而不是 TextureRect：
#   这几个面板都是 `PanelContainer`，它会把**直接子节点强行拉伸到底**（这个坑踩过好几次）。
#   TextureRect 被拉满之后只有 `STRETCH_KEEP_ASPECT_CENTERED` 可用 —— 那会画在正中间，
#   没有"右下角对齐"这个 stretch 模式。所以这里自己 `_draw()`：拿到被拉满的 size，
#   在里面按 50% 高度 + 原图比例算一个矩形，贴右下角画。
#
# 画在**最上层**（加在内容之后）：立绘是装饰，挡住一点空处无所谓；
# 反过来（垫在文字底下）会让格子里的数字压在脸上，更难看。
# ⚠️ 所以内容那一侧要给右下角留位置 —— 见各面板里 `PORTRAIT_W` 那几处。

## 立绘高度 = 面板高度 × 这个系数（用户定的"一半"）。
const HEIGHT_RATIO := 0.5

var id := ""
var tex: Texture2D

func setup(pid: String) -> void:
	id = pid
	tex = null
	if pid != "":
		var path := "res://assets/portraits/%s.png" % pid
		if ResourceLoader.exists(path):
			tex = load(path)
	# 立绘是**照片级**的美术，不是像素图：项目默认的最近邻过滤会把它画成一格一格的。
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

## 立绘在面板里占的宽度（给内容留位用）。没图时返回 0。
func width_in(panel_h: float) -> float:
	if tex == null or tex.get_height() <= 0.0:
		return 0.0
	return panel_h * HEIGHT_RATIO * tex.get_width() / tex.get_height()

func _draw() -> void:
	if tex == null:
		return
	var th := size.y * HEIGHT_RATIO
	if th <= 1.0:
		return
	var tw := th * tex.get_width() / maxf(1.0, tex.get_height())
	# 底边贴面板底边、右边贴面板右边（留 6px 让它别糊在边框上）
	draw_texture_rect(tex, Rect2(size.x - tw - 6.0, size.y - th, tw, th), false)
