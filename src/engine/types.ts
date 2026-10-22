// ---------------------------------------------------------------------------
// Sovit engine types
//
// 纯数据 + 纯类型。引擎不依赖任何 UI / 框架 / Node API。
// ---------------------------------------------------------------------------

export type PackID = 'v0.3' | 'v1.0'

// 商品、建筑、配方都用字符串 id，便于内容表扩展。
export type GoodID = string
export type BuildingID = string
export type RecipeID = string
export type TechID = string

export type ClassID = string
export type OwnerID = 'state' | string

export type GoodTier = 0 | 1 | 2 | 3
export type GoodCategory =
  | 'raw'
  | 'food'
  | 'clothing'
  | 'household'
  | 'fuel'
  | 'material'
  | 'housing'
  | 'investment'
  | 'service'
  | 'entertainment'
  /** 工具：工坊耗材，不是消费品（无阶层需求）。 */
  | 'tool'
  /** 军备：武器这类（治安所吃它），不是消费品。 */
  | 'military'

export type BuildingTier = 1 | 2 | 3
export type ShopStatus = 'green' | 'yellow' | 'red'

/**
 * 产业：效率科技（`TechnologyDef.effects`）按它把产出加成加到哪一类建筑上。
 * 只有**有 recipe** 的建筑才有产业（无配方建筑不产商品，加成无从施加）。
 */
export type Sector = 'agri' | 'goods' | 'material'

/** 效率科技加成的 5 个可用键（产出的三个 = `Sector`）。 */
/**
 * 效率科技能影响的键。	oolLife 是**取最高**（不是加法叠加）：见 	ech_bonus.ts。
 */
export type TechEffectKey = Sector | 'research' | 'build' | 'toolLife' | 'services'

/**
 * 效率科技的效果：**加法**叠加的加成小数（`0.10` = +10%），不是倍率。
 * 口径与 GDScript `sim_core.gd::tech_bonuses()` 一致，见 `docs/spec.md`。
 */
export type TechEffects = Partial<Record<TechEffectKey, number>>

/**
 * 贸易科技的效果（B3，见 `docs/trade-routes.md` §6 与 `systems/routes.ts`）。
 *
 * ⚠️ 和 `TechEffects` 分开写：那一类是"百分比加成、加法叠加"，这一类的量纲各不相同 ——
 * 商队数是**加法**、载货 / 带钱是**取最高**、议价是**加法**。混在一个表里迟早算错。
 */
export interface TradeEffects {
  /** +N 支商队（加法）。 */
  caravans?: number
  /** 单程载货上限（**取最高**，不是叠加）。 */
  cargo?: number
  /** 带钱上限（**取最高**）。 */
  purse?: number
  /** 买价折扣（加法，0.10 = 便宜 10%）。 */
  haggleBuy?: number
  /** 卖价加成（加法，0.10 = 贵 10%）。 */
  haggleSell?: number
  /**
   * 商路跑完一趟的好感加成（**加法**：0.5 / 1.0 / 2.0 三档，累计 +200%）。
   * 一趟的好感 = `relation.tradeGain × (1 + goodwill)` → 100 / 150 / 200 / 300。
   * 见 docs/diplomacy.md §3.3。
   */
  goodwill?: number
}

// ---------------------------------------------------------------------------
// 内容定义（静态数据）
// ---------------------------------------------------------------------------

export interface GoodDef {
  id: GoodID
  nameZh: string
  tier: GoodTier
  category: GoodCategory
  /** 是否可长期储存；不可储存的商品每日按 perishRate 损耗。 */
  storable: boolean
  /** 基准价值，用于价格弹性与居民购买意愿。 */
  baseValue: number
  /** 每日损耗比例（0-1），缺省 0。 */
  perishRate?: number
  /** 是否奢侈品：低价格弹性，可提价抽取富人财富。缺省 false。 */
  luxury?: boolean
  /**
   * 工具品级：装配该工具的工坊**产出 ×(1 + toolBonus)、投入不变**。
   * 只有 category = 'tool' 的商品该有此项。见 docs/technology.md §八。
   */
  toolBonus?: number
  /**
   * 工具的**耐久**：一件能用几天（2026-10）。
   *
   * 每工人每日消耗 = `1 / (durabilityDays × (1 + 工具寿命科技加成))`；
   * 没写就退回 `economy.tools.perWorkstation`（老内容兼容）。
   */
  durabilityDays?: number
}

export interface NeedDef {
  good: GoodID
  /** 人均每日需求量。 */
  perCapita: number
  /** 缺货 / 买不起时按顺序尝试的替代品。 */
  fallbacks?: GoodID[]
}

export interface RecipeDef {
  id: RecipeID
  building: BuildingID
  /** 每批次投入。 */
  inputs: Partial<Record<GoodID, number>>
  /** 每批次产出。 */
  output: Partial<Record<GoodID, number>>
  /** 满员每日批次数。 */
  baseRate: number
  /** 每批次额外消耗的木柴（燃料）。 */
  fuel?: number
}

// ---------------------------------------------------------------------------
// 外观规格（art spec）—— 决定建筑长什么样，不参与任何仿真
//
// 33 座建筑不是 33 张手工贴图，而是由这张声明式规格生成：
//   原型(arch) + 屋顶(roof) + 墙体(wall) + 开间数(w) + 特征件(feat)
// 改这里 = 改外观；`npm run gen:art` 重新生成 godot/assets/buildings/*.png
// ---------------------------------------------------------------------------

/** 建筑原型：决定"几行屋顶 + 一行墙"的骨架。 */
export type ArtArch =
  | 'house'      // 小屋
  | 'extract'    // 采集小屋
  | 'mill'       // 磨坊
  | 'bakery'     // 烘焙
  | 'kiln'       // 窑炉
  | 'workshop'   // 宽工坊
  | 'grand'      // 大型公共建筑
  | 'warehouse'  // 中央仓库
  | 'field'      // 农田（土垄 + 作物，无屋顶）
  | 'sprite'     // 成品整图（godot/assets/buildings/<id>.png，尺寸由层数决定）

export type ArtRoof = 'blue' | 'red' | 'green'
export type ArtWall = 'wood' | 'stone' | 'barn' | 'plank'
/** 自绘特征件（图集里没有的部分）。 */
export type ArtFeat = 'windmill' | 'wheel' | 'logs' | 'rocks'
/** 农田作物：决定用哪组 Tiny Farm 作物 tile。 */
export type ArtCrop = 'wheat' | 'cabbage' | 'sprout' | 'bush' | 'corn' | 'tomato'
/** 农田土垄行。 */
export type ArtSoil = 'row5' | 'row6'

export interface BuildingArt {
  arch: ArtArch
  /**
   * arch='sprite'：整图直接用 godot/assets/buildings/<id>.png（不再由图集拼装）。
   * 尺寸规则见 scripts/gen-art.ts 的 STOREYS —— 显示高度由层数决定。
   */
  sprite?: string
  /** 屋顶款式（field / prop 不用）。 */
  roof?: ArtRoof
  /** 墙体款式（field 不用）。 */
  wall?: ArtWall
  /** 横向开间数（格）；缺省 3。 */
  w?: number
  /** 竖向格数；field / prop 必填。 */
  rows?: number
  /**
   * arch='sprite' 的**占地**（格）[宽, 高]，缺省按贴图尺寸算 ceil(px/16)。
   *
   * 为什么要能单独声明：贴图的高度**不占满占地**。建筑是正面平视图，
   * 屋顶/塔尖往上长、可以伸到身后那栋楼的画面上（按地面线做 y 排序遮挡），
   * 所以"占地几格"和"贴图多高"是两件事。不声明的话占地会被贴图撑大
   * —— 128x73 会占 8x5 格，于是只能反过来把贴图缩小，把建筑压成一片小房子。
   * 见 `godot/scripts/world/world_view.gd::_footprint()`。
   */
  foot?: [number, number]
  /** 使用原生烟囱 tile（51 蓝顶 / 55 红顶）。 */
  chimney?: boolean
  /** 附加自绘特征件。 */
  feat?: ArtFeat[]
  /** 农田：土垄行。 */
  soil?: ArtSoil
  /** 农田：作物种类。 */
  crop?: ArtCrop
}

/**
 * 产能建筑的参数：不产商品、只产「每日产能」的建筑（建筑工坊 / 研究所）。
 * 见 docs/technology.md §6.2。
 */
export interface CapacityDef {
  /** 产能种类：build = 建造力，research = 科研力。 */
  kind: 'build' | 'research'
  /** 每个在岗工人的基础产能（再乘熟练度曲线）。 */
  perWorker: number
  /** 每升 1 级，每人产能 ×(1 + levelBonus × (等级−1))。 */
  levelBonus: number
  /** 每升 1 级，工位上限 +slotsPerLevel。 */
  slotsPerLevel: number
}

/**
 * 仓储容量（见 `docs/town.md` §3）。
 *
 * 口径是**全局总量**：所有商品的数量之和，不是每种商品各自一个上限。
 * 超过就**所有物资按同一比例削减**（谁也不被单独针对，见 §3.3），并写日志 + 报警。
 */
export interface StorageDef {
  /** 这座建筑提供的容量（1 级）。 */
  storage: number
  /** 每升 1 级额外增加的容量。 */
  storagePerLevel: number
}

export interface BuildingDef {
  id: BuildingID
  nameZh: string
  tier: BuildingTier
  /** 参照满员工人数（决定每人产出基准）。 */
  workers: number
  /** 工位上限（最多容纳多少工人）；缺省 = workers。升级时再加 capacity.slotsPerLevel。 */
  maxWorkers?: number
  /** 生产配方。产出「建造产能」而非商品时缺省（如建筑工坊、研究所）。 */
  recipe?: RecipeID
  /**
   * 所属产业（只有**有 recipe** 的建筑才有）。决定效率科技（`effects.agri/goods/material`）
   * 的产出加成加在它身上：产出倍率 = 1 + techBonuses()[sector]。
   * 无 recipe 的建筑缺省 → 倍率恒为 1。
   */
  sector?: Sector
  /** 施工工时（建造力 / 人·天）。设计见 docs/construction.md。 */
  buildWork: number
  /** 产能参数（只有不产商品的建筑有）；缺省表示它靠 recipe 产商品。 */
  capacity?: CapacityDef
  /**
   * 仓储容量（缺省 0）。城镇中心与仓库靠它提供仓储，**既没有 recipe 也没有
   * capacity** —— 校验器为此放宽了"建筑总得产出点什么"那条规则。见 docs/town.md §3。
   */
  storage?: StorageDef
  /**
   * **纯功能建筑**（B4 的使馆）：不产商品、不产产能、也不加仓储 —— 它的全部作用是
   * "把某个面板的入口开出来"。
   *
   * ⚠️ 必须显式写：校验器只在 `utility === true` 时放行"三样都没有"的建筑，
   * 否则"忘了写 recipe"会悄悄变成一座没用的房子（见 `validate.ts::parseBuildings`）。
   */
  utility?: boolean
  /** 建造成本（实物原料）；全为包外商品时回退为金钱成本。 */
  buildCost?: Partial<Record<GoodID, number>>
  /** 外观规格（缺省时 gen-art 用兜底样式）。 */
  art?: BuildingArt
}

export interface ClassDef {
  id: ClassID
  nameZh: string
  needs: NeedDef[]
  /** 日收入基准，用于工资水平参照。 */
  incomeBase: number
  /** 阶层满意度加成（点数）。 */
  satBonus: number
  /** 该阶层要求的最低住房等级（1/2/3）。 */
  housingLevel: number
  /** 升入该阶层所需的最低存款（最低阶层填 0）。 */
  wealthThreshold: number
}

export interface HousingDef {
  id: GoodID
  nameZh: string
  quality: 1 | 2 | 3
  /** 每单位住房容纳人口。 */
  capacity: number
  classId: ClassID
  /** 施工工时（建造力 / 人·天）。设计见 docs/construction.md。 */
  buildWork: number
  /** 建造该住房所需的实物材料（占用一个土地名额）。 */
  buildCost?: Partial<Record<GoodID, number>>
  /** 私有化售价（玩家可调，默认取此值）。 */
  salePrice?: number
  /**
   * 可以**改建**成的下一个房型（见 docs/spec.md §5.4）。不写 = 不能改建。
   *
   * 显式指定、**不做"按 quality 自动推下一个"**：别墅同样是高档房，但它不在这条链里
   * （用户明确要求"别墅要单独建造"）—— 谁指向谁全由这张表决定。
   */
  upgradeTo?: GoodID
  /** 外观规格。 */
  art?: BuildingArt
}

export interface PackStart {
  /** 开局人口。 */
  population: number
  /** 开局资金。 */
  money: number
  /** 开局建筑：defId → 数量。 */
  shops: Record<string, number>
  /** 开局住房存量：住房 id → 数量。 */
  housing: Record<string, number>
  /** 开局库存：商品 id → 数量。 */
  goods: Record<string, number>
  /**
   * 开局已研究完的科技（见 docs/technology.md）。
   * 缺省为空 —— 此时只有「没有任何科技解锁它」的建筑可建。
   * 注意：开局自带某座建筑的**实例**时，必须把解锁它的科技也列进来，
   * 否则玩家会看到「我有一座采石场，但建造栏里的采石场是锁的」。
   */
  techs?: TechID[]
}

export interface ContentPack {
  id: PackID
  nameZh: string
  goods: GoodID[]
  buildings: BuildingID[]
  classes: ClassID[]
  housing: GoodID[]
  /** 开局场景（人口 / 资金 / 建筑 / 住房 / 库存）。 */
  start: PackStart
}

// ---------------------------------------------------------------------------
// 运行时状态
// ---------------------------------------------------------------------------

export interface Shop {
  id: string
  defId: BuildingID
  owner: OwnerID
  /** 目标用工数（0..def.workers）。 */
  targetWorkers: number
  /** 每名工人每日工资（基础工资）。 */
  wage: number
  /** 每人实际工资上限（含技能系数后的封顶）；0 表示不限。 */
  wageCap: number
  /** 等级，每级 ×level 产能。 */
  level: number
  active: boolean
  /** 昨日利润（销售收入内部转移口径，仅展示）。 */
  profit: number
  /** 岗位平均熟练度 0-100。 */
  skill: number
  /** 今日计划批次数（黎明排产，白天按小时执行 planned / 工作小时数）。 */
  planned: number
  /**
   * 今日的产出倍率：装了工具就是 1 + toolBonus，否则 1。
   * 黎明一次性分配、当天不变（见 docs/technology.md §8.3）。
   */
  toolBoost?: number
  /**
   * 今天烧哪种燃料（`coal` / `firewood`）—— 黎明排产时按存量挑一次、全天不变
   * （见 `production.ts::FUEL_ORDER`）。缺省（老存档）按木柴处理。
   */
  fuelGood?: string
}

export interface Resident {
  id: string
  classId: ClassID
  savings: number
  /** 满意度 0-100，平滑更新。 */
  satisfaction: number
  /** 熟练度 0-100。 */
  skill: number
  jobShopId?: string
  /** 是否被雇佣（含在工地出工的临时工）。 */
  employed: boolean
  /**
   * 当日工地出工报酬（毛额，未扣税）。>0 表示当天在工地上干活。
   * 由建造结算写入、当晚工资结算读取；次日黎明 assignLabor 时清空。
   */
  constructionPay?: number
  /** 是否已拥有私有住房（房主 / 房东）。 */
  homeowner?: boolean
  /** 是否租住在私有住房（房客，向房主交租）。 */
  privateTenant?: boolean
  /** 当前居住的住房等级（1 茅屋 / 2 木屋 / 3 砖房）。 */
  housingQuality?: number
  /** 作为房主所拥有住房的等级。 */
  ownedQuality?: number
  /** 房主名下那一栋（`HousingUnit.id`）。 */
  ownedUnitId?: string
  /**
   * 当日**全部需求里最差那一项**的满足率（0-1）。晋升要 = 1.0；连续 3 天 < 0.8 会降级。
   * 由 `runConsumption` 逐项记录（2026-10：需求全部商品化之后，晋升按需求而不再只看存款）。
   */
  needsMet?: number
  /** 连续多少天 needsMet < 0.8（降级宽限期，3 天）。 */
  lowDays?: number
  /** 当日账目（每个游戏日结算一次，逐人记录）。 */
  account?: ResidentAccount
}

// ---------------------------------------------------------------------------
// 逐人账目 / 每日台账
//
// 现状是"平均分配"：所有人按各自阶层的 perCapita 需求购买，所以个人消耗数值
// 上等于阶层汇总。但仍然**逐人分开记录**，这样将来要做差异化（按收入、按偏好、
// 按距离…）时不必再改数据结构，只要改分配逻辑。
// ---------------------------------------------------------------------------

export interface ResidentAccount {
  /** 当日毛收入（在职工资 / 工地出工报酬；失业无收入）。 */
  wage: number
  /** 当日所得税。 */
  tax: number
  /** 当日住房支出（国有租金 / 私租）。 */
  rent: number
  /** 当日购买商品支出。 */
  spent: number
  /** 当日食物满足率 0-1（< hungryThreshold 即挨饿）。 */
  foodScore: number
  /** 当日舒适度 0-1。 */
  comfortScore: number
  /** 当日价格满意度 0-1。 */
  priceScore: number
  /** 当日是否挨饿。 */
  hungry: boolean
  /** 当日买到的商品 good -> 数量（逐人消耗）。 */
  bought: Record<string, number>
}

/** 每日台账：当天全社会的实际流量。挂到当天 DaySnapshot 上。 */
export interface DayLedger {
  day: number
  /** 工资（含工地出工报酬）支出总额。 */
  wages: number
  /** 所得税收入总额。 */
  tax: number
  /** 住房租金收入（国有实收 + 私租累进税）。 */
  rent: number
  /** 居民消费回款。 */
  sales: number
  /**
   * 公共事业补贴（2026-10）：公共建筑当日的工资支出（原料从库存出、销售额极低，
   * 差额等价于国库补贴）。只进台账（面板显示），不参与任何计算。
   */
  publicSubsidy: number
  /** 各商品**实际**产量（生产小时累计）。 */
  produced: Record<string, number>
  /** 各商品**实际**工业消耗（生产投入 + 燃料）。 */
  consumed: Record<string, number>
  /** 各商品居民购买量合计。 */
  bought: Record<string, number>
  /**
   * 工业消耗的**来源拆分**：`goodId -> { defId: 量 }`（谁吃掉了它）。
   *
   * 用户 2026-10："工业消耗是哪类建筑多少个消耗了多少，比如面粉都是面包房消耗。
   * 写面包房 x3 消耗了 xx 面粉。" —— 面板的 tooltip 直接读这张表，
   * 所以它必须由**真正扣料的那一处**（`runProductionStep`）写，不能在 UI 里重算。
   */
  consumedBy: Record<string, Record<string, number>>
  /**
   * 居民购买的**阶层拆分**：`goodId -> { classId: 量 }`。
   *
   * 用户 2026-10："居民消耗应该是哪个等级的居民消耗了多少，比如中产 x11 消耗多少资源。"
   */
  boughtBy: Record<string, Record<string, number>>
  /**
   * 商路（B3，用户 2026-10）：当日的出口所得 / 进口花费 / 进出数量。
   *
   * `routeExport` / `routeImport` 是**钱**（财务页两行），`routeOut` / `routeIn` 是
   * **件数**（资源页「出口/日」「进口/日」两列，取近 7 天均值）。
   * 面板不自己算 —— 谁真的收了钱 / 搬了货，谁就往这里写。
   */
  routeExport: number
  routeImport: number
  routeOut: Record<string, number>
  routeIn: Record<string, number>
  /**
   * 游商（M4）当日收到的钱。
   *
   * ⚠️ 以前 `sellToCaravan` 把钱记进 `sales`（居民消费回款），财务页的「消费收入」
   * 就混进了游商的钱。B3 单列出来（用户："财政面板要加入商路的进出口收益、游商的收益"）。
   */
  merchantSell: number
}

export interface Construction {
  id: string
  /** 施工类型：建店 / 升级 / 建房 / 住房改建。 */
  kind: 'shop' | 'upgrade' | 'housing' | 'housing_upgrade'
  /** kind=shop 时的建筑；kind=upgrade 时用于查定义。 */
  buildingId?: BuildingID
  /** kind=upgrade 时目标建筑实例。 */
  shopId?: string
  /** kind=housing 时的住房 id；kind=housing_upgrade 时是**改建前**的房型。 */
  housingId?: GoodID
  /** kind=housing_upgrade 时**改建后**的房型。 */
  toHousingId?: GoodID
  /**
   * kind=housing_upgrade 时的**具体哪一栋**（`HousingUnit.id`，改建前后不变）。
   * 有了它，"这条改建是给哪栋房的"就是确定的 —— 进度条不用再按顺序猜。
   */
  housingUnitId?: string
  /** 还差的建造力（人·天）。开工时 = buildWork，逐日被产能扣减。 */
  remaining: number
  /** 总建造力需求（进度条用）。 */
  totalRequired: number
  /** 是否已开工（材料已在开工时扣除）。未开工的停在队首等材料。 */
  started: boolean
}

// ---------------------------------------------------------------------------
// 研究（见 docs/technology.md）
// ---------------------------------------------------------------------------

/** 一项科技：解锁一组建筑 / 住房，消耗科研力 + 原料。 */
export interface TechDef {
  id: TechID
  nameZh: string
  /** 所属纪元（只用于 UI 分组与排序）。 */
  era: number
  /** 完成所需的科研力（人·天）。 */
  research: number
  /** 开工时扣除的实物原料。 */
  cost: { goods: Partial<Record<GoodID, number>> }
  /** 知识前置。 */
  requires: TechID[]
  /**
   * 效率加成（加法叠加，见 `techBonuses()`）。缺省 = 这项科技只解锁东西、不给加成。
   * 键只有 5 个：`agri` / `goods` / `material`（产出）、`research`（科研速度）、`build`（建造速度）。
   */
  effects?: TechEffects
  /**
   * 贸易科技（B3）：带这个块的科技只出现在科技面板「贸易」页，效果见 `TradeEffects`。
   */
  trade?: TradeEffects
  /** 本科技解锁的建筑与住房。每座建筑至多被一项科技解锁。 */
  unlocks: { buildings: BuildingID[]; housing: GoodID[] }
}

/** `TechDef` 的别名（两者是同一份定义）。 */
export type TechnologyDef = TechDef

/** 队列里的一项在研科技。结构与 Construction 刻意保持一致。 */
export interface ResearchProject {
  id: TechID
  /** 还差的科研力。白天按小时投入，用 r4 累积。 */
  remaining: number
  /** 总需求（进度条用）。 */
  totalRequired: number
  /** 材料是否已扣（队首开始投入科研力时扣，即当天第一个工作小时）。 */
  started: boolean
  /**
   * 队首是否正卡在材料上（**尚未满足**开工条件）。
   *
   * 科研力在工作小时里按小时投入，每小时都会撞上同一个缺口 —— 用它去重，
   * 「等待材料」一天只写一条，不逐小时刷屏（与施工把诊断留给夜晚同一目的）。
   * 旧存档没有这个键 = 还没判定过，照常当 false。
   */
  waiting?: boolean
}

export interface ResearchState {
  /** 已研究完成的科技。 */
  done: TechID[]
  /** 先进先出队列；只有队首在推进。 */
  queue: ResearchProject[]
}

// ---------------------------------------------------------------------------
// 任务（引导系统）
//
// 契约见 docs/quests.md。要点：
//   - 任务 = 一组**对当前状态的只读谓词**（`goals` 全为真 = 完成）
//   - 判定与发钱都发生在**黎明**（`runDawn` 末尾）——所以「玩家先干了、任务后出现」
//     当场就算完成（可追溯）；判定与奖励都进仿真，golden 可复现
//   - 渐进显示：只有 `requires` 全部完成过的任务才可见（玩家看不到后面还有什么）
// ---------------------------------------------------------------------------

export type QuestID = string

/** 可修缮的建筑：`townhall` 是内容里用的口语名，`town_center` 是建筑表里的 id。 */
export type RepairTargetID = 'townhall' | 'town_center'

/**
 * 城镇中心的三段状态（用户 2026-10：第三章先「初步修缮」，第四章再「修好」）。
 * `ruined`（开局废墟）→ `patched`（初步修缮）→ `restored`（修好）。
 * 顺序是硬闸：一次只走一段，不能跳级。
 */
export type RepairStage = 'ruined' | 'patched' | 'restored'

/** 任务目标：每种都能算出「当前 / 需要」，用于追踪条上的进度。 */
export type QuestGoal =
  /**
   * 建成 N 座某建筑（在途工地不算）。
   *
   * `repaired: true` = 换个口径：数的是「这座**已经修好**了吗」（只对 `town_center` 有意义）。
   * 等价于 `building_repaired`，留着是给内容里换个写法用的。
   */
  | { type: 'building'; id: BuildingID; min: number; repaired?: true; stage?: RepairStage }
  /**
   * 某座**塌了的**建筑修到了某个段位（用户 2026-10：第三章初步修缮、第四章修好）。
   * `stage` 缺省 = `restored`（修好）；`patched` = **至少**初步修缮过（也认已修好的）。
   */
  | { type: 'building_repaired'; id: RepairTargetID; min: number; stage?: RepairStage }
  /** 拥有 N 栋某住房（国有 + 私有）。 */
  | { type: 'housing'; id: GoodID; min: number }
  /** 住房总容量不低于 N。 */
  | { type: 'housing_capacity'; min: number }
  /** 人口不低于 N。 */
  | { type: 'population'; min: number }
  /** 某阶层人数不低于 N。 */
  | { type: 'class'; id: ClassID; min: number }
  /** 已完成某科技。 */
  | { type: 'tech'; id: TechID }
  /** 已完成的科技数不低于 N。 */
  | { type: 'tech_count'; min: number }
  /** 仓库里某商品不低于 N。 */
  | { type: 'good'; id: GoodID; min: number }
  /** 历史上有过某商品**单日产量**不低于 N（看产能，不看库存）。 */
  | { type: 'produced'; id: GoodID; min: number }
  /** 平均满意度不低于 N。 */
  | { type: 'avg_satisfaction'; min: number }
  /** 私有住房不低于 N 户。 */
  | { type: 'private_housing'; min: number }
  /**
   * **累计送出**某商品不少于 N（用户 2026-10：给瑟拉菲娜送物资）。
   *
   * ⚠️ 判的是"送出去多少"，**不是**"仓库里有多少" —— 所以 `good` 那种口径糊不了这一条：
   * 东西得真的走 `gift` 命令出门（扣货 + 记进 `state.gifts[to][good]`）才算数。
   */
  | { type: 'gifted'; to: string; id: GoodID; min: number }

/**
 * 一条任务的**种类**（用户 2026-10，B2）。
 *
 *   · `main`      —— 主线：进追踪条、参与章节奖励判定（"本章全绿"只数这些）
 *   · `side`      —— 支线：进「支线」页，不挡任何后续任务、不影响章节奖励
 *   · `milestone` —— 里程碑：**不发钱**、不参与章节奖励、也不挡剧情。
 *                    它唯一的职责是"让追踪条不空"（目标可以设得很远）。
 */
export type QuestKind = 'main' | 'side' | 'milestone'

export interface QuestDef {
  id: QuestID
  /** 章节号：整章全绿（只数 `kind: "main"`）另有一次性奖励。 */
  chapter: number
  /** 种类（`main` / `side` / `milestone`）。内容里不写就是 `main`。 */
  kind: QuestKind
  /**
   * 发布这条任务的 NPC（`sebastian` / `luna` / `vila` …）。用户 2026-10：
   * 任务触发时要**暂停时间、弹一段 galgame 对话** —— 说话的就是这位。
   */
  giver: string
  /** 这位 NPC 的立绘 id（`<id>_<mood>`，见 docs/characters.md）。 */
  giverPortrait: string
  title: string
  /** 一句「怎么做」，直接显示在追踪条上。 */
  hint: string
  /**
   * 「为什么要做这一条」——任务面板右侧的描述，用**老臣（塞巴斯蒂安）**的口吻写给玩家。
   * 与 `hint` 分工明确：`hint` 说怎么点，`brief` 说为什么值当。
   *
   * ⚠️ 任务触发时那段对话就是拿它**逐句**说的（`splitSentences`），所以它必须是一段
   * 能当台词念的话，而不是提纲。
   */
  brief: string
  reward: number
  /** 前置任务：全部完成过之后，这条才可见、才可能完成。 */
  requires: QuestID[]
  goals: QuestGoal[]
  /**
   * 支线：不挡任何后续任务，也不影响章节奖励。
   *
   * ⚠️ 这是 `kind` 的**派生别名**（`kind === 'side'`）。内容里两种写法都收
   * （老内容写 `"side": true`），但引擎与 UI 只认 `kind` —— 两处判断必须同源。
   */
  side?: boolean
}

/**
 * 章节结尾那段对话里的一个选项（用户 2026-10）。
 *
 * `action` 决定选完之后干什么：
 *   · `free_prophecy` —— 送一次预言（第一章：瑟拉菲娜出场，绕过 5 天冷却）
 *   · `close`        —— 什么都不做，把对话关掉（缺省）
 */
export interface QuestChoice {
  id: string
  text: string
  action?: 'free_prophecy' | 'close'
}

/**
 * 章节完成时弹出的一段对话（galgame 形式）。
 *
 * 结构与任务发布对话同形（说话人 + 立绘 + 逐行台词），只多了可选的 `choices`。
 */
export interface QuestOutro {
  /** 说话人（NPC id，同上 `giver`）。 */
  speaker: string
  /** 立绘 id。 */
  portrait: string
  /** 逐行显示的台词（一行 = 一页）。 */
  lines: string[]
  choices?: QuestChoice[]
}

export interface QuestChapterDef {
  id: number
  title: string
  reward: number
  /**
   * **剧情时钟**（用户 2026-10，B1）：上一章领奖那天起，再隔这么多天才开这一章。
   *
   *   · 缺省 `0` = 上一章一收尾，这一章的任务当场就在（章 1–5 全是 0）
   *   · 章 6 起填 3–5 的**固定值**（不随机 —— 黄金轨迹要可复现）
   *   · 只在"上一章主线全绿"之后才开始计时；玩家拖多久都不催
   *   · 只闸 `kind: "main"` 的任务：支线与里程碑不受它管
   */
  gapDays: number
  /** 章节全部完成时的那段对话（可选）。 */
  outro?: QuestOutro
}

/**
 * 预言家（AI 辅助）的记账。见 `docs/ai-assist.md` §六。
 *
 * `lastAskDay` = 上一次问他是第几天；`-1` = 这一局还没问过。
 * 冷却 `PROPHET_COOLDOWN_DAYS`（5）天：`day >= lastAskDay + 5` 才问得动。
 */
export interface ProphetState {
  lastAskDay: number
}

/** 单个目标的进度（只读）。`text` 由引擎拼好，保证 TS 与 GDScript 显示一致。 */
export interface QuestGoalProgress {
  goal: QuestGoal
  have: number
  need: number
  met: boolean
  text: string
}

/** 一条任务的进度（只读，引擎判定与 UI 显示共用同一份）。 */
export interface QuestProgress {
  def: QuestDef
  goals: QuestGoalProgress[]
  /** 目标已全绿（但可能还没到黎明结算 —— 见 `done`）。 */
  met: boolean
  /** 已经结算过（`done` 里有它）。 */
  done: boolean
  /** 完成那一天（`done` 时才有）。 */
  day?: number
}

// ---------------------------------------------------------------------------
// 住房的**单体身份**（用户 2026-10：建筑和村民本来就有 id，只有住房是 `{hut: 6}` 计数）
//
// 每栋房现在有自己的 id（`h#7`）：**改建也换不掉的**那个 id。
// 于是"哪一栋在改建 / 哪一栋被买下 / 哪一栋住着谁"都能直接指到它，
// 不用再靠"同类型第 i 座"这种顺序约定（那套约定曾让改建进度条到处乱跳）。
//
// ⚠️ `housing` / `privateHousing` 仍然保留，但它们是**派生计数**：
// 任何 unit 变动之后 `syncHousingCounts()` 从 units 重算一遍。
// 容量 / 租金 / 任务判定 / 黄金摘要都继续读计数，所以摘要不会因为这层改动而漂。
// ---------------------------------------------------------------------------

export interface HousingUnit {
  /** `h#<n>`：单调递增，**改建时不变**（换的是 `type`，不是身份）。 */
  id: string
  /** 房型（`hut` / `wooden_house` / `brick_house`）。 */
  type: GoodID
  /** 被居民买下了（户主名下）。 */
  private: boolean
  /** 房主的 resident id（`private` 时才有）。 */
  ownerId?: string
}

export interface QuestState {  /** questId → 完成那一天。 */
  done: Record<QuestID, number>
  /** chapterId → 领到章节奖励那一天。 */
  chapters: Record<string, number>
  /**
   * 已经播过的剧情对话（`q:<questId>` / `c:<chapterId>`）。
   *
   * 只记事、不演化：播没播过都不改村子的任何数字。放在状态里是为了读档 / 退出重进
   * 之后**不重播**，也不会漏播（事件队列会丢，比对状态不会）。
   */
  shown: Record<string, boolean>
}

/**
 * 一段剧情对话（引擎说"该播这个"，UI 只管画）—— 用户 2026-10。
 *
 * 三种触发共用这一个形状：任务一出现、一章全绿、以及 `scenes.json` 里那种
 * "不挂任务的戏"（艾莉丝/米拉/加雷斯的登场）。所以 `kind` 有三档。
 */
export interface StoryTalk {
  /** 记账键：`q:<questId>` / `c:<chapterId>` / `s:<sceneId>`。播完调 `markQuestTalkShown()`。 */
  key: string
  kind: 'quest' | 'outro' | 'scene'
  /** 任务 id / 章节 id（数字章节转成字符串）/ 场次 id。 */
  id: string
  chapter: number
  /** 说话的 NPC id（`sebastian` / `luna` / `sara` …）。 */
  speaker: string
  /** 立绘 id（`<id>_<mood>`）。 */
  portrait: string
  lines: string[]
  choices?: QuestChoice[]
}

/**
 * 场次的触发条件（用户 2026-10，A1）。全部**可选**，写几个就要求几个。
 *
 * 判定口径与任务同一条：**状态比对**，不是事件队列 —— 读档不重播、不漏播。
 */
export interface SceneWhen {
  /** 第 N 章**收尾之后**才播（缺省 = 开局就能播）。 */
  chapter?: number
  /** 那一章收尾之后再过 N 天（`chapter` 缺省时等于"开局后第 N 天"）。 */
  afterDays?: number
  /** 最早第几天（绝对天数）。 */
  minDay?: number
  /** 人口不低于 N。 */
  pop?: number
  /** 已经建成某建筑。 */
  building?: BuildingID
  /** 已经完成某科技。 */
  tech?: TechID
  /** 某阶层至少 N 人（`class` + `classMin`）。 */
  class?: ClassID
  classMin?: number
}

/** 一段"不挂任务的戏"（`content/scenes.json`，用户 2026-10 · A1）。 */
export interface SceneDef {
  id: string
  /** 触发表（见 `SceneWhen`）。 */
  when: SceneWhen
  speaker: string
  portrait: string
  /** 逐行显示的台词（一行 = 一页）。 */
  lines: string[]
  choices?: QuestChoice[]
}

/**
 * 场次的记账（只记事，不演化）。
 *
 * `shown` 与 `quests.shown` 同一类东西：记"这段播过了"，好让读档 / 退出重进都不重播。
 * 单独开一段而不是合进 `quests.shown`，是因为场次**不属于任务系统**（`docs/quests.md`
 * 里那三种触发各记各的账）；存档版本 5 一起加。
 */
export interface SceneState {
  shown: Record<string, boolean>
}

/**
 * 游商**卖**给你的一条报价（玩家从他买）。
 *
 * 他带来的货是有限的：`qty` = 还剩多少件，成交一次就减。
 */
export interface CaravanSellOffer {
  good: GoodID
  /** 单价（baseValue×1.3，玩家付钱）。 */
  price: number
  /** 剩余可买量。 */
  qty: number
}

/**
 * 游商**收**你货的一条报价（玩家卖给他）。
 *
 * ⚠️ **没有数量上限**（用户 2026-10："游商本来就为了收购这个货物来的，所以是多多益善，
 * 阻止他收购这个货物的唯一就是自己钱不够了"）。所以这里只有商品与单价，
 * 上限全靠 `Caravan.cash`：`floor(cash / price)` 件，卖一次他的现金就少一截。
 * 早先这里有个 `qty: 20` 的每种配额 —— 已经删掉了，别再偷偷加回来。
 */
export interface CaravanBuyOffer {
  good: GoodID
  /** 单价（baseValue×1.6，他付现金给你）。 */
  price: number
}

/**
 * 一位游商（2026-10 M4）。
 *
 * `cash` = 他能用来收你货的现金；玩家买他的货会让它变大（"你买得越多他越有钱"）。
 * `goodsValue` = 他带的货值（决定每种商品带多少件）。
 */
export interface Caravan {
  id: string
  arriveDay: number
  /** 最后一天（含）；次日黎明离开。 */
  leaveDay: number
  cash: number
  goodsValue: number
  /** 他卖的（玩家买）。 */
  sell: CaravanSellOffer[]
  /** 他收的（玩家卖）。**不限量**，只受 `cash` 限制。 */
  buy: CaravanBuyOffer[]
}

/** 游商系统的状态（见 `systems/caravan.ts`）。 */
export interface TradeState {
  caravans: Caravan[]
  /** 下一批到货日。 */
  nextWaveDay: number
  /** 第几批（用于 id 与确定性种子）。 */
  wave: number
  /** 首遇剧情播过没有。 */
  introShown: boolean
  /**
   * 和游商**成交过几次**（B4 任务 `caravan_trade` 用；见 docs/trade-routes.md §12.1）。
   * 单调递增的计数器，只记事、不参与任何公式，不进黄金摘要。
   */
  soldTimes: number
  boughtTimes: number
}

// ---------------------------------------------------------------------------
// 商路（B3，见 docs/trade-routes.md）
// ---------------------------------------------------------------------------

/** 一座目的地城市（内容 `content/routes.json`）。 */
export interface RouteCityDef {
  id: string
  nameZh: string
  lord: string
  /**
   * 这座城市归哪个势力（`content/factions.json` 的 id）。
   *
   * **唯一真源就是这个字段** —— 好感门槛（中立及以上才开得了商路）与"跑完一趟 +好感"
   * 都按它查势力，别在代码里另写映射表。见 docs/diplomacy.md §2.2 / §3。
   */
  faction: FactionID
  /** 单程天数（1–5）。 */
  days: number
  /** 特产 2 种：**只能从这里买**。 */
  specialty: GoodID[]
  /** 需求 3 种：**只能卖给它**。 */
  demand: GoodID[]
  /** 章节解锁（0 = 商路一开通就能去）。 */
  unlockChapter: number
}

/** `routes.json` 里那个"距离 → 买卖倍率"的表。 */
export interface RouteDistanceStep {
  days: number
  sellMul: number
  buyMul: number
}

export interface RoutesConfig {
  /** `days → { sellMul, buyMul }`。 */
  distance: Record<number, { sellMul: number; buyMul: number }>
  caravan: { count: number; maxCount: number; cargo: number; purse: number; roundTrip: boolean }
  market: {
    specialtyStock: number
    specialtyDaily: number
    specialtyCap: number
    demandDaily: number
    demandCap: number
  }
  cities: RouteCityDef[]
  cityIds: string[]
}

/** 一支商队 + 它当前挂着的那条商路。 */
export interface TradeRoute {
  /** `route_1`…`route_5`，与商队槽位一一对应。 */
  id: string
  /** null = 这支商队还没派活。 */
  cityId: string | null
  phase: 'home' | 'out' | 'back'
  /** 本趟出发日 / 到达日 / 回家日（0 = 从没跑过）。 */
  departDay: number
  arriveDay: number
  backDay: number
  /** 配置：购买预算（带上路的钱）。 */
  budget: number
  /** 配置：出售数量（商品 → 件数）。 */
  sellPlan: Record<string, number>
  /** 已锁的卖货（在家等着出发时才非空）。 */
  loaded: Record<string, number>
  /** 已锁的带出钱。 */
  cash: number
  /** 回程载着的买货。 */
  cart: Record<string, number>
  /** 本趟卖出所得 / 买入花费。 */
  revenue: number
  spent: number
  /** 上一趟回家那天（面板写"3 天前"）。 */
  lastTripDay: number
  /** 最后一次往公告里写"停在村里缺货"是哪天（同一天只写一条，别刷屏）。 */
  lastStuckDay: number
}

export interface RouteMarket {
  /** 特产库存（商品 → 件数）。 */
  specialty: Record<string, number>
  /** 需求池（商品 → 件数）：这座城市还能吃多少。 */
  demand: Record<string, number>
}

export interface RouteState {
  routes: TradeRoute[]
  /** `cityId → 市场`。 */
  market: Record<string, RouteMarket>
  /**
   * **累计创建过几条商路**（B4 任务 `route_created` 用；见 docs/trade-routes.md §12.2）。
   * 单调递增的计数器：取消商路也不减 —— 任务问的是"你会用这套系统了吗"。
   * 只记事、不参与任何公式，不进黄金摘要。
   */
  created: number
}

// ---------------------------------------------------------------------------
// 邦交（B4，见 docs/diplomacy.md）
//
// 一个势力挂一条好感（-10000..10000），七档；**只有中立及以上才开得了商路**；
// 主动开战直接打到敌对（-6000）；好感满分再花 2000 钱才能结盟；打服的势力变附庸。
// ---------------------------------------------------------------------------

export type FactionID = string

/** 好感档位（数值档）。附庸是**状态位**，不是档位 —— 见 `FactionState.vassal`。 */
export type RelationBand = 'enemy' | 'cold' | 'neutral' | 'friendly' | 'respect' | 'ally'
/** 可以当**天花板**的档位（`cap`）：不存在"最高敌对"这种东西。 */
export type CapBand = 'cold' | 'friendly' | 'respect' | 'ally'

/**
 * 一档好感：`max` 是上界，`incl` 决定含不含它。
 *
 * ⚠️ **边界归属是用户口述的**，别自作主张改成统一口径（见 docs/diplomacy.md §1.1）：
 * 敌对 `≤ -6000` / 冷淡 `(-6000, -2000]` / 中立 `(-2000, 2000)` / 友善 `[2000, 6000)` /
 * 尊重 `[6000, 10000)` / 同盟 `≥ 10000`。所以**负的两档含上界、正的三档不含**，
 * 同盟是"兜底那一档"（含 10000）。
 */
export interface RelationBandDef {
  id: RelationBand
  nameZh: string
  max: number
  /** 上界是否包含（缺省 false）。 */
  incl: boolean
}

/** `content/factions.json` 的 `relation` 段：档位表 + 各种率。 */
export interface RelationConfig {
  min: number
  max: number
  /** 从低到高，`max` 单调递增。 */
  bands: RelationBandDef[]
  /** 附庸那一档的显示名（不是数值档，UI 拼在档位名后面）。 */
  vassalNameZh: string
  /** `cap` 档位 → 数值上限（避免在 JSON 里写 -2001 这种魔数）。 */
  capByBand: Record<CapBand, number>
  /** 送钱最少多少（步长）。 */
  giftStep: number
  /** 1 钱换多少好感。 */
  giftRate: number
  /** 主动开战把关系直接打到这里（不是"减"）。 */
  attackHit: number
  /** 结盟要花的钱。 */
  allyCost: number
  /** 这一档起才能开商路。 */
  tradeBand: RelationBand
  /** 商路每跑完一趟的基础好感（再乘 1 + 科技加成）。 */
  tradeGain: number
}

/** 剧情翻转：`completed_chapter() >= chapter` 时把关系直接打到 `to`，只做一次。 */
export interface FactionFlip {
  chapter: number
  to: number
  reason: string
}

/** 打赢之后怎么收场：好感打到 `rep`、天花板换成 `cap`、要不要变附庸。 */
export interface FactionDefeat {
  rep: number
  cap: CapBand
  vassal: boolean
  /** 打赢那一仗的公告文案（缺省由引擎拼）。 */
  reason?: string
}

export interface FactionDef {
  id: FactionID
  nameZh: string
  /** 面板/列表里的短名（王庭 / 铁峰 …）。 */
  short: string
  lord: string
  /** 归它的城市（`routes.json` 的 cityId）。银叶 / 灰烬没有城。 */
  cityIds: string[]
  /** 开局好感。 */
  initial: number
  cap: CapBand
  allyable: boolean
  vassalable: boolean
  flip: FactionFlip | null
  /** 打赢之后怎么收场；null = 这个势力在剧情里打不了（王庭 / 铁王城）。 */
  defeat: FactionDefeat | null
  /** 徽记图标 id（`assets/ui/faction/<glyph>.png`）。 */
  glyph: string
}

export interface FactionsConfig {
  relation: RelationConfig
  factions: FactionDef[]
  factionIds: FactionID[]
}

/**
 * 邦交状态（存档 v7）。
 *
 * `rep` 是唯一会演化的数值；`ally` / `vassal` 是状态位；`gifts` / `flipped` 是记账。
 * ⚠️ 它不参与经济的任何公式（好感只决定"能不能开商路"和"跑完一趟加多少"），
 * 所以黄金摘要不受影响 —— 但 `assign_route` 的行为会变，golden 脚本不碰商路即可。
 */
export interface FactionState {
  /** 好感，夹在 [min, cap]。 */
  rep: Record<FactionID, number>
  /** 是否已结盟（好感满分 + 付过钱）。 */
  ally: Record<FactionID, boolean>
  /** 是否是我们的附庸（打服的）。 */
  vassal: Record<FactionID, boolean>
  /** 送过几次钱（任务 `faction_gift` 用；单调递增，只记事）。 */
  gifts: Record<FactionID, number>
  /** 剧情翻转做过没有（只做一次）。 */
  flipped: Record<FactionID, boolean>
  /**
   * 打服过没有（B5 打赢讨伐战才置 true）。
   *
   * 它是**天花板**的依据：没打服时按 cap，打服之后按 defeat.cap。
   * 不能拿 ep 当标记 —— 铁鸦堡打服后是 -4000（和开局一样），看不出变化。
   */
  defeated: Record<FactionID, boolean>
}

export interface Government {  money: number
  /** 累进所得税税表（可运行时调整）。最后一段 upTo 为 null 表示无上限。 */
  taxBrackets: TaxBracket[]
  /** 国有住房人均日租金（玩家可调）。 */
  rent: number
  /** 日补贴预算（预留，未启用）。 */
  subsidyBudget: number
  /**
   * 人口上限（玩家可调）：迁入到该数就停。
   * 用来防止"一口气涌进来一堆人、粮食跟不上饿死"。1e9 = 不限。
   */
  populationCap: number
  /**
   * **每种物资的软上限**（玩家在「设置资源」里逐项设置）。缺项 = 该项不限。
   *
   * 为什么要它：全局仓储上限是"总量"口径，一种货囤多了就会把空间占满，
   * 于是别的物资生产出来**收不下、当晚被丢掉**。给单个货设一个软上限
   * （超过就在日终结算时把超出部分丢掉），就能把它挡在别人前面。
   * 见 `docs/town.md` §3.6。
   */
  storageCaps: Partial<Record<GoodID, number>>
}

export interface TaxBracket {
  /** 该档收入上限；null = 无上限（最后一档）。 */
  upTo: number | null
  /** 该档边际税率 0-0.95。 */
  rate: number
}

export interface DaySnapshot {
  day: number
  population: number
  avgSatisfaction: number
  money: number
  hungry: number
  employed: number
  /** 当日台账（实际流量）。 */
  ledger?: DayLedger
}

export interface LogEntry {
  day: number
  kind:
    | 'production'
    | 'shortage'
    | 'finance'
    | 'population'
    | 'hunger'
    | 'invest'
    | 'alert'
    | 'storage'
    /** 商路（B3）：出发 / 到达 / 回家 / 停在村里。 */
    | 'trade'
    /** 邦交（B4）：送礼 / 结盟 / 宣战 / 剧情翻脸。 */
    | 'diplomacy'
    | 'info'
  text: string
}

export type AlertType =
  | 'hunger'
  | 'bankruptcy'
  | 'shortage'
  | 'unemployment'
  | 'low_satisfaction'
  | 'storage_full'

export interface Alert {
  type: AlertType
  count: number
  text: string
}

export interface GameState {
  pack: PackID
  seed: number
  /** 村庄名（可改，随存档保存）。UI 显示用，不参与任何仿真计算。 */
  villageName: string
  rngState: number
  day: number
  /** 当前小时（0 .. hoursPerDay-1）。 */
  hour: number
  /** 待生效命令队列：在次日 06:00（dawnHour）排产时统一应用。 */
  pending: Action[]
  /** 当日已计划消耗的原料（剩余锁定）；可用花料量 = goods − reserved。 */
  reserved: Record<GoodID, number>

  government: Government
  /** 中央仓库库存。 */
  goods: Record<GoodID, number>
  /** 已建成住房存量（按住房商品计），决定人口上限。**由 `housingUnits` 派生**。 */
  housing: Record<GoodID, number>
  /** 其中已私有化的住房数量（⊆ housing）。**由 `housingUnits` 派生**。 */
  privateHousing: Record<GoodID, number>
  /**
   * 每栋房一个条目（**唯一真源**）。`housing` / `privateHousing` 是它算出来的计数。
   * 见文件上方 `HousingUnit` 的说明。
   */
  housingUnits: HousingUnit[]
  /** 下一条住房 id 的序号（`h#<n>`）。单调递增，收房也不回收号码。 */
  housingSeq: number
  /** 售价（居民购买价）。 */
  prices: Record<GoodID, number>

  shops: Shop[]
  residents: Resident[]
  construction: Construction[]
  /** 科技：已完成的 + 在研队列。见 docs/technology.md。 */
  research: ResearchState
  /** 任务（引导系统）：完成记录 + 章节奖励记录。见 docs/quests.md。 */
  quests: QuestState
  /**
   * 送出去的东西（用户 2026-10 · A4）：`gifts[收礼人][商品] = 累计数量`。
   *
   * 只由 `gift` 命令往上加（次日黎明生效、当场扣货），任务目标 `gifted` 读它。
   * ⚠️ 它是"送出过多少"的账，**不是库存** —— 所以判 `gifted` 不能用 `good` 糊。
   */
  gifts: Record<string, Record<GoodID, number>>
  /** 场次（不挂任务的戏）的记账：播过哪些。见 `systems/scenes.ts`。 */
  scenes: SceneState
  /**
   * 山顶那位预言家（AI 辅助）的记账：`lastAskDay` = 上次问他话是第几天（-1 = 还没问过）。
   *
   * ⚠️ 这是**唯一一个不参与仿真演化**的状态段：问不问都不改村子的任何数值，
   * 它只是"5 天才能问一次"这条冷却的记账（规则与 UI 在 Godot 侧，见 docs/ai-assist.md §六）。
   * 放在状态里而不是 UI 配置里，是为了让退出重进 / 读档都绕不过冷却。
   */
  prophet: ProphetState
  /**
   * 城镇中心的**修缮进度**（用户 2026-10）：`ruined` → `patched` → `restored`。
   *
   * ⚠️ 仿真的任何数字都不读它 —— 和 `prophet` 一样"只记事、不演化"，
   * 所以黄金摘要（按字段取的）不受影响。修缮命令和其它命令一样**次日黎明生效**，
   * 表现层按它挑贴图（破旧 / 初步修缮 / 修好三张）。
   */
  townCenter: { stage: RepairStage }
  /** 游商（M4）：在场队伍 / 下一批到达日 / 批次号 / 首遇剧情。见 `systems/caravan.ts`。 */
  trade: TradeState
  /**
   * 商路（B3）：车队列表 + 各城市场库存。见 `systems/routes.ts` 与 `docs/trade-routes.md`。
   *
   * ⚠️ 商队（caravan）和**游商**（`trade.caravans`）是两套东西：游商是谷口来的货郎，
   * 商路是我们自己派出去的车队。
   */
  routes: RouteState
  /**
   * 邦交（B4）：13 个势力的好感 / 结盟 / 附庸 / 送礼次数 / 剧情翻转。
   * 见 `systems/factions.ts` 与 `docs/diplomacy.md`。存档 v7 新增。
   */
  factions: FactionState

  /** 当日台账累加器：黎明清零，夜间结算时挂到当天快照上。 */
  ledgerToday: DayLedger
  /**
   * 当日建造力预算（人·天）：黎明 `planConstructionDay` 钉死，全天不变。
   *
   * 与 `researchRateToday` 同形制：它是"一天总量恰好等于当日建造力"的硬闸 ——
   * 白天每个工作小时投入的量（`constructionRateToday × fraction`）都抵着它，
   * 不必依赖"同一天里 `constructionRate()` 恰好不变"（它取决于失业人口与
   * 建筑工坊的在岗人数，任何中途的人事变动都会当场改变现算值）。
   * 见 `docs/spec.md` §9.3。
   */
  constructionRateToday: number
  /**
   * 当日已投入施工的建造力（人·天）累加器。
   *
   * 施工在**工作小时里按小时累积**（`applyConstructionHours`），到夜晚才把它
   * 一次性折成「工地出工」的建造工资（`markConstructionWorkers`）——
   * 所以这一天里投了多少必须攒着，结算完清零。见 `docs/spec.md` §9.3 / §9.4。
   */
  constructionWorkToday: number
  /**
   * 当日科研力预算（人·天）：黎明 `planResearchDay` 钉死，全天不变。
   *
   * 它是"一天总量恰好等于当日科研力"的硬闸：逐小时投入的量与当日已投累计
   * （`researchWorkToday`）都抵着它，不必依赖"同一天里 `researchRate()` 恰好不变"。
   * 与施工的 `constructionRateToday` 同一套口径。见 `docs/spec.md` §10.3。
   */
  researchRateToday: number
  /** 当日已投入科研的科研力（人·天）累加器：抵住上面的预算，黎明清零。 */
  researchWorkToday: number

  history: DaySnapshot[]
  log: LogEntry[]
  alerts: Alert[]
  /** 本回合"想来"的移民人数（由引擎按满意度等计算）。 */
  arrivals: number
  /**
   * 昨夜算出来的「需求满足率」（0..1，键 = `medical` / `education` / `safety` / `food` …）。
   *
   * ⚠️ **派生量、只给面板看**：夜间 `runConsumption` 写完，除统计面板没人再读它 ——
   * 不参与任何公式（教育那一项当场被 `growSkills` 用掉了）。
   * 放在状态里是为了让面板不必自己再跑一遍需求链（用户 2026-10 · A3 教育页）。
   * **不进黄金摘要**（`scripts/golden.ts` 的 `summarize()` 不取它）。
   */
  needScores: Record<string, number>
}

// ---------------------------------------------------------------------------
// 动作（AI / 玩家输入）
// ---------------------------------------------------------------------------

export type Action =
  | { type: 'set_wage'; shopId: string; value: number }
  | { type: 'set_wage_cap'; shopId: string; value: number }
  | { type: 'set_workers'; shopId: string; value: number }
  | { type: 'set_price'; goodId: GoodID; value: number }
  | { type: 'expand'; shopId: string }
  | { type: 'toggle'; shopId: string; active: boolean }
  /**
   * 拆除：直接销毁一座**已建成**的建筑（玩家在建筑面板点「拆除」）。
   *
   * 语义（见 docs/spec.md §9.7）：
   * - 从 `state.shops` 移除；**不退钱、不退料**（"直接销毁"就是玩家的决定）
   * - 里面的工人自动变回失业 —— `assignLabor` 每晚按 `state.shops` 现算，
   *   不需要额外处理
   * - **只作用于已建成的**。还在 `state.construction` 队列里的走 `cancel_construction`，
   *   不走这条
   * - 占用的地格由表现层（world_view）在收到拆除结果后释放
   */
  | { type: 'demolish'; shopId: string }
  | { type: 'build'; buildingId: BuildingID }
  | { type: 'build_housing'; goodId: GoodID }
  /**
   * 住房**改建**：把一栋**国有**住房（`goodId` = 改建前的房型）改成本房型
   * `upgradeTo` 指定的下一档（见 docs/spec.md §5.4）。
   *
   * - 成本 = 目标房型 buildCost **减去**原房型 buildCost（只算差、旧料视为已回收）；
   *   工期同理取差值。都只认当前内容包里存在的商品。
   * - **只作用于国有住房**：私有（居民买下的）住房不能改建，条目会被拒。
   * - 完工时那栋房的 `type` 换成目标房型，**id 不变、不额外占地**。
   */
  | {
      type: 'upgrade_housing'
      goodId: GoodID
      /**
       * 指定改建**哪一栋**（`HousingUnit.id`）。不传就由引擎挑最早那栋国有空房
       * （玩家从某栋房的面板点「改建」时会带上它，进度条因此能钉在那栋房头上）。
       */
      unitId?: string
    }
  /**
   * 建造队列调序：把 `id` 这条按 `delta` 的方向挪**一位**（-1 = 上移 / +1 = 下移）。
   *
   * 队列是**先进先出**的一条 `state.construction`，队首先吃到建造力，所以调序 =
   * 决定谁先建（见 docs/construction.md 六）。只改顺序，不改投入量、不退料；
   * 已经开工的工程被挪到后面时只是**暂停**。
   */
  | { type: 'move_construction'; id: string; delta: number }
  /**
   * 取消建造：把一个**还在队列里**的工程撤掉（已建成的建筑走 `demolish`）。
   *
   * 退料口径：材料是**开工那一刻**才扣的 ——
   * - 还没开工 → 没扣过，退 0
   * - 已开工   → 退回量 = 已扣材料 × (remaining / totalRequired)（只退没干完的那一份）
   */
  | { type: 'cancel_construction'; id: string }
  | { type: 'sell_shop'; shopId: string }
  | { type: 'retake_shop'; shopId: string }
  | { type: 'set_tax'; value: number }
  | { type: 'set_tax_bracket'; index: number; upTo?: number | null; rate?: number }
  | { type: 'set_rent'; value: number }
  | { type: 'set_population_cap'; value: number }
  /** 整体替换「每种物资的软上限」表（缺项 = 不限）。见 docs/town.md §3.6。 */
  | { type: 'set_storage_caps'; caps: Partial<Record<GoodID, number>> }
  | { type: 'subsidy'; shopId?: string; amount: number }
  | { type: 'research'; techId: TechID }
  /**
   * 取消研究：把一项**还在研究队列里**的科技撤掉，并**按进度退回原料**
   * （见 docs/spec.md §10.7）。材料是开工那一刻扣的，所以没开工退 0、
   * 开工了按 `remaining / totalRequired` 退还没干完的那份；科研力本身不退。
   */
  | { type: 'cancel_research'; techId: TechID }
  /**
   * 研究队列调序：按 `delta` 的方向挪**一位**（-1 上移 / +1 下移）。
   * 与施工队列同一套语义（见 §9.8）：只改顺序，不重算进度、不退料。
   */
  | { type: 'move_research'; id: TechID; delta: number }
  /**
   * 修缮城镇中心（用户 2026-10：开局废墟 → 初步修缮 → 修好）。和别的命令一样**次日黎明生效**，
   * 材料不够就白下这一单。价格见 `investment.ts` 的 `TOWN_CENTER_PATCH_COST` /
   * `TOWN_CENTER_REPAIR_COST`。
   *
   * `stage` = 这一步走到哪：`patched`（初步修缮，第三章）/ `restored`（修好，第四章，缺省）。
   * 顺序是硬闸（不能从废墟直接修好）。
   */
  | { type: 'repair_town_center'; stage?: RepairStage }
  | { type: 'sell_to_caravan'; caravanId: string; goodId: GoodID; qty: number }
  | { type: 'buy_from_caravan'; caravanId: string; goodId: GoodID; qty: number }
  /**
   * 送物资（用户 2026-10 · A4）：把仓库里的东西送给某个人。
   *
   * 与建造 / 研究同一拍 —— **次日黎明生效**：扣货、累加 `state.gifts[to][good]`、
   * 写一条公告。任务目标 `gifted` 判的就是这个累计量。
   *
   * `to` = 收礼人的 id（`serafina`）；`qty` 取非负整数，仓库不够就整单不做。
   */
  | { type: 'gift'; to: string; goodId: GoodID; qty: number }
  /**
   * 商路（B3）：把某座城派给**第一支空闲商队**。
   *
   * 与 `research` / `gift` 一样**当场生效**（`IMMEDIATE_ACTIONS`）—— 它不花任何资源，
   * 只是给一支在家闲着和商队挂上目的地，没理由等到 6:00。
   * 没有空闲商队时拒绝并给原因。
   */
  | { type: 'route_assign'; cityId: string }
  /** 商路：取消一条商路（已锁的货与带出的钱退回）。 */
  | { type: 'route_unassign'; routeId: string }
  /** 商路：改购买预算（夹到钱箱上限）。 */
  | { type: 'route_set_budget'; routeId: string; value: number }
  /** 商路：改某项出售数量（夹到载货上限）。 */
  | { type: 'route_set_sell'; routeId: string; goodId: GoodID; qty: number }
  /**
   * 邦交 · 送礼 / 进贡（B4）：给某个势力送钱换好感（**1 钱 = 1 好感**，最少 100）。
   *
   * 和 `research` / `route_assign` 一样**当场生效**（`IMMEDIATE_ACTIONS`）：钱当场扣、
   * 好感当场涨、面板当场变 —— 送钱这种事没有"等到 6:00"的道理。
   * 钱不够 / 少于步长 / 已到天花板一律拒绝并给原因。
   */
  | { type: 'faction_gift'; factionId: FactionID; amount: number }
  /**
   * 邦交 · 结盟（B4）：好感必须**已经到满分 10000**、该势力 `allyable`、
   * 再花 `relation.allyCost`（2000）钱。当场生效。
   */
  | { type: 'faction_ally'; factionId: FactionID }
  /**
   * 邦交 · 派兵进攻（B4）：关系**直接打到 -6000（敌对）**，当场生效。
   *
   * ⚠️ B4 只做"宣战"这件事，**不打仗**：真正的战斗结算在 B5（讨伐战）。
   * 附庸 / 已结盟的不许打。
   */
  | { type: 'faction_attack'; factionId: FactionID }
  | { type: 'end_turn' }

export interface AppliedAction {
  type: string
  ok: boolean
  reason?: string
}

export interface TickResult {
  state: GameState
  log: LogEntry[]
  applied: AppliedAction[]
}

// ---------------------------------------------------------------------------
// 观测（给 AI 的精简状态）
// ---------------------------------------------------------------------------

export interface ObserveShop {
  id: string
  type: BuildingID
  nameZh: string
  workers: number
  maxWorkers: number
  wage: number
  wageCap: number
  level: number
  active: boolean
  profit: number
  skill: number
  status: ShopStatus
}

export interface ObserveClass {
  id: ClassID
  count: number
}

export interface Observation {
  day: number
  pack: PackID
  government: { money: number; taxBrackets: TaxBracket[]; rent: number }
  population: {
    total: number
    byClass: Record<string, number>
    hungry: number
    avgSatisfaction: number
    employed: number
    unemployed: number
    housingCapacity: number
    /** 本回合想来的移民人数，以及本回合允许上限。 */
    arrivals: number
    populationCap: number
  }
  shops: ObserveShop[]
  market: {
    prices: Record<string, number>
    inventory: Record<string, number>
  }
  alerts: Alert[]
  housing: {
    capacity: number
    stateOwned: number
    privateOwned: number
    owners: number
    privateTenants: number
    stateTenants: number
    rent: number
  }
  history: DaySnapshot[]
}
