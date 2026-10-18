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
最近补的六条：

| 步骤 | 文件 | 盯什么 |
|---|---|---|
| `queue` | `tools/queue_test.gd` | 建造队列的调序 / 撤单退料（与 TS 的 `check-queues.ts` 同口径同数字） |
| `sitecancel` | `tools/sitecancel_test.gd` | 撤单后地图上的工地要消失、地格要放回；命令还没生效的工地**不许**被当孤儿收掉 |
| `glyph` | `tools/glyph_test.gd` | UI 字符串里不许出现像素字体没有的字（见下）。⚠️ 扫的还有 `res://content/quests.json`（任务标题/hint 是直接画在追踪条上的） |
| `quest` | `tools/quest_test.gd` | 任务（引导系统，见 `docs/quests.md`）：渐进显示（未解锁的不下发）、黎明自动结算（达成即完成 + 发钱，不用提交）、连锁可追溯、支线不挡章节奖励、完成不回退。与 TS 的 `scripts/check-quests.ts` 同口径同数字；任务的**显示文案由引擎拼**（`goal.text`），UI 不许自己拼。2026-10 又加了：面板数据源 `quest_journal()`（已完成的隔天仍留着、锁着的不进）与追踪条标题图标在位 |
| `questpanel` | `tools/questpanel_test.gd` | 任务面板（见 `docs/town.md` §十九）：左侧圆钮第 5 个接对了、点得开、**全屏**（anchors 0..1，和统计/科技同一个口径）、**默认选中第一个未完成的任务**、左树分章且可展开收起、右栏四块齐全（`brief` / 要求 / 完成情况 / 第几天完成）。⚠️ 圆钮列挂在 HUD 的**父节点**上，找按钮要从 `UI/Root` 找 |
| `ai` | `tools/ai_test.gd` | AI 辅助（见 `docs/ai-assist.md`）：**跑完全套顾问之后 `sim.s` 逐字节不变**（只读契约，不然黄金轨迹会漂）、建议里只出现已解锁任务（不剧透）、**人设是瑟拉菲娜（22 岁猫系傲娇、水晶球、征兆 / 应对 / 预言）、面板上只有这一个口吻**、**模型看到的字里不许出现「沙盘 / 模拟引擎」**、玩家写的那句问话原样进提示词、**预言家 5 天冷却**（问过才起算、逐天递减、进存档、老存档能迁移）、**沙盘 `Trial`**（跑完真实状态逐字节不变 / 命令真的落地 / 确定性 / 拒绝理由说人话 / 天数夹到 5 / 一轮 5 个方案 < 2s）、**多轮协议 `ProphetAgent`**（3 轮封顶、第 3 轮明说「最后一轮」、收尾关掉工具、轮次用满会拒跑、坏工具/坏参数只回原因、文本 JSON 兜底但长正文不被劫持）、`tool_calls` 解析、**金色 / 冷却灰两张图标都在 32×32**、新开局的每个数字与引擎对拍、`KNOWN_GOAL_TYPES` 覆盖内容里全部 `goal.type`、配置往返 + `api_key` 不进请求体 + 模型回答里的缺字形被收拾掉 |
| `esc` | `tools/esc_test.gd` | ESC 菜单：**每一行都有图标**（`UIKit.icon_left_button()`：图标贴左边、文字居中）、保存 / 读取开的是自绘对话框而不是 `FileDialog`、顶栏只剩 快存/快读/菜单、圆钮列 5 个且在左侧 |
| `consumetip` | `tools/consumetip_test.gd` | 资源页「工业消耗 / 居民消耗」的悬停明细（2026-10）：台账拆分表 `consumedBy` / `boughtBy` **加起来等于总量**、面板上那两个标签**真的挂着** tooltip 且 `mouse_filter = STOP`（Label 默认 IGNORE，只设 tooltip_text 不会弹）、真鼠标移动过去 `gui_get_hovered_control()` 命中的就是它、tooltip 里的「建筑名 ×座数」「阶层名 ×人数」与村里实际一致 |
| `tools` | `tools/tool_test.gd` | 工具（石制工具）**消耗换产能**（2026-10）：`perWorkstation = 0.1`（一个工人 10 天 1 件）、农业/工业/矿场三类在黎明都会装配（`toolBoost = 1.25`）、按 `0.1×在岗人数` 扣料且台账总量与 `consumedBy` 一致、**产出 ×1.25 而投入一件不多**、没工具就不加成、空工坊不扣、不够时按 shops 顺序先到先得。与 TS 的 `scripts/check-tools.ts` 同口径同数字 |
| `coal` | `tools/coal_test.gd` | 煤矿与**燃料**（2026-10）：`GameMap.COAL = 6` / 地形名 "coal" / 生成量与出生点距离 / 贴图索引 54 / 内容（`coal_mine` 建在 `coal`、产煤、矿场页、中文「煤矿」）/ 放置闸 / **有煤先烧煤且只扣煤**、没煤改烧木柴、两种都没有就不排产不产出（不许凭空烧）。与 TS 的 `scripts/check-fuels.ts` 同口径 |
| `coverage` | `tools/coverage_test.gd` | 人口覆盖（2026-10 第二批）：**服务不是消费品**——诊所/医院/学校/治安所按"一座覆盖 N 人 × 等级"算覆盖率，`min(1, 覆盖/人口)`；**医疗/教育只加中产以上**、治安四阶层都加；排不上产（没药水）就覆盖 0；学校按教育覆盖率加速熟练度成长（满覆盖 ×1.5）；覆盖率**不写进存档**（每次现算）。与 TS `scripts/check-coverage.ts` 同口径 |

### 像素字体里没有的字 = 屏幕上什么都没有（而且不报错）

`assets/fonts/fusion-pixel-12px-zh_hans.ttf` 缺这些常用符号，画出来是**空**：

```
缺：− (U+2212)   ∑ (U+2211)   ≈ (U+2248)   ✗ (U+2717)   ⚠ (U+26A0)   ≤ ≥   √ (U+221A)   ✓ ✔ (U+2713/2714)   ❤ (U+2764)
有：+ - × (U+00D7) – (U+2013) — … ↑ ↓ → ▲ ▼ Σ (U+03A3) － ± ÷ · 【】《》● ■ •
```

实测踩过：建筑面板的折叠按钮写的是 U+2212 `−`，**展开状态下按钮上一个字都没有**；
存档对话框的「⚠ 无法识别」、收支分页的「∑ 居民 gross」同理。
2026-10 又踩一次：给模型回答做缺字替换时，拿 `√` 当 `✓` 的替身 —— **替身自己也是缺的**。

⚠️ 要写"缺字形 → 替身"的映射表（`ui_kit.gd::GLYPH_FIX`）时，**键写成码点 `0x2212` 而不是字符**：
这张表的键按定义就是字体里没有的字，写进字符串字面量会被本门槛抓个正着；码点只出现在注释里，注释不进画面。

门槛 `tools/glyph_test.gd` 扫 `res://scripts/**/*.gd` 里**字符串字面量内**的字符（注释不算，
注释里爱写啥写啥）+ `res://content/*.json` 全文，用 `Font.has_char()` 判定。
换字形前先问一句引擎：

```gdscript
load("res://assets/fonts/fusion-pixel-12px-zh_hans.ttf").has_char(0x2212)   # false
```

## 移植契约

- 仿真公式/顺序/常量以仓库根 `docs/spec.md` 为**唯一契约**。
- `tests/golden/*.json` 由 `npm run golden` 生成；GDScript 必须复现同一摘要（容差 1e-3）。
