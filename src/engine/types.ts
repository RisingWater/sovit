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

export type BuildingTier = 1 | 2 | 3
export type ShopStatus = 'green' | 'yellow' | 'red'

/**
 * 产业：效率科技（`TechnologyDef.effects`）按它把产出加成加到哪一类建筑上。
 * 只有**有 recipe** 的建筑才有产业（无配方建筑不产商品，加成无从施加）。
 */
export type Sector = 'agri' | 'goods' | 'material'

/** 效率科技加成的 5 个可用键（产出的三个 = `Sector`）。 */
export type TechEffectKey = Sector | 'research' | 'build'

/**
 * 效率科技的效果：**加法**叠加的加成小数（`0.10` = +10%），不是倍率。
 * 口径与 GDScript `sim_core.gd::tech_bonuses()` 一致，见 `docs/spec.md`。
 */
export type TechEffects = Partial<Record<TechEffectKey, number>>

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
  /** 各商品**实际**产量（生产小时累计）。 */
  produced: Record<string, number>
  /** 各商品**实际**工业消耗（生产投入 + 燃料）。 */
  consumed: Record<string, number>
  /** 各商品居民购买量合计。 */
  bought: Record<string, number>
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
  /** 已建成住房存量（按住房商品计），决定人口上限。 */
  housing: Record<GoodID, number>
  /** 其中已私有化的住房数量（⊆ housing）。 */
  privateHousing: Record<GoodID, number>
  /** 售价（居民购买价）。 */
  prices: Record<GoodID, number>

  shops: Shop[]
  residents: Resident[]
  construction: Construction[]
  /** 科技：已完成的 + 在研队列。见 docs/technology.md。 */
  research: ResearchState

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
   * - 完工时 `housing[from] −1`、`housing[to] +1`，**不额外占地**。
   */
  | { type: 'upgrade_housing'; goodId: GoodID }
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
