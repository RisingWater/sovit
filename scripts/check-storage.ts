/**
 * 仓储（`docs/town.md` §三 / `docs/spec.md` §2.4）的 TS 侧自检。
 *
 * 为什么要单独测：仓储是**双边契约**（TS ↔ GDScript），而 golden 轨迹里
 * 库存从没逼近过上限 —— 也就是说 `npm test` 根本碰不到丢弃那条路。
 * 丢掉顺序错、两层口径搞反，都只有在 GDScript 对拍（也碰不到）时才可能暴露。
 *
 * 用法：node --experimental-strip-types scripts/check-storage.ts
 */
import { createInitialState } from '../src/engine/index.ts'
import { buildContext, ALL_GOODS } from '../src/engine/content/index.ts'
import { applyActions } from '../src/engine/actions.ts'
import { applyStorageCap, storageCapacity, storedTotal } from '../src/engine/systems/storage.ts'

let failed = 0
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok   ${msg}`)
  } else {
    console.error(`  FAIL ${msg}`)
    failed += 1
  }
}

const ctx = buildContext('v0.3')
const total = (s: ReturnType<typeof createInitialState>): number => storedTotal(s, ctx)
const cap = (s: ReturnType<typeof createInitialState>): number => storageCapacity(s, ctx)

// --- 1. 容量 = 城镇中心 1000；仓库要有工人才算
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  check(s.shops.some((x) => x.defId === 'town_center'), 'v0.3 开局自带一座城镇中心')
  check(cap(s) === 1000, `开局容量 = 城镇中心 1000（实际 ${cap(s)}）`)

  const wh = ctx.buildings['warehouse']!
  s.shops.push({
    id: 'warehouse#probe',
    defId: 'warehouse',
    owner: 'state',
    targetWorkers: 1,
    wage: 3,
    wageCap: 6,
    level: 1,
    active: true,
    profit: 0,
    skill: 50,
    planned: 0,
    toolBoost: 1,
  })
  // 没人上工 → 不算容量（用户要求"每个仓库需要一个工人"）
  s.residents.forEach((r) => (r.employed = false))
  check(cap(s) === 1000, `仓库没工人 → 不增加容量（实际 ${cap(s)}，仓库 1 级 +${wh.storage!.storage}）`)
  // 派一个人去仓库：`assignedWorkers` 认的是 jobShopId，光 employed=true 不算在岗
  s.residents[0]!.employed = true
  s.residents[0]!.jobShopId = 'warehouse#probe'
  check(cap(s) === 1000 + wh.storage!.storage, `仓库有 1 个工人 → +${wh.storage!.storage}（实际 ${cap(s)}）`)
}

// --- 2. 全局超限：按 baseValue 升序丢（先丢便宜的）
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  // 清空后只放两种货：一个便宜一个贵，总量超过容量
  for (const g of ctx.pack.goods) s.goods[g] = 0
  const cheap = [...ctx.pack.goods].sort(
    (a, b) => (ALL_GOODS[a]!.baseValue - ALL_GOODS[b]!.baseValue) || (a < b ? -1 : 1),
  )[0]!
  const pricey = [...ctx.pack.goods].sort(
    (a, b) => (ALL_GOODS[b]!.baseValue - ALL_GOODS[a]!.baseValue) || (a < b ? -1 : 1),
  )[0]!
  check(cheap !== pricey, `挑出最便宜(${cheap}) 与最贵(${pricey})`)
  const c = cap(s)
  s.goods[cheap] = c
  s.goods[pricey] = 40
  const logs = applyStorageCap(s, ctx, 1)
  check(total(s) === c, `总量被削回容量 ${c}（实际 ${total(s)}）`)
  check(s.goods[cheap] === c - 40, `丢的是便宜的 ${cheap}（${c} → ${s.goods[cheap]}）`)
  check(s.goods[pricey] === 40, `贵的 ${pricey} 一点没动（${s.goods[pricey]}）`)
  check(logs.length === 1 && logs[0]!.kind === 'storage', `写了一条 storage 日志：${logs[0]?.text}`)
}

// --- 3. 逐项软上限：先修剪单项，再判全局
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  for (const g of ctx.pack.goods) s.goods[g] = 0
  s.goods['wood'] = 250
  s.goods['coarse_bread'] = 50
  applyActions(s, ctx, [{ type: 'set_storage_caps', caps: { wood: 100 } }])
  check(s.government.storageCaps['wood'] === 100, 'set_storage_caps 写进 government.storageCaps')
  const logs = applyStorageCap(s, ctx, 1)
  check(s.goods['wood'] === 100, `木材被单项上限削到 100（实际 ${s.goods['wood']}）`)
  check(s.goods['coarse_bread'] === 50, `面包没被碰（实际 ${s.goods['coarse_bread']}）`)
  check(logs.some((l) => l.text.includes('单项上限')), '单项上限有独立日志')
  check(total(s) === 150, `总量 150，远低于容量 ${cap(s)} → 全局那一步不该再丢`)
}

// --- 4. 逐项上限**保护**其它物资：这正是用户要它的理由
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  for (const g of ctx.pack.goods) s.goods[g] = 0
  s.goods['wood'] = 1000            // 木材独自把容量占满
  s.goods['coarse_bread'] = 30      // 面包是当天新产的
  applyStorageCap(s, ctx, 1)
  check(s.goods['coarse_bread'] === 0, '不给木材设上限时：全局超限 → 面包被一起丢掉（存量按价格升序）')

  const s2 = createInitialState({ pack: 'v0.3', seed: 7 })
  for (const g of ctx.pack.goods) s2.goods[g] = 0
  s2.goods['wood'] = 1000
  s2.goods['coarse_bread'] = 30
  applyActions(s2, ctx, [{ type: 'set_storage_caps', caps: { wood: 900 } }])
  applyStorageCap(s2, ctx, 1)
  check(s2.goods['wood'] === 900, `设了木材上限 900 → 木材先被削到 900（实际 ${s2.goods['wood']}）`)
  check(s2.goods['coarse_bread'] === 30, `面包这次留住了（实际 ${s2.goods['coarse_bread']}）—— 这就是逐项软上限的用途`)
}

// --- 5. 没有仓储建筑就不丢（容量 0 ≠ 无限丢）
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  s.shops = s.shops.filter((x) => x.defId !== 'town_center')
  for (const g of ctx.pack.goods) s.goods[g] = 0
  s.goods['wood'] = 5000
  check(cap(s) === 0, '拆掉城镇中心后容量为 0')
  const logs = applyStorageCap(s, ctx, 1)
  check(s.goods['wood'] === 5000 && logs.length === 0, '容量 0 时不做任何丢弃')
}

console.log(failed === 0 ? '\n仓储自检通过 🎉' : `\n仓储自检失败 ❌（${failed} 项）`)
process.exit(failed === 0 ? 0 : 1)
