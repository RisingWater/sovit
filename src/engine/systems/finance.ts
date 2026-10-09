import type { GameState, LogEntry } from '../types.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 财政
//
// 累进所得税：按边际分档，收入越高税率越高（工资与租金收入同规则）。
// 政府付 gross（工资/保障金），按累进税率代扣，余额给居民。
// ---------------------------------------------------------------------------

/** 累进所得税：对一笔收入按边际分档征税。 */
export function progressiveTax(income: number, baseRate: number): number {
  const { thresholds, rateMultipliers } = ECONOMY.progressiveTax
  let tax = 0
  let prev = 0
  for (let i = 0; i < rateMultipliers.length; i++) {
    const upper = i < thresholds.length ? thresholds[i]! : Infinity
    const slice = Math.max(0, Math.min(income, upper) - prev)
    if (slice <= 0) break
    const rate = Math.min(0.95, baseRate * rateMultipliers[i]!)
    tax += slice * rate
    prev = upper
  }
  return round2(tax)
}

export function payWages(state: GameState, day: number): LogEntry[] {
  const wageByShop = new Map<string, number>()
  const capByShop = new Map<string, number>()
  for (const s of state.shops) {
    wageByShop.set(s.id, s.wage)
    capByShop.set(s.id, s.wageCap)
  }
  const baseRate = clamp(state.government.taxRate, 0, 0.95)
  const welfareGross = round2(ECONOMY.refWage * ECONOMY.welfareRate)

  let grossTotal = 0
  let taxTotal = 0
  for (const r of state.residents) {
    const employed = r.employed && r.jobShopId
    const wageBase = employed ? wageByShop.get(r.jobShopId!) ?? 0 : welfareGross
    // 技能挂钩收入：熟练者更富，形成阶层流动。
    let gross = employed
      ? wageBase * (ECONOMY.skillIncomeBase + Math.min(ECONOMY.skillMax, r.skill) / 100)
      : wageBase
    // 工坊工资上限：封顶每人实际工资。
    if (employed) {
      const cap = capByShop.get(r.jobShopId!) ?? 0
      if (cap > 0) gross = Math.min(gross, cap)
    }
    const tax = progressiveTax(gross, baseRate)
    r.savings = round2(r.savings + gross - tax)
    grossTotal += gross
    taxTotal += tax
  }

  state.government.money = round2(state.government.money - grossTotal + taxTotal)
  const logs: LogEntry[] = [
    { day, kind: 'finance', text: `发放工资 ¥${round2(grossTotal)}` },
  ]
  if (taxTotal > 0.01) {
    logs.push({ day, kind: 'finance', text: `征收累进所得税 ¥${round2(taxTotal)}` })
  }
  return logs
}
