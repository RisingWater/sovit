/**
 * 仓储（`docs/town.md` §三 / `docs/spec.md` §2.4）的 TS 侧自检。
 *
 * 为什么要单独测：仓储是**双边契约**（TS ↔ GDScript），而 golden 轨迹里
 * 库存从没逼近过上限 —— 也就是说 `npm test` 根本碰不到丢弃那条路。
 * 削减比例算错、两层口径搞反，都只有在 GDScript 对拍（也碰不到）时才可能暴露。
 *
 * 用法：node --experimental-strip-types scripts/check-storage.ts
 */
import { createInitialState } from '../src/engine/index.ts'
import { buildContext } from '../src/engine/content/index.ts'
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

// --- 1. 容量 = 城镇中心 2000；仓库要有工人才算
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  check(s.shops.some((x) => x.defId === 'town_center'), 'v0.3 开局自带一座城镇中心')
  check(cap(s) === 2000, `开局容量 = 城镇中心 2000（实际 ${cap(s)}）`)
  check(total(s) === 980, `v0.3 开局物资 980（实际 ${total(s)}）`)

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
  check(cap(s) === 2000, `仓库没工人 → 不增加容量（实际 ${cap(s)}，仓库 1 级 +${wh.storage!.storage}）`)
  // 派一个人去仓库：`assignedWorkers` 认的是 jobShopId，光 employed=true 不算在岗
  s.residents[0]!.employed = true
  s.residents[0]!.jobShopId = 'warehouse#probe'
  check(cap(s) === 2000 + wh.storage!.storage, `仓库有 1 个工人 → +${wh.storage!.storage}（实际 ${cap(s)}）`)
}

// --- 2. 全局超限：**所有物资按同一比例削减**（2026-10 改；旧规则是"先丢便宜的"）
{
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  for (const g of ctx.pack.goods) s.goods[g] = 0
  // 便宜的食物（蔬菜 1.2 / 粗面包 1.3）与贵的木材（1.5）各放一些，总量 2030 > 容量 2000
  const veg = 30
  const bread = 30
  const wood = 1970
  s.goods['vegetable'] = veg
  s.goods['coarse_bread'] = bread
  s.goods['wood'] = wood
  const c = cap(s)
  const keep = c / (veg + bread + wood)
  const logs = applyStorageCap(s, ctx, 1)

  check(total(s) <= c, `削减后总量不超容量 ${c}（实际 ${total(s)}）`)
  check(total(s) > c - 0.5, `削减到位，没有多丢（实际 ${total(s)}）`)
  // 这是本次修改的核心：旧规则按 baseValue 升序丢，蔬菜/面包会先被丢光
  check(s.goods['vegetable']! > 0 && s.goods['coarse_bread']! > 0, '食物没有被单独针对（旧规则下会被丢光）')
  check(
    Math.abs(s.goods['coarse_bread']! - bread * keep) < 0.02 &&
      Math.abs(s.goods['wood']! - wood * keep) < 0.02,
    `便宜的与贵的按同一比例削减（面包 ${s.goods['coarse_bread']} / 木材 ${s.goods['wood']}，比例 ${keep.toFixed(4)}）`,
  )
  check(logs.length === 1 && logs[0]!.kind === 'storage', `写了一条 storage 日志：${logs[0]?.text}`)
  check(logs[0]!.text.includes('削减'), '日志说明是"按比例削减"，不是只报一种货')
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
  // 不给木材设上限：木材独自把容量占满 → 面包也跟着按比例缩水
  const s = createInitialState({ pack: 'v0.3', seed: 7 })
  for (const g of ctx.pack.goods) s.goods[g] = 0
  s.goods['wood'] = 2000
  s.goods['coarse_bread'] = 30
  applyStorageCap(s, ctx, 1)
  check(
    s.goods['coarse_bread']! > 0 && s.goods['coarse_bread']! < 30,
    `不设上限时：全局超限 → 面包也跟着缩水（30 → ${s.goods['coarse_bread']}）`,
  )

  // 给木材设上限 1900：木材先被削到 1900，总量 1930 < 2000 → 面包一点没动
  const s2 = createInitialState({ pack: 'v0.3', seed: 7 })
  for (const g of ctx.pack.goods) s2.goods[g] = 0
  s2.goods['wood'] = 2000
  s2.goods['coarse_bread'] = 30
  applyActions(s2, ctx, [{ type: 'set_storage_caps', caps: { wood: 1900 } }])
  applyStorageCap(s2, ctx, 1)
  check(s2.goods['wood'] === 1900, `设了木材上限 1900 → 木材先被削到 1900（实际 ${s2.goods['wood']}）`)
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
