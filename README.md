# sovit

一个回合制经济沙盒：你是国有资本运营者，通过调工资、调价格、建店、建房、扩产，维持人口与满意度，并逐步私有化。

> **当前进度：v0.2 = 纯函数引擎 + AI HTTP 接口（无 UI）。**
> v0.2 引入「建材链 + 住房」，人口可长期增长（受土地上限约束）。
> 完整设计见 [`docs/plan_v0.1.md`](docs/plan_v0.1.md)；UI（React + 等距地图 + 图表）留待后续里程碑。

---

## 快速开始

```bash
npm install

npm run typecheck   # 类型检查
npm run sim         # 无头验收（默认 v0.2，100 天）
npm run api         # 启动 AI HTTP 接口（http://localhost:8787）
```

`npm run sim` 支持参数：`npm run sim -- [天数] [种子] [内容包]`，例如
`npm run sim -- 1000 777 v0.2`。

---

## 目录结构

```
src/
├─ engine/                 # 纯函数引擎（不依赖 UI / Node API）
│  ├─ types.ts             # 全部类型
│  ├─ config.ts            # 经济参数（集中调参）
│  ├─ rng.ts               # 确定性随机（同种子 → 同结果）
│  ├─ state.ts             # createInitialState
│  ├─ content/             # 全 v1.0 内容表 + v0.1 / v0.2 pack
│  ├─ systems/             # 生产 / 消费 / 人口 / 满意度 / 财政 / 投资 / 用工
│  ├─ tick.ts              # advanceDay(state, actions) 主入口
│  ├─ actions.ts           # 动作应用
│  └─ observe.ts           # 观测 JSON
├─ ai/heuristic.ts         # 启发式基线 AI（自动按 pack 分派策略）
└─ api/server.ts           # AI HTTP 接口
scripts/simulate.ts        # 无头验收脚本
```

引擎与 UI 分离：`advanceDay` 是不修改入参的纯函数，带种子随机，UI / AI / 测试共用同一套逻辑。

---

## 引擎 API

```ts
import { createInitialState, advanceDay, observe } from './src/engine/index.ts'

let state = createInitialState({ pack: 'v0.2', seed: 12345 })

state = advanceDay(state, [
  { type: 'set_wage', shopId: 'coarse_bakery#1', value: 3 },
  { type: 'set_price', goodId: 'coarse_bread', value: 1.8 },
  { type: 'build_housing', goodId: 'hut' },   // 建房，提升人口上限
  { type: 'build', buildingId: 'brick_kiln' },// 建店，进入施工队列
  { type: 'end_turn' },                        // 含 end_turn 才会结算一天
]).state

console.log(observe(state))
```

### 动作

| 动作 | 说明 |
|---|---|
| `set_wage { shopId, value }` | 设定该店工资 |
| `set_workers { shopId, value }` | 设定目标用工数 |
| `set_price { goodId, value }` | 设定商品售价 |
| `expand { shopId }` | 扩产（+1 等级） |
| `toggle { shopId, active }` | 开 / 关 |
| `build { buildingId }` | 建店（进入施工队列） |
| `build_housing { goodId }` | 建造住房，提升人口上限 |
| `set_tax { value }` | 设定所得税率 0–0.95 |
| `end_turn` | 结算一天 |

预留（返回 `not_implemented`）：`sell_shop`、`retake_shop`、`subsidy`。

---

## AI HTTP 接口

```
GET  /health                     健康检查
GET  /state                      当前观测（Observation）
POST /reset  { seed?, pack? }    重开局
POST /act    { actions: [...] }  应用动作；含 end_turn 则结算一天
```

示例：

```bash
curl http://localhost:8787/state

curl -X POST http://localhost:8787/act \
  -H "content-type: application/json" \
  -d '{"actions":[{"type":"build_housing","goodId":"hut"},{"type":"end_turn"}]}'
```

响应包含 `observation` / `applied`（每个动作是否成功）/ `log`（当日日志）。

---

## 内容包

| Pack | 内容 | 人口 |
|---|---|---|
| `v0.1` | 面包链 + 蔬菜链，纯货币建造 | 受岗位封顶（稳定不增长） |
| `v0.2`（默认） | v0.1 + 木材 / 粘土 / 燃料 / 砖 建材链 + 住房 | 可增长，受住房与土地封顶 |
| `v1.0` | 全量商品 / 配方 / 建筑 / 四阶层 | 仅冒烟测试 |

全量内容始终存在于 `src/engine/content/`，`ContentPack` 只决定「本局允许出现什么」。

---

## 验收（`npm run sim`）

断言：

1. 人口不崩（≥ 开局 70%）
2. 满意度终值 ≥ 45
3. 政府余额 ≥ -1000
4. 同种子结果完全可复现
5. 含住房的 pack：人口增长 ≥ 开局 1.3 倍

参考结果（v0.2，seed 12345，300 天）：人口 **24 → 70**，满意度 ~87，余额稳定 ¥975。

---

## 经济说明

- **封闭货币循环**：政府是唯一雇主与卖方，按 `taxRate` 征所得税。工资 − 所得税 ≈ 食物成本，销售回款回流政府 → 政府日常收支平衡，只剩投资消耗。
- **政府无法累积盈余**：封闭经济下 `政府净收入 = 销售 + 税收 − 工资 ≤ 0`。因此 v0.2 的建造走**实物材料**（木材 / 石块 / 粘土 / 砖），不依赖财政积累。
- **人口增长**：`人口上限 = min(住房容量, 岗位数)`；移民只在有空位时迁入。住房与产线都通过建造增加，受**土地上限**（`ECONOMY.maxBuildingSlots`）约束，因此增长有界、后期收敛。
- **劳动力分配**：食品链优先保证用工，剩余劳动力按需求比例分给建材链，避免扩产过快导致饥荒。
- **失业保障**：失业者领取保障金（可温饱）但满意度较低。

---

## 后续

- UI 里程碑（React + 等距地图 + 趋势图）
- 私有化 / 竞争 / 老板经营（已预留接口签名）
- 全量 v1.0 产业链的经济平衡调参
- 库存上限 / 损耗，抑制过量囤积
