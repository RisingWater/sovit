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
	if not _chk(String(d["base_url"]) == "" and String(d["model"]) == "",
			"没配过时 base_url / model 是空的（空的才算「没配」）"):
		return false
	if not _chk(not AiConfig.is_ready(d), "空 base_url 就是没配好 —— 别拿默认地址去发注定失败的请求"):
		return false
	if not _chk(String(d["api_key"]) == "", "没配过时 api_key 应该是空的"):
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
	_ok("配置：首次读取是「未配置」，只填 base_url + model 即可用（api_key 不强求）")

	d["base_url"] = "http://127.0.0.1:11434/v1"
	d["api_key"] = "sk-abcdefghijklmnop"
	d["model"] = "qwen2.5:7b"
	d["timeout"] = 30.0
	d["max_tokens"] = 512
	d["pause_on_ask"] = false
	if not _chk(AiConfig.save_cfg(d) == OK, "写配置应该成功"):
		return false
	var back := AiConfig.load_cfg()
	if not _chk(String(back["base_url"]) == "http://127.0.0.1:11434/v1"
			and String(back["model"]) == "qwen2.5:7b"
			and String(back["api_key"]) == "sk-abcdefghijklmnop", "配置往返要一模一样"):
		return false
	if not _chk(is_equal_approx(float(back["timeout"]), 30.0)
			and int(back["max_tokens"]) == 512 and not bool(back["pause_on_ask"]),
			"超时 / 回复上限 / 自动暂停也要往返"):
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
	_ok("接入：响应解析覆盖成功 / 401 / 500 / 空体 / 非 JSON / 无 choices / 200 里带错误")
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
	_ok("界面：AI 辅助的图标在位（32x32，顶栏 16px / 面板标题 32px）")
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
			"开局可见任务 2 条（得到 %d）" % rows.size()):
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
	# 人设：**隐居的预言家**（用户 2026-10 定：口吻要符合游戏背景）。
	# 人设是外壳，所以这里只锁"外壳在不在"，不锁具体措辞 —— 改文案不该红线。
	var sys := ad.system_prompt()
	for needle in ["预言家", "征兆", "应对", "预言："]:
		if not _chk(sys.contains(needle), "系统提示里少了人设 / 格式的「%s」" % needle):
			return false
	if not _chk(sys.contains("江湖术士"),
			"必须写明「你是卜者但不是江湖术士」（否则模型会滑向含糊其辞）"):
		return false
	if not _chk(sys.contains("没有信息量"),
			"必须明写「不许说没信息量的空话」—— 预言家这个人设最容易滑向「来日可期」"):
		return false
	# 本地分析那半边仍是**账房口吻**（数字、条目）：两种口吻并存是刻意的，别被统一掉
	if not _chk(ad.plan_text().contains("为什么：") and ad.plan_text().contains("怎么做："),
			"本地分析仍应是账房口吻（为什么 / 怎么做 的结构化条目）"):
		return false
	_ok("契约：只引用可见任务；AI 那半边是隐居的预言家（征兆 / 应对 / 预言），本地分析仍是账房口吻")
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
			"本地分析 / 局势包 / 规则摘要里不许有像素字体画不出的字"):
		return false
	if not _chk(ad.system_prompt().length() > 200 and ad.user_prompt().contains("【玩家的追问】") == false,
			"没追问时不该出现追问那一段"):
		return false
	ad.question = "先补粮还是先盖房？"
	if not _chk(ad.user_prompt().contains("【玩家的追问】"), "有追问时要带上那一段"):
		return false
	_ok("提示词：规则与局势都从内容里取数（改内容就跟着变），分块齐、无缺字形")
	return true

# ---------------------------------------------------------------------------
# 10. 中局：建好食物链、跑一次黎明之后的建议
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
# 11. 规则覆盖：饥饿 / 住房满 / 仓储满 / 工地没产能 / 研究队列
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
	s2.s["housing"]["hut"] = 3.0          # 容量 12 = 人口 12 → 空 0
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
# 12. goal 类型全覆盖（内容里新增一种目标，必须先教 Advisor 认识）
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
