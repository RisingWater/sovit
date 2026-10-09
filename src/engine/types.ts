// ---------------------------------------------------------------------------
// Sovit engine types
//
// 纯数据 + 纯类型。引擎不依赖任何 UI / 框架 / Node API。
// ---------------------------------------------------------------------------

export type PackID = 'v0.1' | 'v0.2' | 'v0.3' | 'v1.0'

// 商品、建筑、配方都用字符串 id，便于内容表扩展。
export type GoodID = string
export type BuildingID = string
export type RecipeID = string

export type ClassID = 'poor' | 'middle' | 'rich' | 'boss'
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

export type BuildingTier = 1 | 2 | 3
export type ShopStatus = 'green' | 'yellow' | 'red'

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

export interface BuildingDef {
  id: BuildingID
  nameZh: string
  tier: BuildingTier
  /** 满员工人数。 */
  workers: number
  recipe: RecipeID
  /** 建造成本（材料 / 建造力）；v0.1 仅扩产使用。 */
  buildCost?: Partial<Record<GoodID, number>>
}

export interface ClassDef {
  id: ClassID
  nameZh: string
  needs: NeedDef[]
  /** 日收入基准，用于工资水平参照。 */
  incomeBase: number
}

export interface HousingDef {
  id: GoodID
  nameZh: string
  quality: 1 | 2 | 3
  /** 每单位住房容纳人口。 */
  capacity: number
  classId: ClassID
  /** 建造该住房所需的实物材料（占用一个土地名额）。 */
  buildCost?: Partial<Record<GoodID, number>>
  /** 私有化售价（玩家可调，默认取此值）。 */
  salePrice?: number
}

export interface ContentPack {
  id: PackID
  nameZh: string
  goods: GoodID[]
  buildings: BuildingID[]
  classes: ClassID[]
  housing: GoodID[]
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
  /** 是否被雇佣。 */
  employed: boolean
  /** 是否已拥有私有住房（房主 / 房东）。 */
  homeowner?: boolean
  /** 是否租住在私有住房（房客，向房主交租）。 */
  privateTenant?: boolean
  /** 当前居住的住房等级（1 茅屋 / 2 木屋 / 3 砖房）。 */
  housingQuality?: number
  /** 作为房主所拥有住房的等级。 */
  ownedQuality?: number
}

export interface Construction {
  id: string
  buildingId: BuildingID
  /** 还需天数。 */
  daysLeft: number
  totalDays: number
}

export interface Government {
  money: number
  /** 税率 0-1，v0.1 固定 0。 */
  taxRate: number
  /** 国有住房人均日租金（玩家可调）。 */
  rent: number
  /** 日补贴预算，v0.1 未启用。 */
  subsidyBudget: number
}

export interface DaySnapshot {
  day: number
  population: number
  avgSatisfaction: number
  money: number
  hungry: number
  employed: number
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
    | 'info'
  text: string
}

export type AlertType =
  | 'hunger'
  | 'bankruptcy'
  | 'shortage'
  | 'unemployment'
  | 'low_satisfaction'

export interface Alert {
  type: AlertType
  count: number
  text: string
}

export interface GameState {
  pack: PackID
  seed: number
  rngState: number
  day: number

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

  history: DaySnapshot[]
  log: LogEntry[]
  alerts: Alert[]
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
  | { type: 'build'; buildingId: BuildingID }
  | { type: 'build_housing'; goodId: GoodID }
  | { type: 'sell_shop'; shopId: string }
  | { type: 'retake_shop'; shopId: string }
  | { type: 'set_tax'; value: number }
  | { type: 'set_rent'; value: number }
  | { type: 'subsidy'; shopId?: string; amount: number }
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
  government: { money: number; taxRate: number; rent: number }
  population: {
    total: number
    byClass: Record<string, number>
    hungry: number
    avgSatisfaction: number
    employed: number
    unemployed: number
    housingCapacity: number
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
