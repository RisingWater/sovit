import type { GameState } from '../types.ts'
import { ECONOMY } from '../config.ts'
import { clamp } from '../util.ts'

// ---------------------------------------------------------------------------
// 满意度
//
// 每名居民：foodScore（阶层食物满足）× wageScore（工资水平）× priceScore（价格压力）
// 目标值平滑逼近，避免数值抖动。
// ---------------------------------------------------------------------------

export function updateSatisfaction(
  state: GameState,
  foodScore: Record<string, number>,
  priceScoreMap: Record<string, number>,
): void {
  const { weights, refWage, satisfactionSmoothing } = ECONOMY
  const weightSum = weights.food + weights.wage + weights.price + weights.employment
  const wageByShop = new Map<string, number>()
  for (const s of state.shops) wageByShop.set(s.id, s.wage)
  const welfare = ECONOMY.refWage * ECONOMY.welfareRate

  for (const r of state.residents) {
    const food = foodScore[r.classId] ?? 1
    const price = priceScoreMap[r.classId] ?? 1
    const employed = r.employed && r.jobShopId !== undefined
    const wage = employed ? wageByShop.get(r.jobShopId!) ?? 0 : welfare
    const wageScore = clamp(wage / refWage, 0, 1.5) / 1.5
    const employmentScore = employed ? 1 : 0.5

    const target =
      (100 *
        (weights.food * food +
          weights.wage * wageScore +
          weights.price * price +
          weights.employment * employmentScore)) /
      weightSum

    r.satisfaction = clamp(
      r.satisfaction + (target - r.satisfaction) * satisfactionSmoothing,
      0,
      100,
    )
  }
}
