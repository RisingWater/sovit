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

## 内容与仿真的契约

- 公式/顺序/常量的**唯一契约**是 `docs/spec.md`；改引擎行为必须同步它
- 引擎有 **TS（`src/engine/`）与 GDScript（`godot/scripts/sim/`）两份实现**，
  改一边就要改另一边，并让 `godot/tests/golden/` 对拍通过
- 内容数据源在根 `content/*.json`；`godot/content/` 是 `npm run sync:content` 的副本，**不要手改**

## 并行协作

多个 agent 可能同时在同一工作区改文件。所以：
- commit 前先 `git diff --cached --name-only` 确认**只有自己的文件**，别用 `git add -A` 把别人的在途改动卷进提交
- 看到不认识的未跟踪文件，**不要**擅自提交或删除 —— 可能是兄弟 agent 正在写的产物
