# AGENTS.md — Godot 子工程约定

- **引擎**：Godot **4.7.2 stable**（`D:\wangxu\game\Godot_v4.7.2\Godot_v4.7.2-stable_win64_console.exe`，headless 用 `_console.exe`）。
- **语言**：GDScript（不用 C#）。
- **不要碰** `godot/.godot/`（可再生的导入缓存）。
- 内容数据源在仓库根 `content/*.json`；`godot/content/` 是 `npm run sync:content` 生成的副本，不要手改。

## 分层（强制）

- `scripts/core/`：内容加载 / RNG / 存档等基础设施（可挂 Node 的只有 autoload 壳）。
- `scripts/sim/`：**纯仿真核心**——只能 `RefCounted`，**不得**引用任何 Node / 场景 / 输入 / 渲染。必须能在 headless 下运行。
- `scripts/world/`、`scripts/ui/`：表现层（可挂 Node）。
- 表现层只读仿真状态、通过信号更新；不得把逻辑写进仿真层之外。
- **公告日志的真源是 `sim.s["log"]`**（逐小时累积、上限 500、进存档），表现层用
  `SimCore.log_tail()` / `log_size()` 读它 —— **不要**在 `scripts/world/`、`scripts/ui/`
  里再攒一份副本。曾经 `SimRunner.recent_logs` 就是这么一份内存环形缓冲，读档时被清空，
  用户看到的是"公告，退出再进来就全清空了"（见 `docs/town.md` §7.7、门槛 `logsave`）。

## 门槛（每次改动都要过）

```sh
./verify.sh      # 或 Windows: bash verify.sh
```

必须全绿：`--import` → 每个改动的 `.gd` 过 `--check-only` → gdUnit4 测试 → headless 冒烟。

⚠️ `verify.sh` 里的条数会随功能增加，**改行为就要回来补一条**（每条都写清"红了说明什么"）。
最近补的三条：

| 步骤 | 文件 | 盯什么 |
|---|---|---|
| `queue` | `tools/queue_test.gd` | 建造队列的调序 / 撤单退料（与 TS 的 `check-queues.ts` 同口径同数字） |
| `sitecancel` | `tools/sitecancel_test.gd` | 撤单后地图上的工地要消失、地格要放回；命令还没生效的工地**不许**被当孤儿收掉 |
| `glyph` | `tools/glyph_test.gd` | UI 字符串里不许出现像素字体没有的字（见下） |

### 像素字体里没有的字 = 屏幕上什么都没有（而且不报错）

`assets/fonts/fusion-pixel-12px-zh_hans.ttf` 缺这些常用符号，画出来是**空**：

```
缺：− (U+2212)   ∑ (U+2211)   ≈ (U+2248)   ✗ (U+2717)   ⚠ (U+26A0)   ≤ ≥
有：+ - × (U+00D7) – (U+2013) — … ↑ ↓ → ▲ ▼ Σ (U+03A3) － ± ÷ ·
```

实测踩过：建筑面板的折叠按钮写的是 U+2212 `−`，**展开状态下按钮上一个字都没有**；
存档对话框的「⚠ 无法识别」、收支分页的「∑ 居民 gross」同理。

门槛 `tools/glyph_test.gd` 扫 `res://scripts/**/*.gd` 里**字符串字面量内**的字符（注释不算，
注释里爱写啥写啥）+ `res://content/*.json` 全文，用 `Font.has_char()` 判定。
换字形前先问一句引擎：

```gdscript
load("res://assets/fonts/fusion-pixel-12px-zh_hans.ttf").has_char(0x2212)   # false
```

## 移植契约

- 仿真公式/顺序/常量以仓库根 `docs/spec.md` 为**唯一契约**。
- `tests/golden/*.json` 由 `npm run golden` 生成；GDScript 必须复现同一摘要（容差 1e-3）。
