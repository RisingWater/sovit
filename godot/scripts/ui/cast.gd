class_name Cast
extends RefCounted

# 七人顾问团的**名字与立绘**解析（用户 2026-10）。
#
# 为什么要有这一层：内容（`content/quests.json`）与剧情脚本里，人物的写法有三种：
#   · 人 id         `sebastian` / `luna` / `vila` …
#   · 立绘 id       `<人>_<表情>`（`sebastian_neutral` / `isabella_shy`），见 docs/characters.md
#   · 历史上的拼法   `reynard` / `vera` / `serafina`（立绘文件名就是这几个），
#                    而内容里写的是 `renard` / `vila` / `seraphina`
#
# 所以「拿到一个 id → 得到中文名 / 一张贴图」这件事必须**只有一份实现**，
# 否则每加一处对话就要再抄一遍拼写表，抄错一个人玩家就会看到"露娜"顶着薇拉的脸。
#
# ⚠️ 表情图现在只有**每人一张**（`<人>.png`），所以 `xx_neutral` 一律落到默认立绘；
#    以后画了表情差分，只要放进 `assets/portraits/<人>_<表情>.png` 就自动生效。

## 人 id → 中文名（见 docs/characters.md §一）。
## 键统一用**立绘文件名**那套拼法（`serafina` / `reynard` / `vera`）。
const NAME := {
	"sebastian": "塞巴斯蒂安",
	"alvin": "阿尔文",
	"reynard": "雷纳德",
	"isabella": "伊莎贝拉",
	"vera": "薇拉",
	"luna": "露娜",
	"serafina": "瑟拉菲娜",
	# 2026-10 新登场三人（场次里说话的就是他们，见 content/scenes.json）：
	"milla": "米拉",
	"gareth": "加雷斯",
	"elise": "艾莉丝",
}

## 内容里的拼法 → 立绘文件名用的拼法（同一个人的两种写法）。
## ⚠️ 只有这三处不一致：`quests.json` 写 `renard` / `vila` / `seraphina`，
## 而立绘文件叫 `reynard.png` / `vera.png` / `serafina.png`。
const ALIAS := {
	"seraphina": "serafina",
	"renard": "reynard",
	"vila": "vera",
}

## 把任意写法（人 id / 立绘 id）归一成**人 id**（`seraphina_hooded` → `serafina`）。
static func char_id(who: String) -> String:
	var base := who
	var i := base.find("_")
	if i > 0:
		base = base.substr(0, i)
	return String(ALIAS.get(base, base))

## 中文名。找不到就原样返回 id（宁可露出 id，也不要空一块）。
static func speaker_name(who: String) -> String:
	var c := char_id(who)
	return String(NAME.get(c, c))

## 立绘。`<人>_<表情>` 先找表情图，没有就落回这个人的默认立绘；都没有返回 null。
static func portrait(who: String) -> Texture2D:
	var base := who
	var mood := ""
	var i := who.find("_")
	if i > 0:
		base = who.substr(0, i)
		mood = who.substr(i + 1)
	base = String(ALIAS.get(base, base))
	if mood != "":
		var p := "res://assets/portraits/%s_%s.png" % [base, mood]
		if ResourceLoader.exists(p):
			return load(p)
	var fallback := "res://assets/portraits/%s.png" % base
	return load(fallback) if ResourceLoader.exists(fallback) else null

## 只取**上半身**的头像（AtlasTexture，上面 36%：头顶到胸口）。
## 直接把人缩到 300 高会整条身子挤在角上，看起来不像"头像"。
static func portrait_head(who: String) -> Texture2D:
	var t := portrait(who)
	if t == null:
		return null
	var at := AtlasTexture.new()
	at.atlas = t
	at.region = Rect2(0, 0, t.get_width(), t.get_height() * 0.36)
	return at
