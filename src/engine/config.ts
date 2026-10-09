import type { BuildingTier, ClassID } from './types.ts'

// ---------------------------------------------------------------------------
// 经济参数（集中调参）
// ---------------------------------------------------------------------------

export interface EconomyConfig {
  /** 工资水平的参照基准。 */
  refWage: number
  /** 失业者领取的保障金 = refWage × welfareRate。 */
  welfareRate: number
  /** 默认所得税率。政府借此回收工资，闭合货币循环。 */
  defaultTaxRate: number
  /** 需求价格弹性：价格越高需求越低。 */
  priceElasticity: number
  /** 奢侈品价格弹性（低弹性 → 提价反而多赚，用于抽取富人财富）。 */
  luxuryElasticity: number
  /** AI / 默认奢侈品的加价倍率。 */
  luxuryPriceMarkup: number
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
  /** 迁出触发。 */
  emigrationSatThreshold: number
  /** 饥饿致死的比例。 */
  hungerDeathRate: number
  /** 最低人口保护。 */
  minPopulation: number
  /** 新建 / 扩产的金钱成本（当建筑无可用的实物 buildCost 时的兜底）。 */
  buildMoneyByTier: Record<BuildingTier, number>
  expandMoneyBase: number
  /** 土地上限：建筑总数（含在建、住房）不得超过该值。 */
  maxBuildingSlots: number
  /** 施工天数。 */
  constructionDays: number
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
  /** 财富分层阈值：[中产, 富人, 老板] 的下界。 */
  classWealth: { middle: number; rich: number; boss: number }
  /** 各阶层满意度加成。 */
  classSatBonus: Record<ClassID, number>
  /** 居住等级低于本阶层要求时，每缺一级的满意度惩罚。 */
  housingQualityPenalty: number
  /** 各阶层要求的最低住房等级。 */
  classHousingLevel: Record<ClassID, number>
  /** 熟练度每日增长与上限。 */
  skillGainPerDay: number
  skillMax: number
  /** 阶层晋升门槛。 */
  promotionSavings: number
  promotionSatThreshold: number
}

export const ECONOMY: EconomyConfig = {
  refWage: 3,
  welfareRate: 1.0,
  defaultTaxRate: 0.2,
  priceElasticity: 1.2,
  luxuryElasticity: 0.4,
  luxuryPriceMarkup: 2.5,
  satisfactionSmoothing: 0.2,
  weights: { food: 0.45, wage: 0.2, price: 0.1, employment: 0.1, comfort: 0.15 },
  priceIntercept: 1.3,
  priceSlope: 0.6,
  immigrationSatThreshold: 60,
  immigrationRate: 0.1,
  emigrationSatThreshold: 40,
  hungerDeathRate: 0.2,
  minPopulation: 4,
  buildMoneyByTier: { 1: 100, 2: 250, 3: 500 },
  expandMoneyBase: 80,
  maxBuildingSlots: Infinity,
  constructionDays: 2,
  defaultRent: 0.05,
  privateHousingSatBonus: 12,
  privateTenantSatBonus: 4,
  rentSatPenalty: 25,
  privateHousingNeedThreshold: 80,
  privateHousingPerDay: 2,
  skillIncomeBase: 0.5,
  classWealth: { middle: 40, rich: 120, boss: 300 },
  classSatBonus: { poor: 0, middle: 4, rich: 8, boss: 12 },
  housingQualityPenalty: 8,
  classHousingLevel: { poor: 1, middle: 2, rich: 3, boss: 3 },
  skillGainPerDay: 0.5,
  skillMax: 100,
  promotionSavings: 50,
  promotionSatThreshold: 70,
}
