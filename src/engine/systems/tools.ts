import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { round2, round4 } from '../util.ts'
import { assignedWorkers } from './labor.ts'

// ---------------------------------------------------------------------------
// 工具（见 docs/technology.md §八）
//
// 工坊按**在岗工位**每日消耗工具，换来**产出 ×(1 + toolBonus)、投入不变**
// —— 单位原料的成品率提高，多出来的部分是"虚空产量"（灵感来自《戴森球计划》增产剂）。
//
// 消耗率 = `economy.tools.perWorkstation`（2026-10 用户："一个工人 10 天消耗 1 工具"
// → **0.1 件/人/日**）。农业 / 工业 / 矿场三类**一视同仁**：只要这栋建筑有配方、
// 且在岗有人，就按人头扣工具、按 `toolBonus` 放大产出（石制工具目前是 +25%）。
//
// 分配在**黎明一次性完成**（排产之前），当天不再变，所以只需把结果存进
// `shop.toolBoost`；生产小时只把它乘在**产出**上（投入一行不动）。
// ---------------------------------------------------------------------------

/** 装配了工具时的产出倍率；没装就是 1。 */
export function shopToolBoost(shop: { toolBoost?: number }): number {
  return shop.toolBoost && shop.toolBoost > 0 ? shop.toolBoost : 1
}

/**
 * 黎明：给产商品的工坊分配工具。
 *
 * - 只有**有 recipe 且在岗有人**的工坊才耗工具（产能建筑不产商品，加成无从施加）
 * - `economy.tools.order` 由低到高，这里从**最高级**往下找第一个够用的
 * - 工具不够时按 `state.shops` 顺序先到先得（确定性，便于 golden 对拍）
 */
export function allocateTools(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  const per = ECONOMY.tools.perWorkstation
  const order = ECONOMY.tools.order
  let boosted = 0

  for (const shop of state.shops) {
    shop.toolBoost = 1
    const def = ctx.buildings[shop.defId]
    if (!def || !def.recipe || !shop.active) continue
    const workers = assignedWorkers(state, shop.id)
    if (workers <= 0) continue

    const need = round2(per * workers)
    if (need <= 0) continue

    for (let i = order.length - 1; i >= 0; i--) {
      const gid = order[i]!
      const bonus = ALL_GOODS[gid]?.toolBonus
      if (!bonus || (state.goods[gid] ?? 0) < need) continue
      state.goods[gid] = round2((state.goods[gid] ?? 0) - need)
      state.ledgerToday.consumed[gid] = round2((state.ledgerToday.consumed[gid] ?? 0) + need)
      // 台账拆分表：工具是被**这栋建筑**吃掉的（资源页的悬停明细读它）
      const by = (state.ledgerToday.consumedBy[gid] ??= {})
      by[shop.defId] = round4((by[shop.defId] ?? 0) + need)
      shop.toolBoost = 1 + bonus
      boosted++
      break
    }
  }

  const totalNeed = round2(
    state.shops.reduce((a, s) => {
      const def = ctx.buildings[s.defId]
      const w = def && def.recipe && s.active ? assignedWorkers(state, s.id) : 0
      return a + w * per
    }, 0),
  )
  if (totalNeed > 0) {
    logs.push({
      day,
      kind: 'production',
      text: `工具：${boosted} 座工坊已装配（需求 ${totalNeed}/日）`,
    })
  }
  return logs
}
