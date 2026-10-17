extends SceneTree

# 标题页门槛。
#
# 查这几件事：
#   1. `assets/ui/logo_title.png` **真的被导入了** —— 贴图尺寸必须等于磁盘上 PNG 的尺寸。
#      踩过：换了 logo 的 PNG 却没跑 `--import`，游戏里照样显示旧图（.import 指向旧的
#      .ctex），而且**什么错都不报**。
#   2. logo 水平居中、不与菜单重叠、整块落在视口内（大窗口与矮窗口各验一遍 ——
#      排版是按"菜单上面的可用高度"反推 logo 宽度的，窗口一矮最容易压到菜单）。
#   3. 上下两条压暗渐变都在、铺满宽。
#   4. 标题页期间世界的建筑名标签藏着（否则一堆「茅屋 / 砖房」飘在 logo 上），
#      `_end_title()` 之后要还回来。
#   5. 窗口标题是 Harvest of Heirs。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("TITLE TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	# ---- 1. 贴图和磁盘上的一致（防"换了图没重新导入"）
	var path := "res://assets/ui/logo_title.png"
	var tex: Texture2D = load(path)
	if tex == null:
		_fail("logo 贴图加载不到：%s" % path)
		return
	var disk := Image.load_from_file(path)
	if disk == null:
		_fail("读不到 logo 的 PNG 源文件：%s" % path)
		return
	if tex.get_size() != Vector2(disk.get_size()):
		_fail("logo 贴图 %s 与源文件 %s 尺寸不一致 —— 换了 PNG 但没跑 --import" % [
			str(tex.get_size()), str(disk.get_size())])
		return

	var title = node.get_node_or_null("TitleLayer/Title")
	if title == null:
		_fail("找不到标题页 TitleLayer/Title")
		return
	if not node.get_node("TitleLayer").visible:
		_fail("开局标题页应该是可见的")
		return

	# ---- 2. 排版（主视口）
	var vp: Vector2 = root.get_visible_rect().size
	var logo = title.get_node_or_null("Logo")
	_assert_layout(title, vp, "主视口")

	# ---- 3. 渐变：两条铺满宽的 TextureRect（渐变纹理）
	var scrims := 0
	for c in title.get_children():
		var tr := c as TextureRect
		if tr != null and tr.texture is GradientTexture2D:
			scrims += 1
			if absf(tr.size.x - vp.x) > 1.0:
				_fail("压暗渐变没有铺满宽（%.1f / %.1f）" % [tr.size.x, vp.x])
				return
	if scrims != 2:
		_fail("上下压暗的渐变应该有 2 条，实际 %d 条" % scrims)
		return

	# ---- 4. 世界的建筑名标签
	var world = node.get_node_or_null("World")
	if world == null:
		_fail("找不到 World")
		return
	if world.label_layer != null and world.label_layer.visible:
		_fail("标题页期间世界里的建筑名标签应该是藏着的")
		return
	node._end_title()
	await process_frame
	if world.label_layer != null and not world.label_layer.visible:
		_fail("_end_title() 之后建筑名标签没有还回来")
		return
	if node.get_node("TitleLayer").visible:
		_fail("_end_title() 之后标题页应该收起")
		return

	# ---- 5. 窗口标题
	if root.title != "Harvest of Heirs":
		_fail("窗口标题应该是 Harvest of Heirs，实际「%s」" % root.title)
		return

	# ---- 6. 矮窗口 / 窄窗口：另起 SubViewport 装一份新的标题页
	for sz in [Vector2i(1280, 600), Vector2i(1024, 640)]:
		var sub := SubViewport.new()
		sub.size = sz
		root.add_child(sub)
		var t2 = load("res://scripts/ui/title_screen.gd").new()
		sub.add_child(t2)
		await process_frame
		_assert_layout(t2, Vector2(sz), "SubViewport %dx%d" % [sz.x, sz.y])
		t2.queue_free()
		sub.queue_free()

	print("TITLE TEST 视口=%s logo=%s" % [str(vp), str((logo as Control).size)])
	print("TITLE TEST RESULT: PASS")
	quit(0)

## logo 居中 / 不压菜单 / 不出画；菜单居中贴底；三个按钮齐全
func _assert_layout(title, vp: Vector2, tag: String) -> void:
	var logo := title.get_node_or_null("Logo") as Control
	var wrap := title.get_node_or_null("MenuWrap") as Control
	if logo == null or wrap == null:
		_fail("%s：logo 或菜单不见了" % tag)
		return
	var lr := Rect2(logo.position, logo.size)
	var mr := Rect2(wrap.position, wrap.size)

	if absf(lr.get_center().x - vp.x * 0.5) > 1.0:
		_fail("%s：logo 没有水平居中（中心 %.1f，视口中心 %.1f）" % [
			tag, lr.get_center().x, vp.x * 0.5])
	if lr.position.y < 0.0:
		_fail("%s：logo 顶部出画（y=%.1f）" % [tag, lr.position.y])
	if lr.end.y > mr.position.y:
		_fail("%s：logo 压到菜单上了（logo 底 %.1f，菜单顶 %.1f）" % [
			tag, lr.end.y, mr.position.y])
	if lr.size.x <= 0.0 or lr.size.y <= 0.0:
		_fail("%s：logo 尺寸为 0" % tag)
	if lr.end.y > vp.y:
		_fail("%s：logo 超出视口底部" % tag)
	if absf(mr.get_center().x - vp.x * 0.5) > 1.0:
		_fail("%s：菜单没有水平居中" % tag)
	if absf(mr.end.y - (vp.y - 28.0)) > 1.0:
		_fail("%s：菜单没有贴底（底 %.1f，应该 %.1f）" % [tag, mr.end.y, vp.y - 28.0])
	var names := []
	for b in wrap.find_children("*", "Button", true, false):
		names.append((b as Button).text)
	for need in ["开始游戏", "读取进度", "退出游戏"]:
		if not names.has(need):
			_fail("%s：菜单里少了「%s」（实际 %s）" % [tag, need, str(names)])
