import type { BuildingDef, GameState, GoodID, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { assignedWorkers } from './labor.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 仓储（设计见 docs/town.md §三）
//
// 两层口径：
//   1. **全局总量上限** = 所有仓储建筑的容量之和（城镇中心 + 每座仓库）。
//      超了就在日终结算时把货丢掉 —— 先丢便宜的（baseValue 升序）。
//   2. **每种物资的软上限**（玩家在「设置资源」里逐项设置，缺项 = 不限）。
//      先按它修剪，再按全局上限修剪。它的用途是：某一种货囤满自己的额度后
//      就不再挤占全局空间，别的物资才收得下（用户原话："防止某一个物资太多
//      导致其它物资无法收获"）。
//
// 两步都在 `applySpoilage` **之后**：先损耗、后判上限 —— 损耗腾出来的空间
// 可以救下本来会被丢掉的货。
// ---------------------------------------------------------------------------

/** 一座建筑在某个等级下的仓储容量。 */
function shopStorage(def: BuildingDef, level: number): number {
  if (!def.storage) return 0
  return def.storage.storage + def.storage.storagePerLevel * Math.max(0, level - 1)
}

/**
 * 全局仓储容量。
 *
 * **需要工人的仓储建筑，没人在岗就不算容量** —— 用户要求"每个仓库目前需要有一个
 * 工人"；城镇中心 `workers = 0`，直接计入。
 */
export function storageCapacity(state: GameState, ctx: ContentContext): number {
  let cap = 0
  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    if (!def?.storage) continue
    if (def.workers > 0 && assignedWorkers(state, shop.id) < 1) continue
    cap += shopStorage(def, shop.level)
  }
  return round2(cap)
}

/** 当前库存总量（该 pack 的全部商品之和）。 */
export function storedTotal(state: GameState, ctx: ContentContext): number {
  let n = 0
  for (const gid of ctx.pack.goods) n += state.goods[gid] ?? 0
  return round2(n)
}

/** 丢弃顺序：`baseValue` 升序（先丢便宜的），并列按 goodId 字典序。 */
function discardOrder(ctx: ContentContext): string[] {
  return [...ctx.pack.goods].sort((a, b) => {
    const va = ALL_GOODS[a]?.baseValue ?? 0
    const vb = ALL_GOODS[b]?.baseValue ?? 0
    if (va !== vb) return va - vb
    return a < b ? -1 : a > b ? 1 : 0
  })
}

function nameOf(gid: string): string {
  return ALL_GOODS[gid]?.nameZh ?? gid
}

/**
 * 日终丢弃。返回日志（调用方负责并进当日 logs）。
 *
 * ⚠️ 在建工程的材料在**工作小时**开工时（`applyConstructionHours`）就已经从 `goods`
 * 扣走了，而它在夜晚顺序里排在日终丢弃之前 —— 所以不会出现"把工地材料丢了导致工地卡死"。
 */
export function applyStorageCap(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []

  // ① 逐项软上限
  const caps = state.government.storageCaps ?? {}
  for (const gid of ctx.pack.goods) {
    const lim = caps[gid as GoodID]
    if (lim === undefined) continue
    const cur = state.goods[gid] ?? 0
    if (cur <= lim) continue
    const lost = round2(cur - lim)
    state.goods[gid] = round2(lim)
    logs.push({
      day,
      kind: 'storage',
      text: `${nameOf(gid)} 超过单项上限 ${lim}，丢弃 ${lost} 单位`,
    })
  }

  // ② 全局总量上限
  const cap = storageCapacity(state, ctx)
  let over = round2(storedTotal(state, ctx) - cap)
  if (cap > 0 && over > 0) {
    for (const gid of discardOrder(ctx)) {
      if (over <= 0) break
      const cur = state.goods[gid] ?? 0
      if (cur <= 0) continue
      const take = round2(Math.min(cur, over))
      state.goods[gid] = round2(cur - take)
      over = round2(over - take)
      logs.push({ day, kind: 'storage', text: `仓储超限，丢弃 ${take} 单位 ${nameOf(gid)}` })
    }
  }

  return logs
}
