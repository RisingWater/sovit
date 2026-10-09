import type { GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'

// ---------------------------------------------------------------------------
// 用工分配
//
// 全国有：岗位全部由国家提供。按 shop 顺序，把未就业居民依次填满岗位。
// 未就业居民仍可动用储蓄消费，但失去工资收入（影响满意度）。
// ---------------------------------------------------------------------------

export function assignLabor(state: GameState, ctx: ContentContext): void {
  for (const r of state.residents) {
    r.employed = false
    r.jobShopId = undefined
  }

  let cursor = 0
  for (const shop of state.shops) {
    if (!shop.active) {
      shop.skill = 0
      continue
    }
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    const want = Math.max(0, Math.min(shop.targetWorkers, def.workers))
    const assigned: number[] = []
    while (assigned.length < want && cursor < state.residents.length) {
      const r = state.residents[cursor++]!
      r.employed = true
      r.jobShopId = shop.id
      assigned.push(r.skill)
    }
    shop.skill = assigned.length > 0
      ? assigned.reduce((a, b) => a + b, 0) / assigned.length
      : 0
  }
}

/** 某店铺当前实际到岗人数。 */
export function assignedWorkers(state: GameState, shopId: string): number {
  let n = 0
  for (const r of state.residents) if (r.jobShopId === shopId) n++
  return n
}
