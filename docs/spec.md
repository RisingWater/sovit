# Sovit 仿真规格（跨语言契约）

> 这份文档是 **TS 引擎与 Godot(GDScript) 移植之间的唯一契约**。
> 任何一处公式/顺序/常量不一致都会导致 golden 轨迹漂移。改引擎必须同步改这里。
> 所有可调数值都在 `content/*.json`，公式里的常量名对应 `content/economy.json`。

---

## 0. 时间模型

- 1 tick = 1 游戏小时；`hoursPerDay`（默认 24）。
- `tickSec`：1 游戏小时 = 多少真实秒（@1x，默认 5 → 2 分钟/天）。
- 每小时的阶段（`tick.ts` → `stepHour`）：
  - `h == dawnHour(6)`：**黎明** `runDawn`
  - `workStart(6) <= h < workEnd(18)`：**生产** `runProductionStep(f)` → **施工** `applyConstructionHours(f)`，
    `f = 1/(workEnd-workStart)`
  - `h == settleHour(18)`：**夜晚** `runNight`
  - 推进：`hour = (hour+1) % hoursPerDay`
- `state.day` 在**黎明** +1。
- **公告日志 `state.log`（2026-10 起）**：`stepHour` 在这一小时跑完后，把**当小时返回的全部
  日志**（黎明 / 白天 / 夜晚三批）并进 `state.log`，超过 500 条截掉最旧的。
  - `state.log` 是公告页的**唯一真源**，随存档保存 —— 表现层**不得**再自己攒一份副本
    （曾经 Godot 侧读的是 `SimRunner.recent_logs` 这份内存环形缓冲，读档时被清空，
    于是"退出再进来公告全没了"）。
  - ⚠️ 以前只有 `runNight()` 往里写，所以「建成投产」「研究完成」「X 改建为 Y」这类
    **黎明**日志从来没进过存档。直接调 `runDawn()` / `runNight()` 只拿到返回值，
    不写 `state.log` —— 累积只发生在 `stepHour()` 这一处（两边实现都如此）。

## 1. 命令队列（次日生效）

- 所有命令（玩家/AI）追加到 `state.pending`。
- **黎明**统一执行 `applyActions(state, pending)` 后清空。因此：
  - 06:00 前下的命令当天 06:00 生效；
  - 06:00 后下的命令等次日 06:00。**例外：研究队列的三条（research / cancel_research / move_research）当场生效**，见 technology.md §10.2。
- 命令语义见 `actions.ts`；`end_turn` 为空操作。

## 2. 生产（日计划 + 小时执行）

### 2.1 黎明排产 `planProduction`（两阶段公平分配）

对每个 `active` 且到岗人数 `w>0` 的建筑：

```
staffing = w / def.workers
skillEff = skillEffectBase + skillEffectSlope * (shop.skill / 100)     // 0.6 + 0.4*skill/100
desired  = recipe.baseRate * staffing * skillEff * shop.level
inputPer = recipe.inputs（每批次），另加 firewood: recipe.fuel
```

汇总总需求 `demand[g] += inputPer[g] * desired`；再对每种投入算统一系数：

```
factor[g] = min(1, goods[g] / demand[g])
planned   = desired * min_{g∈该建筑用到的投入} factor[g]      // 与建筑顺序无关
shop.planned = planned
shop.profit  = Σ_output(q*planned*baseValue) − Σ_input(q*planned*baseValue) − w*shop.wage
```

### 2.2 白天执行 `runProductionStep(fraction)`

`fraction = 1/(workEnd−workStart)`（默认 1/12）。对每个 `active && planned>0` 的建筑：

```
batches = shop.planned * fraction
goods[g] -= inputPer[g] * batches      // 含 firewood
goods[g] += output[g]  * batches * shop.toolBoost * (1 + techBonuses[def.sector])
```

**不取整**（浮点，避免 12 次累积误差）。

### 2.3 损耗 `applySpoilage`（夜晚，每天一次）

`goods[g] *= (1 − perishRate)`（非耐储商品）。

### 2.4 仓储上限 `applyStorageCap`（夜晚，**紧接 §2.3 之后**）

设计见 `docs/town.md` §三。**两层口径**，都在这一步、每天一次：

**① 每种物资的软上限**（玩家在**选中仓库后的检视面板**里逐项设置，见 §2.4 末的命令）
```
cap_g = government.storageCaps[g]        # 缺项 = 不限
若 goods[g] > cap_g  →  goods[g] = cap_g，丢弃 (原值 − cap_g)，写一条 log
```
用途：某一种货囤满自己的额度后就不再挤占全局空间，别的物资才收得下。

**② 全局总量上限**
```
容量 = Σ 仓储建筑的容量          # 见下
总量 = Σ goods[g]  (本 pack 全部商品)
若 容量 > 0 且 总量 > 容量:
    keep = 容量 / 总量                       # 保留比例
    对每种 goods[g] > 0:  goods[g] = floor2(goods[g] × keep)     # 向下取整到 2 位小数
    写一条 log（含比例与共丢弃量）
```
- 一座建筑的容量 = `storage.storage + storage.storagePerLevel × (等级 − 1)`
- **`workers > 0` 的仓储建筑，`assignedWorkers < 1` 时不计容量**（仓库要有人看着）；
  `workers == 0` 的（城镇中心）直接计入
- 容量 = 0 时**不丢弃**（没有仓储建筑 = 不受上限约束）

**削减规则（确定性）**：**所有物资按同一比例削减** —— `keep = 容量 / 总量`，每种物资保留
`floor2(原值 × keep)`。谁也不被单独针对，**食物不会被优先丢掉**；向下取整保证削减后总量 ≤ 容量。

> ⚠️ 2026-10 改：原来是「按 `baseValue` 升序丢（先丢便宜的）」。那条规则有致命副作用 ——
> **食物恰好是最便宜的**（蔬菜 1.2 / 粗面包 1.3 / 小麦 1.0），于是"开局资源 x2"
> （1960 > 容量 1000）**第一晚就把 400 粗面包 + 174.6 蔬菜全丢了**，剩下的全是
> 木材/石块/砖，接下来几天饿死一半人口。用户原话："怎么能先盯着食物丢弃，
> 应该是各种物资平均丢弃吧。"

| 常量 | 值 | 来源 |
|---|---|---|
| 城镇中心容量 | 2000 | `content/buildings.json` 的 `town_center.storage.storage` |
| 仓库容量（1 级） | 300 | 同上 `warehouse` |
| 仓库每级增量 | 150 | `warehouse.storage.storagePerLevel` |

**顺序上的两条硬约束**（都在 `tick.ts` 的夜晚序列里，见 §9.4 / §2.3）：
1. 在**施工开工扣材料之后** —— 开工扣料发生在白天第一个工作小时（§9.3），
   夜晚那条施工收尾（§9.4）也排在丢弃之前，所以不会出现"工地材料被超限丢弃、工地卡死"
2. 在 `applySpoilage` **之后** —— 先损耗、后判上限，损耗腾出的空间能救下本来会被丢的货

**报警**：库存总量 ≥ 容量时 `alerts` 里加 `{type:'storage_full'}`（否则货凭空消失，像是 bug）。

**命令 `set_storage_caps { caps }`**：整体替换 `government.storageCaps`；只收本 pack 里存在的商品，值取非负整数，`0` 视为不限（不入表）。

### 2.5 效率科技加成 `techBonuses`（跨全天的倍率）

「效率科技」在 `content/technologies.json` 里带 `effects`，形如 `"effects": { "agri": 0.10 }`。
值是**加成小数**（`0.10` = +10%），不是倍率。可用键只有 6 个：

| 键 | 作用点 |
|---|---|
| `agri` / `goods` / `material` | 该 **sector** 建筑的产出 |
| `research` | 每日科研力（§10.1） |
| `build` | 每日建造力（§9.1） |
| `services` | **治安 / 医疗 / 教育**这三样公共服务商品的产出（按商品认，不按 sector） |

```
techBonuses(state) = for tid in research.done:
                       for k in [agri, goods, material, research, build, services]:
                         out[k] += technologies[tid].effects[k] ?? 0      # 缺省 0
```

- **加法叠加，不是连乘**：轮作 +20% + 灌溉 +35% + 良种 +50% = **+1.05**。
  连乘后期滚雪球，而且玩家在面板上没法一眼算出"现在是多少"。
- **不取整**（`round2` 只用在最终速率上）。
- 按固定键序累加，**不依赖内容里 `effects` 的键序**。
- `services` 不是 sector：产这三样商品的建筑 `sector` 都是 `goods`（诊所在造"医疗点数"、
  学校在造"教育点数"），单靠 sector 分不出来，所以按**产出商品 id** 认
  （`SERVICE_GOODS = ['safety', 'medical_service', 'education']`，TS `tech_bonus.ts` /
  GD `sim_core.SERVICE_GOODS` 同一份）。三级科技：培训 +10% / 民生工程 +20% / 治理 +30%。

**三处作用点**（乘数一律是 `1 + 加成`）：

| 位置 | 公式 |
|---|---|
| §2.2 产出 | `goods[g] += output[g] * batches * shop.toolBoost * (1 + techBonuses[def.sector]) * (1 + techBonuses.services if g ∈ SERVICE_GOODS)` —— **投入那张表不动**，多出来的产出是"虚空产量"（不额外吃原料） |
| §10.1 科研 | `researchRate = (基础 + Σ 研究所) * (1 + techBonuses.research)` —— **整条**速率，含 `baseRate` |
| §9.1 建造 | `constructionRate = (失业人口 + Σ 建筑工坊) * (1 + techBonuses.build)` —— **整条**速率 |

- 产出那条与 `toolBoost` 是**相乘**（两条独立路线：工具 +25%、产业科技最多 +105%）；
  `services` 再与 sector 那道**相乘**（诊所的产出 = 工具 × goods 科技 × services 科技）。
- 建筑没有 `sector`（无配方建筑：城镇中心 / 仓库 / 建筑工坊 / 研究所）→ 倍率 1。
- 建筑的 `sector`（`agri`/`goods`/`material`）是**内容字段**，校验器强制：
  **有 `recipe` 就必须有 `sector`**，反之不许有。
- **前端**：科技面板分「制造」「效率」两页（`panel_tech.gd`），顶部显示累计加成，
  卡片 tooltip 里有单项效果。

## 3. 用工 `assignLabor`（黎明）

1. 重置所有居民 `employed=false, jobShopId=undefined, constructionPay=undefined`。
2. **口粮链**：以 `tuning.foodChainSeedClass` 的食物 `needs` 为种子，对 `recipes` 反复回溯上游投入（仅限本 pack 商品），得到集合 `F`。
   - 若种子阶层无食物需求：退化为「本 pack 所有 `category=food` 商品」。
3. 建筑分为两档：`priority`（其配方任一产出 ∈ F；**无配方的建筑不算**）与其余。
4. 分配（`budget = pop`）：
   - priority 按 `state.shops` 顺序依次满足 `want = min(targetWorkers, def.maxWorkers ?? def.workers)`。
   - 其余按 `want` 比例用**最大余数法**分配剩余 `budget`。
5. 落地：按 `state.shops` 顺序、按 `residents` 顺序依次占用；`shop.skill = 到岗者 skill 平均`。
6. 熟练度增长在**夜晚**（`growSkills`）：在岗者 `skill = min(skillMax, skill + skillGainPerDay)`。

## 4. 财政

### 4.1 累进税 `progressiveTax(income, brackets)`
逐档：`slice = max(0, min(income, upTo) − prev)`；`tax += slice*rate`。

### 4.2 工资 `payWages`（夜晚，每天一次）
```
# 失业保障金已取消：没有工程可做 = 零收入（见 §9 与 docs/construction.md）
buildPay = resident.constructionPay ?? 0
gross = buildPay > 0            ? buildPay                         # 工地临时工，固定日薪
      : employed && jobShopId   ? min(wage*(skillIncomeBase+min(skillMax,skill)/100), wageCap||∞)
      : 0
tax = progressiveTax(gross, brackets)
savings += gross − tax ;  government.money += (Σtax − Σgross)
```

## 5. 住房

### 5.1 占用 `assignTenure`
- 房主占自己名下房（`ownedQuality`）。
- 剩余名额：先私有后国有、等级从高到低；租客按阶层从高到低排序。
- 写 `resident.privateTenant`、`resident.housingQuality`。

### 5.2 收租 `collectRent`（夜晚）
- 国有租客 `pay=min(rent,savings)` → 政府。
- 私有租客 `pay` 汇入总额；按**人均份额**`progressiveTax` 计税，税款归政府，余额给房东平分。

### 5.3 买房 `runPrivateHousingMarket`（夜晚）
遍历 `pack.housing`：`price = prices[gid] ?? salePrice ?? baseValue`；
⚠️ 2026-10 起住房**不再是商品**（`goods.json` 里没有 `hut` 等），所以最后那级 `baseValue`
实际退化成常量 **1**（`housing.json` 的 `salePrice` 三档都写了 10 / 25 / 50，永远命中第二级）。
GDScript 侧要小心：`Dictionary.get(k, 默认值)` **不短路**，回退值必须先算出来
（`sim_core.gd::_base_value_or()`）。
当"该房型还有**国有且未售**的一栋"且 `soldTotal<privateHousingPerDay`，选**存款最高**的合格买家：
非房主、`classLevel>=2`、`classLevel==def.quality`、`savings>=price+5`、`satisfaction>=privateHousingNeedThreshold`。
成交（2026-10 起**落在具体那一栋**上）：`savings-=price`、`homeowner=true, ownedQuality=quality`、
`ownedUnitId=<那一栋的房号>`、那一栋 `unit.private=true / unit.ownerId=<买家>`、`government.money+=price`；
计数由 `syncHousingCounts()` 重算（`privateHousing[gid]++` 是它的结果，不再手写）。

### 5.4 住房改建 `upgrade_housing`（2026-10）

内容里 `housing.json` 的 `upgradeTo` 给出**显式**的改建链（当前：茅屋 → 木屋 → 砖房）。
**不按 `quality` 自动推下一档** —— 别墅同样是高档房，但没人指向它，所以只能单独建造
（用户："茅屋可以升级成木屋，木屋升级成砖房，但是别墅要单独建造"）。

```
动作    { type:'upgrade_housing', goodId, unitId? }   # goodId = 改建**前**的房型
        unitId = 指名那一栋（`HousingUnit.id`）；不给就由引擎挑最早那栋可改建的
前提    goodId ∈ pack.housing；有 upgradeTo；目标房型已解锁（同 build_housing）
        选中的那栋必须存在、房型对、**非私有**、且没有已经在改建队列里
        # → 私有住房**不能**改建；在途的也算占用（否则完工时会凭空多出一栋）
成本    mats = { g: max(0, to.buildCost[g] − from.buildCost[g]) }   # 只算差价，旧料视为回收
        work = max(1, to.buildWork − from.buildWork)
条目    construction 里 kind='housing_upgrade'，housingId=from、toHousingId=to、
        **housingUnitId = 那一栋的房号**
        **不额外占土地名额**（`usedSlots()` 跳过它）
完工    **那一栋**的 `unit.type = to`（房号不变、栋数不变），再 `syncHousingCounts()`
        日志：`<from> 改建为 <to>`
```

`available()`（开工时扣材料）与其它工程同一条路径；进度条与悬停提示由表现层负责 ——
2026-10 起**按房号认**（`housingUnitId`），不再靠"同类型第 i 座 ↔ 第 i 条"的顺序配对
（那套约定曾让进度条在批量改建时到处乱跳，见 docs/town.md §二十八）。
自检：`scripts/check-housing-upgrade.ts`（引擎）＋ `godot/tools/housingupgrade_test.gd`（镜像与世界层）。

### 5.5 住房单体 `housingUnits`（2026-10）

用户："引擎没建筑 id？村民 id 也没有？" —— 建筑（`shops[].id`）和村民（`residents[].id`）
本来就有，**只有住房**是 `{hut: 6}` 这种计数。现在补上：

```
state.housingUnits: HousingUnit[]     # 一栋一个：{ id: "h#7", type, private, ownerId? }
state.housingSeq: number              # 下一个房号（单调，收房不回收号码）
state.housing / state.privateHousing  # **派生计数**，由 syncHousingCounts() 从 units 重算
```

- 增删房一律走 `addHousingUnit()` / `removeHousingUnit()`（GDScript 同名下划线版），
  它们内部会重算计数；**改建只换 `type`，房号不变**
- `privateHousing` 不再手写：私有一栋就 `unit.private = true`（+ `ownerId`）
- 容量 / 租金 / 任务判定 / 黄金摘要继续读计数 → 行为与摘要都不变
  （`scripts/golden.ts::summarize` 取的就是 `state.housing`）
- 存档版本 **3**（旧档拒读）；`SaveManager._sanitize()` 在缺 `housingUnits` 的残缺存档里
  按计数重建，然后按 units 回算两个计数
- 世界层与仿真**一一对应**：地图实例的 `uid` 就是房号（`h#N`），
  所以"哪一栋在改建 / 哪一栋是私产"都是确定的

### 5.6 城镇中心修缮 `repair_town_center`（2026-10）

用户："初始城镇中心是破旧的" → 之后又要"第三章加一个初步修复城镇中心的任务"。于是三段：

```
state.townCenter = { stage: 'ruined' | 'patched' | 'restored' }      # 开局 ruined
动作  { type:'repair_town_center', stage?: 'patched' | 'restored' }  # 缺省 restored
硬闸  canRepairTownCenter()：ruined→patched→restored，**不能跳级**
成本  patched  : 木 20 + 石 10        （TOWN_CENTER_PATCH_COST）
      restored : 木 30 + 石 20 + 砖 15（TOWN_CENTER_REPAIR_COST）
生效  与其它动作一样**次日黎明**（applyActions）；材料不够 → 白下这一单
任务  第 3 章 q05e_townhall_patch    → building_repaired{id:townhall, stage:patched}
      第 4 章 q10f_townhall_repair   → building_repaired{id:townhall}（= restored）
判定  段位序比较（`>=`）：patched 那条在 restored 时也算完成
```

⚠️ `stage` 是**给表现层**的状态段（三段三张贴图，见 `docs/town.md` §二十六），
仿真的任何数字都不读它 —— 与 `prophet` / `quests.shown` 同类，黄金摘要不受影响。


## 6. 消费 `runConsumption`（夜晚）

逐**阶层**、逐**居民**、逐 `need`：
```
candidates = [good, ...fallbacks] 过滤到本 pack
若 need 为食物：再补 tuning.basicFoods
target = 第一个 goods>0.001 的候选，否则 candidates[0]
elastic = isLuxury(target) ? luxuryElasticity : priceElasticity
factor  = clamp( (baseValue/price)^elastic , priceFactorMin , priceFactorMax )
desired = perCapita * factor
want    = min(desired, savings/price)
sold    = min(want, goods[target])
goods[target]-=sold ; savings-=sold*price ; revenue+=sold*price
食物 need：foodConsumed+=sold, foodNeeded+=desired（非食物同理记 comfort）
```
每居民 `foodScore = foodConsumed/foodNeeded`；`foodScore < hungryThreshold(0.9)` 记 1 饥饿。
政府 + `revenue`。**奢侈品判定**：`goods[gid].luxury === true`。

## 7. 满意度 `updateSatisfaction`（夜晚）
```
wageScore = clamp(wage/refWage, 0, wageScoreCap) / wageScoreCap
employmentScore = employed ? 1 : unemployedEmploymentScore
base = 100 * (wF*food + wW*wage + wP*price + wE*employment + wC*comfort) / (Σweights)
housingAdj = homeowner ? +privateHousingSatBonus
           : privateTenant ? +privateTenantSatBonus − rentPressure*rentSatPenalty
           : −rentPressure*rentSatPenalty
           + (housingQuality < classHousingLevel ? −(差级数)*housingQualityPenalty : 0)
target = clamp(base + housingAdj + classSatBonus, 0, 100)
satisfaction = clamp(satisfaction + (target−satisfaction)*satisfactionSmoothing, 0, 100)
```
`rentPressure = clamp(rent / max(0.1, refWage − progressiveTax(refWage)), 0, 1)`；`classHousingLevel/classSatBonus` 取自居民阶层的定义。

## 8. 人口与移民（夜晚）

- **死亡（饥饿）**：若 `hungry>0`，`deaths = min(ceil(hungry*hungerDeathRate), pop−minPopulation)`；
  按满意度最低者淘汰，**遗产充公**（政府 +Σsavings）。
- **迁出**：若 `avgSat < emigrationSatThreshold`，`leave = min(max(1,floor(pop*0.02)), pop−minPopulation)`；带走存款。
- **分层** `updateClasses`：按 pack 允许阶层的 `wealthThreshold` 升序，取 `savings` 满足的最高阶层。
- **放行** `applyAdmission`：`admit = min(arrivals, housingCapacity−pop, populationCap−pop)`；
  新居民默认最低阶层，属性取 `defaults.newResident`。
  **岗位数不参与**：岗位可以后补，把 `Σ targetWorkers` 当闸门会让村子永远长不大
  （建造队与移民会互斥）。规模由玩家设定的人口上限（`government.populationCap`）兜住。
- **想来人数** `computeArrivals`（job 无关，只看满意度与饥荒）：
  1. 昨日 `hungry > max(1, pop × immigrationHungryRate)` → `arrivals = 0`（"食物充足"这一条）
  2. `avgSat < immigrationSatThreshold` → 0
  3. 否则 `round(pop × immigrationRate × (avgSat−th)/(100−th))`

## 9. 施工（建店 / 升级 / 建房）

> **建造力 = 每日施工产能（速率，不是库存）**。完整设计见 `docs/construction.md`。
>
> **节奏**：施工与生产**同一节奏** —— 产能摊在白天的工作小时里逐小时投入（§9.3），
> 工地上白天能看见进度在爬；**一天的总量 = 黎明钉住的当日建造力**（不结转）。
> 黎明的 `planConstructionDay` 只做一件事：把这个预算钉死（§9.3），白天不再现算。
> 夜晚只做收尾（§9.4）：诊断队首为什么没动 + 把当日投入折成建造工资。

### 9.1 每日产能 `constructionRate`
```
rate = (Σ(失业居民) × construction.unemployedRate
     + Σ(建筑工坊在岗工人) × construction.workshopBase × (skillEffectBase + skillEffectSlope × 熟练度/100))
     × (1 + techBonuses.build)          # 效率科技：起重架 / 脚手架 / 预制件（见 §2.5）
```
- 「建筑工坊」= **没有 `recipe` 的建筑**（产出建造产能而非商品）。
- 失业居民 = `!resident.employed`。产能**不结转**，当天没用完即作废。
- 效率加成乘在**整条速率**上（失业人口那一项也一起放大）。

### 9.2 下单 `tryBuild` / `tryExpand` / `tryBuildHousing`
只检查资源是否够，占住队列位，**不扣材料**；压入
`construction{kind, remaining=buildWork, totalRequired, started=false}`。
- 建筑工时 `buildWork` 见 `content/buildings.json`；住房见 `housing.json`。
- 升级工时 = `construction.upgradePerLevel × 当前等级`。
- `usedSlots = shops + 在建(非 upgrade) + housing`。
- 下单之后**改顺序 / 撤单**走 §9.8 的两条动作（队列是先进先出的一条）。

### 9.3 黎明 `planConstructionDay` + 白天 `applyConstructionHours(fraction)`（**与 §2.2 同一条件**）

**黎明**（`runDawn`，排在 `assignLabor` **之后**、第一个工作小时**之前**）：
```
state.constructionRateToday = constructionRate(state)   # 当天预算：全天不变
state.constructionWorkToday = 0
```
> 为什么要钉死"当天的预算"：这是"一天总量恰好等于当日建造力"的**硬闸** ——
> 白天每个工作小时投入的量都抵着它，不必依赖"同一天里 `constructionRate()` 恰好不变"
> （它取决于失业人口与建筑工坊的在岗人数；`shop.skill` 只在黎明 `assignLabor` 与
> 入夜 `growSkills` 两处变，但任何一处将来改动都不该动摇当天的总量）。
> 科研（§10.3）钉的是同一道闸，两边完全同构。

**白天**在 `state.hour` 满足 `workStart <= h < workEnd` 时**每小时调用一次**（排在
`runProductionStep` **之后** —— 当小时刚产出的木石粘土，当小时就能用于工地开工扣料）。
`fraction = 1/(workEnd−workStart)`（默认 1/12）。

先进先出，串行投入：
```
rate   = constructionRateToday × fraction     # 这一个小时的量：**常数**，不取整
work   = 0
for c in construction:                        # 队首 → 队尾
    if rate <= 0 → break
    if !c.started:
        spec = costOf(c)                      # 实物原料，或（无可用原料时）资金
        定义缺失 → break                       # 诊断留给夜晚（§9.4）
        不足     → break                       # 停在队首等待，**不跳过**
        足够     → payCost(spec); c.started = true
                   记日志「开工（需建造力 N）」   # **只在 started 翻转时写一次**
    used = min(rate, c.remaining)
    c.remaining = round4(c.remaining − used)  # **r4**：12 次 r2 会漂移
    rate -= used ; work += used
state.constructionWorkToday = round4(state.constructionWorkToday + work)
```
- **每小时的量是个常数**（`constructionRateToday / 工作小时数`），**不是**每小时现算一次
  `constructionRate()`：当天中途的人事变动（在岗人数 / 失业人口）不会动摇今天的量。
- **开工时刻 = 这一天第一个工作小时**（材料在这一刻扣，不是夜晚）。
- 一天的投入总量 = `constructionRateToday`（每小时 1/工作小时数），**不结转**。
- 日志节奏：小时里**不写**「等待材料」（否则一天刷 12 条）—— 那条诊断在夜晚（§9.4），
  每天最多一条；「开工」只在 `started` 翻转的那一小时写一次。
- `rate` 本身**不取整**（取整会让工作小时之和不再恰好等于日产能）；
  只有落进状态的两处（`remaining` / `constructionWorkToday`）用 r4。

### 9.4 夜晚 `settleConstruction`（**在 `payWages` 之前**）

产能已经在白天投完了，这里只做两件事：

```
# ① 诊断：队首为什么没动（每天最多一条）
若 constructionRate > 0：
    c = 第一条 !started 的工程
    它前面若有「已开工且 remaining > 0」的工程 → 不诊断   # 产能被前面的工程正常吃掉了
    costOf(c) 缺失 → 记日志「定义缺失，施工停摆」
    买不起        → 记日志「等待材料（…）」

# ② 当日投入折成建造工资
markConstructionWorkers(state.constructionWorkToday)
state.constructionWorkToday = 0
```

`markConstructionWorkers(work)`：出工人数 `n = min(失业人数, ceil(work))`；
总工资 `bill = work × refWage × construction.wageRate`，在 n 人之间平均分配，
写入 `resident.constructionPay` 并置 `employed = true`（当晚算就业、计熟练度增长）。
`work` = 当日白天逐小时累计的投入量（`constructionWorkToday`，r4）。

### 9.5 黎明 `activateCompleted`
`remaining <= 0` 的按 kind 生效（建店 / 升级 / 建房），其余留队。

### 9.6 有效工位数 `effectiveSlots`
```
slots = (def.maxWorkers ?? def.workers) + (def.capacity?.slotsPerLevel ?? 0) × (等级 − 1)
```
**这是工位上限的唯一口径**，三处共用：
- `assignLabor`：实际派人时按它截断 `targetWorkers`
- `set_workers` 动作：按它截断 `value`
- 表现层：建筑面板的用工拖动条 `max_value`

> 曾经 `set_workers` 是按 `maxWorkers` 那个**常数**截断的，于是
> "把研究所升到 L3 再拖满 12 人"会被**静默夹回 6 人** ——
> 上限看着是 12、拖到 12、次日却只有 6 个工位在开。同一口径必须只有一份实现。

> ⚠️ **工位上限是内容决定的天花板，别开大**（用户 2026-10）：产出按
> `staffing = 在岗 / workers` **线性放大、不封顶**，所以 `maxWorkers` 一开大，
> 玩家就会把整个村子塞进一座采石场而不是多建一座。用户看到采石场写着「最多 100 人」
> 当场否掉 ——「太多了，和农田一样，要就多建造」。现在：采集业（伐木/采石/粘土）= 6，
> 通用硬上限 12（`validate.ts::MAX_WORKERS_CAP`，超过 `check:content` 直接红）。
> 明细见 `docs/content.md` §八之二。

**升级时的用工目标重算**（`activateCompleted` 的 `upgrade` 分支）：

| 升级前 | 升级后 |
|---|---|
| `targetWorkers == 旧 slots`（满员） | `targetWorkers = 新 slots`（**继续满员**） |
| 不满员 | **保持原来的绝对数字**（不按比例缩放） |

不减这一手的话，研究所从 L1 升到 L2 会"自动少 3 个工位"，玩家看着莫名其妙。

### 9.7 拆除 `demolish`
`{ type: 'demolish', shopId }` → 从 `state.shops` 移除该店。

- **只作用于已建成的**。还在 `state.construction` 队列里的不属于 `state.shops`，
  要取消得走施工队列那条路（不在这条动作的职责内）。
- **退「建造资源」**：按 `def.buildCost` 原样退回库存（只退 `goodSet` 里真实存在的项，
  与 `presentCost` 同一口径）。
- **不退「建造力」**：那是每日产能 / 已经投进去的人工，没有"退"的概念。
- **工人自动变回失业**：`assignLabor` 每晚按 `state.shops` 现算，无需额外处理。
- 建筑不存在 → `ok: false, reason: '建筑不存在'`。
- **占用地格由表现层释放**：`world_view._sync()` 会对"引擎里已消失"的店
  调 `_remove_shop_view()` —— 收走精灵、擦掉 `map.occupied`、清掉所有
  按 shop_id 索引的表。不做这一步就会留下"鬼影"且那块地永远不能再建。
- 面板点「拆除」要**弹二次确认窗**（不可撤销，得让玩家看清拆的是哪一座）。

### 9.8 建造队列：调序 `move_construction` / 撤单 `cancel_construction`

队列就是**先进先出**的一条 `state.construction`：队首（index 0）先开工、产能没用完才
溢给下一条。这两条动作让玩家能改它（面板见 `docs/town.md` §十五）。

```
{ type: 'move_construction', id, delta }    # delta = -1 上移一位 / +1 下移一位
{ type: 'cancel_construction', id }
```

**调序**（`moveConstruction`）：
- 只按 `delta` 的**方向**挪**一位**（`sign(delta)`）；只改顺序，**不重算 `remaining`、
  不改 `started`、不退料**。已经开工的工程被挪到后面时只是**暂停**（前面的先吃产能）。
- `id` 不在队列里 → `该工程已不在队列里`；`delta = 0` → `没有移动`；
  在队首再上移 → `已经是队首`；在队尾再下移 → `已经是队尾`。

**撤单**（`cancelConstruction`）：只作用于**还在队列里**的（已建成的走 §9.7 `demolish`）。

- 退料比例：`started && total > 0 ? clamp(remaining / totalRequired, 0, 1) : 0`
  - **还没开工 → 退 0**：材料是**开工那一刻**才扣的（§9.2），没开过工就一分钱都没扣过
  - **已开工 → 退回量 = 已扣材料 × 比例**（只退"还没干完"的那一份），
    金钱口径同理（无实物材料的按 `moneyCostBuild` / `moneyCostExpand` 扣过钱的）
- **不退建造力**：它是每日产能，不是库存（与 §9.7 同口径）。
- 退回物按 `round2` 逐项并进 `state.goods` / `government.money`，然后从队列里移除。
- 成功的返回值里带一句摘要（`text`），`applyActions` 把它**写进公告**
  （`cancel_construction` 是唯一"扣了又还"的动作，退料明细没有别的出口）；
  `reason` 也是它。GDScript 侧同形制：`_apply_actions()` 返回这些日志，
  由 `_run_dawn()` 并进黎明那批（公告的累积仍只发生在 `tick_hour()` 一个入口）。
- 预览：`cancelRefundPreview()`（TS）/ `construction_refund_preview()`（GD）**只算不改**，
  面板的二次确认拿它显示"点了会退回什么"（同一份口径，不会和真退分叉）。
- **取消在建工程要放回土地名额**（`usedSlots` 本来就把在建算作占用）——
  表现层还要收掉地图上那处工地精灵（`world_view._prune_orphan_sites()`），
  否则会留一个永远不完工的"鬼工地"且地格永远占着。

**门槛**：`scripts/check-queues.ts`（TS）与 `godot/tools/queue_test.gd`（GD）
—— 同口径、同数字（木 6/石 3、36 建造力、投 10 点后剩 26 → 退 4.33 / 2.17）。

## 10. 研究（科技解锁）

> **科研力 = 每日产能（速率，不是库存）**，与建造力同构。完整设计见 `docs/technology.md`。
>
> **节奏**：科研与生产 / 施工**同一节奏** —— 产能摊在白天的工作小时里逐小时投入（§10.3），
> 研究所头顶的进度条白天能看见在爬；**一天的总量仍是当天的科研力**（不结转）。
> 夜晚只做收尾（§10.4）：诊断队首为什么没动。

### 10.1 每日产能 `researchRate`
```
rate = (economy.research.baseRate
     + Σ(研究所在岗工人 × capacity.perWorker × (1 + capacity.levelBonus × (等级−1))
                              × (skillEffectBase + skillEffectSlope × 熟练度/100)))
     × (1 + techBonuses.research)       # 效率科技：抄书房 / 学院 / 印刷术（见 §2.5）
```
- 「研究所」= `capacity.kind == 'research'` 的建筑（不产商品）。
- 基础项现在是 **0**（研究所是科研力的唯一来源，见 `docs/technology.md` 纪元 0）。
- 效率加成乘在**整条速率**上（基础项也一起放大）。
- 产能**不结转**，当天没用完即作废。

### 10.2 下单 `research { techId }`
只检查材料是否够，占住队列位，**不扣材料**；压入
`research.queue{id, remaining = tech.research, totalRequired, started = false}`。
拒绝条件（按顺序）：科技不存在 / 已完成 / 已在队列 / **前置未完成** / 材料不足。

`cancel_research { techId }`：从队列移除 + **按进度退回原料**（见 §10.7；以前是"材料不退"，
施工侧加了撤单之后两边口径必须统一）。

`move_research { id, delta }`：调序（见 §10.7）。

### 10.3 黎明 `planResearchDay` + 白天 `applyResearchHours(fraction)`

**黎明**（`runDawn`，排在 `assignLabor` **之后**、第一个工作小时**之前**）：
```
state.researchRateToday = researchRate(state)   # 当天预算：全天不变
state.researchWorkToday = 0
```
> 为什么要钉死"当天的预算"：这是"一天总量恰好等于当日科研力"的**硬闸** ——
> 逐小时投入的量与当日已投累计都抵着它，不必依赖"同一天里 `researchRate()` 恰好不变"
> （`shop.skill` 只在黎明 `assignLabor` 与入夜 `growSkills` 两处变，所以实际一天内不变，
> 但多一条隐含依赖就多一个将来会被改坏的地方）。施工那边（§9.3 的
> `planConstructionDay`）钉的是同一道预算，两边完全同构。

**白天**在 `state.hour` 满足 `workStart <= h < workEnd` 时**每小时调用一次**，
排在 `runProductionStep`、`applyConstructionHours` **之后**（先生产、再施工、后科研）。
`fraction = 1/(workEnd−workStart)`（默认 1/12）。
```
rate  = researchRateToday × fraction     # 这一个小时的量：**常数**，不取整
left  = min(rate, researchRateToday − researchWorkToday)   # 同一格多调一次不会多投
for p in research.queue:                 # 队首 → 队尾
    if left <= 0 → break
    if !p.started:
        材料不足 → 记「等待材料」（p.waiting 去重，每天最多一条）; break   # 停在队首，不跳过
        足够   → 扣材料; p.started = true; 记「开始研究」
    used = min(left, p.remaining)
    p.remaining = max(0, round4(p.remaining − used))   # **r4**：12 次 r2 会漂移
    p.waiting = false
    left = round4(left − used)
    researchWorkToday = round4(researchWorkToday + used)
```
- **每小时的量是个常数**（不是"把队首剩下的需求摊到当天剩下的小时里"）：队首只剩 5、
  日产能 12 时，就是每小时 1、走 5 个小时在**当天中途**跑完。
- **队首中途跑完 → 这一格剩下的产能继续投给下一条**（同格、串行）—— 剩余的产能不许丢，
  这是"一天总量 = 当天科研力"成立的关键；队列空了就作废（**不结转第二天**）。
- `fraction` 只用于"这一格投多少"的语义说明与对称；实际额度由 `researchRateToday` 与
  `researchWorkToday` 的差兜底，所以一天的总投入恰好等于 `researchRateToday`。
- **完工不在这里激活**：跑完后仍留在队列里，等夜晚之后的黎明 `activateResearch` 才出队（§10.5）。

### 10.4 夜晚 `settleResearch`（紧接 `settleConstruction` 之后）

产能已经在白天投完了，这里只做一件事：**队首为什么没动**（每天最多一条诊断）。
```
若 researchRate(state) > 0：               # 产能为 0 时队首本来就没机会开工，不诊断
    p = queue[0]；没有 / 定义缺失 / 已 started 且 remaining<=0 → 不写
    材料不足 → 记「研究「X」等待材料（缺什么）」
```
> 白天每小时都可能撞上同一个缺口，日志若写在小时里会刷 12 条屏，所以挪到夜晚，
> 与施工的 §9.4 同一套口径。

### 10.5 黎明 `activateResearch`
`remaining <= 0` 的项目出队并 push 进 `research.done`（解锁随之生效），**扫全队列**、保持顺序。

> 老版本只认 `queue[0]`（队列是先进先出，正常玩只有队首能跑完）。加了 §10.7 的**调序**
> 之后，"跑完的那项被挪到后面"变成可达状态 —— 只认队首的话它会一直卡在队列里，
> 玩家看到的是"研究完成了却没解锁"。现在与施工的 `activateCompleted` 同形制：谁跑完谁次日生效。

### 10.6 解锁判定
```
可建(建筑) = 没有任何科技 unlocks 它          # 开局免费
          或 解锁它的科技 ∈ research.done
```
住房同理（`unlocks.housing`）。`unlocks` 里每座建筑**至多出现一次**（内容校验强制）。
**商品不单独设锁**：商品的可用性由"产出它的建筑是否解锁"决定。

开局已研究的科技取 `pack.start.techs`（缺省空）。开局自带某建筑**实例**的 pack
必须把解锁它的科技也列进去，否则会出现"有这座建筑但建造栏里是锁的"。

### 10.7 研究队列：调序 `move_research` / 撤单 `cancel_research`

与施工队列（§9.8）**同一套契约**：队列是先进先出的一条 `research.queue`，队首先吃到
科研力，所以调序 = 决定谁先研究。

```
{ type: 'move_research', id, delta }     # delta = -1 上移一位 / +1 下移一位
{ type: 'cancel_research', techId }
```

**调序**（`moveResearch`）：只按 `sign(delta)` 挪一位；只改顺序，**不重算 `remaining`、
不改 `started`、不退料**。已开工的被挪到后面时只是**暂停**。
`id` 不在队列里 → `不在研究队列中`；`delta = 0` → `没有移动`；队首上移 → `已经是队首`；
队尾下移 → `已经是队尾`。

**撤单**（`cancelResearch`）：退料比例 `started && total > 0 ? clamp(remaining/total, 0, 1) : 0`
- **还没开工 → 退 0**：原料是开工那一刻扣的（§10.2/§10.3），没开过工就一分没扣
- **已开工 → 退回量 = 已扣原料 × 比例**，逐项 `round2` 并进 `state.goods`
- **科研力不退**（它是每日产能，不是库存）
- 成功时返回一句摘要（`text`），`applyActions` 把它**写进公告**；`reason` 也是它
- 预览 `researchCancelPreview()`（TS）/ `research_cancel_preview()`（GD）**只算不改**

**门槛**：`scripts/check-queues.ts`（TS）与 `godot/tools/queue_test.gd`（GD），同口径同数字
（木 15 / 20 科研力，投 8 点后剩 12 → 退 9）。

## 11. 工具（工坊耗材与产出加成）

> 完整设计见 `docs/technology.md` §八。

- `economy.tools.perWorkstation`（0.05）：每个**在岗工位**每日消耗的工具数。
- 商品带 `toolBonus`（category = `tool`）；`economy.tools.order` 由低到高排工具品级。

### 11.1 黎明 `allocateTools`（**必须在 `planProduction` 之前**）
```
for shop in shops:
    shop.toolBoost = 1
    if !shop.active or 该建筑没有 recipe: continue    # 产能建筑不产商品，加成无从施加
    workers = 在岗工人数;  if workers <= 0: continue
    need = perWorkstation × workers
    for gid in reverse(economy.tools.order):          # 从**最高级**工具往下找
        if goods[gid] >= need:
            goods[gid] -= need ; ledgerToday.consumed[gid] += need
            ledgerToday.consumedBy[gid][shop.defId] += need
            shop.toolBoost = 1 + ALL_GOODS[gid].toolBonus
            break
```
- 消耗率按**每种工具自己的耐久**（2026-10）：
  `need = 1 / (durabilityDays × (1 + toolLife)) × workers`，再 `round2`
  - 石制 `durabilityDays: 10`（0.1/人/日 = 原来的口径）；铁制 `durabilityDays: 15`
  - `toolLife` 来自科技（`TechEffectKey: 'toolLife'`），**取最高不叠加**（`tech_bonus.ts::MAX_KEYS`）
  - 没写 `durabilityDays` 的工具退回 `economy.tools.perWorkstation`
- 农业 / 工业 / 矿场**一视同仁**：只要这栋建筑有配方、且**在岗有人**就按人头扣工具；
  采集业（农田/伐木场/采石场…）`inputs` 是空的，所以工具给它们的是"零成本 +25%"
- 工具不够时按 `state.shops` 顺序先到先得（确定性，便于对拍）；不够就是**不装配**，
  不匀着分、也不欠账
- 台账的 `consumedBy` 一并记上（资源页「工业消耗」的悬停明细读它）

### 11.2 生产小时 `runProductionStep`
```
goods[g] += q × batches × shop.toolBoost × (1 + techBonuses[def.sector])   # 只放大**产出**
ledgerToday.produced[g] += 同上
# 投入与燃料那几行**完全不动**
```
效果即"投入不变、产出 ×1.25" —— 单位原料成品率提高（"虚空产量"）。

**台账的拆分表**（2026-10，面板 tooltip 用）：扣投入与燃料的那两处**同时**往
`ledgerToday.consumedBy[goodId][defId]` 累加（谁吃掉了它）；`runConsumption` 在成交那一处
往 `ledgerToday.boughtBy[goodId][classId]` 累加（哪一等居民买走的）。
两条都是**可加总回到总量**的（`consumed` / `bought`），门槛 `consumetip` 钉着这一条 ——
它们只进台账（存档），**不参与任何计算**，黄金摘要也不读它们。

### 11.2.1 服务需求：治安 / 医疗 / 教育（2026-10 定稿）

服务**不是覆盖、也不是无成本**：它们是**三件独立商品**，居民按 perCapita 花钱买，
买不齐就升不了阶层（完整表见 `docs/needs.md`）。

```
safety(治安) 0.3 / medical_service(医疗) 0.5 / education(教育) 0.5   每点基准价；perishRate 1（当日归零）
需求：穷人 治安 0.03；中产 +医疗 0.04；富人 +医疗 0.05 +教育 0.05；老板 +医疗 0.06 +教育 0.08
晋升：本阶层**每项需求满足率 = 1.0** 且存款 ≥ 下一档门槛
降级：**连续 3 天**每项满足率 < 0.8（`lowDays` 计数；存款跌破门槛不再直接降级）
```

- 逐项判定：`runConsumption` 记录每项需求满足率，取最小值写进 `r.needsMet`
- 岗位工资：**公共事业统一** `economy.publicServiceWage`（3.6，研究/建造产能 + 医疗/教育/治安/仓储），
  私营按建筑 tier（3.0 / 3.6 / 4.5）
- 公共事业补贴：`ledgerToday.publicSubsidy` = 当晚公共建筑的工资支出（台账口径，不参与计算）
### 11.3 燃料：煤 / 木柴（2026-10）

`recipe.fuel` 是"每批次烧多少燃料"。**烧哪种**由下面这条顺序决定（两份实现同序）：

```
FUEL_ORDER = ['coal', 'firewood']      # 先煤、后木柴
```

黎明 `planProduction`：对每座有 `fuel > 0` 的工坊
```
need   = fuel × desired
fuelGood = FUEL_ORDER 里第一个 stock >= need 的；都不够 → 存量最多的那个；一个没有 → ""
inputPer[fuelGood] += fuel              # 排产按它算需求 / 折扣
shop.fuelGood = fuelGood                # 全天不变 —— 执行时照它扣
```
白天 `runProductionStep`：`gid = shop.fuelGood ?? 'firewood'`，从它扣料、记台账
（`consumed[gid]`、`consumedBy[gid][defId]`）。

- **排产与执行必须是同一个答案**：所以选择发生在黎明、存在 shop 上，而不是每批现挑
- 老存档 / 老内容没有 `fuelGood` → 回退 `firewood`（与旧行为一致）
- 一个燃料都没有时 `planned = 0` —— 不许凭空烧
- 门槛：`godot verify.sh` 的 `coal`、`npm run check:fuels`（同口径同数字）

## 12. 初始状态 `createInitialState`

- 商品/价格/住房取自 `ctx.pack.goods` / `pack.housing`，数量取自 `pack.start`。
- 建筑取自 `pack.start.shops`；居民默认值取 `defaults.startResident`，阶层分布取 `defaults.startDistribution`。
- 科技：`research.done = pack.start.techs ?? []`，`research.queue = []`。
- 工具：新建 / 初始店铺 `toolBoost = 1`。
- `hour=0, day=0, pending=[]`。

## 13. 随机数（mulberry32）

```
state = (state + 0x6d2b79f5) & 0xFFFFFFFF
t = state
t = (t ^ (t >> 15)) * (t | 1) & 0xFFFFFFFF          // 32 位乘法
t ^= (t + ((t ^ (t >> 7)) * (t | 61) & 0xFFFFFFFF)) & 0xFFFFFFFF
out = ((t ^ (t >> 14)) & 0xFFFFFFFF) / 2^32
```
> GDScript 无无符号移位/32 位乘法，需手动 `& 0xFFFFFFFF`。

## 14. 内容 schema

见 `content/README.md`。`economy.json.schemaVersion` 必须等于引擎支持的版本（当前 `1`）。

## 15. 黄金轨迹（golden）

- `scripts/golden.ts`：固定 `pack/seed/脚本`，逐日输出 `godot/tests/golden/<pack>-<seed>.json`。
- Godot 侧 `tests/` 用 gdUnit4 回放同一脚本，逐日比对摘要（数值容差 ~1e-3）。
- 脚本只在指定 tick 入队命令；不含 AI，保证纯仿真可跨语言复现。

## 16. 任务（引导系统）

> 完整设计（任务树、每条任务为什么存在、UI）见 `docs/quests.md`；内容在 `content/quests.json`。
> 两份实现：`src/engine/systems/quests.ts` 与 `godot/scripts/sim/sim_core.gd`（同口径、同数字）。

### 16.1 判定 `checkQuests`（**每小时**，`stepHour` 末尾；黎明那一趟在 `runDawn` 末尾）

> 2026-10-20 用户："提交了任务直接完成。任务完成不用等到 6:00 吧，这样游戏体验很差。"
> 所以判定从"只在天亮时跑"改成**每小时都跑一次**，另外**即时动作之后**再跑一次
> （他当面交完东西，那一条必须当场完成 —— 见 §17）。
> ⚠️ 黎明那一趟**没有**去掉：`runDawn()` 是测试与脚本的直接入口，它自己扫一遍更稳。

```
for sweep in range(questIds.size() + 1):          # 反复扫，直到这一轮没有新完成
  for q in questIds:                              # 内容定义顺序（确定性）
    未完成 && requires 全部完成过 && 本章已开（只闸主线） && goals 全为真:
        quests.done[q] = day ; government.money += reward(q) ; 记一条公告
        若同一趟完成多条 → 合并成一条「完成 N 项任务（+M 金）：A、B」（M = 0 时不写金额）
        并报出被这次结算"顶"出来的新任务：「新任务：…」
章节奖励：某一章的**主线**（`kind:"main"`）全绿 → quests.chapters[chapter] = day ; money += chapter.reward
日志：「章节「X」全部完成（+1000 金）」
```

`reward(q)`：`kind:"milestone"` 一律 0（内容校验也拦：里程碑不许写 `reward`）。

- **什么时候跑**：`stepHour` 里，除黎明那一小时之外每小时扫一次（黎明由 `runDawn` 扫）；
  以及**每一条即时动作之后**（`tick.ts::queueActions` / `sim_core::_apply_immediate`）
- 判定**只看当前状态**（`shops` / `housing` / `residents` / `research.done` / `goods` /
  `history` 台账 / `privateHousing`）—— 所以玩家先干了、任务后出现也**当场算完成**
- 一趟里会**连锁**（反复扫）：刚建好的研究所可以把一条"只差它当前置"的任务一起结算
- 完成**不回退**（人口掉回去也不算未完成）、**不重复发钱**；判定**幂等**，多跑几趟没有副作用
- 显示文案由**引擎**拼（`goalProgress().text` / `quest_progress()`），数字一律向下取整；
  UI 不许自己拼 —— 否则 TS 与 GDScript 会显示出两种样子

### 16.2 可见性 `questView`（渐进显示 + 剧情时钟）

```
返回   未完成但 **可用**（`questAvailable`）的  +  今天刚完成的（done[q] >= day，留一天打勾）
不返回 还没解锁的（玩家不该知道后面还有什么）、还没到点的、以及昨天以前完成的

questAvailable(q) = requires 全部完成过 && 它自己那一道时间闸
  main      : 本章已开 = day >= chapters[上一章] + gapDays(ch)      # 剧情时钟
  side      : 上一章**主线全绿**（不看 gapDays）                       # 2026-10-20 加
  milestone : 没有时间闸（只认 requires —— 它要一直挂在追踪条上填空档）
```

`chapters[].gapDays` = **上一章领奖那天**起再隔几天（章 1–5 填 0，章 6 起 3–5 的固定值）。
上一章还没收尾时这一章一律不开。

**支线为什么要闸**（2026-10-20 用户："瑟拉菲娜的支线一开始就出现了，第一章她还没出场"）：
支线的闸是"上一章主线全绿"，与 `gapDays` 无关 —— 她章 1 收尾登场，章 2 那条支线
就正好在同一瞬间露出来。⚠️ 上一章**一条主线都没有**（还没写内容的占位章）→ 视为"还没到"，
否则章 7 之后那几条支线会在章 6 一结束就一口气全摊出来。

同一个 `questAvailable` 被四个入口共用：追踪条、任务面板、每小时结算、剧情对话播报。

### 16.3 goal 类型（摘要，细节见 docs/quests.md §四）

| type | 判什么 |
|---|---|
| `building` / `housing` / `housing_capacity` | 建成 N 座建筑（在途不算）/ N 栋住房（含私有）/ 住房总容量不低于 N |
| `population` / `class` / `private_housing` | 人口 / 某阶层人数 / 私有住房户数 |
| `tech` / `tech_count` | 某科技已完成 / 已完成科技数 |
| `good` / `produced` | 仓库库存不低于 N / **历史单日产量**曾达到 N（看产能不看库存） |
| `avg_satisfaction` | 全体居民满意度的算术平均 |
| `building_repaired` | 一座**塌了的**建筑修到了某段位（`state.townCenter.stage`）；id 写 `townhall` 或 `town_center` 都认。`stage` 缺省 = `restored`（已修好），`stage:"patched"` = 至少初步修缮过（三段见 `spec` §5.6 / `docs/town.md` §二十六）。别名写法 `{type:"building", id:"town_center", repaired:true}` 等价（也认 `stage`）|
| **`gifted`** | **累计送出**某商品不少于 N（`state.gifts[to][good]`）。⚠️ 判的是"送出去多少"，**不是**库存 —— 所以它糊不了 `good`：东西得真的走 `gift` 命令出门才算数（见 §17）|

### 16.4 面板数据源 `questJournal`（全部**已知**任务）

```
返回   已完成的不论第几天  +  未完成但 requires 全完成过的
不返回 还没解锁、且自己也没完成的（与 questView 同一条渐进显示契约）
顺序   内容定义顺序（`questIds`）
```

与 `questView` 的分工是**用途**不同，不是判定不同：追踪条要"现在做什么"（已完成的最多留一天），
面板要"这一路做过什么、第几天做的"（全部留着）。**两条都只读 `GameState`**，
所以不影响黄金轨迹。

> ⚠️ 任务的显示文案（`goal.text`）与 `brief`（面板右侧的描述）都由**内容 + 引擎**给，
> 表现层一个字都不自己拼 —— 两份实现必须给出同一个字符串。

### 16.5 预言家（AI 辅助）的冷却记账

```
state.prophet = { lastAskDay: int }      # -1 = 这一局还没问过
可问条件：lastAskDay < 0  或  day >= lastAskDay + 5
写入：SimCore.mark_prophet_asked()       # 唯一的写入口，由 UI 在**收到回答后**调用
```

**这是唯一一个不参与仿真演化**的状态段：问不问都不改村子的任何数值，它只是
"5 天才能问一次"这条冷却的记账。因此：

- **不进命令队列**（命令是次日黎明生效，而冷却必须当场生效），也没有任何 `tick` 逻辑读它
- 但**进存档**：退出重进 / 读档都绕不过冷却；2026-10 之前的存档没有这一段，
  `SaveManager._sanitize` 迁移成 `{lastAskDay: -1}`
- **不进黄金摘要**（`scripts/golden.ts::summarize` 是按字段取的），所以加这个段不需要重生成 golden
- TS 侧只有字段（`GameState.prophet` + `createInitialState`），规则与 UI 都在 Godot 侧
  （TS 引擎没有"问话"这个动作）—— 详见 `docs/ai-assist.md` §五

> ⚠️ 发钱会改 `government.money`，因此会改黄金轨迹：动 `content/quests.json` 之后要
> `npm run golden` 重生成，并让 GDScript 侧回放通过（`npm run check:quests` +
> `godot verify.sh` 的 `quest` / `questpanel` 步骤）。

### 16.6 沙盘 `Trial`（AI 辅助的"试方案"，只读）

```
克隆：SimCore.new(db) + s = source.s.duplicate(true) + rng = Rng.new(source.rng.state)
跑法：从**现在**起 days × 24 小时，每小时 tick_hour()；第 1/25/49… 个小时把当天下达的命令入队
命令：翻译成 _apply_actions() 认的动作（build / build_housing / expand / research / set_workers）
      —— 缺料、科技锁、没有那座建筑，全由引擎自己拒，沙盘只如实报告
产出：那一刻的汇总（人口/满意度/饥饿/国库/住房/岗位/食物/材料/建成数/在建数/新完成任务/短板）
      + 与"什么都不做、同样跑 days 天"的对照之差
```

**契约要点**：

- **只读真实状态**：沙盘只读 `source.s`，跑完 `sim.s` 逐字节不变（门槛 `ai_test` 钉这一条），
  所以它**不进黄金轨迹**、不影响确定性。
- **不另写规则**：命令走引擎自己的动作与判定，`Trial` 里没有一个经济公式；
  汇总也复用 `Advisor` 的口径函数（食物/住房/满意度/规则引擎）。
- **确定性**：同一份状态 + 同一个方案跑两遍，结果逐位相同（rng 状态一起复制）。
- **上限**：`days ≤ 5`、命令 `≤ 12`（`Trial.MAX_DAYS` / `MAX_MANDATES`）——
  这是给模型用的工具，不能让它一次把 CPU 吃光。实测一轮 5 个方案 ≈ 20~30 ms。
- **命令集刻意收窄**：只给"建设 / 研究 / 用工"三类；拆房、改税、改价不开放试。
  详见 `docs/ai-assist.md` §五。

### 16.7 剧情对话 `questTalks`（只读，用户 2026-10）

```
输入   state.quests.{done, chapters, shown} + 内容（giver / giverPortrait / brief / chapters[].outro）
输出   [ { key, kind, id, chapter, speaker, portrait, lines[], choices[]? } ]     # 还没播过的
顺序   按 chapters 顺序，每章先「本章未完成且已解锁的任务」，再「本章 outro」
记账   markQuestTalkShown(key) → state.quests.shown[key] = true
切句   splitSentences()：只按 。！？… 断，标点跟着前一句走
```

- **只读**：不改任何数字，所以不影响黄金摘要、不进 `golden.ts::summarize`
- `shown` 是**只记事**的状态段（与 `prophet` / `townCenter` 同类），进存档是为了
  读档 / 退出重进不重播；缺了也不会算错（最多补播一遍）
- 台词内容全在 `content/quests.json`（任务的 `brief`、章节的 `outro`），引擎不硬编码一个字
- 表现层：`godot/scripts/ui/quest_talk.gd`（galgame 框），由 `main.gd` 在
  `hour_ticked` / 开场剧情结束后轮询 `quest_talks_pending()`；对话期间
  `hud.set_paused_external(true)` 暂停时间（纯表现层，不进仿真状态）
- 选项的 `action` 由 UI 消费。⚠️ **2026-10-18 起章 1 收尾没有选项**：
  那 6 行原文保留，后面直接接 **5 行固定预言**（玩家不能拒绝），`free_prophecy` 这个动作
  与 `ai_panel.open_free_prophecy()` 一并作废。机制本身（`choices` / `action`）保留，
  留给后面的分支场次（例如章 15「救不救集会」）。

### 16.8 任务种类 `kind`（用户 2026-10 · B2）

| kind | 进追踪条 | 进「支线」页 | 挡剧情时钟 | 算进章节奖励 | 发钱 |
|---|---|---|---|---|---|
| `main` | ✅ | — | ✅ | ✅ | ✅ |
| `side` | ✅ | ✅ | — | — | ✅ |
| `milestone` | ✅ | —（单独一组）| — | — | ❌ **不发** |

- 内容里 `"kind"` 与老写法 `"side": true` 都收；校验器把两者归成**一份真相**（`kind`），
  `side` 只是派生别名（GDScript 侧 `quest_provider` 也这么归）
- 里程碑**唯一的职责是让追踪条不空**（目标可以设得很远，2000 人到不了也没关系）
- 校验器拦两条：`kind:"milestone"` 不许写 `reward`；**主线不许 `requires` 支线 / 里程碑**

## 17. 送物资 `gift`（用户 2026-10 · A4，2026-10-20 改成**即时**）

```
命令   { type:"gift", to:"serafina", goodId, qty }     # **即时生效**（IMMEDIATE_ACTIONS）
可用   只能花"**没被锁定的**"：available(gid) = goods[gid] − reserved[gid]
       （reserved = 当天排产已经计划掉的原料；动了它白天就缺料 —— 与 spend() 同一口径）
语义   可用量够 → 当场扣 qty、state.gifts[to][good] += qty、写一条公告「送物资：粗面包 ×20」
       **紧接着跑一趟 checkQuests**：刚交齐的那条任务当场完成、奖励当场进国库（不等 6:00）
       可用量不够 / qty ≤ 0 / 商品不在本 pack → 整单不做（**没有"送一半"**）
状态   state.gifts = { 收礼人: { 商品: 累计送出量 } }     # 存档 v5
判定   任务目标 `gifted` 读它；`good`（库存）读不到"送出过多少"
入口   ① 任务面板：`gifted` 那条要求的后面长一个「提交」按钮
          （qty = min(还差多少, **可用量**)；没有可交的就灰着）
       （2026-10-20：「预言面板底部一行送物资」那个入口**删掉了** —— 只在任务面板里交）
```

## 18. 历法（`AE` 纪元，用户 2026-10 · B0）

```
第 1 天 = AE 312年1月1日          # AE = 帝国纪元 = After Empire
12 个月 × 30 天 = 360 天/年             # 常量在 content/economy.json 的 time.calendar
year  = epochYear + floor((day-1) / 360)
month = floor((day-1) / 30) % 12 + 1
dom   = (day-1) % 30 + 1
```

- **纯派生**：`state.day` 一个字节都不动 → 不升存档版本、不动黄金轨迹
- **唯一实现**：`src/engine/calendar.ts::dateOf()` / `godot/scripts/sim/sim_core.gd::date_of()`；
  UI（顶栏时间框 / 公告 / 任务面板 / 存档列表 / 预言历史）**一个字都不自己拼**
- **日期不驱动剧情**：节奏靠任务与 `chapters[].gapDays`，历法只负责显示

## 19. 场次 `scenes`（"不挂任务的戏"，用户 2026-10 · A1）

```
内容   content/scenes.json: { id, when, speaker, portrait, lines[], choices[]? }
when   { chapter?, afterDays?, minDay?, pop?, building?, tech?, class?+classMin? }   # 写几个要求几个
闸     chapter 给了 → 那一章领奖那天 + afterDays（缺省 0）；没给 → 第 1 天 + afterDays
记账   state.scenes.shown["s:<id>"] = true       # 只记事，进存档（v5）
顺序   插在 `questTalks` 里：**上一章收尾之后、下一章任务之前**（章与章之间那段戏）
播放   复用 quest_talk.gd —— `quest_talk_mark_shown("s:…")` 会写进 scenes.shown 而不是 quests.shown
```

场次**不进追踪条、不进任务面板**（它不是差事，是一段戏）；也不改任何数字 —— 与 `quests.shown`
同一类"只记事"的状态段。

## 20. 游商 `trade`（M4，2026-10；2026-10 取消收购配额）

```
节奏   第 3 章完成起才有游商；每 7 天一批；第 3/4/5 章同时在场 1/2/3 队；每队停留 7 天
       （第 D 天到 → D+6 最后一天 → D+7 黎明离开）
商品池 本包 goods 里 category ∉ {service, military, tool} 且 perishRate < 1，按 id 排序
报价   每队 4 收 + 4 卖，抽签用独立 mulberry32：seed = day × 1000 + wave × 100 + 序号
       （不吃 state.rngState —— 别扰动黄金轨迹）
价格   他收（玩家卖）= baseValue × 1.6；他卖（玩家买）= baseValue × 1.3
现金   cash = 400 + rnd × 400（收你货的钱）；玩家买他的货 → 现金变多（同一笔钱）
货值   goodsValue = 600 + rnd × 400；他卖的每种 qty = floor(goodsValue ÷ 4 ÷ 单价)，至少 1
```

**两个方向的成交上限不一样**（这是 2026-10 用户专门纠正过的地方）：

| 动作 | 报价字段 | 一次能成交多少 |
|---|---|---|
| `sell_to_caravan`（玩家卖给他）| `{ good, price }` —— **没有 qty** | `min(库存, floor(cash ÷ price))` |
| `buy_from_caravan`（玩家从他买）| `{ good, price, qty }` | `min(qty, floor(国库钱 ÷ price))` |

- ⚠️ **他收的"多多益善"**（用户原话："游商本来就为了收购这个货物来的，所以是多多益善，
  阻止他收购这个货物的唯一就是自己钱不够了"）—— 所以**没有"每种 20 件"的配额**，
  上限只有两条：我没有货、他的钱不够。`QTY_PER_OFFER` / `CARAVAN_QTY` 已删，别再生成。
- 成交是**部分成交**：要 50 件、他钱只够 2 件 → 成交 2 件（不报错，也不是整单拒绝）。
- 双向都**记账**：卖给他 → `goods` 减、`government.money` 增、`cash` 减、`ledgerToday.merchantSell` 增
  （⚠️ B3 起**不再记进 `sales`** —— 财务页的「消费收入」只算居民消费，「游商收入」单列一行）；
  从他买 → 反过来（且 `cash` 增）。
- 面板只读 `trade_snapshot()`；命令走 pending，**次日黎明**生效。
- 唯一实现：`src/engine/systems/caravan.ts` / `godot/scripts/sim/sim_core.gd`
  （`_update_caravans` / `sell_to_caravan` / `buy_from_caravan`）；门槛 `merchant`

## 21. 商路 `routes`（B3，用户 2026-10）

设计正文在 [`trade-routes.md`](trade-routes.md)；这一节只钉**公式与顺序**。

### 21.1 价格

```
卖价 = round2(baseValue × sellMul[days] × (1 + haggleSell))
买价 = round2(baseValue × buyMul[days]  × (1 − haggleBuy))
```

| 单程 | 卖 × | 买 × |
|---:|---:|---:|
| 1 天 | 1.0 | 2.0 |
| 2 天 | 2.2 | 1.5 |
| 3 天 | 3.5 | 1.0 |
| 4 天 | 4.8 | 0.8 |
| 5 天 | 6.0 | 0.6 |

`haggleSell` / `haggleBuy` = 贸易科技的**加法**合计（0 / 0.10 / 0.20 / 0.30）。
`baseValue` 与游商**同一份**（`goods.json`），不另立价格表。

### 21.2 商队上限（贸易科技）

| 量 | 聚合方式 | 基础值 | 满级 |
|---|---|---|---:|
| 商队数 | **加法**（`trade.caravans`）| `routes.caravan.count`（0）| 5 |
| 单程载货 | **取最高**（`trade.cargo`）| 40 | 160 |
| 带钱 | **取最高**（`trade.purse`）| 800 | 6000 |

> 商队数是"基础 0 + 科技"：**研究完「常设商队」才有第一支**（用户口径：商路是研究出来的）。

### 21.3 黎明的顺序（`runDawn`）

```
applyActions(...)          # 今天的命令先落地（含 route_assign 等即时命令，其实早已生效）
updateRoutes(day)          # ← B3 插在这里：先结算、后派车
  ├ 1) 市场补给：每座城 特产 +specialtyDaily（封顶 specialtyCap）
  │                    需求 +demandDaily（封顶 demandCap）
  ├ 2) 结算「到达」：按需求卖出 → 记 routeExport / routeOut → 扣需求池
  │                 → 用「带出的钱 + 卖得的钱」买特产（受载重、库存、钱三重限制）
  │                 → 记 routeImport / routeIn；phase = back
  ├ 3) 结算「回家」：买的货入库、剩的钱回国库；phase = home
  └ 4) 派车：锁货（搬出仓库）→ 货齐 + 国库够 → 扣钱、phase = out
activateCompleted(...)     # 后面的步骤照旧：买到的货当天就能被排产用上
```

- **锁货 = 把货搬出仓库**记在商队名下（不是 `reserved` 那种软预留），所以生产 / 消费 / 送物资
  都碰不到它；配置调小或取消商路才退回。
- 缺货 → 留在家继续锁；钱不够 → 留在家但**不退货**（面板写明差多少）。
- 一趟 = **2 × 单程**（`caravan.roundTrip`，默认 true）；1 天城 D 出发、D+1 到、D+2 回家。

### 21.4 命令

`route_assign` / `route_unassign` / `route_set_budget` / `route_set_sell` 四条都走
`IMMEDIATE_ACTIONS`（与研究队列、`gift` 同一套）：**当场生效**，不进 `pending`。

### 21.5 台账

| 字段 | 含义 | 谁读 |
|---|---|---|
| `routeExport` | 当日卖出所得（钱） | 财务页「商路出口」 |
| `routeImport` | 当日买货花费（钱） | 财务页「商路进口」 |
| `routeOut` / `routeIn` | 当日进出**件数**（good → 件） | 资源页两列（7 日均） |

唯一实现：`src/engine/systems/routes.ts` / `godot/scripts/sim/sim_core.gd::_update_routes`；
门槛 `routes`（引擎行为）+ `check:routes`（内容与科技链）。

### 21.6 读档兜底（`state.routes` 缺失时）

`state.routes` 是**v6 才有**的段，而 `world_view.load_from()` 收 v3 起的存档
（地图占格的锚点从 v3 才对得上）。所以 `SaveManager._sanitize()` 必须调
`SimCore.repair_routes(s, db)` 把这一段补成当前内容能用的形状 —— 不然老档一开
贸易页就崩在 `routes_snapshot()` 的 `s["routes"]["routes"]` 上（用户 2026-10 实测）。

补的规矩：**只补形状，不发钱不发车**

- 整段缺失 → 建一份空的（市场按 `routes.json::market` 默认值铺满，槽位 = `caravan.count`）
- 缺某座城 / 某个商品 → 补那一项，**已有库存绝不动**
- 缺某个字段（`phase` / `sellPlan` / `loaded` …）→ 按空车默认值补，在途的车不丢
- 科技给的槽位不在这里补，由 `sync_route_count()` 在黎明 / 打开商路页时加（只加不撤）

门槛：`routes` 第 ⑩ 条（老档 + 半截档各一遍，且补两次不许改库存）。
