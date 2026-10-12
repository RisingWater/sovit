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
  - `workStart(6) <= h < workEnd(18)`：**生产** `runProductionStep(1/(workEnd-workStart))`
  - `h == settleHour(18)`：**夜晚** `runNight`
  - 推进：`hour = (hour+1) % hoursPerDay`
- `state.day` 在**黎明** +1。

## 1. 命令队列（次日生效）

- 所有命令（玩家/AI）追加到 `state.pending`。
- **黎明**统一执行 `applyActions(state, pending)` 后清空。因此：
  - 06:00 前下的命令当天 06:00 生效；
  - 06:00 后下的命令等次日 06:00。
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
goods[g] += output[g]  * batches
```

**不取整**（浮点，避免 12 次累积误差）。

### 2.3 损耗 `applySpoilage`（夜晚，每天一次）

`goods[g] *= (1 − perishRate)`（非耐储商品）。

## 3. 用工 `assignLabor`（黎明）

1. 重置所有居民 `employed=false, jobShopId=undefined`。
2. **口粮链**：以 `tuning.foodChainSeedClass` 的食物 `needs` 为种子，对 `recipes` 反复回溯上游投入（仅限本 pack 商品），得到集合 `F`。
   - 若种子阶层无食物需求：退化为「本 pack 所有 `category=food` 商品」。
3. 建筑分为两档：`priority`（其配方任一产出 ∈ F）与其余。
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
welfareGross = refWage * welfareRate
gross = employed ? min(wage*(skillIncomeBase + min(skillMax,skill)/100), wageCap||∞) : welfareGross
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
当 `stateOwned>0 && soldTotal<privateHousingPerDay`，选**存款最高**的合格买家：
非房主、`classLevel>=2`、`classLevel==def.quality`、`savings>=price+5`、`satisfaction>=privateHousingNeedThreshold`。
成交：`savings-=price`、`homeowner=true, ownedQuality=quality`、`privateHousing[gid]++`、`government.money+=price`。

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
- **放行** `applyAdmission`：`admit = min(arrivals, floor(immigrationAllowance), housingCapacity−pop, jobCapacity−pop)`；
  新居民默认最低阶层，属性取 `defaults.newResident`。
- **想来人数** `computeArrivals`：`avgSat < immigrationSatThreshold` → 0；
  否则 `round(pop * immigrationRate * (avgSat−th)/(100−th))`。

## 9. 施工（建店 / 升级 / 建房）

- `tryBuild/tryExpand/tryBuildHousing`：立即扣材料（或资金），压入 `construction{kind, daysLeft=constructionDays}`。
- **夜晚** `advanceConstruction`：`daysLeft -= 1`。
- **黎明** `activateCompleted`：`daysLeft<=0` 的按 kind 生效（建店/升级/建房）。
- `usedSlots = shops + 在建(非 upgrade) + housing`。

## 10. 初始状态 `createInitialState`

- 商品/价格/住房取自 `ctx.pack.goods` / `pack.housing`，数量取自 `pack.start`。
- 建筑取自 `pack.start.shops`；居民默认值取 `defaults.startResident`，阶层分布取 `defaults.startDistribution`。
- `hour=0, day=0, pending=[]`。

## 11. 随机数（mulberry32）

```
state = (state + 0x6d2b79f5) & 0xFFFFFFFF
t = state
t = (t ^ (t >> 15)) * (t | 1) & 0xFFFFFFFF          // 32 位乘法
t ^= (t + ((t ^ (t >> 7)) * (t | 61) & 0xFFFFFFFF)) & 0xFFFFFFFF
out = ((t ^ (t >> 14)) & 0xFFFFFFFF) / 2^32
```
> GDScript 无无符号移位/32 位乘法，需手动 `& 0xFFFFFFFF`。

## 12. 内容 schema

见 `content/README.md`。`economy.json.schemaVersion` 必须等于引擎支持的版本（当前 `1`）。

## 13. 黄金轨迹（golden）

- `scripts/golden.ts`：固定 `pack/seed/脚本`，逐日输出 `godot/tests/golden/<pack>-<seed>.json`。
- Godot 侧 `tests/` 用 gdUnit4 回放同一脚本，逐日比对摘要（数值容差 ~1e-3）。
- 脚本只在指定 tick 入队命令；不含 AI，保证纯仿真可跨语言复现。
