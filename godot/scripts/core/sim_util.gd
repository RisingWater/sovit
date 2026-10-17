class_name SimUtil
extends RefCounted

# 与 TS 的 Math.round 行为一致（half 向 +Infinity 舍入），再保留 2 位小数。
static func r2(v: float) -> float:
	return floor(v * 100.0 + 0.5) / 100.0

static func clampf01(v: float) -> float:
	return clampf(v, 0.0, 1.0)

## **安静地**解析 JSON：成功返回解析结果，失败返回 `null`。
##
## 为什么不直接用 `JSON.parse_string()`：它在失败时会**往 stderr 打一行**
## `ERROR: Parse JSON failed. Error at line N: ...`。而我们有两处**预期会失败**的调用：
##   · 模型给的 `tool_calls[].function.arguments` 可能是坏 JSON（很正常，回给模型改就行）；
##   · 文本兜底协议要在**一整段回答**里找 JSON 块（大部分 `{` 下面都不是 JSON）。
## 用实例 API（`JSON.new().parse()`）失败时不打印，还能拿到错误行与原因。
##
## 放 `SimUtil` 是因为 sim 与 ui **两层都要用**（`prophet_agent` 找 JSON 块、
## `ai_client` 解 arguments），而这个类本来就是这个"两层共用的小工具"的位置。
static func parse_json_quiet(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data
