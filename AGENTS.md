# AGENTS.md — 仓库级约定

> Godot 子工程另有 `godot/AGENTS.md`（引擎版本、分层、门槛），在 `godot/` 下工作时以它为准。

## 工具链的坑（都是实际踩过的，别重复踩）

### 1. 别用内联 Python / Node 写含引号或中文的脚本

```sh
# ✗ 会被 PowerShell 拆坏：引号、$、反斜杠、中文都可能出问题
python -c "print('中文')"
node -e "console.log('a\"b')"
```

本会话因为这条失败了至少四次，症状各不相同（参数被吞、字符串被截断、静默输出错东西）。
**一律写成临时脚本文件再跑**，跑完删掉：

```sh
# ✓
python scripts/tmp-xxx.py
node scripts/tmp-xxx.ts
```

### 2. 多行中文提交信息必须用 `git commit -F <文件>`

```sh
# ✗ PowerShell 会把多行 -m 参数拆坏，报 "did not match any file(s) known to git"
git commit -m "第一行" -m "第二行"

# ✓ 把信息写进文件（用 write 工具，别用 Set-Content —— 会加 BOM）
git commit -F .git/COMMIT_MSG
```

### 3. 临时文件

- 临时脚本用完**立刻删**，别留在工作区（会让并行 agent 误判成"来路不明的文件"）
- `__pycache__/`、`*.pyc` 已在 `.gitignore`；`scripts/` 下的脚本互相 import 会产生它们

### 4. 带中文的 `.ps1` 必须存成 **UTF-8 带 BOM**

Windows PowerShell 5.1（本机没有 `pwsh`）读**无 BOM** 的脚本时按 **ANSI/GBK** 解码。
中文注释的字节会两两配对，**把紧随其后的换行也吃掉** —— 于是 `param(` 被并进上一行
注释里，报出来的是这种指错方向的错：

```
Unexpected token ')' in expression or statement.
Missing closing '}' in statement block or type definition.
The assignment expression is not valid.   ← 指着 [int]$TimeoutMs = 90000
```

**症状极具误导性**：文件本身完全正常（`git diff` 干净、`read` 工具看也对），
只有 `powershell -File` 跑它会炸；而 `powershell -Command "& script.ps1"` 有时又是好的。

```powershell
# 加 BOM（改完 .ps1 就补一次 —— write/edit 工具写出来的是无 BOM）
$p='godot/tools/xxx.ps1'
$t=[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($p,$t,[Text.UTF8Encoding]::new($true))
```

⚠️ 这条**只针对 `.ps1`**：`git commit -F` 的消息文件、`.json`、`.gd`、`.sh`
都**不要** BOM（`git` 会把 BOM 当成提交信息的一部分；Godot 也不喜欢）。

### 5. `godot/content/buildings.json` 会莫名变成 tab 缩进 —— 是 Godot 编辑器干的

症状：改完内容跑过 `verify.sh`（第一步是 `godot --headless --import`），
`git status` 里 `godot/content/buildings.json` 就脏了，`git diff` 是 **900 行纯空白**
（`git diff -w` 为空、语义完全没变）。

**原因**：Godot **编辑器**曾经把 `res://content/buildings.json` 当成 JSON 资源**开着**，
记在 `.godot/editor/editor_layout.cfg` 的 `[ScriptEditor] open_scripts` 里。
之后每次编辑器启动（含 headless 的 `--import`）都会恢复这个标签页 → 载入该 JSON 资源
→ 退出时**用 Godot 自己的 JSON 序列化器重存**（`JSON.stringify(dict, "\t")`，tab 缩进，
12700 字节 vs 源文件的 16642）。只有这一个文件会中招，因为只有它被编辑器打开过。

**修法**（`.godot/` 是本地缓存，不进仓库）：

```sh
# 把 buildings.json 从编辑器"打开着的标签页"里去掉（保留其它 .gd）
# .godot/editor/editor_layout.cfg → [ScriptEditor] open_scripts=[...] 
```

改完再跑一次同步 + `--import`，文件应保持源文件的字节数、`git status` 干净。
⚠️ **在 Godot 编辑器里别再双击打开 `content/*.json`** —— 一开就又记进 `open_scripts`，
下次门槛又把它改成 tab。要查内容用文本编辑器看根目录那份。

### 6. `godot/content/*.json` 必须与 `sync:content` 的输出逐字节一致

内容数据源是根 `content/*.json`，`godot/content/` 是 `npm run sync:content` 的
**逐字节副本**（`cpSync`，不做任何转换）。⚠️ 根目录那几份是**手工排版**的：
`buildings.json` / `housing.json` 是 **2 空格缩进**、长数组换行展开，
`goods.json` / `technologies.json` / `packs.json` / `economy.json` 里还有**行内数组/压缩对象**。
所以**不要**用 `JSON.parse` → `JSON.stringify(…, 2)` 整文件重写来改内容（会把全文重排、
diff 一片红）；用编辑工具改那几行，或者写完自己比对"差异里只有我要改的行"。
历史上 `godot/content/buildings.json` 长期是 tab 缩进（就是上面第 5 条那个原因被误当成
"仓库风格"），一度让多个 agent 不敢跑同步。**现在已对齐**（提交 `8bc7651`），往后：改完根
`content/` 就跑同步，副本的 diff 应该只反映真实内容变化；如果又冒出大段空白 diff，回去看第 5 条。

## 内容与仿真的契约

- 公式/顺序/常量的**唯一契约**是 `docs/spec.md`；改引擎行为必须同步它
- 引擎有 **TS（`src/engine/`）与 GDScript（`godot/scripts/sim/`）两份实现**，
  改一边就要改另一边，并让 `godot/tests/golden/` 对拍通过
- 内容数据源在根 `content/*.json`；`godot/content/` 是 `npm run sync:content` 的副本，**不要手改**
- **改建筑占地**：每座 `arch:"sprite"` 建筑/住房都在 `art.foot` 里显式写了占地。缺省规则是
  `floor(贴图宽/16) × (floor(贴图高/16) − 1)` —— **最上面一行（屋顶/塔尖）不占地**。
  ⚠️ 占地的**锚点是"脚"**：`cell` 存的是**底边那一行的最左格**，占格**往上**长（换算只走
  `world_view._foot_top()` / `_foot_anchor()` / `_foot_rect()`，别自己写 `cell.y - fp.y + 1`）。
  改完 → `npm run sync:content` → `npm run check:footprint`（秒级：越界 / 顶部隐形行 / 副本同步 /
  哪些座与推导不同）。点屋顶要能选中建筑靠"命中区"（`_sprite_rect()`）。口径与坑见
  `docs/town.md` §13.9–13.11，公式的唯一实现是 `world_view.gd::_footprint()`

## 并行协作

多个 agent 可能同时在同一工作区改文件。所以：
- commit 前先 `git diff --cached --name-only` 确认**只有自己的文件**，别用 `git add -A` 把别人的在途改动卷进提交
- 看到不认识的未跟踪文件，**不要**擅自提交或删除 —— 可能是兄弟 agent 正在写的产物
