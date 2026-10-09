import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { assignedWorkers } from './labor.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 生产
//
// 产出 = baseRate × (到岗/满员) × 熟练度系数 × level
// 原料或燃料不足时按最短板封顶。
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

export function runProduction(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []

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
      shop.profit = -0
      continue
    }

    const staffing = workers / def.workers // 不封顶：工坊多派人就多产
    const skillEff = 0.6 + 0.4 * (shop.skill / 100)
    const scale = staffing * skillEff * shop.level

    // 计划批次
    const planned = recipe.baseRate * scale
    if (planned <= 0) continue

    // 受原料 / 燃料限制的实际批次
    let limit = planned
    for (const [gid, qty] of Object.entries(recipe.inputs)) {
      if (!qty || qty <= 0) continue
      const avail = state.goods[gid] ?? 0
      limit = Math.min(limit, avail / qty)
    }
    if (recipe.fuel && recipe.fuel > 0) {
      const fuelAvail = state.goods['firewood'] ?? 0
      limit = Math.min(limit, fuelAvail / recipe.fuel)
    }
    const actual = Math.max(0, Math.min(planned, limit))

    // 消耗投入
    for (const [gid, qty] of Object.entries(recipe.inputs)) {
      if (!qty) continue
      state.goods[gid] = round2((state.goods[gid] ?? 0) - qty * actual)
    }
    if (recipe.fuel && recipe.fuel > 0) {
      state.goods['firewood'] = round2((state.goods['firewood'] ?? 0) - recipe.fuel * actual)
    }

    // 产出
    let outputValue = 0
    const parts: string[] = []
    for (const [gid, qty] of Object.entries(recipe.output)) {
      if (!qty) continue
      const produced = qty * actual
      state.goods[gid] = round2((state.goods[gid] ?? 0) + produced)
      outputValue += goodValue(gid, produced)
      parts.push(`${ALL_GOODS[gid]?.nameZh ?? gid} +${round2(produced)}`)
    }

    let inputCost = 0
    for (const [gid, qty] of Object.entries(recipe.inputs)) {
      if (!qty) continue
      inputCost += goodValue(gid, qty * actual)
    }
    if (recipe.fuel && recipe.fuel > 0) inputCost += goodValue('firewood', recipe.fuel * actual)

    const wages = workers * shop.wage
    shop.profit = round2(outputValue - inputCost - wages)

    // 只在产出有量时记日志，避免刷屏
    if (actual > 0.01 && parts.length > 0) {
      logs.push({ day, kind: 'production', text: `${def.nameZh} 产出 ${parts.join('、')}` })
    }
    if (actual < planned - 0.01) {
      logs.push({ day, kind: 'shortage', text: `${def.nameZh} 因缺料减产（${round2(actual)}/${round2(planned)} 批次）` })
    }
  }

  return logs
}
