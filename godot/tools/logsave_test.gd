extends SceneTree

# 公告（城镇中心 → 公告）必须**随存档保存**：退出再进来，看到的还是那些消息。
#
# 用户报的 bug：**"公告，退出再进入就全部清空了，这个没有进入存档吗？"**
#
# 根因有两条，缺一条都修不干净：
#   1. 公告页读的是表现层 `SimRunner.recent_logs` —— 一份**只在内存里**的环形缓冲
#      （60 条），而不是进存档的 `sim.s["log"]`；`world_view.load_from()` 还会把它清空。
#   2. 就算改成读 `sim.s["log"]` 也还是"少半截"：那份 state.log 以前**只**在夜晚写，
#      黎明那批（建成投产 / 研究完成 / X 改建为 Y）从来没进过存档。
#
# 所以这条门槛锁三件事：
#   A. 公告 == **当小时返回的全部日志**（黎明 / 白天 / 夜晚三批都并进 `s["log"]`）；
#   B. 公告页显示的正好是 `s["log"]` 的尾巴（最后一行 == 日志最后一条）；
#   C. 存 → 往前跑（把内存里的公告改脏）→ 读 → 公告与页面**原样回来**。
#
# 走的是玩家真实路径：地图上点城镇中心 → 切到「公告」页 → 存 → 读 → 再看那一页。

const SAVE_PATH := "user://zz-logsave-test.json"

var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("LOGSAVE FAIL: ", msg)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  ok  ", msg)

## 公告页里那些「[D3] …」行（其它说明性文字不算）。
func _notice_lines(civic: Node) -> Array:
	var out := []
	for l in civic.find_children("*", "Label", true, false):
		var t := String((l as Label).text)
		# 公告每行现在是「AE 312年1月1日　正文」（用户 2026-10 · B0；
		# 更早是「第N天」、再早是 [D37] 那种缩写）
		if t.begins_with("AE") and t.contains("日"):
			out.append(t)
	return out

func _texts(arr: Array) -> Array:
	var out := []
	for e in arr:
		out.append(String((e as Dictionary).get("text", "")))
	return out

func _run() -> void:
	# 用测试专用的存档位；玩家自己的快存位（SaveManager.DEFAULT_PATH）绝不能碰
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(abs_path)

	var ps: PackedScene = load("res://scenes/main.tscn")
	var node := ps.instantiate()
	root.add_child(node)
	await process_frame
	await process_frame
	if node.has_method("_end_title"):
		node._end_title()
		await process_frame

	var runner = node.get("runner")
	var world = node.get_node_or_null("World")
	var civic = node.get_node_or_null("UI/Root/Civic")
	if runner == null or world == null or civic == null:
		_fail("找不到 runner / World / Civic")
		return

	world.start_new_game(20261020, 2.0, "公告")
	runner.paused = true          # 下面手动 tick，别让 _process 偷偷加日志
	await process_frame
	var sim = runner.sim

	# 塞一条"明天黎明就完工"的工地：黎明那批日志（建成投产）正是以前唯一不进存档的一批，
	# 不把它凑出来的话，这条门槛就验不到要害上。
	(sim.s["construction"] as Array).append({
		"kind": "shop", "buildingId": "lumberjack",
		"remaining": 0.0, "totalRequired": 24.0, "started": true,
	})

	# ---- A. 公告 == 全部日志（三批都进 s["log"]）-----------------------------
	var returned: Array = []
	var dawn_text := ""
	for h in 48:
		for e in sim.tick_hour([]):
			returned.append(e)
			var t := String((e as Dictionary).get("text", ""))
			if t.contains("建成投产"):
				dawn_text = t
	var state_log: Array = sim.s["log"]
	if state_log.size() != returned.size():
		_fail("公告 %d 条 != 这 48 小时返回的日志 %d 条 —— 有批次没并进 state.log"
			% [state_log.size(), returned.size()])
		return
	var bad := ""
	var rt := _texts(returned)
	var st := _texts(state_log)
	for i in st.size():
		if String(st[i]) != String(rt[i]):
			bad = "第 %d 条：state=「%s」返回值=「%s」" % [i, st[i], rt[i]]
			break
	if bad != "":
		_fail("公告与返回的日志逐条不一致：" + bad)
		return
	if dawn_text == "":
		_fail("48 小时里没有黎明日志（建成投产）—— 这条门槛没验到要害上")
		return
	_ok("公告 = 全部日志（%d 条，含黎明「%s」）" % [state_log.size(), dawn_text])

	# ---- B. 公告页把 s["log"] **全部**列出来（不再只显示最近 24 条）-----------
	var tc_id := ""
	for sh in sim.s["shops"]:
		if String(sh["defId"]) == "town_center":
			tc_id = String(sh["id"])
	if tc_id == "":
		_fail("找不到城镇中心")
		return
	node._on_select_building(tc_id)
	await process_frame
	civic._select_tab(3)          # 第 4 个页签 = 公告（城镇中心：基本信息/资源/建造队列/公告）
	await process_frame
	var lines := _notice_lines(civic)
	var all_logs: Array = sim.log_tail(sim.log_size())
	if lines.is_empty():
		_fail("公告页一条都没有（假绿）")
		return
	if lines.size() != all_logs.size():
		_fail("公告页 %d 行，日志总数 %d 条（应全部显示）" % [lines.size(), all_logs.size()])
		return
	var last_e: Dictionary = all_logs[all_logs.size() - 1]
	var want := "%s　%s" % [sim.date_label(int(last_e.get("day", 0))), String(last_e.get("text", ""))]
	if String(lines[lines.size() - 1]) != want:
		_fail("公告页最后一行「%s」，应为「%s」" % [lines[lines.size() - 1], want])
		return
	_ok("公告页 %d 行 = 全部日志，最后一行「%s」" % [lines.size(), want])

	# ---- C. 存 → 跑脏 → 读：公告与页面都原样回来 ------------------------------
	var before := _texts(sim.s["log"])
	if world.save_to(SAVE_PATH) != OK:
		_fail("存档写失败：%s" % SAVE_PATH)
		return
	# ⚠️ 要跑满**一整天**才算"跑脏"：只跑 6 小时的话这 6 个小时可能一个日志都不产生
	#    （开局 0–5 点既不是黎明也不是工作小时），断言就变成假的。
	for h in 24:
		sim.tick_hour([])
	if (sim.s["log"] as Array).size() == before.size():
		_fail("又跑满一天日志却一条没多 —— 这段没法验「读档把脏数据盖回去」")
		return
	if not world.load_from(SAVE_PATH):
		_fail("读档失败：%s" % SAVE_PATH)
		return
	await process_frame
	sim = runner.sim
	var after := _texts(sim.s["log"])
	if after.size() != before.size():
		_fail("读档后公告 %d 条，存档前 %d 条" % [after.size(), before.size()])
		return
	for i in after.size():
		if String(after[i]) != String(before[i]):
			_fail("读档后第 %d 条对不上：存档前「%s」，读回「%s」" % [i, before[i], after[i]])
			return
	# 界面这一层：重新点开城镇中心 → 公告页，行数与末行都该和存档前一样
	node._on_select_building(tc_id)
	await process_frame
	civic._select_tab(3)
	await process_frame
	var lines2 := _notice_lines(civic)
	if lines2.size() != lines.size():
		_fail("读档后公告页 %d 行，存档前 %d 行" % [lines2.size(), lines.size()])
		return
	if String(lines2[lines2.size() - 1]) != String(lines[lines.size() - 1]):
		_fail("读档后公告页末行「%s」，存档前「%s」" % [lines2[lines2.size() - 1], lines[lines.size() - 1]])
		return
	_ok("存 → 跑脏 → 读：公告 %d 条、页面末行都原样回来（退出再进来不会清空）" % [after.size()])

	# ---- D. 日志很多时：**全部**列出来 ----------------------------------------
	# 用户要求："公告要全部显示"（日志本身由 SimCore 封顶 500 条），
	# 而且不再写「共 N 条，显示最近 24 条」那一行。
	for i in 30:
		(sim.s["log"] as Array).append({
			"day": int(sim.s["day"]), "kind": "test", "text": "补的第 %d 条" % (i + 1),
		})
	node._on_select_building(tc_id)
	await process_frame
	civic._select_tab(3)
	await process_frame
	var lines3 := _notice_lines(civic)
	var total3: int = sim.log_size()
	if lines3.size() != total3:
		_fail("公告页应列出**全部** %d 条，实际 %d 行" % [total3, lines3.size()])
		return
	for l in civic.find_children("*", "Label", true, false):
		var t := String((l as Label).text)
		if t.begins_with("共 ") or t.contains("显示最近"):
			_fail("公告页不该再有「共 N 条 / 显示最近 N 条」那行：%s" % t)
			return
	# 日期写 `AE 312年1月1日`（用户 2026-10 · B0），不是「D37」也不是「第 N 天」
	var last_lb := String(lines3[lines3.size() - 1])
	if last_lb != "%s　补的第 30 条" % sim.date_label(int(sim.s["day"])):
		_fail("公告页末行是「%s」，不是「AE 日期 + 最新那条」" % last_lb)
		return
	if last_lb.begins_with("[D"):
		_fail("公告页还在写 D%d 那种缩写" % int(sim.s["day"]))
		return
	_ok("日志 %d 条时全部列出（末行最新、写 AE 日期、无「共 N 条」行）" % total3)

	# 测试存档用完就删，别留在玩家的存档目录里
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(abs_path)
	print("LOGSAVE TEST 检查了 %d 条断言" % _checks)
	print("LOGSAVE TEST RESULT: PASS")
	quit(0)
