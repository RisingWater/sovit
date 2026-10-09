# sovit

一个回合制经济沙盒：你是国有资本运营者，通过调工资、调价格、建店、扩产，维持人口与满意度，并逐步私有化。

> **当前进度：v0.1 = 纯函数引擎 + AI HTTP 接口（无 UI）。**
> 完整设计见 [`docs/plan_v0.1.md`](docs/plan_v0.1.md)。UI（React + 等距地图 + 图表）留待后续里程碑。

---

## 快速开始

```bash
npm install

npm run typecheck   # 类型检查
npm run sim         # 100 天无头验收（默认 v0.1）
npm run api         # 启动 AI HTTP 接口（http://localhost:8787）
```

`npm run sim` 支持参数：`npm run sim -- [天数] [种子] [内容包]`，例如
`npm run sim -- 200 42 v1.0`。

---

## 目录结构

```
src/
├─ engine/                 # 纯函数引擎（不依赖 UI / Node API）
│  ├─ types.ts             # 全部类型
│  ├─ config.ts            # 经济参数（集中调参）
│  ├─ rng.ts               # 确定性随机（同种子 → 同结果）
│  ├─ state.ts             # createInitialState
│  ├─ content/             # 全 v1.0 内容表 + v0.1 pack
│  ├─ systems/             # 生产 / 消费 / 人口 / 满意度 / 财政 / 投资 / 用工
│  ├─ tick.ts              # advanceDay(state, actions) 主入口
│  ├─ actions.ts           # 动作应用
│  └─ observe.ts           # 观测 JSON
├─ ai/heuristic.ts         # 启发式基线 AI
└─ api/server.ts           # AI HTTP 接口
scripts/simulate.ts        # 100 天验收脚本
```

引擎与 UI 分离：`advanceDay` 是不修改入参的纯函数，带种子随机，UI / AI / 测试共用同一套逻辑。

---

## 引擎 API

```ts
import { createInitialState, advanceDay, observe } from './src/engine/index.ts'

let state = createInitialState({ pack: 'v0.1', seed: 12345 })

state = advanceDay(state, [
  { type: 'set_wage', shopId: 'coarse_bakery#1', value: 3 },
  { type: 'set_price', goodId: 'coarse_bread', value: 1.8 },
  { type: 'expand', shopId: 'wheat_farm#1' },
  { type: 'end_turn' },        // 含 end_turn 才会结算一天
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
  -d '{"actions":[{"type":"set_wage","shopId":"coarse_bakery#1","value":3},{"type":"end_turn"}]}'
```

响应包含 `observation` / `applied`（每个动作是否成功）/ `log`（当日日志）。

---

## 内容包

- **v0.1**（默认）：面包链（小麦农场 → 磨坊 → 面包房）+ 蔬菜链，单阶层（穷人）。
- **v1.0**：全量商品 / 配方 / 建筑 / 四阶层（穷人 / 中产 / 富人 / 老板），目前仅冒烟测试。

全量内容始终存在于 `src/engine/content/`，`ContentPack` 只决定「本局允许出现什么」。

---

## 验收（`npm run sim`）

用启发式基线 AI 跑 100 天，断言：

1. 人口不崩（≥ 开局 70%）
2. 满意度终值 ≥ 45
3. 政府余额 ≥ -1000
4. 同种子结果完全可复现

参考结果（seed 12345，v0.1）：人口 16 → 28，满意度 ~87，余额稳定在 ¥290。

---

## 经济说明（v0.1）

- 全国有：政府是唯一所有者和卖方，按 `taxRate` 征收所得税，销售回款回流政府。
- 货币近似闭合：工资（gross）− 所得税 = 居民净收入 ≈ 食物成本，故政府日常收支大致平衡，扩产 / 建店消耗初始资本。
- 移民受「岗位空缺」限制：要先建店创造岗位，人口才会增长。
- 失业者领取保障金（可温饱），但满意度较低。
