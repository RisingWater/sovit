import type { GameState, LogEntry } from '../types.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 财政
//
// 政府支付工资 / 保障金（gross），同时按 taxRate 征收所得税；
// 差额（gross × (1-tax)）留在居民手中，再通过购买商品回流政府。
// 补贴（subsidy）预留。
// ---------------------------------------------------------------------------

export function payWages(state: GameState, day: number): LogEntry[] {
  const wageByShop = new Map<string, number>()
  for (const s of state.shops) wageByShop.set(s.id, s.wage)
  const taxRate = clamp(state.government.taxRate, 0, 0.95)
  const welfareGross = round2(ECONOMY.refWage * ECONOMY.welfareRate)

  let grossTotal = 0
  let taxTotal = 0
  for (const r of state.residents) {
    const employed = r.employed && r.jobShopId
    const gross = employed ? wageByShop.get(r.jobShopId!) ?? 0 : welfareGross
    const tax = gross * taxRate
    r.savings = round2(r.savings + gross - tax)
    grossTotal += gross
    taxTotal += tax
  }

  state.government.money = round2(state.government.money - grossTotal + taxTotal)
  const logs: LogEntry[] = [
    { day, kind: 'finance', text: `发放工资 ¥${round2(grossTotal)}` },
  ]
  if (taxTotal > 0.01) {
    logs.push({ day, kind: 'finance', text: `征收所得税 ¥${round2(taxTotal)}` })
  }
  return logs
}
