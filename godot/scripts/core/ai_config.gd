class_name AiConfig
extends RefCounted

# AI 辅助的**配置**（base_url / api_key / model_name 等）。
#
# 为什么单独一个文件、而且是 core 层：
#   · 这是基础设施（读写用户目录），不是仿真、也不是画面；
#   · sim 层是纯的、**不许**碰文件；ui 层的 `ai_panel.gd` 只负责把这里的值
#     显示成输入框。门槛 `ai_test.gd` 也要能不起 UI 就测一遍读写往返。
#
# ⚠️ **api_key 只写在 `user://ai.cfg`，永远不进仓库、不进存档、不进日志**。
#    `user://` 在 Windows 上是 `%APPDATA%\Godot\app_userdata\sovit\`，
#    和存档、hud.cfg 放在一起。这是明文（Godot 没有系统钥匙串接口），
#    doc 里写明了这一点：**别把带 key 的 user 目录传给别人**。
#    `masked_key()` 只给界面用，任何打印/公告都必须走它。
#
# 另一个刻意的设计：**没有 api_key 也算「配好了」**。
#   本地推理（llama.cpp / ollama / LM Studio / vLLM）就是不需要 key 的，
#    只填 base_url + model_name 就能用。要不要发 Authorization 头由 `has_key()` 决定。

const PATH := "user://ai.cfg"
const SECTION := "ai"

## 实际读写的路径。**故意做成变量而不是直接用 `PATH`**：门槛 `ai_test.gd`
## 要真跑一遍读写往返，指到临时文件才不会把玩家自己的 key 覆盖掉
## （和 `hud.quick_path` 一样的理由 —— 那条也是为门槛留的口子）。
static var path := PATH

## 默认值：**空的**。空 base_url 就是"还没配" —— 面板这时只显示本地分析、不联网。
##
## 为什么不默认填 DeepSeek 的地址：填了的话 `is_ready()` 立刻为真，
## 玩家第一次点顶栏那个按钮就会**真的发一次注定 401 的请求**（没有 key），
## 等十几秒换回一句"HTTP 401"。空着的话按钮直接把他带到「设置」页，那句话才是有用的。
## 地址只作为输入框的**占位提示**（`PLACEHOLDER_*`），不进配置。
const DEFAULT_BASE_URL := ""
const DEFAULT_MODEL := ""
const PLACEHOLDER_BASE_URL := "https://api.deepseek.com/v1"
const PLACEHOLDER_MODEL := "deepseek-chat"
const DEFAULT_TIMEOUT := 60.0
## 单次回答的 token 上限。顾问只要三条建议，800 足够；
## 给太大只会让模型啰嗦、也更容易编数字。
const DEFAULT_MAX_TOKENS := 800
## 温度：顾问要稳、要引用数字，不要发散。0.3 是"同一局势给同一个答案"的档。
const DEFAULT_TEMPERATURE := 0.3

## 读配置。缺键一律兜默认值 —— 于是"没配过"和"只配了一半"是同一条代码路径。
static func load_cfg() -> Dictionary:
	var cf := ConfigFile.new()
	cf.load(path)      # 读不到就当空文件，不报错（首次运行就是这种）
	return {
		"base_url": String(cf.get_value(SECTION, "base_url", DEFAULT_BASE_URL)).strip_edges(),
		"api_key": String(cf.get_value(SECTION, "api_key", "")).strip_edges(),
		"model": String(cf.get_value(SECTION, "model", DEFAULT_MODEL)).strip_edges(),
		"timeout": clampf(float(cf.get_value(SECTION, "timeout", DEFAULT_TIMEOUT)), 5.0, 300.0),
		"max_tokens": int(clampf(float(cf.get_value(SECTION, "max_tokens", DEFAULT_MAX_TOKENS)),
			64.0, 8192.0)),
		"temperature": clampf(float(cf.get_value(SECTION, "temperature", DEFAULT_TEMPERATURE)),
			0.0, 2.0),
		# 提问时是否自动暂停：查询要几秒到几十秒，不暂停的话答案到手时局势已经跑过去了。
		# 这是**纯表现层**的开关（只动 SimRunner.paused，不进仿真状态、不影响确定性）。
		"pause_on_ask": bool(cf.get_value(SECTION, "pause_on_ask", true)),
	}

## 写配置。⚠️ 会覆盖整个 [ai] 段，所以调用方必须传一份完整的 cfg
## （`load_cfg()` 的结果改几个键再传回来）。
static func save_cfg(cfg: Dictionary) -> Error:
	var cf := ConfigFile.new()
	cf.load(path)      # 保留其它段（万一以后有别的段）
	cf.set_value(SECTION, "base_url", String(cfg.get("base_url", DEFAULT_BASE_URL)).strip_edges())
	cf.set_value(SECTION, "api_key", String(cfg.get("api_key", "")).strip_edges())
	cf.set_value(SECTION, "model", String(cfg.get("model", DEFAULT_MODEL)).strip_edges())
	cf.set_value(SECTION, "timeout", float(cfg.get("timeout", DEFAULT_TIMEOUT)))
	cf.set_value(SECTION, "max_tokens", int(cfg.get("max_tokens", DEFAULT_MAX_TOKENS)))
	cf.set_value(SECTION, "temperature", float(cfg.get("temperature", DEFAULT_TEMPERATURE)))
	cf.set_value(SECTION, "pause_on_ask", bool(cfg.get("pause_on_ask", true)))
	return cf.save(path)

## 能不能发请求。**api_key 不参与判断**（本地推理不需要 key）。
static func is_ready(cfg: Dictionary) -> bool:
	return String(cfg.get("base_url", "")).strip_edges() != "" \
		and String(cfg.get("model", "")).strip_edges() != ""

static func has_key(cfg: Dictionary) -> bool:
	return String(cfg.get("api_key", "")).strip_edges() != ""

## 界面上显示的 key：只露头尾，中间打码。**不要**在别处打印真 key。
## 空 key 返回「（未设置）」；短于 12 位的整段打码（露头尾等于全露）。
static func masked_key(cfg: Dictionary) -> String:
	var k := String(cfg.get("api_key", "")).strip_edges()
	if k == "":
		return "（未设置）"
	if k.length() < 12:
		return "*".repeat(k.length())
	return "%s…%s" % [k.substr(0, 6), k.substr(k.length() - 4)]

## 把 base_url 拼成 chat/completions 的完整地址。
##
## 玩家会粘三种东西，这里都得认：
##   https://api.deepseek.com/v1                → 补 /chat/completions
##   https://api.deepseek.com/v1/               → 先去尾斜杠
##   https://api.deepseek.com/v1/chat/completions  → 原样用（已经是终点了）
## 其它情况（比如 ollama 的 http://127.0.0.1:11434/v1）走同一条补路径。
static func endpoint(base_url: String) -> String:
	var b := base_url.strip_edges()
	while b.ends_with("/"):
		b = b.substr(0, b.length() - 1)
	if b == "":
		return ""
	if b.ends_with("/chat/completions"):
		return b
	return b + "/chat/completions"
