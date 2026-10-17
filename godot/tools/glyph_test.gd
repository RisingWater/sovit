extends SceneTree

# 字形门槛：**UI 里不能出现像素字体没有的字**。
#
# 为什么要有这条：缺字形在 Godot 里不报任何错，画出来就是个**空**（宽度 0 或 .notdef 方块）。
# 实测踩过的（fusion-pixel-12px-zh_hans 里**没有**）：
#   U+2212 "−"（建筑面板的折叠按钮就是它 → 展开状态下按钮上什么都没有）
#   U+2211 "∑"、U+2248 "≈"、U+2717 "✗"、U+26A0 "⚠"
#   U+221A "√"（2026-10 拿它当对勾的替身，结果替身自己也是缺的）
# 有的：+ - × – — … ↑ ↓ → ▲ ▼ Σ － ± ÷ · 【】《》√以外的 CJK 标点
#
# 扫两处（都只扫**会画到屏幕上的字**）：
#   · `res://scripts/**/*.gd` 里**字符串字面量内**的字符（注释不进画面，不算）
#   · `res://content/*.json` 的全部文本（nameZh 之类会被画出来）
# 判定用 `Font.has_char()` —— Godot 渲染时真正查的那张表。
#
# 用法（在 godot/ 下）：
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/glyph_test.gd

const FONT_PATH := "res://assets/fonts/fusion-pixel-12px-zh_hans.ttf"
const SCRIPT_ROOTS := ["res://scripts"]
const DATA_FILES := [
	"res://content/goods.json",
	"res://content/buildings.json",
	"res://content/housing.json",
	"res://content/technologies.json",
	"res://content/classes.json",
	"res://content/economy.json",
	"res://content/packs.json",
	# 任务的标题与 hint 是**直接画在任务追踪条上**的（docs/quests.md），
	# 漏了它就等于漏了一整块 UI 文案 —— 2026-10 补上。
	"res://content/quests.json",
]

var _font: FontFile = null
## 每个缺字形只报一次：缺字 -> [[文件, 行号, 原句], ...]
var _bad := {}

func _init() -> void:
	call_deferred("_run")

func _fail(msg: String) -> void:
	print("GLYPH TEST FAIL: ", msg)
	print("GLYPH TEST RESULT: FAIL")
	quit(1)

## 收集某个目录下所有 .gd（递归）。
func _collect(dir_path: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var nm := d.get_next()
	while nm != "":
		if d.current_is_dir():
			if nm != "." and nm != "..":
				_collect(dir_path.path_join(nm), out)
		elif nm.ends_with(".gd"):
			out.append(dir_path.path_join(nm))
		nm = d.get_next()
	d.list_dir_end()

func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()

## 逐字扫一段文本，把"字符串字面量里"的字符交给 `_check_char()`。
## `whole` = true 时整段都算（JSON 就是纯数据，全是给人看的字）。
##
## 规则（手写小扫描器，够用就行）：
##   · 只把 `"` 当字符串定界符。GDScript 里 `'` 在中文注释里就是普通的撇号，
##     认它会把"半个文件"当成字符串扫进去（满屏假报）。用 `'` 写的字符串会漏扫 ——
##     那是"少报"而不是"误报"，宁可少报。
##   · 不在串里时遇到 `#` 就是注释，跳到行尾 —— 注释不进画面，不该被扫
##     （否则注释里写一句「以前用的是 "−"」就会被门槛抓住）。
func _scan(text: String, path: String, whole: bool) -> void:
	var line := 1
	var in_str := false
	var esc := false
	var comment := false
	for ch in text:
		if ch == "\n":
			line += 1
			esc = false
			comment = false
			continue
		if whole:
			if ch == " " or ch == "\t" or ch == "\r":
				continue
			_check_char(ch, path, line)
			continue
		if comment:
			continue
		if esc:
			esc = false
		elif in_str and ch == "\\":
			esc = true
		elif ch == "\"":
			in_str = not in_str
		elif not in_str and ch == "#":
			comment = true
			continue
		if not in_str:
			continue
		if ch == " " or ch == "\t" or ch == "\r":
			continue
		_check_char(ch, path, line)

func _check_char(ch: String, path: String, line: int) -> void:
	var cp := ch.unicode_at(0)
	if _font.has_char(cp):
		return
	if not _bad.has(ch):
		_bad[ch] = []
	var list: Array = _bad[ch]
	var where := "%s:%d" % [path.replace("res://", ""), line]
	if list.size() < 4 and not list.has(where):
		list.append(where)

func _run() -> void:
	_font = load(FONT_PATH)
	if _font == null:
		_fail("找不到像素字体 %s" % FONT_PATH)
		return
	var files := []
	for root in SCRIPT_ROOTS:
		_collect(String(root), files)
	if files.is_empty():
		_fail("res://scripts 下一个 .gd 都没扫到（路径写错了？）")
		return
	for p in files:
		_scan(_read(String(p)), String(p), false)
	for p in DATA_FILES:
		if FileAccess.file_exists(String(p)):
			_scan(_read(String(p)), String(p), true)

	var scanned := files.size() + DATA_FILES.size()
	if _bad.is_empty():
		print("GLYPH TEST 扫了 %d 个文件（res://scripts + res://content），UI 里没有缺字形 ✅" % scanned)
		print("GLYPH TEST RESULT: PASS")
		quit(0)
		return

	print("GLYPH TEST FAIL: UI 里用了 %d 个像素字体没有的字（画出来是空的）：" % _bad.size())
	var keys := _bad.keys()
	keys.sort_custom(func(a, b): return a.unicode_at(0) < b.unicode_at(0))
	for ch in keys:
		print("  U+%04X  %s   出现于 %s" % [ch.unicode_at(0), ch, "、".join(_bad[ch])])
	print("  替换建议：− → -（ASCII）；∑ → Σ（U+03A3）；≈ → 约；✗ → ×（U+00D7）；⚠ → ！（U+FF01）；√ → · 或「完成」")
	print("GLYPH TEST RESULT: FAIL")
	quit(1)
