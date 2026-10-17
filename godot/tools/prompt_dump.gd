extends SceneTree

# 把**实际会发给模型的两条消息**原样打出来（不联网、不花钱）。
#
# 为什么要有它：提示词改起来很快，但"到底发了什么"只有真发一次才知道 ——
# 而真发要 key、要钱、还慢。这个工具用一份新开局（或一个"第 9 天的小村"）把
# `Advisor.system_prompt()` / `user_prompt()` 打出来，改完立刻能看。
#
# 用法（仓库根目录）：
#   godot --headless --path godot -s res://tools/prompt_dump.gd
#   godot --headless --path godot -s res://tools/prompt_dump.gd -- mid   # 造一个更像样的局
#
# ⚠️ 这不是门槛（不跑断言），只是开发时的眼睛。

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var mid := OS.get_cmdline_user_args().has("mid")
	var db := ContentDB.load_all()
	var sim := SimCore.new(db)
	sim.new_game("v0.3", 12345)
	if mid:
		# 摆一个"有点规模"的村子，否则提示词里一大半是"还没有"
		for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
			var d: Dictionary = db.buildings[bid]
			sim.s["shops"].append({"id": "%s#b" % bid, "defId": bid, "owner": "state",
				"targetWorkers": int(d["workers"]), "wage": 3.0, "wageCap": 6.0, "level": 1,
				"active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0})
		sim.s["housing"]["hut"] = 14.0
		for i in 9:
			for h in 24:
				sim.tick_hour([])
	var ad := Advisor.new(sim)
	ad.question = "我下一步要做什么"
	print("========== 1. system（Advisor.system_prompt）==========")
	print(ad.system_prompt())
	print("========== 2. user（Advisor.user_prompt）==========")
	print(ad.user_prompt())
	# 3、4 是 ProphetAgent 追加的：水晶球简报 + 工具声明。
	# 这两块**也是提示词**（模型看得到的字），改人设时别忘了它们。
	var ag := ProphetAgent.new(sim, ad.question)
	var brief := ""
	for m in (ag.next_request()["messages"] as Array):
		var mm: Dictionary = m
		var c := String(mm["content"])
		if String(mm["role"]) == "user" and c.contains("水晶球") and brief == "":
			brief = c
	print("========== 3. 水晶球简报（ProphetAgent._briefing）==========")
	print(brief if brief != "" else "（没找到简报）")
	print("========== 4. 工具声明（ProphetAgent.tool_schema）==========")
	print(JSON.stringify(ag.tool_schema(), "  "))
	print("========== 字节数 ==========")
	print("system ", ad.system_prompt().to_utf8_buffer().size(), " B / user ",
		ad.user_prompt().to_utf8_buffer().size(), " B / 简报 ", brief.to_utf8_buffer().size(),
		" B / 工具 ", JSON.stringify(ag.tool_schema()).to_utf8_buffer().size(), " B")
	quit(0)
