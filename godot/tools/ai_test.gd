extends SceneTree

# AI 辅助门槛：程序计算 / 提示词 / 配置读写 / HTTP 请求体与响应解析。
#
# 契约见 `docs/ai-assist.md`。这条门槛盯的几件事（红了就说明什么坏了）：
#
#   1. **只读**：`Advisor` 跑一遍（plan / digest / messages / 各种 text）之后
#      `sim.s` 必须**逐字节没变** —— 它要是偷偷改了状态，黄金轨迹就会跟着漂
#   2. **不剧透**：建议里出现的任务 id 必须都在 `quest_view()` 可见集合里
#      （任务系统的契约是渐进显示，AI 抢先说出来就废了引导）
#   3. **不重抄公式**：成本/产能一律读引擎的现有值 —— 这里拿"新开局"的真实
#      数字对拍（住房容量 24、岗位 0、基础食物日需 18、库存 300、还够 16.7 天）
#   4. **goal 类型全覆盖**：内容里出现 `KNOWN_GOAL_TYPES` 之外的类型 → 红。
#      否则新加一种任务目标会在建议里**静默消失**（玩家少一条引导，没人发现）
#   5. **接入层**：base_url 补全 / api_key 不进请求体 / 各种响应形状的解析 /
#      模型回答里的缺字形被收拾掉（像素字体画不出来 = 屏幕上一片空，还不报错）
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/ai_test.gd

const SEED := 12345
const TMP_CFG := "user://ai_test.cfg"
const FONT := "res://assets/fonts/fusion-pixel-12px-zh_hans.ttf"

var db: ContentDB = null
var _checks := 0

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("AI TEST FAIL: ", msg)
	print("AI TEST RESULT: FAIL（检查了 %d 条）" % _checks)
	quit(1)

func _ok(msg: String) -> void:
	_checks += 1
	print("  · ", msg)

func _chk(cond: bool, msg: String) -> bool:
	if not cond:
		_fail(msg)
	return cond

## 像素字体画不画得出来（控制字符不算，换行不在字形表里）。
func _font_ok(s: String) -> bool:
	var f: FontFile = load(FONT)
	if f == null:
		return false
	for i in s.length():
		var cp := s[i].unicode_at(0)
		if cp < 32:
			continue
		if not f.has_char(cp):
			return false
	return true

func _fresh() -> SimCore:
	var sim := SimCore.new(db)
	sim.new_game("v0.3", SEED)
	return sim

## 直接塞一座"已建成"的建筑（和 tools/quest_test.gd 同一个做法）。
func _add_shop(sim: SimCore, def_id: String, n: int = 1) -> void:
	for _i in n:
		var d: Dictionary = db.buildings[def_id]
		sim.s["shops"].append({
			"id": "%s#t%d" % [def_id, (sim.s["shops"] as Array).size() + 1],
			"defId": def_id, "owner": "state",
			"targetWorkers": int(d["workers"]),
			"wage": float(db.economy["refWage"]),
			"wageCap": float(db.economy["defaultWageCap"]),
			"level": 1, "active": true, "profit": 0.0, "skill": 50.0, "planned": 0.0,
		})

## 建造栏页签：直接问内容层（和真游戏里 `build_bar._category_of` 同一个来源）。
func _cat_of(id: String) -> String:
	return db.build_category(id)

func _ids(plan: Array) -> Array:
	var out := []
	for s in plan:
		out.append(String(s["id"]))
	return out

func _find(plan: Array, id: String) -> Dictionary:
	for s in plan:
		if String(s["id"]) == id:
			return s
	return {}

func _has(plan: Array, id: String) -> bool:
	return not _find(plan, id).is_empty()

# ===========================================================================
func _run() -> void:
	db = ContentDB.load_all()
	if db == null or db.quests.is_empty():
		_fail("内容没加载起来")
		return

	if not _config_section():
		return
	if not _request_section():
		return
	if not _parse_section():
		return
	if not _clean_section():
		return
	if not _icon_section():
		return
	if not _advisor_section():
		return
	if not _readonly_section():
		return
	if not _reveal_section():
		return
	if not _prompt_section():
		return
	if not _cooldown_section():
		return
	if not _trial_section():
		return
	if not _protocol_section():
		return
	if not _midgame_section():
		return
	if not _coverage_section():
		return
	if not _goal_types_section():
		return

	print("AI TEST 检查了 %d 条断言" % _checks)
	print("AI TEST RESULT: PASS")
	quit(0)

# ---------------------------------------------------------------------------
# 1. 配置读写（走临时文件，别碰玩家自己的 user://ai.cfg）
# ---------------------------------------------------------------------------
func _config_section() -> bool:
	var real := AiConfig.path
	AiConfig.path = TMP_CFG
	if FileAccess.file_exists(TMP_CFG):
		DirAccess.remove_absolute(TMP_CFG)

	var d := AiConfig.load_cfg()
	# 2026-10 用户要求"把当前 deepseek 模型的 base_url 和 api 填写进去"：
	# 地址与模型名现在是**预填的默认值**（DeepSeek 官方 + deepseek-flash），
	# 于是"没配过"和"配好了"不再由 base_url 是否为空区分。
	# ⚠️ **key 绝不能有默认值** —— 它只活在 `user://ai.cfg` 里，不能进仓库。
	if not _chk(String(d["base_url"]).begins_with("https://") and String(d["model"]) != "",
			"默认应当预填 DeepSeek 的地址与模型名（%s / %s）" % [String(d["base_url"]),
				String(d["model"])]):
		return false
	if not _chk(not String(d["base_url"]).contains("key") and not String(d["model"]).contains("sk-"),
			"默认值里不许出现任何像 key 的东西"):
		return false
	if not _chk(String(d["api_key"]) == "", "没配过时 api_key 必须是空的（key 不进仓库）"):
		return false
	if not _chk(AiConfig.masked_key(d) == "（未设置）", "空 key 的显示文案"):
		return false
	# 只填地址与模型也算配好：本地推理（ollama / llama.cpp）就是不需要 key
	var nokey := d.duplicate()
	nokey["base_url"] = "http://127.0.0.1:11434/v1"
	nokey["model"] = "qwen2.5:7b"
	if not _chk(AiConfig.is_ready(nokey) and not AiConfig.has_key(nokey),
			"没有 api_key 也算配好了（本地推理不需要 key）"):
		return false
	var blank := nokey.duplicate()
	blank["base_url"] = "   "
	if not _chk(not AiConfig.is_ready(blank), "base_url 全是空白就算没配好"):
		return false
	_ok("配置：默认预填 DeepSeek 地址 + 模型名，**key 没有默认值**（只填地址+模型即可用）")

	d["base_url"] = "http://127.0.0.1:11434/v1"
	d["api_key"] = "sk-abcdefghijklmnop"
	d["model"] = "qwen2.5:7b"
	d["timeout"] = 30.0
	d["max_tokens"] = 512
	if not _chk(AiConfig.save_cfg(d) == OK, "写配置应该成功"):
		return false
	var back := AiConfig.load_cfg()
	if not _chk(String(back["base_url"]) == "http://127.0.0.1:11434/v1"
			and String(back["model"]) == "qwen2.5:7b"
			and String(back["api_key"]) == "sk-abcdefghijklmnop", "配置往返要一模一样"):
		return false
	if not _chk(is_equal_approx(float(back["timeout"]), 30.0)
			and int(back["max_tokens"]) == 512,
			"超时 / 回复上限也要往返"):
		return false
	# 用户 2026-10："问的时候游戏暂停" —— 不再是一个设置项，问话期间一定暂停。
	# （老配置文件里留着 pause_on_ask 也无害：读的时候被忽略、写的时候不再落盘。）
	if not _chk(not back.has("pause_on_ask"),
			"暂停不该再是配置项（问话期间无条件暂停）"):
		return false
	if not _chk(AiConfig.masked_key(back) == "sk-abc…mnop", "显示 key 只能露头尾"):
		return false
	_ok("配置：往返一致，界面上只露 key 的头尾")

	if not _chk(AiConfig.endpoint("https://api.deepseek.com/v1")
			== "https://api.deepseek.com/v1/chat/completions", "endpoint 补 /chat/completions"):
		return false
	if not _chk(AiConfig.endpoint("https://api.deepseek.com/v1/")
			== "https://api.deepseek.com/v1/chat/completions", "endpoint 先去尾斜杠"):
		return false
	if not _chk(AiConfig.endpoint("http://127.0.0.1:8080/v1/chat/completions")
			== "http://127.0.0.1:8080/v1/chat/completions", "已经是终点就原样用"):
		return false
	if not _chk(AiConfig.endpoint("") == "", "空 base_url 得到空 endpoint"):
		return false
	_ok("配置：base_url 三种写法都能拼对")

	DirAccess.remove_absolute(TMP_CFG)
	AiConfig.path = real
	return true

# ---------------------------------------------------------------------------
# 2. 请求体 / 请求头
# ---------------------------------------------------------------------------
func _request_section() -> bool:
	var cfg := AiConfig.load_cfg()
	cfg["base_url"] = "https://example.com/v1"
	cfg["model"] = "test-model"
	cfg["api_key"] = "sk-secret-1234567890"
	cfg["max_tokens"] = 400
	var msgs := [{"role": "system", "content": "sys"}, {"role": "user", "content": "usr"}]
	var body := AiClient.build_body(cfg, msgs)
	var parsed: Variant = JSON.parse_string(body)
	if not _chk(parsed is Dictionary, "请求体必须是合法 JSON"):
		return false
	var p := parsed as Dictionary
	if not _chk(String(p["model"]) == "test-model" and int(p["max_tokens"]) == 400
			and not bool(p["stream"]), "请求体的 model / max_tokens / 非流式"):
		return false
	if not _chk((p["messages"] as Array).size() == 2
			and String((p["messages"] as Array)[0]["role"]) == "system", "请求体带 messages"):
		return false
	if not _chk(not body.contains("sk-secret-1234567890"), "api_key 不许出现在请求体里"):
		return false
	var h := AiClient.build_headers(cfg)
	if not _chk(h.size() == 2 and h[1] == "Authorization: Bearer sk-secret-1234567890",
			"有 key 时发 Authorization 头"):
		return false
	var no_key := cfg.duplicate()
	no_key["api_key"] = ""
	if not _chk(AiClient.build_headers(no_key).size() == 1, "没有 key 时不发 Authorization 头"):
		return false
	_ok("接入：请求体是 OpenAI 形状，key 只在请求头里，本地推理不发 Authorization")

	# 带工具（"把引擎当工具交给模型"就是这一段）：
	#   `tools` + `tool_choice: "auto"` 非空时才出现在 body 里；
	#   不带工具时**不许**留一个空的 `tools` 字段（有些端点会因此报 400）。
	var schema := [{"type": "function", "function": {"name": "simulate_plan"}}]
	var body_tools: Variant = JSON.parse_string(AiClient.build_body(cfg, msgs, schema))
	if not _chk(body_tools is Dictionary and (body_tools as Dictionary).has("tools")
			and String((body_tools as Dictionary)["tool_choice"]) == "auto",
			"带工具时 body 要有 tools 与 tool_choice=auto"):
		return false
	var body_plain: Variant = JSON.parse_string(AiClient.build_body(cfg, msgs, []))
	if not _chk(not (body_plain as Dictionary).has("tools"),
			"不带工具时不该留空的 tools 字段"):
		return false
	_ok("接入：tools 与 tool_choice 只在真要试方案时带上")
	return true

# ---------------------------------------------------------------------------
# 3. 响应解析（不联网，直接喂各种形状的响应体）
# ---------------------------------------------------------------------------
func _parse_section() -> bool:
	var ok := AiClient.parse_reply(200,
		'{"choices":[{"message":{"role":"assistant","content":"  先补粮食  "}}]}')
	if not _chk(bool(ok["ok"]) and String(ok["text"]) == "先补粮食", "标准 chat/completions 解析"):
		return false
	var legacy := AiClient.parse_reply(200, '{"choices":[{"text":"老式回答"}]}')
	if not _chk(bool(legacy["ok"]) and String(legacy["text"]) == "老式回答", "choices[0].text 也要认"):
		return false
	var e401 := AiClient.parse_reply(401, '{"error":{"message":"Invalid API key"}}')
	if not _chk(not bool(e401["ok"]) and String(e401["error"]).contains("Invalid API key")
			and String(e401["error"]).contains("401"), "401 要把服务端的原话带出来"):
		return false
	var e500 := AiClient.parse_reply(500, "boom: internal error")
	if not _chk(not bool(e500["ok"]) and String(e500["error"]).contains("boom"),
			"非 JSON 的错误体也要露一段出来"):
		return false
	if not _chk(not bool(AiClient.parse_reply(200, "")["ok"]), "空响应判失败"):
		return false
	if not _chk(not bool(AiClient.parse_reply(200, "<html>nope</html>")["ok"]), "非 JSON 判失败"):
		return false
	if not _chk(not bool(AiClient.parse_reply(200, '{"choices":[]}')["ok"]), "没有 choices 判失败"):
		return false
	var in200 := AiClient.parse_reply(200, '{"error":{"message":"model not found"}}')
	if not _chk(not bool(in200["ok"]) and String(in200["error"]).contains("model not found"),
			"200 里带 error 也要判失败并说明原因"):
		return false
	if not _chk(not bool(AiClient.parse_reply(200,
			'{"choices":[{"message":{"content":"   "}}]}')["ok"]), "空内容判失败"):
		return false
	# ---- 函数调用（tool_calls）：把游戏引擎当工具交给模型，靠的就是这一段解析
	var tc := AiClient.parse_reply(200, '{"choices":[{"finish_reason":"tool_calls","message":'
		+ '{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function",'
		+ '"function":{"name":"simulate_plan","arguments":"{\\"days\\":5,\\"actions\\":[]}"}}]}}]}')
	var tcs: Array = tc["tool_calls"]
	if not _chk(bool(tc["ok"]) and tcs.size() == 1 and String(tcs[0]["name"]) == "simulate_plan",
			"tool_calls 要能解析出来（content 为 null 也算成功）"):
		return false
	if not _chk((tcs[0]["args"] as Dictionary).has("days"),
			"tool_calls.function.arguments 是 **JSON 字符串**，要顺手解析出来"):
		return false
	if not _chk(String(tc["finish_reason"]) == "tool_calls", "finish_reason 也要带出来"):
		return false
	# arguments 不是合法 JSON → 整条回复仍然算成功，但那一条标 `bad`（由 agent 回给模型改）
	var tcbad := AiClient.parse_reply(200, '{"choices":[{"message":{"tool_calls":[{"id":"c9",'
		+ '"function":{"name":"simulate_plan","arguments":"{oops"}}]}}]}')
	if not _chk(bool(tcbad["ok"]) and (tcbad["tool_calls"] as Array).size() == 1
			and String((tcbad["tool_calls"] as Array)[0]["bad"]) != "",
			"坏 arguments 不该让整条回复失败（要标 bad 交回给模型改）"):
		return false
	_ok("接入：响应解析覆盖成功 / 401 / 500 / 空体 / 非 JSON / 无 choices / 200 里带错误 / **tool_calls**")
	return true

# ---------------------------------------------------------------------------
# 4. 模型回答的清理（Markdown + 缺字形）
# ---------------------------------------------------------------------------
func _clean_section() -> bool:
	var dirty := "# 建议\n**第一条**：先补粮\n- 建 2 座小麦农场\n−2 ≈3 ⚠ 注意\n结论 ✓"
	var clean := AiClient.clean_reply(dirty)
	if not _chk(not clean.contains("**") and not clean.contains("#") and not clean.contains("`"),
			"Markdown 痕迹要去掉：%s" % clean):
		return false
	if not _chk(clean.contains("· 建 2 座小麦农场"), "行首短横线列表换成「·」：%s" % clean):
		return false
	if not _chk(clean.contains("-2") and clean.contains("约3") and clean.contains("注意"),
			"缺字形要换成能画的替身：%s" % clean):
		return false
	if not _chk(_font_ok(clean), "清理之后每一个字都必须是像素字体有的：%s" % clean):
		return false
	var weird := AiClient.clean_reply("正常文字\u2764\u2705结束")
	if not _chk(_font_ok(weird) and weird.contains("正常文字") and weird.contains("结束"),
			"字体没有的字符被丢掉：%s" % weird):
		return false
	_ok("接入：模型回答过一道「去掉 Markdown + 换掉/丢掉缺字形」的清理")
	return true

# ---------------------------------------------------------------------------
# 5. 图标（按钮上那张，workbuddy 那套面板图标里的）
# ---------------------------------------------------------------------------
## 「AI 辅助」这三处用的是同一张图：顶栏按钮、ESC 菜单那一行、面板标题。
##
## 为什么要单测一张图：Godot 对**缺贴图不报错** —— `panel_icon()` 拿不到就返回 null，
## 而调用处一律是 `if ico != null`（有兜底是为了换素材包时不炸），结果是"按钮上
## 空一块"这种没人会发现的毛病。这里直接问资源在不在、尺寸对不对。
func _icon_section() -> bool:
	var ico: Texture2D = UIKit.panel_icon("ai_assist")
	if not _chk(ico != null, "`assets/ui/panel/ai_assist.png` 不见了（顶栏按钮与面板标题会空一块）"):
		return false
	if not _chk(ico.get_width() == 32 and ico.get_height() == 32,
			"ai_assist.png 应当是 32x32（顶栏按 16 = 一半显示、面板标题按 32 = 原件显示），实际 %dx%d"
			% [ico.get_width(), ico.get_height()]):
		return false
	# 冷却期间顶栏换的那张**灰问号**（用户给的 disable 图）—— 缺了会是个灰块，不报错
	var off: Texture2D = UIKit.panel_icon("ai_assist_off")
	if not _chk(off != null, "`assets/ui/panel/ai_assist_off.png` 不见了（冷却时顶栏会空一块）"):
		return false
	if not _chk(off.get_width() == 32 and off.get_height() == 32,
			"ai_assist_off.png 应当是 32x32，实际 %dx%d" % [off.get_width(), off.get_height()]):
		return false
	_ok("界面：AI 辅助的两张图标都在（金色 / 冷却灰，32x32；顶栏 16px / 面板标题 32px）")
	return true

# ---------------------------------------------------------------------------
# 6. 程序计算（新开局，数字逐个对拍）
# ---------------------------------------------------------------------------
func _advisor_section() -> bool:
	var sim := _fresh()
	var ad := Advisor.new(sim)
	ad.cat_of = Callable(self, "_cat_of")
	var h := ad.housing_summary()
	if not _chk(int(h["capacity"]) == 24 and int(h["vacant"]) == 12,
			"住房容量 6 座茅屋 × 4 = 24、空 12（得到 %s）" % str(h["capacity"])):
		return false
	if not _chk(sim.job_capacity() == 0, "开局只有城镇中心，岗位 0"):
		return false
	if not _chk(sim.housing_capacity() == 24, "公开的住房容量访问器 = 24"):
		return false
	var f := ad.food_summary()
	if not _chk(is_equal_approx(float(f["demand_total"]), 18.0),
			"基础食物名义日需 = 粗面包 12 + 蔬菜 6 = 18（得到 %s）" % str(f["demand_total"])):
		return false
	if not _chk(is_equal_approx(float(f["stock_total"]), 300.0), "基础食物库存 = 200 + 100 = 300"):
		return false
	if not _chk(absf(float(f["days_left"]) - 16.6667) < 0.01,
			"按缺口算还够 16.7 天（得到 %s）" % str(f["days_left"])):
		return false
	if not _chk(int(ad.class_counts()[0]["count"]) == 12, "开局 12 个穷人"):
		return false
	_ok("计算：住房 / 岗位 / 食物日需与库存 / 阶层人数都对上真实数字")

	var rows := ad.quest_rows()
	if not _chk(rows.size() == 2 and String(rows[0]["id"]) == "q01_bread_chain",
			"开局可见任务 2 条（第 1 章两条主线；她的支线要等章 1 收尾，得到 %d）" % rows.size()):
		return false
	if not _chk(String(rows[0]["goals"][0]["type"]) == "building"
			and String(rows[0]["goals"][0]["id"]) == "wheat_farm",
			"goal 的 type / id 要从内容定义并回来（否则建议全落空）"):
		return false
	var plan := ad.plan()
	if not _chk(plan.size() == 3 and String(plan[0]["id"]) == "quest_q01_bread_chain_wheat_farm",
			"开局建议第一条 = 建小麦农场（得到 %s）" % str(_ids(plan))):
		return false
	if not _chk(String(plan[0]["how"][0]).contains("建造栏「农场」页"),
			"建议要指名建造栏页签（得到 %s）" % str(plan[0]["how"][0])):
		return false
	if not _chk(_has(plan, "unemployed"), "开局还要提醒「没人上班」（岗位 0 / 人口 12）"):
		return false
	var ad2 := Advisor.new(_fresh())
	if not _chk(not ad2.plan_text().contains("建造栏「"), "拿不到页签名时不编页签名"):
		return false
	_ok("计算：开局建议 = 建小麦农场 / 建蔬菜农场 / 岗位不足，并按紧急度排序")

	var poor := _fresh()
	for g in (poor.s["goods"] as Dictionary).keys():
		poor.s["goods"][g] = 0.0
	var ad3 := Advisor.new(poor)
	ad3.cat_of = Callable(self, "_cat_of")
	var gate := ad3.build_gate("wheat_farm")
	if not _chk(not bool(gate["ok"]) and (gate["reasons"] as PackedStringArray).size() == 1
			and String((gate["reasons"] as PackedStringArray)[0]).contains("木材 4"),
			"木材清零后建小麦农场应当报「缺 木材 4」（得到 %s）" % str(gate["reasons"])):
		return false
	var item := _find(ad3.plan(), "quest_q01_bread_chain_wheat_farm")
	if not _chk((item["how"] as Array).size() >= 2, "缺料时建议里要追加一条「料从哪来」"):
		return false
	if not _chk(ad3.plan_text().contains("伐木场"), "缺木材要指出由伐木场产"):
		return false
	_ok("计算：够不够 / 缺多少全走引擎的 `_cost_of` 与 `_can_afford`，缺料点出生产建筑")

	var locked := _fresh()
	var ad4 := Advisor.new(locked)
	ad4.cat_of = Callable(self, "_cat_of")
	var g4 := ad4.build_gate("quarry")
	if not _chk(not bool(g4["ok"]) and String(g4["tech"]) == "stonework"
			and String((g4["reasons"] as PackedStringArray)[0]).contains("石作"),
			"没研究石作时采石场应当先要科技（得到 %s）" % str(g4["reasons"])):
		return false
	_ok("计算：科技锁走 `tech_for_building`，缺前置会说先研究哪一项")
	return true

# ---------------------------------------------------------------------------
# 7. 只读契约：算完之后状态逐字节不变
# ---------------------------------------------------------------------------
func _readonly_section() -> bool:
	var sim := _fresh()
	_add_shop(sim, "wheat_farm", 2)
	_add_shop(sim, "coarse_mill", 1)
	_add_shop(sim, "coarse_bakery", 1)
	sim.s["construction"].append({
		"id": "c#1-hut", "kind": "housing", "buildingId": "", "shopId": "",
		"housingId": "hut", "remaining": 12.0, "totalRequired": 12.0, "started": false,
	})
	var ad := Advisor.new(sim)
	ad.cat_of = Callable(self, "_cat_of")
	ad.question = "先补粮还是先盖房？"
	var before := JSON.stringify(sim.s)
	ad.plan()
	ad.plan_text()
	ad.digest()
	ad.situation_text()
	ad.rules_text()
	ad.messages()
	ad.quest_rows()
	ad.buildables()
	ad.tech_summary()
	var after := JSON.stringify(sim.s)
	if not _chk(before == after, "Advisor 跑完全套之后 sim.s 必须逐字节不变（只读契约）"):
		return false
	_ok("契约：Advisor 全程只读，仿真状态一个字节都没动（黄金轨迹不受影响）")
	return true

# ---------------------------------------------------------------------------
# 8. 渐进显示：建议里不许出现还没解锁的任务
# ---------------------------------------------------------------------------
func _reveal_section() -> bool:
	var sim := _fresh()
	var ad := Advisor.new(sim)
	ad.cat_of = Callable(self, "_cat_of")
	var visible := {}
	for q in sim.quest_view():
		visible[String(q["id"])] = true
	for s in ad.plan():
		var id := String(s["id"])
		if not id.begins_with("quest_"):
			continue
		var hit := false
		for qid in visible.keys():
			if id.begins_with("quest_%s_" % String(qid)):
				hit = true
				break
		if not _chk(hit, "建议 %s 引用了不可见的任务（渐进显示被破坏）" % id):
			return false
	var locked_title := String(db.quests["q18_pop1000"]["title"])
	var prompt := ad.user_prompt()
	if not _chk(not prompt.contains(locked_title),
			"提示词里不许出现未解锁任务的标题「%s」" % locked_title):
		return false
	if not _chk(prompt.contains("粗面包链") and prompt.contains("蔬菜农场"), "可见任务的标题要在提示词里"):
		return false
	if not _chk(ad.system_prompt().contains("绝对不要猜测或提及还没出现的任务"),
			"系统提示必须写明不许剧透后续任务"):
		return false
	if not _chk(ad.quest_rows().size() == visible.size(), "quest_rows 只给可见任务"):
		return false
	# 人设：**瑟拉菲娜**（用户 2026-10 给了完整人设：22 岁、猫系傲娇、紫瞳泪痣、
	# 紫色露肩长裙，口头禅「哼，才不是特意为你预言呢」）。人设是外壳，
	# 所以这里只锁"外壳在不在 + 别把机器词漏进戏里"，不锁具体措辞 —— 改文案不该红线。
	var sys := ad.system_prompt()
	# 格式（用户 2026-10 定的新样子）：我明白了 → 我看见了，你应该 → 一条一句措施。
	# **没有编号、没有「征兆 / 应对 / 预言」标签** —— 那套旧格式会让她像个操作手册。
	for needle in ["瑟拉菲娜", "预言家", "水晶球", "我明白了", "我看见了", "你应该", "木匠"]:
		if not _chk(sys.contains(needle), "系统提示里少了人设 / 格式的「%s」" % needle):
			return false
	for gone in ["征兆", "应对", "预言："]:
		if not _chk(not sys.contains(gone),
				"旧格式的标签「%s」不该再出现在提示里（用户 2026-10 明确要求去掉）" % gone):
			return false
	# 措施要用**世界里的人**去办（用户 2026-10："让她用世界里的说法点一句，
	# 比如「让木匠把菜园的架子搭起来」，不提页签"）。
	if not _chk(sys.contains("派谁") and sys.contains("农夫"),
			"措施里要交代「派谁去办」（工匠 / 农夫 / 磨坊工 / 读书人 / 石匠）"):
		return false
	if not _chk(sys.contains("傲娇") or sys.contains("猫系"),
			"必须写明性格是猫系傲娇（否则只会是一个中性的顾问）"):
		return false
	if not _chk(sys.contains("江湖术士"),
			"必须写明「不是江湖术士」（否则模型会滑向含糊其辞）"):
		return false
	if not _chk(sys.contains("没有信息量"),
			"必须明写「不许说没信息量的空话」—— 傲娇这个人设最容易滑向「来日可期」"):
		return false
	# ⚠️ **戏里不许出现机器词**（用户 2026-10："不要说什么沙盘，可以说水晶球"）：
	# 模型看到的每一段字（系统提示 + 简报 + 工具声明）都按水晶球来写，
	# 否则它会在回答里冒出"模拟""沙盘""引擎"，那就出戏了。
	var all_model_text := sys + "\n" + ad.user_prompt()
	var ag_text := ProphetAgent.new(sim, "测试")
	var brief := ""
	for m in (ag_text.next_request()["messages"] as Array):
		brief += String((m as Dictionary)["content"]) + "\n"
	for t in ag_text.tool_schema():
		brief += JSON.stringify(t)
	all_model_text += "\n" + brief
	for banned in ["沙盘", "模拟引擎", "引擎拒绝", "simulate_plan"]:
		if not _chk(not all_model_text.contains(banned),
				"模型看到的字里不许出现机器词「%s」（要说水晶球）" % banned):
			return false
	# 玩家看得到的**只有**瑟拉菲娜这一个口吻：面板上原来那块「本地分析」已经拿掉了
	# （用户 2026-10："不要本地分析"）。`plan_text()` 还在，它是引擎侧的纯文本渲染
	# （内容正确性的断言拿它当靶子），但**不再是给玩家看的一块**。
	if not _chk(ad.plan_text().contains("为什么：") and ad.plan_text().contains("怎么做："),
			"`plan_text()` 仍是引擎侧的结构化渲染（为什么 / 怎么做）"):
		return false
	_ok("契约：只引用可见任务；口吻是瑟拉菲娜（水晶球 + 我明白了 / 我看见了，你应该 / 措施）")
	return true

# ---------------------------------------------------------------------------
# 9. 提示词内容：规则从内容里取数、局势包有该有的分块
# ---------------------------------------------------------------------------
func _prompt_section() -> bool:
	var sim := _fresh()
	var ad := Advisor.new(sim)
	var rules := ad.rules_text()
	for needle in ["500 金", "1000 金", "55", "0.45", "只花材料，不花金币", "次日黎明才生效",
			"粗面包 1/人/天", "研究所"]:
		if not _chk(rules.contains(needle), "规则摘要里少了「%s」" % needle):
			return false
	sim.db.economy["immigrationSatThreshold"] = 61.0
	var follows := ad.rules_text().contains("61")
	sim.db.economy["immigrationSatThreshold"] = 55.0
	if not _chk(follows, "规则摘要里的移民门槛要跟着内容变（数字是读的，不是写死的）"):
		return false

	var sit := ad.situation_text()
	for needle in ["住房：容量 24", "岗位 0 / 人口 12", "食物：基础食物日需 18",
			"当前任务：", "可建清单", "关键物资", "现在可研究", "仓储"]:
		if not _chk(sit.contains(needle), "局势包少了「%s」" % needle):
			return false
	if not _chk(not sit.contains("城镇中心（"), "可建清单不该列城镇中心（地图上固定那一座）"):
		return false
	if not _chk(_font_ok(ad.plan_text()) and _font_ok(sit) and _font_ok(rules),
			"引擎侧的结构化渲染 / 局势包 / 规则摘要里不许有像素字体画不出的字"):
		return false
	if not _chk(ad.system_prompt().length() > 200
			and not ad.user_prompt().contains("【殿下的问话】"),
			"没写问话时不该出现「【殿下的问话】」那一段（也不能空着什么都不说）"):
		return false
	ad.question = "我的食物不够了怎么办"
	var p1 := ad.user_prompt()
	if not _chk(p1.contains("【殿下的问话】\n我的食物不够了怎么办"),
			"写了问话就要原样带上那一段：%s" % p1.substr(p1.length() - 160)):
		return false
	if not _chk(ad.system_prompt().contains("殿下的问话"),
			"系统提示要交代「先答他那句话，再给该做的事」"):
		return false
	if not _chk(ad.system_prompt().contains("为什么") and ad.system_prompt().contains("我看见了"),
			"要交代「问为什么时先答一句『我看见了：』」"):
		return false
	_ok("提示词：规则与局势都从内容里取数（改内容就跟着变），分块齐、问话原样带上、无缺字形")
	return true

# ---------------------------------------------------------------------------
# 9b. 预言家的冷却：5 天一次（见 docs/ai-assist.md §六）
# ---------------------------------------------------------------------------
func _cooldown_section() -> bool:
	var sim := _fresh()
	if not _chk(sim.s.has("prophet"), "新开局的 state 里应当有 prophet 段（冷却的记账）"):
		return false
	if not _chk(sim.prophet_days_left() == 0 and sim.can_ask_prophet(),
			"开局就能问（`lastAskDay` = -1 = 还没问过）"):
		return false
	# 问到了 → 从当天起算冷却
	sim.mark_prophet_asked()
	if not _chk(not sim.can_ask_prophet() and sim.prophet_days_left() == SimCore.PROPHET_COOLDOWN_DAYS,
			"问过之后应当要等 %d 天（得到 %d）" % [SimCore.PROPHET_COOLDOWN_DAYS,
				sim.prophet_days_left()]):
		return false
	# 每过一天少一天；第 5 天正好放行
	for d in range(1, SimCore.PROPHET_COOLDOWN_DAYS):
		sim.s["day"] = d
		if not _chk(not sim.can_ask_prophet()
				and sim.prophet_days_left() == SimCore.PROPHET_COOLDOWN_DAYS - d,
				"第 %d 天：应当还剩 %d 天（得到 %d）" % [d, SimCore.PROPHET_COOLDOWN_DAYS - d,
					sim.prophet_days_left()]):
			return false
	sim.s["day"] = SimCore.PROPHET_COOLDOWN_DAYS
	if not _chk(sim.can_ask_prophet() and sim.prophet_days_left() == 0,
			"第 %d 天正好可以再问（边界：>= last + %d）" % [SimCore.PROPHET_COOLDOWN_DAYS,
				SimCore.PROPHET_COOLDOWN_DAYS]):
		return false

	# 冷却必须**进存档** —— 不然退出重进 / 读档就能刷问话
	var path := "user://ai_test_save.json"
	sim.mark_prophet_asked()
	var day := int(sim.s["day"])
	if not _chk(SaveManager.save_to(path, sim) == OK, "存档应当写得进去"):
		return false
	var back: SimCore = SaveManager.load_into(path, sim.db)
	DirAccess.remove_absolute(path)
	if not _chk(back != null, "存档应当读得回来"):
		return false
	if not _chk(int((back.s["prophet"] as Dictionary)["lastAskDay"]) == day
			and not back.can_ask_prophet(),
			"读档之后冷却还得在（第 %d 天问的）—— 不然读档就能刷问话" % day):
		return false
	# 老存档（没有 prophet 段）要能迁移
	var old: Dictionary = back.s.duplicate(true)
	old.erase("prophet")
	var migrated := SimCore.new(back.db)
	migrated.s = old
	SaveManager._sanitize(migrated.s, migrated.db)
	if not _chk(migrated.s.has("prophet")
			and int((migrated.s["prophet"] as Dictionary)["lastAskDay"]) == -1
			and migrated.can_ask_prophet(),
			"2026-10 之前的存档（没有 prophet 段）迁移后应当是「没问过」"):
		return false
	_ok("冷却：5 天一次、问过才起算、跨天递减、进存档、老存档能迁移")

	# 历史预言：**发在 `prophet.log` 里**，跟存档一起走（面板左栏读的就是它）。
	# ⚠️ 只有真拿到回答（`answer` 非空）才写键 —— 新开局的状态里没有这个键，
	#    所以黄金摘要不会因为这一条功能而漂。
	var psim: SimCore = SimCore.new(sim.db)
	psim.s = sim.s.duplicate(true)
	psim.s["prophet"] = {"lastAskDay": -1}
	if not _chk((psim.prophecy_log() as Array).is_empty(),
			"新开局的历史应当是空的（连 log 键都不该有）"):
		return false
	psim.mark_prophet_asked("我下一步要做什么", "我看见了，你应该先把菜种上")
	var plog: Array = psim.prophecy_log()
	if not _chk(plog.size() == 1
			and String(plog[0]["q"]) == "我下一步要做什么"
			and String(plog[0]["t"]).contains("我看见了")
			and int(plog[0]["d"]) == int(psim.s["day"]),
			"记一次问答之后，历史里应当正好一条（天数 / 问话 / 原文）：%s" % str(plog)):
		return false
	# 空回答只记冷却、不进历史（门槛与截图工具会这么调）
	psim.mark_prophet_asked("", "")
	if not _chk((psim.prophecy_log() as Array).size() == 1,
			"没拿到回答时不该往历史里塞空条目"):
		return false
	# 第一章收尾那次「免费预言」（用户 2026-10）：**历史照记、不占冷却**。
	# `charge_cooldown = false` 的那条路 —— 玩家一进游戏不该被罚等 5 天。
	var fsim: SimCore = SimCore.new(sim.db)
	fsim.s = sim.s.duplicate(true)
	fsim.s["prophet"] = {"lastAskDay": -1}
	fsim.mark_prophet_asked("我下一步要做什么", "我看见了，你先把菜种上", false)
	if not _chk(fsim.can_ask_prophet() and fsim.prophet_days_left() == 0
			and (fsim.prophecy_log() as Array).size() == 1,
			"免费预言应当进历史但**不吃冷却**（days_left=%d / 历史 %d 条）" % [
				fsim.prophet_days_left(), (fsim.prophecy_log() as Array).size()]):
		return false
	# 上限 30 条，超出丢最旧的
	for i in 40:
		psim.mark_prophet_asked("问 %d" % i, "答 %d" % i)
	if not _chk((psim.prophecy_log() as Array).size() == SimCore.PROPHECY_LOG_MAX,
			"历史应当封顶 %d 条（实际 %d）" % [SimCore.PROPHECY_LOG_MAX,
				(psim.prophecy_log() as Array).size()]):
		return false
	# 历史必须**跟着存档走**：`prophet` 整段是原样过 `SaveManager._sanitize()` 的
	# （它只把 `lastAskDay` 修成 int），所以 log 不会被吞。这里直接验这一点 ——
	# 比真写一个文件更稳（写文件那条在 headless 下要碰 user:// 的时序）。
	var raw: Dictionary = psim.s.duplicate(true)
	SaveManager._sanitize(raw, psim.db)
	if not _chk((raw.get("prophet", {}) as Dictionary).has("log")
			and ((raw["prophet"] as Dictionary)["log"] as Array).size() == SimCore.PROPHECY_LOG_MAX,
			"存档净化不许吞掉 prophet.log（预言页左栏的历史靠它）"):
		return false
	_ok("历史预言：真回答才记、空回答不记、封顶 30 条、进存档")
	return true

# ---------------------------------------------------------------------------
# 10. 沙盘（把引擎当工具）：只读 / 真的落地 / 确定性 / 会拒
# ---------------------------------------------------------------------------
func _trial_section() -> bool:
	var sim := _fresh()
	var before := JSON.stringify(sim.s)
	var base := Trial.run_baseline(sim, Trial.MAX_DAYS)
	if not _chk(base.has("pop") and base.has("food") and base.has("problems"),
			"对照（什么都不做）得是一份完整的汇总"):
		return false
	var plan := {"label": "先补粮", "days": 5, "actions": [
		{"day": 1, "type": "build", "id": "wheat_farm"},
		{"day": 2, "type": "build", "id": "coarse_mill"},
	]}
	var res := Trial.run(sim, plan, base)
	if not _chk(JSON.stringify(sim.s) == before,
			"**沙盘跑完真实状态必须逐字节不变**（这是「引擎当工具」的前提）"):
		return false
	# 落地了吗：排上队 或 已建成，二者之和应当正好等于下的 2 条 build
	var landed := int(res["delta"]["construction"]) + int(res["delta"]["shops"])
	if not _chk(landed == 2, "两条 build 应当排上队或建成（实际落地 %d 条）" % landed):
		return false
	if not _chk((res["rejected"] as Array).is_empty(), "这两条命令不该被拒：%s" % str(res["rejected"])):
		return false
	_ok("沙盘：只读真实状态、命令真的落地（排上队/建成）、对照齐全")

	# 确定性：同一份状态 + 同一个方案 = 同一份结果
	var again := Trial.run(sim, plan, base)
	if not _chk(JSON.stringify(again["summary"]) == JSON.stringify(res["summary"]),
			"同一个方案跑两遍结果必须逐位相同（rng 状态一起复制）"):
		return false
	# 引擎自己拒：不认识的建筑 / 科技没解锁 / 村里还没有那座建筑
	var bad := Trial.run(sim, {"label": "瞎下", "days": 3, "actions": [
		{"type": "build", "id": "nope_thing"},
		{"type": "build", "id": "quarry"},
		{"type": "expand", "id": "nothing_here"},
		{"type": "demolish", "id": "town_center"},
	]}, base)
	var rej: Array = bad["rejected"]
	if not _chk(rej.size() == 4, "四条乱下的命令都应当被拒（实际 %d 条：%s）" % [rej.size(), str(rej)]):
		return false
	if not _chk(String(rej[0]).contains("没有叫") and String(rej[1]).contains("还锁着")
			and String(rej[2]).contains("还没有") and String(rej[3]).contains("不认的命令类型"),
			"拒绝理由要说人话（模型下一轮能照着改）：%s" % str(rej)):
		return false
	# 天数 / 命令条数有上限
	var clamp_plan := {"label": "超量", "days": 99, "actions": []}
	for i in 20:
		clamp_plan["actions"].append({"type": "build", "id": "wheat_farm"})
	var clamped := Trial.run(sim, clamp_plan, base)
	if not _chk(int(clamped["days"]) == Trial.MAX_DAYS,
			"days 应当被夹到 %d（得到 %d）" % [Trial.MAX_DAYS, int(clamped["days"])]):
		return false
	_ok("沙盘：确定性、拒绝理由说人话、天数被夹到 %d 天" % Trial.MAX_DAYS)

	# 换代太快的局面（12 人开局）里，5 天跑完仍然要 < 几百 ms —— 工具是同步跑的
	var t0 := Time.get_ticks_usec()
	for i in ProphetAgent.MAX_PLANS:
		Trial.run(sim, plan, base)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	if not _chk(ms < 2000.0, "一轮 %d 个方案要跑得动（实测 %.0f ms，上限 2000）" % [
			ProphetAgent.MAX_PLANS, ms]):
		return false
	_ok("沙盘：一轮 %d 个方案耗时 %.0f ms（同步跑得起）" % [ProphetAgent.MAX_PLANS, ms])
	return true

# ---------------------------------------------------------------------------
# 11. 多轮协议：3 轮、最终轮要说、收尾关工具
# ---------------------------------------------------------------------------
func _protocol_section() -> bool:
	var ag := ProphetAgent.new(_fresh(), "我的食物不够了怎么办")
	# 工具声明
	var tools := ag.tool_schema()
	if not _chk(tools.size() == 1
			and String((tools[0] as Dictionary)["function"]["name"]) == ProphetAgent.TOOL_NAME,
			"应当只暴露一个工具 `%s`" % ProphetAgent.TOOL_NAME):
		return false
	var params: Dictionary = (tools[0] as Dictionary)["function"]["parameters"]
	if not _chk((params["required"] as Array).has("actions")
			and (params["properties"] as Dictionary).has("days"),
			"工具参数要写清 days 与 actions"):
		return false
	# 第 1 步：plan，带工具，简报里有"什么都不做的对照"
	var req1 := ag.next_request()
	if not _chk(String(req1["stage"]) == "plan" and (req1["tools"] as Array).size() == 1,
			"第 1 步应当是 plan 且带工具"):
		return false
	var brief := ""
	for m in (req1["messages"] as Array):
		if String((m as Dictionary)["role"]) == "user":
			brief += String((m as Dictionary)["content"])
	# 简报要交代清楚三件事（但**用戏里的说法**：水晶球 / 卦，不写沙盘）
	if not _chk(brief.contains("水晶球") and brief.contains("什么都不做")
			and brief.contains("最后一轮"),
			"简报里要说清：水晶球是什么、什么都不做的那一卦、第 3 轮是最后一轮"):
		return false
	_ok("协议：只暴露一个水晶球工具，第 1 步 plan + 简报（含对照与轮次规则）")

	# 喂 3 个方案 → 跑 3 个，进第 2 轮
	var r1 := ag.accept(_calls_reply(3))
	if not _chk(String(r1["kind"]) == "trials" and ag.rounds_done == 1 and ag.trials.size() == 3,
			"第 1 轮应当跑 3 个方案（实际 %d 个 / rounds=%d）" % [ag.trials.size(), ag.rounds_done]):
		return false
	var req2 := ag.next_request()
	if not _chk(String(req2["stage"]) == "review" and _role_count(req2, "tool") == 3,
			"第 2 步应当是 review，且消息里有 3 条沙盘结果（实际 %d 条）" % _role_count(req2, "tool")):
		return false
	# 第 2 轮 → last，且明确写"这是最后一轮"
	ag.accept(_calls_reply(2))
	var req3 := ag.next_request()
	if not _chk(String(req3["stage"]) == "last", "第 3 步应当是 last（实际 %s）" % req3["stage"]):
		return false
	if not _chk(_last_user_text(req3).contains("最后一轮"),
			"**最后一轮必须明说**（用户要求：「第三轮要告诉他这是最终轮」）：%s" % _last_user_text(req3)):
		return false
	# 第 3 轮 → conclude：**工具关掉**，逼它说话
	ag.accept(_calls_reply(1))
	var req4 := ag.next_request()
	if not _chk(String(req4["stage"]) == "conclude" and (req4["tools"] as Array).is_empty(),
			"3 轮跑完应当进 conclude 且**不带工具**（实际 stage=%s tools=%d）" % [
				req4["stage"], (req4["tools"] as Array).size()]):
		return false
	# 收尾给文本 → 结束
	var fin := ag.accept({"ok": true, "text": "我看见了，你应该先补粮。", "tool_calls": []})
	if not _chk(String(fin["kind"]) == "final" and String(ag.final_text).contains("先补粮"),
			"收尾那次回答应当成为结论"):
		return false
	if not _chk(ag.rounds_done == ProphetAgent.MAX_ROUNDS,
			"一共只能跑 %d 轮（实际 %d）" % [ProphetAgent.MAX_ROUNDS, ag.rounds_done]):
		return false
	_ok("协议：3 轮封顶、第 3 轮明说「最后一轮」、收尾关掉工具、结论落在 final_text")

	# 轮次用满之后还在试方案 → 拒绝执行（不再跑沙盘），转收尾
	var ag2 := ProphetAgent.new(_fresh(), "测试")
	for i in ProphetAgent.MAX_ROUNDS:
		ag2.accept(_calls_reply(1))
	var before_trials := ag2.trials.size()
	var refused := ag2.accept(_calls_reply(2))
	if not _chk(String(refused["kind"]) == "refused" and ag2.trials.size() == before_trials,
			"轮次用满后不许再跑沙盘（实际 kind=%s，方案数 %d → %d）" % [
				refused["kind"], before_trials, ag2.trials.size()]):
		return false
	if not _chk(String(ag2.next_request()["stage"]) == "conclude", "被拒之后应当转收尾"):
		return false

	# 一轮给太多方案 → 只跑上限那么多
	var ag3 := ProphetAgent.new(_fresh(), "测试")
	ag3.accept(_calls_reply(9))
	if not _chk(ag3.trials.size() == ProphetAgent.MAX_PLANS,
			"一轮最多跑 %d 个方案（实际 %d）" % [ProphetAgent.MAX_PLANS, ag3.trials.size()]):
		return false

	# 工具名不认识 / 参数不是合法 JSON → 都回一条"说明原因"的结果，不崩
	var ag4 := ProphetAgent.new(_fresh(), "测试")
	var weird := {"ok": true, "text": "", "tool_calls": [
		{"id": "c1", "name": "no_such_tool", "arguments": "{}", "args": {}, "bad": ""},
		{"id": "c2", "name": ProphetAgent.TOOL_NAME, "arguments": "{oops", "args": {}, "bad": "{oops"},
	]}
	var res4 := ag4.accept(weird)
	if not _chk(String(res4["kind"]) == "trials" and ag4.trials.size() == 2,
			"坏工具/坏参数也要各回一条结果（而不是整条失败）"):
		return false
	var shown := ""
	for t in ag4.trials:
		shown += String(t["display"])
	if not _chk(shown.contains("没有叫") and shown.contains("不是合法 JSON"),
			"两条坏调用都要说清原因：%s" % shown):
		return false
	_ok("协议：轮次用满会拒跑、一轮最多 %d 个、坏工具/坏参数只回原因不崩" % ProphetAgent.MAX_PLANS)

	# 文本兜底：不支持函数调用的端点，把方案写成 JSON 块也要认
	var ag5 := ProphetAgent.new(_fresh(), "测试")
	var text_reply := {"ok": true, "tool_calls": [], "text":
		"```json\n{\"label\":\"文本方案\",\"days\":5,\"actions\":[{\"type\":\"build\",\"id\":\"wheat_farm\"}]}\n```"}
	var res5 := ag5.accept(text_reply)
	if not _chk(String(res5["kind"]) == "trials" and ag5.trials.size() == 1,
			"文本 JSON 块应当被当成方案跑掉（兜底协议）"):
		return false
	if not _chk(String((ag5.trials[0] as Dictionary)["display"]).begins_with("文本方案"),
			"文本兜底也要带上 label"):
		return false
	# 但如果正文很长（明显是在给结论），就不许劫持成方案
	var ag6 := ProphetAgent.new(_fresh(), "测试")
	var long_prose := "这里是一大段结论性的正文，明显不是方案。".repeat(3)
	var prose := {"ok": true, "tool_calls": [], "text":
		"我看见了：仓里只剩一点粮，先别急着盖房。" + long_prose
		+ "{\"label\":\"x\",\"days\":5,\"actions\":[{\"type\":\"build\",\"id\":\"wheat_farm\"}]}"}
	var res6 := ag6.accept(prose)
	if not _chk(String(res6["kind"]) == "final" and ag6.trials.is_empty(),
			"正文很长时应当当结论看，不许被 JSON 块劫持成方案"):
		return false
	_ok("协议：文本 JSON 兜底能跑，但「正文很长」的结论不会被劫持")
	return true

## 造一个"模型回了 N 个 tool_calls"的假回答。
func _calls_reply(n: int) -> Dictionary:
	var calls := []
	for i in n:
		calls.append({"id": "call%d" % (i + 1), "name": ProphetAgent.TOOL_NAME,
			"arguments": JSON.stringify({"label": "方案%d" % (i + 1), "days": 5, "actions": [
				{"type": "build", "id": "wheat_farm"}]}),
			"args": {"label": "方案%d" % (i + 1), "days": 5,
				"actions": [{"type": "build", "id": "wheat_farm"}]},
			"bad": ""})
	return {"ok": true, "text": "", "tool_calls": calls}

func _role_count(req: Dictionary, role: String) -> int:
	var n := 0
	for m in (req["messages"] as Array):
		if String((m as Dictionary)["role"]) == role:
			n += 1
	return n

func _last_user_text(req: Dictionary) -> String:
	var out := ""
	for m in (req["messages"] as Array):
		if String((m as Dictionary)["role"]) == "user":
			out = String((m as Dictionary)["content"])
	return out

# ---------------------------------------------------------------------------
# 12. 中局：建好食物链、跑一次黎明之后的建议
# ---------------------------------------------------------------------------
func _midgame_section() -> bool:
	var sim := _fresh()
	for g in (sim.s["goods"] as Dictionary).keys():
		sim.s["goods"][g] = 5000.0
	for bid in ["wheat_farm", "coarse_mill", "coarse_bakery", "vegetable_farm"]:
		_add_shop(sim, bid, 1)
	sim._run_dawn()
	var done: Dictionary = sim.s["quests"]["done"]
	if not _chk(done.has("q01_bread_chain") and done.has("q02_vegetable"),
			"建好两条链之后黎明应当结算任务 1、2（得到 %s）" % str(done.keys())):
		return false
	var ad := Advisor.new(sim)
	ad.cat_of = Callable(self, "_cat_of")
	var plan := ad.plan()
	if not _chk(not _has(plan, "quest_q01_bread_chain_wheat_farm"),
			"已完成的任务不该再出现在建议里（得到 %s）" % str(_ids(plan))):
		return false
	var cap := _find(plan, "quest_q03a_housing_capacity_cap")
	if not _chk(not cap.is_empty(), "应当建议「把住房容量撑到 32」（得到 %s）" % str(_ids(plan))):
		return false
	if not _chk(String(cap["why"]).contains("还差 8"),
			"住房容量建议要算出差 8（得到 %s）" % String(cap["why"])):
		return false
	if not _chk(String(cap["how"][0]).contains("2 座茅屋"),
			"差 8 个床位 = 2 座茅屋（得到 %s）" % String(cap["how"][0])):
		return false
	var prod := _find(plan, "quest_q03b_output_prod_coarse_bread")
	if not _chk(not prod.is_empty(), "应当建议提粗面包产量（得到 %s）" % str(_ids(plan))):
		return false
	if not _chk(String(prod["why"]).contains("目标 30"),
			"产量建议要写出目标 30（得到 %s）" % String(prod["why"])):
		return false
	_ok("中局：黎明结算之后建议自动换到第 2 章，并算出「差 8 个床位 = 2 座茅屋」")
	return true

# ---------------------------------------------------------------------------
# 13. 规则覆盖：饥饿 / 住房满 / 仓储满 / 工地没产能 / 研究队列
# ---------------------------------------------------------------------------
func _coverage_section() -> bool:
	var sim := _fresh()
	var hist: Array = sim.s["history"]
	hist[hist.size() - 1]["hungry"] = 3
	var ad := Advisor.new(sim)
	ad.cat_of = Callable(self, "_cat_of")
	var plan := ad.plan()
	if not _chk(String(plan[0]["id"]) == "food_shortage" and String(plan[0]["tag"]) == "紧急",
			"有人挨饿时第一条必须是紧急的食物建议（得到 %s）" % str(_ids(plan))):
		return false
	if not _chk(String(plan[0]["why"]).contains("3 人挨饿"), "饥饿建议要写出人数"):
		return false
	_ok("规则：挨饿时紧急建议排第一，并指名缺的那一项食物")

	var s2 := _fresh()
	s2.debug_set_housing_units("hut", 3)  # 容量 12 = 人口 12 → 空 0
	s2.s["arrivals"] = 4
	var ad2 := Advisor.new(s2)
	ad2.cat_of = Callable(self, "_cat_of")
	var p2 := ad2.plan()
	var hf := _find(p2, "housing_full")
	if not _chk(not hf.is_empty(), "住房满了要提醒（得到 %s）" % str(_ids(p2))):
		return false
	if not _chk(String(hf["how"][0]).contains("茅屋"), "住房建议要指名房型"):
		return false
	_ok("规则：住房满了 + 有人想来 → 提醒盖房，并算出盖几座")

	var s3 := _fresh()
	s3.s["goods"]["stone"] = 1900.0        # 总存量超过城镇中心的 2000
	var ad3 := Advisor.new(s3)
	var p3 := ad3.plan()
	if not _chk(_has(p3, "storage_full"), "仓储满了要提醒（得到 %s）" % str(_ids(p3))):
		return false
	if not _chk(String(_find(p3, "storage_full")["why"]).contains("已满"), "仓储建议要说明后果"):
		return false
	_ok("规则：仓储满 → 提醒会按比例削减，并给出仓库方案")

	var s4 := _fresh()
	# 建造力是**现算**的：失业的人 × 1 + 建筑工坊产能。让所有人都有班上，
	# 才是"工地停着"的真实场景（没有闲人可派，也没建建筑工坊）。
	for r in s4.s["residents"]:
		r["employed"] = true
	s4.s["construction"].append({
		"id": "c#1-hut", "kind": "housing", "buildingId": "", "shopId": "",
		"housingId": "hut", "remaining": 12.0, "totalRequired": 12.0, "started": false,
	})
	var ad4 := Advisor.new(s4)
	ad4.cat_of = Callable(self, "_cat_of")
	var p4 := ad4.plan()
	if not _chk(_has(p4, "no_build_power"), "建造力为 0 且有工程时要提醒（得到 %s）" % str(_ids(p4))):
		return false
	_ok("规则：工地停着 → 提醒给建筑工坊 / 让失业者出工")

	var s5 := _fresh()
	_add_shop(s5, "research_institute", 1)
	var ad5 := Advisor.new(s5)
	var p5 := ad5.plan()
	if not _chk(_has(p5, "research_idle"), "有研究所但队列空要提醒（得到 %s）" % str(_ids(p5))):
		return false
	var s6 := _fresh()
	_add_shop(s6, "research_institute", 1)
	s6.s["research"]["queue"].append({"id": "stonework", "remaining": 20.0,
		"totalRequired": 20.0, "started": false, "waiting": false})
	s6.s["researchRateToday"] = 0.0
	var ad6 := Advisor.new(s6)
	ad6.cat_of = Callable(self, "_cat_of")
	var p6 := ad6.plan()
	var rs := _find(p6, "research_stalled")
	if not _chk(not rs.is_empty(), "队列有人但吃不到产能要提醒（得到 %s）" % str(_ids(p6))):
		return false
	if not _chk(String(rs["why"]).contains("石作"), "提醒里要写出队首是哪一项科技"):
		return false
	_ok("规则：研究队列空着 / 队首吃不到产能，两种都提醒")

	if not _chk(ad.plan().size() <= Advisor.MAX_PLAN, "建议条数不超过上限"):
		return false
	var seen := {}
	for s in ad.plan():
		var id := String(s["id"])
		if not _chk(not seen.has(id), "建议 id 不许重复：%s" % id):
			return false
		seen[id] = true
	if not _chk(_font_ok(ad.plan_text()), "所有建议文案都要能画出来"):
		return false
	_ok("规则：条数有上限、id 去重、文案无缺字形")
	return true

# ---------------------------------------------------------------------------
# 14. goal 类型全覆盖（内容里新增一种目标，必须先教 Advisor 认识）
# ---------------------------------------------------------------------------
func _goal_types_section() -> bool:
	var seen := {}
	for qid in db.quest_ids:
		for g in (db.quests[qid]["goals"] as Array):
			seen[String(g.get("type", ""))] = true
	for t in seen.keys():
		if not _chk(Advisor.KNOWN_GOAL_TYPES.has(String(t)),
				"内容里出现了 Advisor 不认识的 goal 类型「%s」—— 建议会静默漏掉，去 advisor.gd 补一条" % t):
			return false
	# 每种认识的类型都要在内容里真的被覆盖到（不然白写了）
	for t in Advisor.KNOWN_GOAL_TYPES:
		if not _chk(seen.has(t), "KNOWN_GOAL_TYPES 里的「%s」在内容里没有对应任务（口径表该更新了）" % t):
			return false
	_ok("契约：内容里 %d 种 goal 类型全在 KNOWN_GOAL_TYPES 里" % seen.size())
	return true
