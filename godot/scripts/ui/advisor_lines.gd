class_name AdvisorLines
extends RefCounted

# 面板右下角那位的**一句闲话**（用户 2026-10）：
#   "点开面板出现一个立绘有点尴尬，立绘说一句话吧，你每个角色设计5个台词
#    （根据当前情况，随机选一个），然后在立绘的左边冒个气泡，说一下话，有个叉可以点掉。"
#
# 每个人 5 句。`when` 是这句**优先**出现的时机（空 = 什么时候都能说）：
#   hungry   有人挨饿
#   broke    国库见底
#   nohouse  没空房了
#   unhappy  平均满意度低
#   idle     岗位空着一大片
#   small    人还很少
#   ok       日子正常
#
# 选法：先按当前情况挑"对得上"的那几句；对得上就七成说它，否则从那几句万能的里挑。
# 同一个人**不会连着说同一句**（`_last`），面板多开几次也不会复读。
#
# ⚠️ 这些字是**画在屏幕上的**：只许用像素字体里有的字（见 godot/AGENTS.md 的缺字表），
#    门槛 `panel_test` 会逐字查一遍。也别写现代词（面板/数值/点击/系统）。

const LINES := {
	"sebastian": [
		{"when": "hungry", "text": "殿下，仓里那点存粮撑不了几天了。先顾嘴，再顾别的。"},
		{"when": "broke", "text": "账上不宽裕。老臣劝一句：这几日先别动土。"},
		{"when": "ok", "text": "老臣把仓底又数了一遍 —— 眼下这光景，还算稳当。"},
		{"when": "", "text": "有些事急不得。先把眼前这一摊料理干净，再谈往后。"},
		{"when": "", "text": "老臣年纪大了，见得多：能熬过第一个冬天的，才谈得上以后。"},
	],
	"alvin": [
		{"when": "idle", "text": "殿下，人手闲着的时候，正好把这些图样试出来。"},
		{"when": "ok", "text": "这几样图样我都看过了，随时可以试着做。"},
		{"when": "unhappy", "text": "人心和图纸不一样 —— 画错了，不能刮掉重来。"},
		{"when": "", "text": "这个……属下也没想通，容属下再算一遍。"},
		{"when": "", "text": "书上的东西要落到地上，总得有人肯先动手。"},
	],
	"reynard": [
		{"when": "hungry", "text": "殿下，饿着的村子，账做得再漂亮也撑不住。"},
		{"when": "small", "text": "人还少。臣不催 —— 但这话迟早要回给陛下。"},
		{"when": "ok", "text": "这一回，臣回王庭有话可说了。"},
		{"when": "", "text": "陛下问的只有一件事：这块地，你养得活多少人。"},
		{"when": "", "text": "殿下，陛下的意思，臣带到了。"},
	],
	"isabella": [
		{"when": "", "text": "哼，我才不是来看你的 —— 我是路过。"},
		{"when": "", "text": "你这儿连一盏像样的灯都没有。"},
		{"when": "", "text": "……喂，你上回说的那件事，我记着了。"},
		{"when": "", "text": "他们都说你撑不过三年。我说他们眼瞎。"},
		{"when": "", "text": "别送了。送了就不好玩了。"},
	],
	"vera": [
		{"when": "broke", "text": "殿下，国库又要空了。"},
		{"when": "idle", "text": "有人在闲着，养他们的钱可没闲着。"},
		{"when": "ok", "text": "这几日的账还算干净。难得。"},
		{"when": "", "text": "这两笔支出记在同一个名目下，是想让属下猜吗。"},
		{"when": "", "text": "钱不是省出来的 —— 但也不是这么花的。"},
	],
	"luna": [
		{"when": "nohouse", "text": "房子不够了。挤一挤能过冬，可孩子会长大。"},
		{"when": "hungry", "text": "饿着的人不会说，只会走。"},
		{"when": "unhappy", "text": "日子过得不痛快，人就走了。留不住的。"},
		{"when": "ok", "text": "这几天有人来打听，问这边还收不收人。"},
		{"when": "", "text": "殿下，村里又添了新丁。"},
	],
	"serafina": [
		{"when": "", "text": "哼，才不是特意为你预言呢。"},
		{"when": "", "text": "球里有雾。你自己心里也不是没数。"},
		{"when": "", "text": "要问就问。别站在这儿，风大。"},
		{"when": "", "text": "我看见了 —— 不过现在不说。"},
		{"when": "", "text": "……你这副样子，倒也不像快撑不住。"},
	],
}

## 上一个说话的人说了哪句（同一个人不连着说同一句）
static var _last: Dictionary = {}

## 从 `sim` 眼下能便宜读到的几件事里归纳出一个"情况"标签。
## ⚠️ 只读，不改任何状态（这一层是画界面，不能碰仿真）。
static func context_key(sim) -> String:
	if sim == null or sim.s == null:
		return ""
	var s: Dictionary = sim.s
	var residents: Array = s.get("residents", [])
	var pop := residents.size()
	var money := float((s.get("government", {}) as Dictionary).get("money", 0.0))

	var hungry := 0
	var sat_sum := 0.0
	for r in residents:
		var acc: Dictionary = (r as Dictionary).get("account", {})
		if bool(acc.get("hungry", false)):
			hungry += 1
		sat_sum += float((r as Dictionary).get("satisfaction", 0.0))
	var sat := 0.0 if pop == 0 else sat_sum / float(pop)

	var cap := float(sim.housing_capacity())
	var slots := float(sim.job_capacity())
	var employed := 0
	for r in residents:
		if bool((r as Dictionary).get("employed", false)):
			employed += 1

	# 优先级：肚子 > 钱 > 房 > 心情 > 闲人 > 人少 > 正常
	if hungry > 0:
		return "hungry"
	if money < 400.0:
		return "broke"
	if cap > 0.0 and cap - float(pop) <= 0.0:
		return "nohouse"
	if pop > 0 and sat < 55.0:
		return "unhappy"
	if slots - float(employed) >= maxf(6.0, slots * 0.35):
		return "idle"
	if pop < 30:
		return "small"
	return "ok"

## 挑一句话。`key` 是 `context_key()` 的返回值（也可以传空 = 只说万能的那些）。
static func pick(id: String, key: String) -> String:
	var all: Array = LINES.get(id, [])
	if all.is_empty():
		return ""
	var fit: Array = []
	var plain: Array = []
	for l in all:
		var when := String((l as Dictionary).get("when", ""))
		if when == "":
			plain.append(String(l["text"]))
		elif when == key:
			fit.append(String(l["text"]))
	var pool: Array = plain
	# 对得上当前情况的更"值钱"：七成说它；一句都没有就退回万能的
	if fit.size() > 0 and (plain.is_empty() or randf() < 0.7):
		pool = fit
	if pool.is_empty():
		return ""
	var last := String(_last.get(id, ""))
	var pick_txt := String(pool[randi() % pool.size()])
	if pool.size() > 1 and pick_txt == last:
		pick_txt = String(pool[(pool.find(pick_txt) + 1) % pool.size()])
	_last[id] = pick_txt
	return pick_txt
