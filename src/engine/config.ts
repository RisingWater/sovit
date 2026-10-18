import type { BuildingTier, ClassID, TaxBracket } from './types.ts'
import { CONTENT } from './content/bundle.ts'

// ---------------------------------------------------------------------------
// 经济参数（由仓库根 content/economy.json 驱动）
//
// economy = 全局数值；defaults = 新建实体的默认值；tuning = 机制可调常数。
// 改这些值只需编辑 economy.json。
// ---------------------------------------------------------------------------

export interface ConstructionConfig {
  /** 失业人口每人每日提供的建造力（非熟练工，固定）。 */
  unemployedRate: number
  /** 工地临时工工资 = refWage × 该值（失业人口上工地的报酬）。 */
  wageRate: number
  /** 扩产（+1 级）所需建造力 = 该值 × 当前等级。 */
  upgradePerLevel: number
}

/** 研究参数（见 docs/technology.md §2）。 */
export interface ResearchConfig {
  /** 全村基础科研力/天：不需要任何建筑，但慢到必须建研究所。 */
  baseRate: number
}

/** 工具参数（见 docs/technology.md §8.3）。 */
export interface ToolsConfig {
  /** 每个在岗工位每日消耗的工具数。 */
  perWorkstation: number
  /** 工具品级，由低到高；分配时从**最高级**往下找第一个够用的。 */
  order: string[]
}

export interface EconomyConfig {
  /** 工资水平的参照基准。 */
  refWage: number
  /** 公共事业（研究/建造产能 + 医疗/教育/治安/仓储）的统一岗位工资。 */
  publicServiceWage: number
  /** 默认累进所得税税表（AI/玩家可运行时调整）。 */
  defaultTaxBrackets: TaxBracket[]
  /** 需求价格弹性：价格越高需求越低。 */
  priceElasticity: number
  /** 奢侈品价格弹性（低弹性 → 提价反而多赚，用于抽取富人财富）。 */
  luxuryElasticity: number
  /** AI / 默认奢侈品的加价倍率。 */
  luxuryPriceMarkup: number
  /**
   * 覆盖加成（2026-10 第二批）：诊所 / 医院 / 学校 / 治安所"覆盖到人"时加的满意度点，
   * 以及学校对熟练度成长的倍率加成（满覆盖 = 1 + skillGrowth）。
   */
  coverage: { medical: number; education: number; safety: number; skillGrowth: number }
  /** 满意度平滑系数（0-1）。 */
  satisfactionSmoothing: number
  /** 满意度权重（会归一化）。 */
  weights: { food: number; wage: number; price: number; employment: number; comfort: number }
  /** 价格分数：score = clamp(priceIntercept - priceSlope * price/baseValue, 0, 1) */
  priceIntercept: number
  priceSlope: number
  /** 移民触发与速率。 */
  immigrationSatThreshold: number
  immigrationRate: number
  /** 昨日饥饿人数占比超过该值 → 无人愿意迁入（"食物充足"这一条）。 */
  immigrationHungryRate: number
  /** 迁出触发。 */
  emigrationSatThreshold: number
  /** 饥饿致死的比例。 */
  hungerDeathRate: number
  /** 最低人口保护。 */
  minPopulation: number
  /** 新建 / 扩产的金钱成本（当建筑无可用的实物 buildCost 时的兜底）。 */
  buildMoneyByTier: Record<BuildingTier, number>
  expandMoneyBase: number
  /** 土地上限：建筑总数（含在建、住房）不得超过该值（Infinity = 不限）。 */
  maxBuildingSlots: number
  /** 建造力（每日施工产能）参数。设计见 docs/construction.md。 */
  construction: ConstructionConfig
  /** 研究（每日科研力）参数。设计见 docs/technology.md。 */
  research: ResearchConfig
  /** 工具（工坊耗材 + 产出加成）参数。设计见 docs/technology.md §八。 */
  tools: ToolsConfig
  /** 默认人均日租金（国有住房）。 */
  defaultRent: number
  /** 私有住房（房主）带来的满意度加成（点数）。 */
  privateHousingSatBonus: number
  /** 租住私有住房（房客）带来的满意度加成（点数）。 */
  privateTenantSatBonus: number
  /** 租金负担导致的满意度惩罚上限（点数）。 */
  rentSatPenalty: number
  /** 追求私有住房所需的满意度门槛（高层需求：先满足低级需求）。 */
  privateHousingNeedThreshold: number
  /** 每日最多私有化成交户数。 */
  privateHousingPerDay: number
  /** 收入 = 岗位工资 × (skillIncomeBase + 技能/100)。 */
  skillIncomeBase: number
  /** 各工坊默认的每人实际工资上限（0 表示不限）。 */
  defaultWageCap: number
  /** 居住等级低于本阶层要求时，每缺一级的满意度惩罚。 */
  housingQualityPenalty: number
  /** 熟练度每日增长与上限。 */
  skillGainPerDay: number
  skillMax: number
  /** 阶层晋升门槛。 */
  promotionSavings: number
  promotionSatThreshold: number
}

/** 新建 / 初始居民与店铺的默认值。 */
export interface PersonDefaults {
  savings: number
  satisfaction: number
  skillBase: number
  skillRandom: number
}

export interface DefaultsConfig {
  newShop: { level: number; skill: number }
  /** 新移民默认。 */
  newResident: PersonDefaults
  /** 开局居民默认。 */
  startResident: PersonDefaults
  /** 开局阶层分布。 */
  startDistribution: ClassID[]
}

/** 机制可调常数（原本散在各 systems 的"魔数"）。 */
export interface TuningConfig {
  /** 产出 = ... × (skillEffectBase + skillEffectSlope × 技能/100)。 */
  skillEffectBase: number
  skillEffectSlope: number
  /** 失业者的就业分数。 */
  unemployedEmploymentScore: number
  /** 工资分归一化上限（wageScore = clamp(wage/refWage, 0, wageScoreCap) / wageScoreCap）。 */
  wageScoreCap: number
  /** 食物满足率低于该值算"饥饿"。 */
  hungryThreshold: number
  /** 价格系数夹紧区间。 */
  priceFactorMin: number
  priceFactorMax: number
  /** 食物需求兜底到的"基础食物"（高级食物缺货时避免饿死）。 */
  basicFoods: string[]
  /** 口粮链回溯的种子阶层。 */
  foodChainSeedClass: ClassID
}

export interface TimeConfig {
  /** 一天多少小时。 */
  hoursPerDay: number
  /** 排产 / 日界时刻（小时）。 */
  dawnHour: number
  /** 开工 / 收工时刻（工作时段 [workStart, workEnd)）。 */
  workStart: number
  workEnd: number
  /** 夜晚结算时刻。 */
  settleHour: number
  /** 1 游戏小时 = 多少真实秒（@1x）。 */
  tickSec: number
}

export const ECONOMY: EconomyConfig = CONTENT.economy
export const DEFAULTS: DefaultsConfig = CONTENT.defaults
export const TUNING: TuningConfig = CONTENT.tuning
export const TIME: TimeConfig = CONTENT.time
