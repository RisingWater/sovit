/**
 * TS 侧的 `demolish` 自检。
 *
 * 为什么要有这个：`demolish` 是**双边契约**（TS ↔ GDScript）。
 * GDScript 侧有 `worker_demolish_test.gd` 门槛，但 golden 轨迹不使用 demolish，
 * 所以 `npm test` 根本碰不到这条动作 —— 只有这一侧也测了，
 * "改了 TS 忘了改 GDScript"或者"TS 这边改坏了"才会当场暴露。
 *
 * 用法：node --experimental-strip-types scripts/check-demolish.ts
 */
import { createInitialState } from '../src/engine/index.ts'
import { buildContext } from '../src/engine/content/index.ts'
import { applyActions } from '../src/engine/actions.ts'
import { effectiveSlots } from '../src/engine/systems/labor.ts'

let failed = 0
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok   ${msg}`)
  } else {
    console.error(`  FAIL ${msg}`)
    failed += 1
  }
}

const state = createInitialState({ pack: 'v1.0', seed: 4242 })
const ctx = buildContext(state.pack)

// --- 1. 有效工位数：含升级加成，不是 maxWorkers 那个常数
const inst = ctx.buildings['research_institute']!
check(
  effectiveSlots(inst, 1) === (inst.maxWorkers ?? inst.workers),
  `L1 有效工位 == maxWorkers(${inst.maxWorkers})`,
)
const perLevel = inst.capacity?.slotsPerLevel ?? 0
check(perLevel > 0, `研究所确实有 slotsPerLevel(${perLevel})，这条断言才有意义`)
check(
  effectiveSlots(inst, 3) === (inst.maxWorkers ?? inst.workers) + perLevel * 2,
  `L3 有效工位 = 基础 + ${perLevel}×2 = ${effectiveSlots(inst, 3)}`,
)

// --- 2. set_workers 按**有效工位**截断（旧实现在这里会夹回 maxWorkers）
{
  const s2 = createInitialState({ pack: 'v1.0', seed: 4242 })
  // v1.0 开局没有研究所（它是研究出来的），手动塞一座
  const shop = {
    id: 'research_institute#probe',
    defId: 'research_institute',
    owner: 'state' as const,
    targetWorkers: inst.workers,
    wage: 3,
    wageCap: 6,
    level: 3,
    active: true,
    profit: 0,
    skill: 50,
    planned: 0,
    toolBoost: 1,
  }
  s2.shops.push(shop)
  const want = effectiveSlots(inst, 3)
  applyActions(s2, ctx, [{ type: 'set_workers', shopId: shop.id, value: want }])
  check(
    shop.targetWorkers === want,
    `L3 拖满 ${want} 人不会被夹回 maxWorkers(${inst.maxWorkers})（实际 ${shop.targetWorkers}）`,
  )
}

// --- 3. demolish：移除建筑 + 退建造资源
{
  const s3 = createInitialState({ pack: 'v1.0', seed: 4242 })
  const shop = s3.shops[0]!
  const def = ctx.buildings[shop.defId]!
  const before = { ...s3.goods }
  const applied = applyActions(s3, ctx, [{ type: 'demolish', shopId: shop.id }])
  check(applied[0]?.ok === true, 'demolish 返回 ok')
  check(!s3.shops.some((s) => s.id === shop.id), '建筑已从 state.shops 移除')
  let refundOk = true
  let anyRefund = false
  for (const [gid, qty] of Object.entries(def.buildCost ?? {})) {
    const n = Number(qty)
    if (!n || !ctx.goodSet.has(gid)) continue
    anyRefund = true
    const got = s3.goods[gid] ?? 0
    const want = (before[gid] ?? 0) + n
    if (Math.abs(got - want) > 0.005) {
      console.error(`       ${gid}: 期望 ${want}，实际 ${got}`)
      refundOk = false
    }
  }
  check(anyRefund, `该建筑有可退的 buildCost（${JSON.stringify(def.buildCost)}）`)
  check(refundOk, '建造资源按 buildCost 原样退回')

  // 拆不存在的建筑要明确失败，而不是静默成功
  const again = applyActions(s3, ctx, [{ type: 'demolish', shopId: shop.id }])
  check(again[0]?.ok === false, '重复拆同一座 → ok: false（建筑不存在）')
}

console.log(failed === 0 ? '\ndemolish 自检通过 🎉' : `\ndemolish 自检失败 ❌（${failed} 项）`)
process.exit(failed === 0 ? 0 : 1)
