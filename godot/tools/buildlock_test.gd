extends SceneTree

# 建造栏科技锁门槛：
#   已解锁的建筑卡片必须**接上**点击；未解锁的必须灰显、带「（锁）」、
#   并且在 tooltip 里说清缺哪项科技 —— 且**不接**点击（点了什么也不发生）。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("BUILDLOCK TEST FAIL: ", msg)
	quit(1)

func _label_of(btn: Button) -> String:
	for c in btn.find_children("*", "Label", true, false):
		return (c as Label).text
	return ""

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var bar = node.get_node_or_null("UI/Root/BuildBar")
	if bar == null:
		_fail("找不到 UI/Root/BuildBar")
		return
	# 切到「农场」页：这一页同时有免费的（小麦/蔬菜）和锁着的（亚麻/棉花/甘蔗/染料）
	bar._select_tab(1)
	for i in 3:
		await process_frame

	var cards := []
	for c in bar.find_children("*", "Button", true, false):
		var b := c as Button
		if b.custom_minimum_size.x == UIKit.CARD_W and b.custom_minimum_size.y == UIKit.CARD_H:
			cards.append(b)
	if cards.is_empty():
		_fail("农场页一张卡片都没有")
		return

	var world = node.world
	var free_card: Button = null
	var locked_card: Button = null
	for b in cards:
		var txt := _label_of(b)
		if txt.ends_with("（锁）"):
			if locked_card == null:
				locked_card = b
			if not b.tooltip_text.contains("需要科技"):
				_fail("锁着的卡片「%s」tooltip 没说缺哪项科技：%s" % [txt, b.tooltip_text])
				return
			if b.modulate.v > 0.95:
				_fail("锁着的卡片「%s」没有灰显（modulate=%s）" % [txt, b.modulate])
				return
		else:
			if free_card == null:
				free_card = b
			if b.modulate.v < 0.95:
				_fail("已解锁的卡片「%s」被误灰显了" % txt)
				return

	if locked_card == null:
		_fail("农场页一个锁着的建筑都没有（亚麻/棉花农场应该是锁的）")
		return
	if free_card == null:
		_fail("农场页一个免费建筑都没有（小麦农场应该是免费的）")
		return

	# 真正的行为断言：点锁着的卡片**不能**进入建造模式；点免费的必须进。
	# （不能用 pressed.get_connections() 判断 —— UIKit.card 自己接了音效，人人都有连接。）
	world.build_mode = ""
	locked_card.pressed.emit()
	await process_frame
	if world.build_mode != "":
		_fail("点锁着的卡片「%s」竟然进入了建造模式（build_mode=%s）" % [_label_of(locked_card), world.build_mode])
		return

	free_card.pressed.emit()
	await process_frame
	if world.build_mode == "":
		_fail("点已解锁的卡片「%s」没有进入建造模式" % _label_of(free_card))
		return

	print("BUILDLOCK TEST 免费「%s」进入建造模式=%s；锁「%s」点击后仍为 %s"
		% [_label_of(free_card), world.build_mode, _label_of(locked_card), ""])
	print("BUILDLOCK TEST RESULT: PASS")
	quit(0)
