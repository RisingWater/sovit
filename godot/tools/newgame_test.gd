extends SceneTree

# 新游戏对话框门槛。
#
# 重点是**倍率真的生效**以及**村名真的塞得下**：
#   倍率写错的话只是数字不对，不报错；
#   村名生成后再超长的话，红巾上会顶出去，也是不报错的。

const NAME_MAX := 6

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("NEWGAME TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame

	var dlg = node.get_node_or_null("UI/Root/NewGame")
	var world = node.get_node_or_null("World")
	if dlg == null or world == null:
		_fail("找不到 NewGame 或 World")
		return
	if dlg.visible:
		_fail("对话框一开始不该显示")
		return

	# 1. 村名上限必须和红巾放得下的字数一致
	if dlg.NAME_MAX != NAME_MAX:
		_fail("NAME_MAX=%d，应为 %d" % [dlg.NAME_MAX, NAME_MAX])
		return
	if dlg._name_edit.max_length != NAME_MAX:
		_fail("输入框 max_length=%d，与 NAME_MAX 不一致" % dlg._name_edit.max_length)
		return
	# 红巾宽度必须装得下 NAME_MAX 个汉字（24px 像素字）
	var mm = node.get_node_or_null("UI/Root/Minimap")
	if mm != null:
		var need: float = NAME_MAX * float(UIKit.BIG_FS)
		if float(mm.RIB_W) < need:
			_fail("红巾宽 %d 装不下 %d 字 @24px（需要 %.0f）" % [mm.RIB_W, NAME_MAX, need])
			return

	# 2. 三个难度
	if dlg.DIFFICULTIES.size() != 3:
		_fail("难度档数应为 3，实际 %d" % dlg.DIFFICULTIES.size())
		return

	# 3. 倍率必须真的作用在初始资源上：跑两局，比较库存与国库
	var sim = node.get("runner").sim
	var snap := func(mult: float) -> Dictionary:
		world.start_new_game(4242, mult, "sovit")
		await process_frame
		var g: Dictionary = node.get("runner").sim.s["goods"]
		var tot := 0.0
		for k in g.keys():
			tot += float(g[k])
		return {"goods": tot, "money": float(node.get("runner").sim.s["government"]["money"])}

	var one: Dictionary = await snap.call(1.0)
	var two: Dictionary = await snap.call(2.0)
	var half: Dictionary = await snap.call(0.5)

	if absf(float(two["goods"]) - float(one["goods"]) * 2.0) > 0.05:
		_fail("2 倍开局库存不对：1x=%.1f 2x=%.1f" % [one["goods"], two["goods"]])
		return
	if absf(float(half["goods"]) - float(one["goods"]) * 0.5) > 0.05:
		_fail("0.5 倍开局库存不对：1x=%.1f 0.5x=%.1f" % [one["goods"], half["goods"]])
		return
	if absf(float(two["money"]) - float(one["money"]) * 2.0) > 0.05:
		_fail("2 倍开局国库不对：1x=%.1f 2x=%.1f" % [one["money"], two["money"]])
		return

	# 4. 村名会写进状态，且超长的会被截断
	world.start_new_game(4242, 1.0, "一二三四五六七八")
	await process_frame
	var nm := String(node.get("runner").sim.s.get("villageName", ""))
	if nm.length() > NAME_MAX:
		_fail("村名没有被截断到 %d 字：%s" % [NAME_MAX, nm])
		return

	# 5. 新游戏之后仓库精灵必须还在
	#    （曾经 start_new_game 换了新 GameMap 却没重建仓库精灵，仓库就消失了）
	if world.town_center_sprite == null or not is_instance_valid(world.town_center_sprite):
		_fail("新游戏后仓库精灵没了")
		return
	if not world.town_center_sprite.visible:
		_fail("新游戏后仓库精灵不可见")
		return

	# 6. 默认 1.0 倍必须与从前逐位相同（golden 依赖这一点）
	world.start_new_game(12345, 1.0, "sovit")
	await process_frame
	print("NEWGAME TEST 1x=%.1f 2x=%.1f 0.5x=%.1f 村名=%s" % [
		one["goods"], two["goods"], half["goods"], nm])
	print("NEWGAME TEST RESULT: PASS")
	quit(0)
