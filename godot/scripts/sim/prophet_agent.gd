class_name ProphetAgent
extends RefCounted

# ===========================================================================
# 预言家的一次"问话"= 一场**多轮试方案**的对话（用户 2026-10 定）
#
# 原话：
#   "ai预测不应该只有一轮llm对话，应该把游戏模拟引擎作为一个tool给ai，让他可以在决策后，
#    跑一下看看后续几天会怎么样。正常可以让他给5日的决策，3-5个方案，然后跑一下看看结果，
#    返回结果。如果ok就回答，如果不ok，再来3-5个方案再跑。不能超过3轮（第三轮要告诉他这是最终轮）"
#
# 所以流程是：
#
#   第 1 轮  给 3~5 个方案 → 沙盘各跑 5 天 → 把结果喂回去
#   第 2 轮  不满意就再给 3~5 个（不同思路）→ 再跑 → 喂回去
#   第 3 轮  **明确告诉它"这是最后一轮"** → 再跑最后 3~5 个
#   收尾     关掉工具，让它按瑟拉菲娜的口吻给结论（数字只能来自沙盘或局势包）
#
# ⚠️ **"沙盘"是代码里的叫法，不是给玩家/给模型看的**（用户 2026-10）：
#    模型看到的每一个字都按瑟拉菲娜的水晶球来写（`_briefing()` / `tool_schema()` 里
#    只有「球 / 卦 / 显现」），面板上也**一条沙盘结果都不画** —— 那会直接破坏沉浸。
#    机制不变：还是 `Trial` 在副本上真跑，只是戏里叫"拨水晶球"。
#
# 也就是**最多 4 次 HTTP 请求**（3 轮试方案 + 1 次收尾）；第 3 轮若直接给结论就只有 3 次。
#
# ⚠️ 这个类是**纯的**（RefCounted，不碰 Node / 不碰网络）：
#    状态机、工具 schema、方案校验与执行、喂回去的消息，全在这里；
#    `ui/ai_panel.gd` 只负责"把 next_request() 发出去、把回来的东西交给 accept()"。
#    于是整条协议可以 headless 测（门槛 `ai_test` 就是拿假回答喂它）。
#
# ⚠️ 两条协议都认：
#    ① 原生 function calling（`tools` + `tool_calls`，DeepSeek / OpenAI / ollama / vLLM…）
#    ② 文本兜底：回复里带 `{"actions":[...], "days":5}` 这种 JSON 块（不支持函数调用的端点）
# ===========================================================================

## 最多几轮试方案。用户定：不能超过 3 轮，第 3 轮要告诉它这是最终轮。
const MAX_ROUNDS := 3
## 一轮最多跑几个方案（用户定：3~5 个）。
const MAX_PLANS := 5
## 沙盘默认跑几天（用户定：5 日的决策）。
const TRIAL_DAYS := 5
const TOOL_NAME := "scry"

var advisor: Advisor
## 玩家写的那一行问话（原样进提示词）。
var question := ""
## 已经跑到第几轮（0 = 还没跑过）。
var rounds_done := 0
## 阶段：plan → review → last → conclude → done。
var stage := "plan"
## 最后那条回答（预言家的结论）。
var final_text := ""
## 所有跑过的方案（面板列一张小表用的）。
var trials: Array = []
## 每次收尾/试跑给面板的进度行。

var _messages: Array = []
## 什么都不做的对照，按天数缓存（所有方案的 delta 都跟它比）。
var _baseline := {}

func _init(sim: SimCore, q: String = "", cat_of: Callable = Callable()) -> void:
	advisor = Advisor.new(sim)
	# 建造栏页签名由表现层注入（sim 层不该知道页签叫什么）；拿不到就不编页签名。
	if cat_of.is_valid():
		advisor.cat_of = cat_of
	question = q
	advisor.question = q
	_messages = advisor.messages()
	# 第一条"水晶球简报"：告诉它球里能看见什么、能拨出几种未来、有几轮
	_messages.append({"role": "user", "content": _briefing()})


# ---------------------------------------------------------------------------
# 工具声明（OpenAI function calling 的 tools 数组）
#
# ⚠️ 工具名与描述都写成**瑟拉菲娜能理解、也贴人设的样子**（`scry` = 凝视水晶球）。
#    模型看到的每一个字都算提示词的一部分 —— 写 "simulate_plan / 沙盘副本 / 引擎拒绝"
#    会让它自然地在回答里冒出"模拟""沙盘"，那就出戏了（用户 2026-10 明确要求）。
# ---------------------------------------------------------------------------
func tool_schema() -> Array:
	return [{
		"type": "function",
		"function": {
			"name": TOOL_NAME,
			"description": "拨开水晶球里的雾，看某一卦的结果：把「这段时间打算做的事」放进球里，"
				+ "球里会显现最多 5 天之后的村子（人口/满意度/饥饿/国库/住房/岗位/食物/材料/"
				+ "新完成的事/那时候最缺什么），以及和「什么都不做」相比差多少。"
				+ "球里看见的只是幻象，**不会改变真实村子**。",
			"parameters": {
				"type": "object",
				"properties": {
					"label": {"type": "string",
						"description": "给这一卦起个**短名（6 个字以内）**，例如「先补粮」「先盖房」；"
							+ "后面结论里要照抄它。"},
					"days": {"type": "integer",
						"description": "往未来看几天，1~%d，默认 %d" % [Trial.MAX_DAYS, TRIAL_DAYS]},
					"actions": {
						"type": "array",
						"description": "这段时间要做的事，最多 %d 条" % Trial.MAX_MANDATES,
						"items": {
							"type": "object",
							"properties": {
								"day": {"type": "integer",
									"description": "第几天做（1 = 从现在起的头 24 小时），默认 1"},
								"type": {"type": "string", "enum": Trial.KINDS},
								"id": {"type": "string",
									"description": "**英文 id**（【局势数据】里「可建清单」「现在可研究」的〔〕中那个，"
										+ "例如 wheat_farm / coarse_mill / hut）；中文名也认，但英文 id 最稳。"
										+ "build→建筑 id；build_housing→住房 id；"
										+ "expand→建筑 id（升级村里那一种的第一座）；"
										+ "research→科技 id；set_workers→建筑 id"},
								"count": {"type": "integer",
									"description": "build / build_housing 下几座，1~6，默认 1"},
								"value": {"type": "integer",
									"description": "set_workers 的目标用工人数（写 count 也认）"},
							},
							"required": ["type", "id"],
						},
					},
				},
				"required": ["days", "actions"],
			},
		},
	}]

## 「水晶球」简报：球里能看见什么、怎么拨、几轮规则、以及"什么都不做"的那一卦。
##
## ⚠️ 这一整段都是**喂给模型的字**，所以一个人称、一个词都要贴在戏里 ——
## 只写"水晶球 / 卦 / 显现"，**不写**沙盘、命令、引擎、拒绝、模拟（用户 2026-10 要求）。
## 技术细节（次日黎明生效、id、被拒）必须交代清楚，否则它给出的建议落不了地；
## 交代的时候用**村民的语言**（"第二天天不亮就生效"、"村里现在没有这种东西"）。
func _briefing() -> String:
	var b := PackedStringArray()
	b.append("【水晶球】你手边那颗球可以拨出「几条不同的路」，每条路拨一次叫一卦（`%s`）：" % TOOL_NAME
		+ "把你打算在这几天里做的事放进球里，球里就显现那之后最多 %d 天的村子。" % TRIAL_DAYS
		+ "球里显现的只是**幻象**，真实的村子一点都不会变。")
	b.append("- 你能拨出的几种命数：`build`（盖房子）、`build_housing`（盖住人的屋）、"
		+ "`expand`（把村里已有的那种建筑扩一间）、`research`（排进读书人的活儿）、"
		+ "`set_workers`（往那座建筑里派人）。id 用【局势数据】里「可建清单」「现在可研究」的〔〕中那个。")
	b.append("- 你拨出来的事**第二天天不亮才生效**（村里的规矩）。所以要「先做 A、过两天再做 B」，"
		+ "就把 `day` 写成 1 / 3。")
	b.append("- 球里会告诉你哪些事**成不了**（材料不够、读书人还没弄明白那个东西、村里压根没有那座建筑）——"
		+ "成不了就是成不了，别当它成了；换一条路再拨。")
	b.append("- 一次最多拨 %d 卦，**最多 %d 轮**；第 %d 轮我会明说「这是最后一轮」，之后你必须开口。" % [
		MAX_PLANS, MAX_ROUNDS, MAX_ROUNDS])
	b.append("- 你开口时引用的数字只能来自球里看见的或【局势数据】，并且要说清是哪一卦（照抄 `label`）。")
	var base := _base(TRIAL_DAYS)
	b.append("\n【什么都不做的那一卦】同样 %d 天、什么都不动，球里显现的是这个（其余各卦都是跟它比）：\n%s"
		% [TRIAL_DAYS, JSON.stringify(_compact(base))])
	return "\n".join(b)


# ---------------------------------------------------------------------------
# 每一步该发什么
# ---------------------------------------------------------------------------
## 下一次请求：`{messages, tools, stage, note}`。
## `tools` 为空数组 = 这次**关掉工具**（收尾轮，逼它说话）。
func next_request() -> Dictionary:
	var msgs: Array = _messages.duplicate(true)
	var note := ""
	var tools: Array = []
	match stage:
		"plan":
			note = "现在开始：先拨 3~%d 卦**思路不同**的（例如「先补粮」「先盖房」「先扩产」），" % MAX_PLANS \
				+ "每卦都拨 %d 天看看，我们再挑。" % TRIAL_DAYS
		"review":
			tools = tool_schema()
			note = "（第 %d 轮）看上面对照 —— 哪条路真的把村子带好了？不满意就再拨 3~%d 卦**换了思路**的，" % [
				rounds_done + 1, MAX_PLANS] + "满意就直接开口。"
		"last":
			tools = tool_schema()
			note = "（第 %d 轮 · **这是最后一轮**）只能再拨这 3~%d 卦；拨完必须开口，不会再有下一轮了。" % [
				MAX_ROUNDS, MAX_PLANS]
		"conclude":
			note = ("（到此为止）别再拨了，开口吧：说清你选中了哪一卦、为什么、"
				+ "球里看见的数字是什么 —— 记住你的语气，别像交报告。")
	if stage == "plan":
		tools = tool_schema()
	if note != "":
		msgs.append({"role": "user", "content": note})
	return {"messages": msgs, "tools": tools, "stage": stage}


## 收尾轮（工具已关）—— 面板用它判断"这一发出去就该结束了"。
func is_concluding() -> bool:
	return stage == "conclude"


# ---------------------------------------------------------------------------
# 处理一次回答
# ---------------------------------------------------------------------------
## `reply` = `AiClient.parse_reply()` 的结果（含 `tool_calls`）。
## 返回 `{kind, ...}`：
##   `final`    —— 拿到结论，结束
##   `trials`   —— 跑了方案（`results` 里有给模型的 `content` 与给面板的 `display`）
##   `error`    —— 这次问话失败
func accept(reply: Dictionary) -> Dictionary:
	if not bool(reply.get("ok", false)):
		stage = "done"
		return {"kind": "error", "message": String(reply.get("error", "未知错误"))}
	var calls: Array = reply.get("tool_calls", [])
	var text := String(reply.get("text", "")).strip_edges()
	if calls.is_empty():
		# 文本兜底：模型不会函数调用时，会把方案写成 JSON 块
		var extra := extract_text_plans(text)
		if not extra.is_empty() and rounds_done < MAX_ROUNDS and _prose_len(text, extra) < 40:
			calls = extra
	if calls.is_empty():
		final_text = text
		stage = "done"
		return {"kind": "final", "text": final_text}
	if rounds_done >= MAX_ROUNDS:
		# 3 轮已经用满，它还在试 —— 关掉工具让它说话
		stage = "conclude"
		return {"kind": "refused", "note": "轮次已用满，转入收尾"}
	# ---- 跑这一轮的方案 ----
	var results: Array = []
	var cut := mini(calls.size(), MAX_PLANS)
	for i in cut:
		results.append(_run_call(calls[i]))
	rounds_done += 1
	_messages.append(_assistant_echo(reply, calls))
	for r in results:
		_messages.append({
			"role": "tool", "tool_call_id": String(r["id"]),
			"name": TOOL_NAME, "content": JSON.stringify(r["content"]),
		})
	if cut < calls.size():
		_messages.append({"role": "user",
			"content": "（这一轮你给了 %d 个方案，一轮最多跑 %d 个，只跑了前 %d 个。）" % [
				calls.size(), MAX_PLANS, cut]})
	for r in results:
			trials.append({"label": String(r["label"]), "display": String(r["display"]),
			"end": (r["content"] as Dictionary).get("end", {}),
			"delta": (r["content"] as Dictionary).get("delta", {})})
	# 下一轮是第几轮
	if rounds_done >= MAX_ROUNDS:
		stage = "conclude"
	elif rounds_done == MAX_ROUNDS - 1:
		stage = "last"
	else:
		stage = "review"
	return {"kind": "trials", "results": results, "rounds_done": rounds_done}


## 跑一个 tool call。参数不合法 / 工具名不认识 → 也回一条 tool 结果**告诉它原因**
## （比直接报错好：模型下一轮能自己改）。
func _run_call(call: Dictionary) -> Dictionary:
	var id := String(call.get("id", "call"))
	var name := String(call.get("name", ""))
	var bad := String(call.get("bad", ""))
	if name != TOOL_NAME:
		return _bad_call(id, "没有叫 `%s` 的工具（只有 `%s`）" % [name, TOOL_NAME])
	if bad != "":
		return _bad_call(id, "参数不是合法 JSON：%s" % bad)
	var args: Dictionary = call.get("args", {})
	if not (args.get("actions", []) is Array) or (args["actions"] as Array).is_empty():
		return _bad_call(id, "`actions` 得是个非空数组 —— 里面写你想下的命令")
	var plan := {
		"label": String(args.get("label", "")),
		"days": clampi(int(args.get("days", TRIAL_DAYS)), 1, Trial.MAX_DAYS),
		"actions": args["actions"],
	}
	var res := Trial.run(advisor.sim, plan, _base(int(plan["days"])))
	var content := {
		"label": String(plan["label"]), "days": int(plan["days"]),
		"end": _compact(res["summary"]), "delta": res["delta"],
		"newQuests": res["new_quests"],
		"rejected": res["rejected"],
	}
	return {"id": id, "label": String(plan["label"]), "content": content,
		"display": _display(plan, res)}


func _bad_call(id: String, why: String) -> Dictionary:
	return {"id": id, "label": "", "content": {"error": why}, "display": "（一条方案没跑成：" + why + "）"}


## 面板上那一行（**显示文案由这一层拼**，和 `goal.text` 一个道理：UI 不许自己拼数字）。
## 例：`先补粮：人口 67（+1）· 满意度 74.2 · 粗面包 够用 · 建成 +2 · 队列 +4`
func _display(plan: Dictionary, res: Dictionary) -> String:
	var end: Dictionary = res["summary"]
	var d: Dictionary = res["delta"]
	var parts := PackedStringArray()
	parts.append("人口 %d（%+d）" % [int(end["pop"]), int(d["pop"])])
	parts.append("满意度 %s" % str(end["sat"]))
	var food: Dictionary = end["food"]
	var food_name := ""
	for name in food.keys():
		food_name = String(name)
		break
	if food_name != "":
		var f: Dictionary = (food as Dictionary)[food_name]
		var dl := float(f["daysLeft"])
		# 99 = 产量够吃（见 Trial.summarize 的哨兵值），别印成"99 天"
		parts.append("%s %s" % [food_name, "够吃" if dl >= 99.0 else "%s 天" % str(dl)])
	# 这一手落没落地：5 天里可能只排上队、没盖完
	if int(d.get("shops", 0)) != 0:
		parts.append("建成 %+d" % int(d["shops"]))
	if int(d.get("construction", 0)) != 0:
		parts.append("队列 %+d" % int(d["construction"]))
	if int(d["money"]) != 0:
		parts.append("国库 %+d" % int(d["money"]))
	if int(d["hungry"]) > 0:
		parts.append("挨饿 %d 人" % int(d["hungry"]))
	var nq: Array = res["new_quests"]
	if not nq.is_empty():
		parts.append("完成任务 " + "、".join(nq))
	var rej: Array = res["rejected"]
	if not rej.is_empty():
		parts.append("拒 %d 条" % rej.size())
	var label := String(plan["label"])
	if label == "":
		label = "（没起名）"
	return "%s：%s" % [label, " · ".join(parts)]


# ---------------------------------------------------------------------------
# 消息拼装
# ---------------------------------------------------------------------------
## 回填 assistant 那条消息。**必须带上 tool_calls**，否则下一轮的 `role:"tool"`
## 消息在 OpenAI / DeepSeek 那边会因为"没有对应的 tool_call"被拒。
func _assistant_echo(reply: Dictionary, calls: Array) -> Dictionary:
	var out := []
	for c in calls:
		var cid := String((c as Dictionary).get("id", "call"))
		out.append({
			"id": cid, "type": "function",
			"function": {"name": String((c as Dictionary).get("name", TOOL_NAME)),
				"arguments": String((c as Dictionary).get("arguments", "{}"))},
		})
	var msg := {"role": "assistant", "content": String(reply.get("text", "")), "tool_calls": out}
	return msg


## 给模型看的"紧凑版"（面板与对照都用它）：去掉给面板看的长字段。
func _compact(sum: Dictionary) -> Dictionary:
	return {
		"day": sum["day"], "pop": sum["pop"], "sat": sum["sat"], "hungry": sum["hungry"],
		"money": sum["money"], "housing": sum["housing"], "jobs": sum["jobs"],
		"employed": sum["employed"], "food": sum["food"], "materials": sum["materials"],
		"shops": sum["shops"], "construction": sum["construction"],
		"questsDone": sum["questsDone"], "problems": sum["problems"],
	}


func _base(days: int) -> Dictionary:
	var k := str(clampi(days, 1, Trial.MAX_DAYS))
	if not _baseline.has(k):
		_baseline[k] = Trial.run_baseline(advisor.sim, int(k))
	return _baseline[k]


# ---------------------------------------------------------------------------
# 文本兜底协议
# ---------------------------------------------------------------------------
## 从一段文本里抠出所有 `{...}` 里带 `actions` 数组的对象，转成"伪 tool call"。
##
## 给不支持函数调用的端点（某些本地推理 / 老网关）留的路：它们会把方案写成
## ```json {"days":5,"actions":[…]}```。`id` 自己编号（`txt1`…），因为那边没有 tool_call id。
static func extract_text_plans(text: String) -> Array:
	var out := []
	var i := 0
	while i < text.length() and out.size() < MAX_PLANS:
		if text[i] != "{":
			i += 1
			continue
		var depth := 0
		var j := i
		var in_str := false
		var esc := false
		while j < text.length():
			var ch := text[j]
			if in_str:
				if esc:
					esc = false
				elif ch == "\\":
					esc = true
				elif ch == "\"":
					in_str = false
			elif ch == "\"":
				in_str = true
			elif ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth == 0:
					break
			j += 1
		if j >= text.length():
			break
		var blob := text.substr(i, j - i + 1)
		var parsed: Variant = SimUtil.parse_json_quiet(blob)
		if parsed is Dictionary and (parsed as Dictionary).get("actions", null) is Array:
			out.append({"id": "txt%d" % (out.size() + 1), "name": TOOL_NAME,
				"arguments": blob, "args": parsed})
		i = j + 1
	return out


## JSON 块之外的正文长度（用来判断"这条回复是不是只在给方案"）。
static func _prose_len(text: String, plans: Array) -> int:
	var left := text
	for p in plans:
		left = left.replace(String((p as Dictionary)["arguments"]), "")
	left = left.replace("```json", "").replace("```", "")
	return left.strip_edges().length()
