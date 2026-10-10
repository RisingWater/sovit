import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { assignedWorkers } from './labor.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 生产（两阶段 · 公平配给）
//
// 阶段 1：算出每个建筑的计划批次与各投入的总需求。
// 阶段 2：对每种投入按「可用 / 总需求」得出统一配给系数，每个建筑取自身
//         各投入系数的最小值 → 所有建筑按同一比例缺料，**与建筑顺序无关**。
//
// 产出 = baseRate × (到岗/满员) × 熟练度系数 × level × 配给系数
// ---------------------------------------------------------------------------

function goodValue(gid: string, qty: number): number {
  return (ALL_GOODS[gid]?.baseValue ?? 0) * qty
}

/** 损耗：非耐储商品每日按 perishRate 折损（服务 perishRate=1 → 当天不结转）。 */
export function applySpoilage(state: GameState, ctx: ContentContext): void {
  for (const gid of ctx.pack.goods) {
    const def = ALL_GOODS[gid]
    if (!def || !def.perishRate || def.perishRate <= 0) continue
    const cur = state.goods[gid] ?? 0
    if (cur <= 0) continue
    state.goods[gid] = round2(cur * (1 - Math.min(1, def.perishRate)))
  }
}

interface Item {
  shop: GameState['shops'][number]
  nameZh: string
  workers: number
  desired: number
  /** 每批次投入（含燃料，统一记在 firewood）。 */
  inputPer: Record<string, number>
  output: Partial<Record<string, number>>
}

export function runProduction(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []

  // ---- 阶段 1：计划批次 + 投入需求 ----
  const items: Item[] = []
  const demand: Record<string, number> = {}

  for (const shop of state.shops) {
    if (!shop.active) {
      shop.profit = 0
      continue
    }
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    const recipe = ctx.recipes[def.recipe]
    if (!recipe) continue
    const workers = assignedWorkers(state, shop.id)
    if (workers <= 0) {
      shop.profit = 0
      continue
    }
    const staffing = workers / def.workers // 不封顶：工坊多派人就多产
    const skillEff = 0.6 + 0.4 * (shop.skill / 100)
    const desired = recipe.baseRate * staffing * skillEff * shop.level
    if (desired <= 0) continue

    const inputPer: Record<string, number> = {}
    for (const [g, q] of Object.entries(recipe.inputs)) {
      if (q && q > 0) inputPer[g] = (inputPer[g] ?? 0) + q
    }
    if (recipe.fuel && recipe.fuel > 0) {
      inputPer['firewood'] = (inputPer['firewood'] ?? 0) + recipe.fuel
    }

    items.push({ shop, nameZh: def.nameZh, workers, desired, inputPer, output: recipe.output })
    for (const [g, q] of Object.entries(inputPer)) {
      demand[g] = (demand[g] ?? 0) + q * desired
    }
  }

  // ---- 阶段 2：每种投入的统一配给系数 ----
  const factor: Record<string, number> = {}
  for (const g of Object.keys(demand)) {
    const avail = state.goods[g] ?? 0
    factor[g] = demand[g]! > 0 ? Math.min(1, avail / demand[g]!) : 1
  }

  // ---- 应用 ----
  for (const it of items) {
    let f = 1
    for (const g of Object.keys(it.inputPer)) f = Math.min(f, factor[g] ?? 1)
    const actual = it.desired * f

    // 消耗投入
    for (const [g, q] of Object.entries(it.inputPer)) {
      state.goods[g] = round2((state.goods[g] ?? 0) - q * actual)
    }
    // 产出
    let outputValue = 0
    const parts: string[] = []
    for (const [g, q] of Object.entries(it.output)) {
      if (!q) continue
      const produced = q * actual
      state.goods[g] = round2((state.goods[g] ?? 0) + produced)
      outputValue += goodValue(g, produced)
      parts.push(`${ALL_GOODS[g]?.nameZh ?? g} +${round2(produced)}`)
    }
    let inputCost = 0
    for (const [g, q] of Object.entries(it.inputPer)) inputCost += goodValue(g, q * actual)
    const wages = it.workers * it.shop.wage
    it.shop.profit = round2(outputValue - inputCost - wages)

    if (actual > 0.01 && parts.length > 0) {
      logs.push({ day, kind: 'production', text: `${it.nameZh} 产出 ${parts.join('、')}` })
    }
    if (actual < it.desired - 0.01) {
      logs.push({
        day,
        kind: 'shortage',
        text: `${it.nameZh} 因缺料减产（${round2(actual)}/${round2(it.desired)} 批次）`,
      })
    }
  }

  return logs
}
