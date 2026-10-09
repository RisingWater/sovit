# Sovit 资源与产业链（内容参考）

> 本文档对应 `src/engine/content/` 与 `src/engine/config.ts` 的当前实现。
> 全量内容始终存在，`ContentPack` 只决定「某一局允许出现哪些商品 / 建筑 / 阶层 / 住房」。
> 最后更新：v0.3（分层社会）。

---

## 一、商品（共 33 种）

`category`：`raw` 原料 · `food` 食物 · `clothing` 衣物 · `household` 日用 · `fuel` 燃料 · `material` 建材 · `housing` 住房 · `investment` 投资品
`baseValue` = 基准价；`可储存` 为否时按 `perishRate` 每日损耗。

### tier 0 · 自然资源（12）

| 商品 | id | category | 基准价 | 可储存 |
|---|---|---|---|---|
| 小麦 | `wheat` | raw | 1.0 | ✅ |
| 蔬菜 | `vegetable` | food | 1.2 | ❌ 10%/日 |
| 亚麻 | `flax` | raw | 1.2 | ✅ |
| 棉花 | `cotton` | raw | 1.4 | ✅ |
| 木材 | `wood` | raw | 1.5 | ✅ |
| 石块 | `stone` | raw | 1.6 | ✅ |
| 粘土 | `clay` | raw | 1.2 | ✅ |
| 肉类 | `meat` | food | 3.0 | ❌ 15%/日 |
| 鱼类 | `fish` | food | 2.5 | ❌ 15%/日 |
| 兽皮 | `hide` | raw | 2.0 | ✅ |
| 甘蔗 | `sugarcane` | raw | 1.5 | ✅ |
| 染料 | `dye` | raw | 2.5 | ✅ |

### tier 1 · 加工品（8）

| 商品 | id | category | 基准价 |
|---|---|---|---|
| 粗面粉 | `coarse_flour` | food | 1.8 |
| 精面粉 | `fine_flour` | food | 2.4 |
| 糖 | `sugar` | food | 2.2 |
| 粗织物 | `coarse_cloth` | material | 2.4 |
| 细织物 | `fine_cloth` | material | 3.2 |
| 木柴 | `firewood` | fuel | 1.6 |
| 砖 | `brick` | material | 3.0 |
| 陶器 | `pottery` | household | 3.5 |

### tier 2 · 消费品（9）

| 商品 | id | category | 基准价 |
|---|---|---|---|
| 粗面包 | `coarse_bread` | food | 1.3 |
| 白面包 | `white_bread` | food | 3.0 |
| 糕点 | `pastry` | food | 5.0 |
| 粗布衣 | `coarse_clothes` | clothing | 4.0 |
| 常服 | `common_clothes` | clothing | 6.0 |
| 华服 | `luxury_clothes` | clothing | 10.0 |
| 皮衣 | `leather_clothes` | clothing | 7.0 |
| 熏鱼 | `smoked_fish` | food | 4.0 |
| 肉干 | `dried_meat` | food | 5.0 |

### tier 3 · 投资品（4）

| 商品 | id | category | 基准价 | 说明 |
|---|---|---|---|---|
| 建造力 | `build_power` | investment | 6.0 | 建筑工坊产出（预留，当前 buildCost 未使用）|
| 茅屋 | `hut` | housing | 15.0 | 住房，容量 4 |
| 木屋 | `wooden_house` | housing | 30.0 | 住房，容量 3 |
| 砖房 | `brick_house` | housing | 55.0 | 住房，容量 2 |

**奢侈品**（`isLuxuryGood`）：category 为 `clothing` / `household`，或商品为 `pastry` → 低价格弹性，用于对富人提价抽取财富。

---

## 二、产业链（30 座建筑，1 建筑 = 1 配方）

格式：`建筑（满员工人）：投入 → 产出`。`baseRate = 1 批次/满员·天`；`🔥` = 额外消耗 `firewood`。

### 链 1 · 面包（基础食物）

```
小麦农场(6)              → 12 小麦
粗面粉磨坊(2)     12 小麦 → 12 粗面粉
粗面包房(2)       12 粗面粉 → 24 粗面包
```

### 链 1b · 高级面包 / 糕点

```
精面粉磨坊(3)     12 小麦 → 10 精面粉
白面包房(3)       10 精面粉 → 20 白面包
甘蔗园(4)                → 8 甘蔗
糖坊(2)           8 甘蔗 → 6 糖
糕点房(4)     8 精面粉 + 4 糖 → 12 糕点
```

### 链 2 · 蔬菜

```
蔬菜农场(4)              → 12 蔬菜
```

### 链 3 · 肉鱼

```
狩猎营地(3)              → 6 肉类 + 3 兽皮
渔场(4)                  → 10 鱼类
熏鱼坊(3)         10 鱼类 🔥 → 8 熏鱼
肉干坊(3)          6 肉类 🔥 → 5 肉干
```

### 链 4 · 纺织 / 成衣

```
亚麻农场(4)              → 8 亚麻
棉花农场(4)              → 8 棉花
染料园(3)                → 5 染料
粗织坊(3)         8 亚麻 → 8 粗织物
细织坊(4)         8 棉花 → 6 细织物
粗布衣坊(3)     8 粗织物 → 6 粗布衣
常服坊(3)       6 细织物 → 5 常服
华服坊(4)  5 细织物 + 3 染料 → 4 华服
皮衣坊(3)         3 兽皮 → 2 皮衣
```

### 链 5 · 建材 / 燃料

```
伐木场(3)                → 10 木材
采石场(3)                → 8 石块
粘土坑(3)                → 8 粘土
木柴坊(2)         10 木材 → 12 木柴
砖窑(2)           8 粘土 🔥 → 6 砖
陶器坊(3)         8 粘土 🔥 → 6 陶器
建筑工坊(3)  6 木材 + 4 石块 + 2 砖 → 4 建造力
```

🔥 燃料统一消耗 `firewood`：砖窑 4、陶器坊 3、熏鱼坊 4、肉干坊 4。

### 链 6 · 住房

```
住房坊(4)        6 木材 + 3 砖 → 1 茅屋
```
> 住房坊属 v1.0；v0.2 / v0.3 用动作 `build_housing` 直接建房（消耗材料，占一个土地名额）。

---

## 三、建筑建造成本

建造成本优先使用「当前 pack 内可获得的实物原料」；全为包外商品时回退货币成本。

| 等级 | 实物成本 | 货币回退 |
|---|---|---|
| tier 1（一级产业） | 木材 4 | ¥100 |
| tier 2（二级加工） | 木材 6 + 石块 3 | ¥250 |
| tier 3（三级投资） | 木材 8 + 石块 6 + 粘土 4 | ¥500 |

扩产（+1 等级）成本 = 上述实物成本 × 当前等级；无实物材料时 = `¥80 × 等级`。
土地上限 `maxBuildingSlots` 当前为 **无限**。

---

## 四、阶层需求（消费）

| 阶层 | 需求（人均/天；括号为缺货/买不起时的替代品）|
|---|---|
| 穷人 poor | 粗面包 1.0、蔬菜 0.5 |
| 中产 middle | 白面包 0.5（→粗面包）、肉类 0.2（→鱼/熏鱼/肉干）、粗布衣 0.05（→常服）、陶器 0.03 |
| 富人 rich | 糕点 0.3（→白面包）、常服 0.1（→粗布衣）、华服 0.05（→常服）、皮衣 0.05（→常服）|
| 老板 boss | 糕点 0.3、华服 0.1 |

- 食物类需求 → 决定**食物满足率**（买不起就挨饿）；食物需求还会兜底到基础食物（粗面包/蔬菜）避免高级食物缺货时饿死。
- 非食物需求 → 决定**舒适度**（缺货只降满意度，不饿死）。
- 消费为**逐居民**结算（各自用自己的存款购买），货币守恒。

---

## 五、住房

| 住房 | id | 等级 | 容量 | 建造成本 | 私有化售价 | 对应阶层 |
|---|---|---|---|---|---|---|
| 茅屋 | `hut` | 1 | 4 | 木材 4 + 砖 3 | 10 | 穷人 |
| 木屋 | `wooden_house` | 2 | 3 | 木材 6 + 砖 6 | 25 | 中产 |
| 砖房 | `brick_house` | 3 | 2 | 木材 4 + 石块 4 + 砖 10 | 50 | 富 / 老板 |

- 人口上限 = `min(住房容量, 岗位数)`；住房分国有 / 私有，占地一个名额。
- 各阶层要求最低住房等级（穷1 / 中2 / 富3 / 老板3）；住低于要求按 `housingQualityPenalty` 扣满意度。
- 只有**中产及以上**才私有化；且只能买与本阶层等级对应的住房。

---

## 六、内容包（ContentPack）

| Pack | 商品 | 建筑 | 阶层 | 住房 |
|---|---|---|---|---|
| **v0.1** 面包与蔬菜 | 小麦、粗面粉、粗面包、蔬菜 | 小麦农场、粗面粉磨坊、粗面包房、蔬菜农场 | 穷人 | — |
| **v0.2** 住房与建材 | v0.1 + 木材、石块、粘土、木柴、砖、茅屋 | v0.1 + 伐木场、采石场、粘土坑、木柴坊、砖窑 | 穷人 | 茅屋 |
| **v0.3** 分层社会（默认） | v0.2 + 精面粉、白面包、糕点、糖、织物、成衣、肉鱼、兽皮、染料、陶器 | v0.2 + 精面粉磨坊、白面包房、糕点房、糖坊、甘蔗园、亚麻/棉花/染料农场、粗/细织坊、各类成衣坊、狩猎营地、渔场、熏鱼坊、肉干坊、陶器坊 | 穷 / 中产 / 富 / 老板 | 茅屋 / 木屋 / 砖房 |
| **v1.0** 完整经济 | 全部 33 种 | 全部 30 座（含建筑工坊、住房坊）| 穷 / 中产 / 富 / 老板 | 茅屋 / 木屋 / 砖房 |

---

## 七、关键机制数值（`src/engine/config.ts`）

| 项 | 默认值 | 说明 |
|---|---|---|
| `refWage` | 3 | 工资参照基准 |
| `welfareRate` | 1.0 | 失业保障金 = refWage × 该值（税前） |
| `skillIncomeBase` | 0.5 | 实发 = 岗位工资 × (0.5 + 技能/100)，技能上限 100、日增 0.5 |
| `defaultWageCap` | 6 | 每人工坊实际工资上限（0=不限） |
| `defaultTaxBrackets` | `[≤2:8%, 2–3.5:22%, >3.5:42%]` | 累进所得税税表（可运行时改） |
| `defaultRent` | 0.05 | 国有住房人均日租金 |
| `privateHousingNeedThreshold` | 80 | 私有化所需满意度门槛 |
| `privateHousingPerDay` | 2 | 每日最多私有化户数 |
| `classWealth` | 中产 40 / 富 120 / 老板 300 | 按存款分层阈值 |
| `classSatBonus` | 穷0 / 中4 / 富8 / 老板12 | 阶层满意度加成 |
| `classHousingLevel` | 穷1 / 中2 / 富3 / 老板3 | 各阶层要求住房等级 |
| `housingQualityPenalty` | 8 | 每缺一级住房的满意度惩罚 |
| `privateHousingSatBonus` | 12 | 房主满意度加成 |
| `privateTenantSatBonus` | 4 | 房客满意度加成 |
| `rentSatPenalty` | 25 | 租金负担满意度惩罚上限 |
| `priceElasticity` | 1.2 | 普通商品需求价格弹性 |
| `luxuryElasticity` | 0.4 | 奢侈品价格弹性（低弹性 → 提价多赚） |
| `luxuryPriceMarkup` | 2.5 | 奢侈品默认加价倍率 |
| `satisfaction weights` | food .45 / wage .2 / price .1 / employment .1 / comfort .15 | 满意度权重 |
| `immigrationRate` / 阈值 | 0.1 / 60 | 迁入速率 / 触发满意度 |
| `emigrationSatThreshold` | 40 | 迁出触发满意度 |
| `hungerDeathRate` | 0.2 | 饥饿致死比例 |
| `minPopulation` | 4 | 人口下限 |
| `maxBuildingSlots` | ∞ | 土地上限（无限） |
| `constructionDays` | 2 | 施工天数 |

---

## 八、动作清单（AI / 玩家）

| 动作 | 说明 |
|---|---|
| `set_wage { shopId, value }` | 设定该店基础工资 |
| `set_wage_cap { shopId, value }` | 设定该店每人实际工资上限（0=不限） |
| `set_workers { shopId, value }` | 设定目标用工数 |
| `set_price { goodId, value }` | 设定商品售价；住房商品即私有化售价 |
| `expand { shopId }` | 扩产（+1 等级） |
| `toggle { shopId, active }` | 开 / 关 |
| `build { buildingId }` | 建店（进入施工队列） |
| `build_housing { goodId }` | 建造国有住房（提升人口上限，占土地名额） |
| `set_rent { value }` | 设定国有住房人均日租金 |
| `set_tax { value }` | 设为单一扁平税率（覆盖整张税表） |
| `set_tax_bracket { index, upTo?, rate? }` | 编辑累进税某档的阈值 / 税率 |
| `end_turn` | 结算一天 |

预留（返回 `not_implemented`）：`sell_shop`、`retake_shop`、`subsidy`。
