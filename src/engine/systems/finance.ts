import type { GameState, LogEntry, TaxBracket } from '../types.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'
import { isPublicService } from './wages.ts'

// ---------------------------------------------------------------------------
// 财政
//
// 累进所得税：按可运行时调整的税表分档计征（工资与租金收入同规则）。
// 政府付 gross（工坊工资 / 工地出工报酬），按累进税率代扣，余额给居民。
// 失业且没有工程可做者收入为 0（失业保障金已取消，见 docs/construction.md 五）。
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

  let grossTotal = 0
  let publicWages = 0
  let taxTotal = 0
  for (const r of state.residents) {
    let gross: number
    if (r.constructionPay !== undefined && r.constructionPay > 0) {
      // 工地临时工：日薪已由建造结算按「当日实际投入的建造力」算出。
      // 非熟练临时工，不吃熟练度加成、也不受工坊工资上限约束。
      gross = r.constructionPay
    } else if (r.employed && r.jobShopId) {
      const wageBase = wageByShop.get(r.jobShopId) ?? 0
      // 技能挂钩收入：熟练者更富，形成阶层流动。
      gross = wageBase * (ECONOMY.skillIncomeBase + Math.min(ECONOMY.skillMax, r.skill) / 100)
      // 工坊工资上限：封顶每人实际工资。
      const cap = capByShop.get(r.jobShopId) ?? 0
      if (cap > 0) gross = Math.min(gross, cap)
    } else {
      // 失业且没有工程可做：无收入（失业保障金已取消，见 docs/construction.md 五）
      gross = 0
    }
    const tax = progressiveTax(gross, brackets)
    r.savings = round2(r.savings + gross - tax)
    grossTotal += gross
    if (r.jobShopId) {
      const jd = state.shops.find((x) => x.id === r.jobShopId)
      if (jd && isPublicService(jd.defId)) publicWages += gross
    }
    taxTotal += tax

    // 逐人记账：工资（含工地出工报酬）与代扣税。租与消费在后面两步append到同一份账目上。
    // 现在是"平均分配"，数值上个人账目汇总 == 阶层汇总；分开记录是为了将来
    // 能做差异化（按收入、按偏好、按距离…）时不必再动数据结构。
    r.account = {
      wage: round2(gross),
      tax: round2(tax),
      rent: 0,
      spent: 0,
      foodScore: 1,
      comfortScore: 1,
      priceScore: 1,
      hungry: false,
      bought: {},
    }
    state.ledgerToday.wages = round2(state.ledgerToday.wages + gross)
    state.ledgerToday.tax = round2(state.ledgerToday.tax + tax)
  }

  state.government.money = round2(state.government.money - grossTotal + taxTotal)
  state.ledgerToday.publicSubsidy = round2(state.ledgerToday.publicSubsidy + publicWages)
  const logs: LogEntry[] = [
    { day, kind: 'finance', text: `发放工资 ¥${round2(grossTotal)}` },
  ]
  if (taxTotal > 0.01) {
    logs.push({ day, kind: 'finance', text: `征收累进所得税 ¥${round2(taxTotal)}` })
  }
  return logs
}
