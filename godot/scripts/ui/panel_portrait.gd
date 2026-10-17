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
## 面板内边距（右 / 下）。面板的 content_margin 把子节点往里挤了一圈，
## 立绘又画在这个被挤小的矩形里 —— 不把它加回去，图就**离面板边还有一条 padding**
## （用户 2026-10："下底边要贴着面板下沿，现在有一个 padding"）。
var edge_pad := Vector2.ZERO
## 立绘左边那个说话气泡（用户 2026-10）。跟着面板打开时冒一句。
var bubble: PanelBubble
var sim = null
## 气泡和立绘之间的空隙
const BUBBLE_GAP := 14.0
## 气泡的**竖位置**：对准立绘的**肩膀**（从立绘顶边往下 0.36 个立绘高）。
## ⚠️ 一开始是"底边和立绘底边齐平"—— 用户 2026-10 一眼看穿："气泡不要贴底啊，
## 大概中偏上，大概在立绘肩膀的位置，你这个不是用屁股说话吗？"
## 立绘是半身像，头在上三分之一、肩在 0.3~0.4 之间，所以按这个比例摆。
const BUBBLE_SHOULDER := 0.36

func setup(pid: String, sim_ref = null) -> void:
	# 换人（统计面板切页签）时把上一位的气泡收掉，否则会挂着别人的话
	if pid != id and bubble != null:
		bubble.visible = false
	id = pid
	sim = sim_ref
	tex = null
	if pid != "":
		var path := "res://assets/portraits/%s.png" % pid
		if ResourceLoader.exists(path):
			tex = load(path)
	# 立绘是**照片级**的美术，不是像素图：项目默认的最近邻过滤会把它画成一格一格的。
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_read_pad()
	queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_read_pad()

	# 气泡是**子节点**：父节点画完才轮到它，所以永远压在立绘上面。
	bubble = PanelBubble.new()
	bubble.name = "Bubble"
	add_child(bubble)
	bubble.resized.connect(_place_bubble)
	# ⚠️ 立绘自己的尺寸是面板排版时才知道的（`_ready` 那一刻还是 0）。尺寸一变就重摆，
	# 否则气泡会摆到 (0,0) 左边去 —— 第一次实测就是这么飘到画外的。
	resized.connect(_place_bubble)

## 从**父节点**（那个 PanelContainer）的 panel 样式盒里读内边距。
## 注意不能问自己：`panel` 这个覆盖是挂在 PanelContainer 身上的，子节点问不到。
func _read_pad() -> void:
	var p := get_parent() as Control
	if p == null:
		return
	var sb := p.get_theme_stylebox("panel")
	if sb == null:
		return
	edge_pad = Vector2(sb.get_margin(SIDE_RIGHT), sb.get_margin(SIDE_BOTTOM))

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
	# 底边 / 右边**贴住面板的边**：把面板的内边距加回去（见 edge_pad 的注释）。
	draw_texture_rect(tex,
		Rect2(size.x + edge_pad.x - tw, size.y + edge_pad.y - th, tw, th), false)

# ---------------------------------------------------------------------------
# 说话气泡
# ---------------------------------------------------------------------------
## 冒一句（面板每次打开时调一次）。台词按**当前情况**从 `AdvisorLines` 里挑。
func speak() -> void:
	if bubble == null or id == "":
		return
	var key := AdvisorLines.context_key(sim)
	var text := AdvisorLines.pick(id, key)
	if text == "":
		bubble.visible = false
		return
	bubble.say(text)
	# 气泡的尺寸要等一帧（autowrap 之后才知道多高）—— 它会发 `resized`，那一刻再摆位。
	_place_bubble()

## 气泡贴在立绘**左边**、底边和立绘的底边齐平。
func _place_bubble() -> void:
	if bubble == null or not bubble.visible or tex == null:
		return
	# 面板还没排版（size 是 0）时先不动 —— 排完会发 `resized` 再来一次
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var th := size.y * HEIGHT_RATIO
	var tw := th * tex.get_width() / maxf(1.0, tex.get_height())
	var px := size.x + edge_pad.x - tw
	var py := size.y + edge_pad.y - th
	# 立绘特别宽（窗口接近正方形时）左边就没地方了 —— 至少不许被顶到面板外面去
	var bx := maxf(px - bubble.size.x - BUBBLE_GAP, 8.0)
	# 竖着对准肩膀，气泡**中心**落在肩线上（"从肩膀旁边说话"，不是从脚底）
	var by := py + th * BUBBLE_SHOULDER - bubble.size.y * 0.5
	by = clampf(by, py + 8.0, py + th - bubble.size.y - 8.0)
	bubble.position = Vector2(bx, by)
