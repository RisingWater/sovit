import type { GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { clamp } from '../util.ts'

// ---------------------------------------------------------------------------
// 满意度
//
// 每名居民：foodScore（阶层食物满足）× wageScore（工资水平）× priceScore（价格压力）
// × employmentScore（就业）；再叠加住房调整：
//   - 房主（私有住房）：+ privateHousingSatBonus
//   - 非房主：− 租金负担
// ---------------------------------------------------------------------------

export function updateSatisfaction(
  state: GameState,
  ctx: ContentContext,
  foodScore: Record<string, number>,
  priceScoreMap: Record<string, number>,
): void {
  void ctx
  const { weights, refWage, satisfactionSmoothing } = ECONOMY
  const weightSum = weights.food + weights.wage + weights.price + weights.employment
  const wageByShop = new Map<string, number>()
  for (const s of state.shops) wageByShop.set(s.id, s.wage)
  const welfare = ECONOMY.refWage * ECONOMY.welfareRate
  const netIncome = ECONOMY.refWage * (1 - state.government.taxRate)
  const rentPressure = clamp(state.government.rent / Math.max(0.1, netIncome), 0, 1)

  for (const r of state.residents) {
    const food = foodScore[r.classId] ?? 1
    const price = priceScoreMap[r.classId] ?? 1
    const employed = r.employed && r.jobShopId !== undefined
    const wage = employed ? wageByShop.get(r.jobShopId!) ?? 0 : welfare
    const wageScore = clamp(wage / refWage, 0, 1.5) / 1.5
    const employmentScore = employed ? 1 : 0.5

    const base =
      (100 *
        (weights.food * food +
          weights.wage * wageScore +
          weights.price * price +
          weights.employment * employmentScore)) /
      weightSum

    const housingAdj = r.homeowner
      ? ECONOMY.privateHousingSatBonus
      : r.privateTenant
        ? ECONOMY.privateTenantSatBonus - rentPressure * ECONOMY.rentSatPenalty
        : -rentPressure * ECONOMY.rentSatPenalty

    const target = clamp(base + housingAdj, 0, 100)
    r.satisfaction = clamp(
      r.satisfaction + (target - r.satisfaction) * satisfactionSmoothing,
      0,
      100,
    )
  }
}
