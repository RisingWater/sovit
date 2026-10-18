import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { round2, round4 } from '../util.ts'
import { assignedWorkers } from './labor.ts'
import { techBonuses } from './tech_bonus.ts'

// ---------------------------------------------------------------------------
// 工具（见 docs/technology.md §八）
//
// 工坊按**在岗工位**每日消耗工具，换来**产出 ×(1 + toolBonus)、投入不变**
// —— 单位原料的成品率提高，多出来的部分是"虚空产量"（灵感来自《戴森球计划》增产剂）。
//
// 消耗率按**每种工具自己的耐久**算（2026-10 用户："铁制工具更耐用，15 天消耗一个"）：
//
//     每工人每日消耗 = 1 / (durabilityDays × (1 + 工具寿命科技加成))
//
//   · 石制工具 durabilityDays = 10 → 0.1 件/人/日（= 原来 `perWorkstation` 的 0.1）
//   · 铁制工具 durabilityDays = 15 → 0.0667 件/人/日
//   · 工具寿命科技（淬火 +20% / 精炼 +50%）**取最高**、不叠加（`tech_bonus.ts::MAX_KEYS`）
//   · 没写 `durabilityDays` 的老内容退回 `economy.tools.perWorkstation`（行为不变）
//
// 农业 / 工业 / 矿场三类**一视同仁**：只要这栋建筑有配方、且在岗有人，就按人头扣工具、
// 按 `toolBonus` 放大产出（石制 +25%、铁制 +60%）。
//
// 分配在**黎明一次性完成**（排产之前），当天不再变，所以只需把结果存进
// `shop.toolBoost`；生产小时只把它乘在**产出**上（投入一行不动）。
// ---------------------------------------------------------------------------

/** 装配了工具时的产出倍率；没装就是 1。 */
export function shopToolBoost(shop: { toolBoost?: number }): number {
  return shop.toolBoost && shop.toolBoost > 0 ? shop.toolBoost : 1
}

/**
 * 某件工具**每工人每天**的消耗量（= 1 / 有效天数）。
 *
 * `toolLife` 是科技加成（取最高），`0.2` = 寿命 +20% → 消耗 ÷1.2。
 * 没写 `durabilityDays` 的工具退回 `economy.tools.perWorkstation`。
 * GDScript 侧同口径：`sim_core.gd::_tool_per_worker()`。
 */
export function toolPerWorker(state: GameState, ctx: ContentContext, goodId: string): number {
  const def = ALL_GOODS[goodId]
  const days = def?.durabilityDays
  if (!days || days <= 0) return ECONOMY.tools.perWorkstation
  const life = 1 + techBonuses(state, ctx).toolLife
  return 1 / (days * life)
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
  const order = ECONOMY.tools.order
  let boosted = 0
  let spent = 0

  for (const shop of state.shops) {
    shop.toolBoost = 1
    const def = ctx.buildings[shop.defId]
    if (!def || !def.recipe || !shop.active) continue
    const workers = assignedWorkers(state, shop.id)
    if (workers <= 0) continue

    for (let i = order.length - 1; i >= 0; i--) {
      const gid = order[i]!
      const bonus = ALL_GOODS[gid]?.toolBonus
      if (!bonus) continue
      const need = round2(toolPerWorker(state, ctx, gid) * workers)
      if (need <= 0 || (state.goods[gid] ?? 0) < need) continue
      state.goods[gid] = round2((state.goods[gid] ?? 0) - need)
      state.ledgerToday.consumed[gid] = round2((state.ledgerToday.consumed[gid] ?? 0) + need)
      // 台账拆分表：工具是被**这栋建筑**吃掉的（资源页的悬停明细读它）
      const by = (state.ledgerToday.consumedBy[gid] ??= {})
      by[shop.defId] = round4((by[shop.defId] ?? 0) + need)
      shop.toolBoost = 1 + bonus
      boosted++
      spent = round2(spent + need)
      break
    }
  }

  if (spent > 0) {
    logs.push({
      day,
      kind: 'production',
      text: `工具：${boosted} 座工坊已装配（消耗 ${spent}/日）`,
    })
  }
  return logs
}
