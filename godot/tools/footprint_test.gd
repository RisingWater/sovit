extends SceneTree

# 占地与贴图的一致性门槛。
#
# 规则：**所有 `arch:"sprite"` 的建筑/住房，占地都不能比贴图高**（显式写了
# `art.foot` 的也一样受这条管）。
#
# 为什么只卡"高"：`_place_sprite()` 把贴图**底边**对齐占地的**底边**，所以
# 占地比贴图高的那几行全在顶部、画面上什么都没有，却占着格子挡建造
# （`TILE` 是 **16**，别用 32 去算 —— 我第一版就是这么算错的）。
# 宽方向多出来的是左右两侧，城镇中心那种"占地含周围铺装"的写法是有意的，所以只提示不判红。
#
# ⚠️ 2026-10 起 content 给**每一座** sprite 建筑都显式写了 `foot`（值 = 贴图推导值），
#    所以这条门槛不能再"有 foot 就跳过"——那样一个都检查不到，直接假绿。
#    现在：显式 foot 也照样查隐形行，只额外统计"与贴图推导不同"的那几座（有意的覆盖）。
#    平时的改动循环用 `npm run check:footprint`（不起引擎、<1 秒），这条门槛兜底。
#
# ⚠️ 从**真跑起来的主场景**取 db（`world.runner.db`），不要自己 `ContentDB.new()`：
# 第一版就是那样写的，`load_all()` 返回 true 但字典是空的 —— 门槛打印
# "自动推导 0 个 … PASS"，**假绿**。所以下面还有一条"检查数为 0 就判红"。

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("FOOTPRINT TEST FAIL: ", msg)
	quit(1)

func _run() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	var world = node.get_node_or_null("World")
	if world == null:
		_fail("找不到 World")
		return
	var db = world.runner.db

	var bad := []
	var explicit := 0
	var overridden := 0
	var checked := 0
	var wide := 0
	for pair in [["建筑", db.buildings], ["住房", db.housing]]:
		var label: String = pair[0]
		for id in (pair[1] as Dictionary).keys():
			var def: Dictionary = pair[1][id]
			var art: Dictionary = def.get("art", {})
			if String(art.get("arch", "")) != "sprite":
				continue
			var tex: Texture2D = world._texture_for(String(id))
			if tex == null:
				bad.append("%s（%s）：贴图缺失" % [String(id), label])
				continue
			checked += 1
			var fp: Vector2i = world._footprint(String(id))     # 走真实代码路径
			if art.has("foot"):
				explicit += 1
				# 镜像 `_footprint()` 的"按贴图推导"分支（两处必须同口径）：
				# 高再减 1 行 —— 顶行（屋顶/塔尖）不占地。
				var derived := Vector2i(
					maxi(1, int(floor(tex.get_width() / float(world.TILE)))),
					maxi(1, int(floor(tex.get_height() / float(world.TILE))) - 1))
				if fp != derived:
					overridden += 1
			var invisible: int = fp.y * world.TILE - tex.get_height()
			if invisible > 0:
				bad.append("%s（%s）：贴图高 %d，占地 %d 格 -> 顶部 %dpx 隐形" % [
					String(id), label, tex.get_height(), fp.y, invisible])
			if fp.x * world.TILE < tex.get_width():
				wide += 1

	if not bad.is_empty():
		_fail("\n".join(bad))
		return
	if checked == 0:
		_fail("一个都没检查到（db 取空了？）—— 这种假绿比红更糟")
		return
	print("FOOTPRINT TEST 检查 %d 座（显式 art.foot %d 座，其中与贴图推导不同 %d 座；%d 座贴图比占地宽，设计允许）"
		% [checked, explicit, overridden, wide])
	print("FOOTPRINT TEST RESULT: PASS")
	quit(0)
