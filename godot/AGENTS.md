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

## 门槛（每次改动都要过）

```sh
./verify.sh      # 或 Windows: bash verify.sh
```

必须全绿：`--import` → 每个改动的 `.gd` 过 `--check-only` → gdUnit4 测试 → headless 冒烟。

## 移植契约

- 仿真公式/顺序/常量以仓库根 `docs/spec.md` 为**唯一契约**。
- `tests/golden/*.json` 由 `npm run golden` 生成；GDScript 必须复现同一摘要（容差 1e-3）。
