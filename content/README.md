# content/ —— 游戏内容数据（JSON 驱动）

引擎的全部「内容」都在这几个 JSON 里。**改这里就能改游戏，不用改代码。**
启动 / 测试时会自动读取并**校验**：字段类型、取值范围、id 唯一、引用是否存在。改错会立刻报错并指出字段路径。

| 文件 | 内容 |
|---|---|
| `goods.json` | 商品（资源 / 加工品 / 消费品 / 投资品） |
| `buildings.json` | 建筑，**配方内嵌**在每个建筑里 |
| `classes.json` | 阶层与它的需求（`needs`）+ 阶层参数 |
| `housing.json` | 住房（容量、等级、造价、私有化售价） |
| `packs.json` | 内容包：每局允许出现哪些内容 + **开局场景** |
| `economy.json` | **全局参数**（`economy`）/ 新建默认值（`defaults`）/ 机制常数（`tuning`） |

> 改完跑 `npm run check:content` 快速自检，或直接 `npm test`。

---

## 1. 加一种资源 / 商品（`goods.json`）

```jsonc
{ "id": "iron_ore", "nameZh": "铁矿石", "tier": 0, "category": "raw",
  "storable": true, "baseValue": 2 }
```

| 字段 | 说明 |
|---|---|
| `id` | 唯一标识（英文，代码里用它引用） |
| `nameZh` | 显示名 |
| `tier` | `0` 自然资源 / `1` 加工品 / `2` 消费品 / `3` 投资品 |
| `category` | `raw` `food` `clothing` `household` `fuel` `material` `housing` `investment` `service` `entertainment`。**决定行为**：`food` 参与吃饭，`housing` 不当普通商品卖，`clothing/household/entertainment` 算奢侈品 |
| `storable` | 是否耐储 |
| `baseValue` | 基准价值（居民购买意愿 + 价格分参照） |
| `perishRate` | 可选，每日损耗比例 0–1（服务填 `1` 表示当天归零） |

## 2. 加一座建筑 + 它的配方（`buildings.json`）

配方**直接写在建筑里**，不用另外维护关联 id。

```jsonc
{ "id": "iron_mine", "nameZh": "铁矿", "tier": 1, "workers": 3, "maxWorkers": 100,
  "buildCost": { "wood": 4, "build_power": 1 },
  "recipe": { "inputs": {}, "output": { "iron_ore": 8 }, "baseRate": 1 } }
```

| 字段 | 说明 |
|---|---|
| `workers` | 参照满员工人数（决定人均产出基准） |
| `maxWorkers` | 可选，**工位上限**（矿场/林场这类劳动密集型可调到 100） |
| `buildCost` | 可选，建店消耗的实物材料（缺省用 money 兜底） |
| `recipe.inputs` | 每批次投入（`{}` = 一级产业，不耗料） |
| `recipe.output` | 每批次产出（不能为空） |
| `recipe.baseRate` | 满员每日批次数 |
| `recipe.fuel` | 可选，每批次额外烧的木柴 |

> 引擎内部会把配方 id 记为 `r_<建筑id>`（如 `iron_mine` → `r_iron_mine`），你**不用手写**。

## 3. 加一条产业链

产业链 = 建筑配方的输入/输出互相引用。例如「铁矿石 → 铁 → 工具」：

```jsonc
// 1) goods.json 加：{ "id": "iron", ... }、{ "id": "tool", ... }
// 2) buildings.json 加：
{ "id": "smelter", "nameZh": "熔炉", "tier": 2, "workers": 3,
  "buildCost": { "stone": 6, "brick": 4, "build_power": 2 },
  "recipe": { "inputs": { "iron_ore": 6 }, "output": { "iron": 4 }, "baseRate": 1, "fuel": 3 } }
{ "id": "tool_works", "nameZh": "工具坊", "tier": 2, "workers": 3,
  "recipe": { "inputs": { "iron": 4 }, "output": { "tool": 3 }, "baseRate": 1 } }
```

## 4. 让新建筑出现在某一局（`packs.json`）

内容包是「这局允许出现什么」的**白名单**。把新 id 加进对应 pack 的 `buildings` / `goods`：

```jsonc
{ "id": "v0.3", "nameZh": "v0.3 分层社会",
  "goods": [ "...", "iron_ore", "iron", "tool" ],
  "buildings": [ "...", "iron_mine", "smelter", "tool_works" ] }
```

> 没加进任何 pack 的内容不会出现在游戏里。

## 5. 阶层与住房

- **阶层** `classes.json`：`needs` 是该阶层的人均日需求；`fallbacks` 是缺货时按序替代。引用的商品必须在 `goods.json` 里存在。
  每个阶层还有：`satBonus`（满意度加成）、`housingLevel`（要求的最低住房等级 1/2/3，≥2 才会私有化买房）、`wealthThreshold`（存款达到多少升入本阶层）。
- **住房** `housing.json`：`quality` 1–3，`capacity` 每单位住几人，`classId` 对应能买它的阶层，`buildCost` 是材料，`salePrice` 是私有化售价。

## 6. 调参数（`economy.json`）

三块：

| 块 | 用途 |
|---|---|
| `economy` | 全局数值：工资基准、税表、价格弹性、满意度权重、移民/迁出阈值、施工天数、土地上限（`null` = 不限）等 |
| `defaults` | 新建实体的默认值：`newShop`（新店 level/skill）、`newResident`（新移民存款/满意度/技能）、`startResident`（开局居民）、`startDistribution`（开局阶层） |
| `tuning` | 机制可调常数：`skillEffectBase/Slope`（技能→产出）、`hungryThreshold`（饥饿判定）、`priceFactorMin/Max`（价格系数夹紧）、`basicFoods`（食物兜底）、`foodChainSeedClass`（口粮链种子阶层） |

改一个数字即可调平衡，无需改代码。

## 7. 开局场景（`packs.json` 的 `start`）

每个 pack 自带开局：

```jsonc
"start": {
  "population": 12,
  "money": 2000,
  "shops": { "wheat_farm": 1 },        // 开局建筑：defId → 数量
  "housing": { "hut": 3 },             // 开局住房存量
  "goods": { "wood": 300 }             // 开局库存
}
```

- `shops` 里的 defId 必须在 `buildings.json`；`housing` 里的 id 必须在 `housing.json` 且属于本 pack；`goods` 里的 id 必须在 `goods.json`。
- 空开局就这样写：`"shops": {}`、`"housing": { "hut": 3 }`、`"goods": { ... }`。
