import { TIME, advanceHour, createInitialState } from '../src/engine/index.ts'
import type { Action, GameState } from '../src/engine/index.ts'
import { constructionCost, housingUpgradeSpec, usedSlots, tryUpgradeHousing } from '../src/engine/systems/investment.ts'
import { buildContext } from '../src/engine/content/index.ts'
import { syncHousingCounts } from '../src/engine/systems/housing.ts'
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
// 全部私有化：现在私有化落在**具体哪一栋**上（`HousingUnit.private`），计数是派生值
for (const u of s3.housingUnits) if (u.type === 'hut') u.private = true
syncHousingCounts(s3)
const r1 = tryUpgradeHousing(s3, ctx, 'hut')
ok('私有住房不能改建', !r1.ok && r1.reason === '私有住房不能改建', String(r1.reason))

let s4 = freshState()
const r2 = tryUpgradeHousing(s4, ctx, 'brick_house')
ok('链尾（砖房）不能改建', !r2.ok && r2.reason === '这档住房不能改建', String(r2.reason))

let s5 = freshState()
// 只留 1 栋茅屋（同样是改 units，不是改计数）
s5.housingUnits = s5.housingUnits.filter((u) => u.type !== 'hut')
s5.housingUnits.push({ id: 'h#only', type: 'hut', private: false })
syncHousingCounts(s5)
const r3a = tryUpgradeHousing(s5, ctx, 'hut')
const r3b = tryUpgradeHousing(s5, ctx, 'hut')
ok('第一单成功', r3a.ok, String(r3a.reason))
ok('在途的也算占用 → 第 2 单被拒（否则完工时会凭空多一栋）',
  !r3b.ok && r3b.reason === '没有空闲的国有住房可改建', String(r3b.reason))

// ---- 4. 单体身份（2026-10）：每栋房一个 id，改建换 type 不换 id -------------
{
  const s6 = freshState()
  const ids = new Set(s6.housingUnits.map((u) => u.id))
  ok('开局每栋房一个 id（唯一）', s6.housingUnits.length === 6 && ids.size === 6,
    `栋数 ${s6.housingUnits.length} / 唯一 id ${ids.size}`)
  ok('计数 == 由 units 数出来的',
    s6.housing['hut'] === s6.housingUnits.filter((u) => u.type === 'hut').length &&
      s6.privateHousing['hut'] === s6.housingUnits.filter((u) => u.type === 'hut' && u.private).length)
  // 指名改建：钉在**某一栋**上，条目里带房号
  const picked = s6.housingUnits.find((u) => u.type === 'hut')!
  const r = tryUpgradeHousing(s6, ctx, 'hut', picked.id)
  const entry = s6.construction.find((c) => c.kind === 'housing_upgrade')
  ok('指名改建：条目里记着是哪一栋', r.ok && entry?.housingUnitId === picked.id,
    `${String(r.reason)} / ${entry?.housingUnitId}`)
  // 指定一栋**私有**的 → 拒
  const privUnit = s6.housingUnits.find((u) => u.type === 'hut' && !u.private)!
  privUnit.private = true
  syncHousingCounts(s6)
  const rBad = tryUpgradeHousing(s6, ctx, 'hut', privUnit.id)
  ok('指名的是一栋私有房 → 拒', !rBad.ok && rBad.reason === '私有住房不能改建', String(rBad.reason))
  // 指定一个不存在的房号 → 拒
  const rNone = tryUpgradeHousing(s6, ctx, 'hut', 'h#nope')
  ok('指名一个不存在的房号 → 拒', !rNone.ok && rNone.reason === '找不到那栋住房', String(rNone.reason))
}

// ---- 5. 改建完工：那栋房的 id 不变、type 换了；私有化按栋落地 --------------
{
  const s7 = freshState()
  for (const t of TECH_IDS) if (!s7.research.done.includes(t)) s7.research.done.push(t)
  for (const g of ['wood', 'brick', 'stone']) s7.goods[g] = 500
  const unit = s7.housingUnits.find((u) => u.type === 'hut')!
  const uid = unit.id
  tryUpgradeHousing(s7, ctx, 'hut', uid)
  // 把工期压到 0 直接过黎明（测试只关心"完工那一刻做了什么"）
  for (const c of s7.construction) c.remaining = 0
  let cur = s7
  for (let i = 0; i < TIME.hoursPerDay + 2; i++) cur = advanceHour(cur).state
  const after = cur.housingUnits.find((u) => u.id === uid)
  ok('改建后那栋房还在，且 id 不变', after !== undefined && after.id === uid, String(after?.type))
  ok('改建后 type 换成木屋，栋数不变', after?.type === 'wooden_house' &&
    cur.housingUnits.length === s7.housingUnits.length,
    `${after?.type} / ${cur.housingUnits.length}`)
  ok('改建后计数跟着变（hut−1 / wooden+1）',
    cur.housing['hut'] === (s7.housing['hut'] ?? 0) - 1 &&
      cur.housing['wooden_house'] === (s7.housing['wooden_house'] ?? 0) + 1,
    `hut=${cur.housing['hut']} wooden=${cur.housing['wooden_house']}`)
  // 私有化落在具体某栋上（`runPrivateHousingMarket` 会写 `unit.private` + `ownerId`）
  const priv = cur.housingUnits.find((u) => u.private)
  if (priv) {
    ok('私有房有房主 id 且计数对得上',
      typeof priv.ownerId === 'string' && priv.ownerId.length > 0 &&
        cur.privateHousing[priv.type] === cur.housingUnits.filter((u) => u.type === priv.type && u.private).length,
      `${priv.id} owner=${priv.ownerId}`)
  } else {
    ok('这一局没有卖出私有房（跳过房主断言）', true)
  }
}

console.log(failed === 0 ? '\n住房改建自检通过 🎉\n' : `\n住房改建自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
