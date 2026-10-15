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
//      超了就在日终结算时把货丢掉 —— **每种物资按同一比例削减**（见 §3.3）。
//   2. **每种物资的软上限**（玩家在「设置资源」里逐项设置，缺项 = 不限）。
//      先按它修剪，再按全局上限修剪。它的用途是：某一种货囤满自己的额度后
//      就不再挤占全局空间，别的物资才收得下（用户原话："防止某一个物资太多
//      导致其它物资无法收获"）。
//
// 两步都在 `applySpoilage` **之后**：先损耗、后判上限 —— 损耗腾出来的空间
// 可以救下本来会被丢掉的货。
//
// ⚠️ 2026-10 改：全局那一步原来是**按 `baseValue` 升序丢**（先丢便宜的）。
// 那条规则有个致命副作用 —— **食物恰好是最便宜的**（蔬菜 1.2 / 粗面包 1.3），
// 于是"开局资源 x2"（1960 > 容量 1000）第一晚就把 400 粗面包 + 174.6 蔬菜全丢了，
// 剩下的全是木材/石块/砖，接下来几天饿死一半人。用户原话："怎么能先盯着食物
// 丢弃，应该是各种物资平均丢弃吧。"现在改成**同比例削减**：谁也不被单独针对，
// 食物的份额原样保留（粮食安全由 `content/classes.json` 的日耗与产量决定，
// 而不是由丢弃规则决定）。
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

/** 向下取整到两位小数。 */
function floor2(value: number): number {
  return Math.floor(value * 100) / 100
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

  // ② 全局总量上限：**每种物资按同一比例削减**（确定性：只需一次乘 + 一次向下取整）
  const cap = storageCapacity(state, ctx)
  const total = storedTotal(state, ctx)
  if (cap > 0 && total > cap) {
    const keep = cap / total
    let after = 0
    for (const gid of ctx.pack.goods) {
      const cur = state.goods[gid] ?? 0
      if (cur <= 0) continue
      const next = floor2(cur * keep)
      state.goods[gid] = next
      after += next
    }
    logs.push({
      day,
      kind: 'storage',
      text: `仓储超限（${round2(total)} / ${round2(cap)}）：所有物资按 ${round2(keep * 100)}% 削减，共丢弃 ${round2(total - after)} 单位`,
    })
  }

  return logs
}
