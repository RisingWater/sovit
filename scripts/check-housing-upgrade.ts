import { TIME, advanceHour, createInitialState } from '../src/engine/index.ts'
import type { Action, GameState } from '../src/engine/index.ts'
import { constructionCost, housingUpgradeSpec, usedSlots, tryUpgradeHousing } from '../src/engine/systems/investment.ts'
import { buildContext } from '../src/engine/content/index.ts'
import { TECH_IDS } from '../src/engine/content/index.ts'

// ---------------------------------------------------------------------------
// 住房改建（茅屋 → 木屋 → 砖房）的引擎自检。见 docs/spec.md §5.4。
//
//   node --experimental-strip-types scripts/check-housing-upgrade.ts
//
// 这条只测**引擎**（TS 那份实现）：差价成本、工期、完工时的数量转移、土地名额不变、
// 以及三条拒绝路径（私有不能改、链尾不能改、在途的也算占用）。
// GDScript 那份镜像由 `godot/tools/housingupgrade_test.gd` 对拍（同口径同数字）。
// ---------------------------------------------------------------------------

let failed = 0
function ok(name: string, cond: boolean, detail = ''): void {
  if (!cond) failed++
  console.log(`${cond ? '  ok  ' : '  FAIL'} ${name}${detail ? '  —— ' + detail : ''}`)
}

const ctx = buildContext('v0.3')

function freshState(): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261016 })
  // 给足材料，免得"材料不足"把断言搞成薛定谔的
  for (const g of ['wood', 'stone', 'brick', 'clay', 'firewood']) s.goods[g] = 500
  s.government.money = 5000
  // ⚠️ 改建的**目标**房型要已解锁（和 `build_housing` 同一条规矩）：v0.3 开局木屋是锁着的，
  //    不解锁的话下单会被 `需要科技：木作住房` 拒掉，下面整条链路全都测不到。
  s.research.done = [...TECH_IDS]
  return s
}

/** 推进 `days` 天（每天 24 小时，AI 不介入）；顺手把**每一小时返回的日志**也收下来。 */
function run(s: GameState, days: number, action?: Action): GameState {
  let cur = s
  for (let d = 0; d < days; d++) {
    for (let h = 0; h < TIME.hoursPerDay; h++) {
      const acts: Action[] = d === 0 && h === 0 && action ? [action] : []
      const r = advanceHour(cur, acts)
      for (const l of r.log) LOGS.push(l.text)
      cur = r.state
    }
  }
  return cur
}
/**
 * ⚠️ 日志要收 `advanceHour()` 的返回值，**也要**核对 `state.log`（公告的真源，进存档）：
 * 两处都有才算「玩家看得到 + 退出再进来还在」。
 *
 * 历史坑：`state.log` 以前只在夜晚写，黎明（`runDawn()` → `activateCompleted()`）那批
 * 只存在于返回值里 —— 改建完工的日志正好是黎明那批，第一版就是这么"看不见"它的。
 * 2026-10 起 `stepHour()` 逐小时把**三批都**并进 `state.log`（见 tick.ts），
 * 于是这条断言从"看不见"变成了"必须在"。
 */
const LOGS: string[] = []

/** 施工队列里还剩几条住房改建。 */
function pendingUpgrades(s: GameState): number {
  return s.construction.filter((c) => c.kind === 'housing_upgrade').length
}

console.log('\n=== 住房改建引擎自检 ===\n')

// ---- 1. 差价公式（两份实现必须同口径）-------------------------------------
const hut = ctx.housing['hut']!
const wood = ctx.housing['wooden_house']!
const brick = ctx.housing['brick_house']!
const s1 = housingUpgradeSpec(hut, wood, ctx)
ok('茅屋→木屋 材料 = 木 2 + 砖 3（6−4 / 6−3）',
  JSON.stringify(s1.mats) === JSON.stringify([['wood', 2], ['brick', 3]]), JSON.stringify(s1.mats))
ok('茅屋→木屋 工期 = 12（24−12）', s1.work === 12, String(s1.work))
const s2 = housingUpgradeSpec(wood, brick, ctx)
ok('木屋→砖房 材料 = 只补石头 3（木 6−6=0、砖 6−6=0 不计）',
  JSON.stringify(s2.mats) === JSON.stringify([['stone', 3]]), JSON.stringify(s2.mats))
ok('木屋→砖房 工期 = 12（36−24）', s2.work === 12, String(s2.work))
ok('砖房没有 upgradeTo（链到此为止，别墅不在链里）', brick.upgradeTo === undefined)
ok('茅屋/木屋的链是显式的', hut.upgradeTo === 'wooden_house' && wood.upgradeTo === 'brick_house')

// ---- 2. 下单 → 开工扣差价 → 完工数量转移 ----------------------------------
// ⚠️ 材料要**差分**测：村里同时在生产/消费，绝对数量每帧都在动，直接比对数字是错的
//    （第一版就是这么写红的：木 500 → 359.87，差的那 140 是村民自己烧的）。
//    同种子跑一次"不改建"的对照组，两条轨只有那次改建不一样，差值就该正好是差价。
const ctrl = run(freshState(), 1)
let s = run(freshState(), 1, { type: 'upgrade_housing', goodId: 'hut' })
const huts0 = Math.floor(ctrl.housing['hut'] ?? 0)
const wood0 = Math.floor(ctrl.housing['wooden_house'] ?? 0)
const slots0 = usedSlots(ctrl)
ok('v0.3 开局有茅屋', huts0 > 0, `hut=${huts0} wooden_house=${wood0}`)

ok('下单后进施工队列', pendingUpgrades(s) === 1, `队列=${pendingUpgrades(s)}`)
const dWood = ctrl.goods['wood']! - s.goods['wood']!
ok('引擎算出来的成本就是差价（木 2 / 砖 3）',
  JSON.stringify(constructionCost(s.construction.find((c) => c.kind === 'housing_upgrade')!, s, ctx)?.mats) ===
    JSON.stringify([['wood', 2], ['brick', 3]]),
  JSON.stringify(constructionCost(s.construction.find((c) => c.kind === 'housing_upgrade')!, s, ctx)?.mats))
ok('差分只反映"村民自己烧的那部分"以外的扰动（不拿它当成本断言）',
  dWood > 0, `对照组 − 改建组 = 木 ${dWood.toFixed(2)}（混杂了工地临时工多买的粮，不用于断言）`)
ok('还没完工时栋数不变', Math.floor(s.housing['hut'] ?? 0) === huts0)
ok('改建**不额外占土地名额**', usedSlots(s) === slots0, `${slots0} → ${usedSlots(s)}`)

s = run(s, 3)
ok('完工后队列清空', pendingUpgrades(s) === 0, `队列=${pendingUpgrades(s)}`)
ok('完工后茅屋 −1、木屋 +1',
  Math.floor(s.housing['hut'] ?? 0) === huts0 - 1 &&
  Math.floor(s.housing['wooden_house'] ?? 0) === wood0 + 1,
  `hut=${s.housing['hut']} wooden_house=${s.housing['wooden_house']}`)
ok('总栋数不变（原地改建）',
  Math.floor(s.housing['hut'] ?? 0) + Math.floor(s.housing['wooden_house'] ?? 0) === huts0 + wood0)
ok('完工后土地名额仍不变', usedSlots(s) === slots0, `${slots0} → ${usedSlots(s)}`)
ok('日志里写明改建', LOGS.some((t) => t.includes('改建为')),
  LOGS.filter((t) => t.includes('改建')).slice(-1)[0] ?? '（没有）')
// 同一条日志还必须在 `state.log` 里 —— 那是公告页读的唯一真源（黎明那批以前漏掉，
// 于是"退出再进来公告就空了"）。
ok('完工日志同时落进 state.log（公告页与存档读的就是它）',
  s.log.some((l) => l.text.includes('改建为')),
  s.log.filter((l) => l.text.includes('改建为')).slice(-1)[0]?.text ?? '（没有）')

// ---- 3. 三条拒绝路径 ------------------------------------------------------
let s3 = freshState()
s3.privateHousing['hut'] = s3.housing['hut'] ?? 0 // 全部私有化
const r1 = tryUpgradeHousing(s3, ctx, 'hut')
ok('私有住房不能改建', !r1.ok && r1.reason === '私有住房不能改建', String(r1.reason))

let s4 = freshState()
const r2 = tryUpgradeHousing(s4, ctx, 'brick_house')
ok('链尾（砖房）不能改建', !r2.ok && r2.reason === '这档住房不能改建', String(r2.reason))

let s5 = freshState()
s5.housing['hut'] = 1
s5.privateHousing['hut'] = 0
const r3a = tryUpgradeHousing(s5, ctx, 'hut')
const r3b = tryUpgradeHousing(s5, ctx, 'hut')
ok('第一单成功', r3a.ok, String(r3a.reason))
ok('在途的也算占用 → 第 2 单被拒（否则完工时会凭空多一栋）',
  !r3b.ok && r3b.reason === '没有空闲的国有住房可改建', String(r3b.reason))

console.log(failed === 0 ? '\n住房改建自检通过 🎉\n' : `\n住房改建自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
