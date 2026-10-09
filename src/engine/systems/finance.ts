import type { GameState, LogEntry, TaxBracket } from '../types.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 财政
//
// 累进所得税：按可运行时调整的税表分档计征（工资与租金收入同规则）。
// 政府付 gross（工资/保障金），按累进税率代扣，余额给居民。
// ---------------------------------------------------------------------------

/** 累进所得税：对一笔收入按税表分档计征。 */
export function progressiveTax(income: number, brackets: TaxBracket[]): number {
  let tax = 0
  let prev = 0
  for (const b of brackets) {
    const upper = b.upTo ?? Infinity
    const slice = Math.max(0, Math.min(income, upper) - prev)
    if (slice > 0) tax += slice * clamp(b.rate, 0, 0.95)
    prev = upper
    if (income <= upper) break
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
  const brackets = state.government.taxBrackets
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
    const tax = progressiveTax(gross, brackets)
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
