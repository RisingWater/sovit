class_name AiClient
extends Node

# AI 辅助的 **HTTP 客户端**：只做"把 messages 发到 OpenAI 兼容端点、把回答取回来"。
#
# 分层理由：这里是**表现层**（挂着 `HTTPRequest` 这个 Node），所以放 `scripts/ui/`；
# 提示词怎么拼是 `scripts/sim/advisor.gd` 的事（纯函数、可 headless 测）。
#
# 兼容面刻意做窄 —— 只认 OpenAI 的 `/chat/completions` 形状：
#   {model, messages:[{role,content}], temperature, max_tokens} →
#   {choices:[{message:{content}}]}
# DeepSeek / OpenAI / 通义 / 硅基流动 / ollama / llama.cpp / vLLM / LM Studio
# 全都吃这一套，所以"配置 base_url + model 就能用"这句是真的。
#
# ⚠️ 三件事必须守住：
#   1. **api_key 不进日志**：出错信息里只提"HTTP 401"，绝不回显请求头。
#      `AiConfig.masked_key()` 是唯一允许把 key 显示出来的地方。
#   2. **不阻塞**：全程异步（HTTPRequest 本身就是信号驱动），游戏照常跑。
#   3. **可重入保护**：一次只发一条。没答完再点就忽略（面板按钮同时会自己禁用）。
#
# 对拍/门槛友好：真正的解析逻辑是 `static func parse_reply()`，
# 不联网也能拿"假的响应体"测遍成功与各种失败形状。

signal replied(reply: Dictionary)
signal failed(message: String)

var _http: HTTPRequest
var _busy := false
## 最近一次请求的 URL（出错时提示用；**不含 key**）。
var _url := ""

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.name = "Http"
	_http.timeout = AiConfig.DEFAULT_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_completed)

func is_busy() -> bool:
	return _busy

## 主动放弃在途请求（关面板 / 关游戏时调）。
func cancel() -> void:
	if _http != null and _busy:
		_http.cancel_request()
	_busy = false

## 发一条请求。`cfg` 是 `AiConfig.load_cfg()` 的形状，`messages` 是
## `ProphetAgent.next_request()["messages"]`，`tools` 是它的 `tool_schema()`（可空 = 关掉工具）。
## 返回是否真的发出去了（没配好 / 正忙 → false，并已经 emit 了 failed）。
func ask(cfg: Dictionary, messages: Array, tools: Array = []) -> bool:
	if _http == null:
		failed.emit("HTTP 组件还没就绪")
		return false
	if _busy:
		return false
	if not AiConfig.is_ready(cfg):
		failed.emit("还没配置 base_url 与 model（ESC 菜单 → AI 辅助 → 设置）")
		return false
	_url = AiConfig.endpoint(String(cfg["base_url"]))
	if _url == "":
		failed.emit("base_url 是空的")
		return false
	_http.timeout = float(cfg.get("timeout", AiConfig.DEFAULT_TIMEOUT))
	_busy = true
	var err := _http.request(_url, build_headers(cfg), HTTPClient.METHOD_POST,
		build_body(cfg, messages, tools))
	if err != OK:
		_busy = false
		failed.emit("请求发不出去（错误码 %d）：%s" % [err, _url])
		return false
	return true

# ---------------------------------------------------------------------------
# 纯函数部分（门槛直接测这几个，不联网）
# ---------------------------------------------------------------------------
## 请求体。字段名/形状就是 OpenAI 的那一套。
## `tools` 非空时带上函数声明 + `tool_choice: "auto"` —— 这就是"把游戏引擎当工具交给模型"。
static func build_body(cfg: Dictionary, messages: Array, tools: Array = []) -> String:
	var body := {
		"model": String(cfg.get("model", AiConfig.DEFAULT_MODEL)),
		"messages": messages,
		"temperature": float(cfg.get("temperature", AiConfig.DEFAULT_TEMPERATURE)),
		"max_tokens": int(cfg.get("max_tokens", AiConfig.DEFAULT_MAX_TOKENS)),
		# 不流式：面板要等整段回来再一次排版，流式只会让像素字一行行跳。
		"stream": false,
	}
	if not tools.is_empty():
		body["tools"] = tools
		body["tool_choice"] = "auto"
	return JSON.stringify(body)

## 请求头。**没有 key 就不发 Authorization** —— 本地推理（ollama 之类）不需要，
## 多发一个空的 Bearer 反而会被某些网关当成鉴权失败。
static func build_headers(cfg: Dictionary) -> PackedStringArray:
	var h := PackedStringArray(["Content-Type: application/json"])
	if AiConfig.has_key(cfg):
		h.append("Authorization: Bearer " + String(cfg["api_key"]).strip_edges())
	return h

## 解析响应。返回 `{ok, text, tool_calls, finish_reason, error}`。
## **不联网也能测**：这就是它存在的理由。
##
## 认的形状：
##   · 200 + `choices[0].message.content`（chat/completions，主流）
##   · 200 + `choices[0].message.tool_calls[]`（**函数调用**：`{id, function:{name, arguments}}`，
##     `arguments` 是个 **JSON 字符串** —— 这里顺手解析出来；解析不了就在那一条上标 `bad`，
##     由调用方作为"参数不合法"喂回给模型，而不是整条回复算失败）
##   · 200 + `choices[0].text`（老的 completions，少数本地服务只给这个）
##   · 非 200 → 尽量把服务端的 `error.message` 挖出来（那通常比 "HTTP 500" 有用）
static func parse_reply(code: int, body: String) -> Dictionary:
	var trimmed := body.strip_edges()
	if trimmed == "":
		return _reply("", "服务端返回了空响应（HTTP %d）" % code)
	# ⚠️ 先看开头像不像 JSON 再解析：`JSON.parse_string()` 遇到 HTML 错误页 /
	# 纯文本报错会往 stderr 喷一行 "Parse JSON failed"，门槛扫到会**误判成失败**
	# （而那恰恰是我们预期要处理的一种响应）。这里自己先挡一道，顺便让
	# "不是 JSON" 的提示更清楚。
	if not (trimmed.begins_with("{") or trimmed.begins_with("[")):
		if code < 200 or code >= 300:
			return _reply("", "HTTP %d：%s" % [code, _snippet(trimmed)])
		return _reply("", "返回的不是 JSON：%s" % _snippet(trimmed))
	var data: Variant = SimUtil.parse_json_quiet(trimmed)
	if code < 200 or code >= 300:
		var detail := _error_detail(data)
		if detail == "":
			detail = _snippet(trimmed)
		return _reply("", "HTTP %d：%s" % [code, detail])
	if data == null or not (data is Dictionary):
		return _reply("", "返回的不是 JSON：%s" % _snippet(trimmed))
	var choices: Variant = (data as Dictionary).get("choices", null)
	if not (choices is Array) or (choices as Array).is_empty():
		# 有些服务端把错误塞在 200 里（本地网关常见）
		var detail2 := _error_detail(data)
		if detail2 != "":
			return _reply("", detail2)
		return _reply("", "响应里没有 choices（模型名写错了？）")
	var first: Variant = (choices as Array)[0]
	if not (first is Dictionary):
		return _reply("", "choices[0] 不是对象")
	var fc := first as Dictionary
	var finish := String(fc.get("finish_reason", ""))
	var msg: Variant = fc.get("message", null)
	var calls: Array = []
	if msg is Dictionary:
		calls = _parse_tool_calls((msg as Dictionary).get("tool_calls", null))
	var text := ""
	if msg is Dictionary and (msg as Dictionary).has("content") \
			and (msg as Dictionary)["content"] != null:
		text = String((msg as Dictionary)["content"]).strip_edges()
	elif fc.has("text"):
		text = String(fc["text"]).strip_edges()
	# 函数调用优先：内容可能是空的（模型只给了 tool_calls）
	if not calls.is_empty():
		return {"ok": true, "text": text, "tool_calls": calls, "finish_reason": finish, "error": ""}
	if text == "":
		return _reply("", "模型返回了空内容")
	return {"ok": true, "text": text, "tool_calls": [], "finish_reason": finish, "error": ""}

static func _reply(text: String, error: String) -> Dictionary:
	return {"ok": false, "text": text, "tool_calls": [], "finish_reason": "", "error": error}


## `message.tool_calls` → `[{id, name, arguments(原样字符串), args(解析后的对象), bad(解析错误)}]`。
static func _parse_tool_calls(raw: Variant) -> Array:
	var out := []
	if not (raw is Array):
		return out
	for i in (raw as Array).size():
		var item: Variant = (raw as Array)[i]
		if not (item is Dictionary):
			continue
		var it := item as Dictionary
		var fn: Variant = it.get("function", null)
		var name := ""
		var args_str := "{}"
		if fn is Dictionary:
			name = String((fn as Dictionary).get("name", ""))
			args_str = String((fn as Dictionary).get("arguments", "{}"))
		elif it.has("name"):
			# 少数网关会把 function 拍平
			name = String(it["name"])
			args_str = String(it.get("arguments", "{}"))
		var call := {"id": String(it.get("id", "call%d" % (i + 1))), "name": name,
			"arguments": args_str, "args": {}, "bad": ""}
		var parsed: Variant = SimUtil.parse_json_quiet(args_str)
		if parsed is Dictionary:
			call["args"] = parsed
		else:
			call["bad"] = _snippet(args_str)
		out.append(call)
	return out

static func _error_detail(data: Variant) -> String:
	if not (data is Dictionary):
		return ""
	var err: Variant = (data as Dictionary).get("error", null)
	if err is Dictionary:
		var d := err as Dictionary
		if d.has("message"):
			return String(d["message"])
		if d.has("type"):
			return String(d["type"])
	elif err is String and String(err) != "":
		return String(err)
	if (data as Dictionary).has("message"):
		return String((data as Dictionary)["message"])
	return ""

static func _snippet(s: String) -> String:
	var one_line := s.replace("\n", " ").strip_edges()
	return one_line.substr(0, 160) if one_line.length() > 160 else one_line

## 把模型的回答收拾成"像素字体画得出来"的纯文本：
##   · 去掉 Markdown 痕迹（星号加粗、井号标题、行首短横线列表、反引号）
##   · 补掉像素字体**没有**的字形（不然画出来是空的，而且不报错）
## 这一步放在客户端而不是面板里，是为了让门槛能直接测串。
static func clean_reply(text: String) -> String:
	var s := text.replace("\r\n", "\n").replace("\r", "\n")
	s = s.replace("**", "").replace("__", "").replace("`", "")
	var lines := PackedStringArray()
	for raw in s.split("\n"):
		var line := String(raw)
		var stripped := line.strip_edges()
		# 「# 标题」→ 标题；「- 条目」/「* 条目」→ 「· 条目」（像素字体有 ·）
		if stripped.begins_with("#"):
			line = stripped.trim_prefix("#").strip_edges()
		elif stripped.begins_with("- ") or stripped.begins_with("* "):
			line = "· " + stripped.substr(2).strip_edges()
		lines.append(UIKit.sanitize_text(line))
	return "\n".join(lines).strip_edges()

# ---------------------------------------------------------------------------
func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS:
		failed.emit("%s（%s）" % [_result_text(result), _url])
		return
	var parsed := parse_reply(code, body.get_string_from_utf8())
	if bool(parsed["ok"]):
		# 把**整条**解析结果交出去：多轮协议要 `tool_calls`，不只 `text`
		replied.emit(parsed)
	else:
		failed.emit(String(parsed["error"]))

## HTTPRequest 的失败码 → 人话。这张表是**给玩家看的**，别直接抛数字。
func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "连不上服务器（base_url 写错？网络不通？）"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "域名解析不了（base_url 的域名对不对？）"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接中断"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败（这个地址不是 https？）"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "服务器没有响应（超时或地址不对）"
		HTTPRequest.RESULT_TIMEOUT:
			return "超时了 —— 模型太慢，或网络卡住"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "请求失败（服务端中途断开）"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "写入失败"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "重定向次数过多（base_url 结尾多了斜杠？）"
		_:
			return "请求失败（错误码 %d）" % result
