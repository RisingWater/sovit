import { TIME, advanceHour, createInitialState } from '../src/engine/index.ts'
import type { Action, GameState } from '../src/engine/index.ts'
import {
  applyConstructionHours,
  cancelConstruction,
  moveConstruction,
  tryBuild,
  usedSlots,
} from '../src/engine/systems/investment.ts'
import {
  activateResearch,
  applyResearchHours,
  cancelResearch,
  moveResearch,
  startResearch,
} from '../src/engine/systems/research.ts'
import { buildContext, TECH_IDS } from '../src/engine/content/index.ts'

// ---------------------------------------------------------------------------
// 两条队列的引擎自检：**建造队列**（调序 / 撤单）+ **研究队列**（调序 / 撤单）。
//
//   node --experimental-strip-types scripts/check-queues.ts
//
// 两条队列是同构的（先进先出、队首先吃到当日产能、材料在**开工那一刻**才扣），
// 契约也共用一套（docs/spec.md §9.8 施工 / §10.7 研究）：
//   1. 调序只改顺序：不重算 `remaining`、不动 `started`、不退料
//   2. 调序真的改变"谁先吃到产能"（产能只投给队首）
//   3. 撤单退料：没开工退 0（没扣过）；开工了按 `remaining / totalRequired` 退
//   4. 取消要进公告（`state.log`）；施工那边还要把土地名额放出来
//
// GDScript 那份镜像由 `godot/tools/queue_test.gd` 对拍（同口径、同数字）。
// ---------------------------------------------------------------------------

let failed = 0
function ok(name: string, cond: boolean, detail = ''): void {
  if (!cond) failed++
  console.log(`${cond ? '  ok  ' : '  FAIL'} ${name}${detail ? '  —— ' + detail : ''}`)
}

const ctx = buildContext('v0.3')

/** 三座同价同工期的建筑（木 6 / 石 3，36 建造力）—— 用它仨，差异只反映顺序。 */
const A = 'pastry_shop'
const B = 'porcelain_works'
const C = 'sugar_works'

function freshState(): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261016 })
  for (const g of ['wood', 'stone', 'brick', 'clay', 'firewood']) s.goods[g] = 5000
  s.government.money = 50000
  // 三座都在科技后面：不解锁的话下单会被 `需要科技` 拒掉，整条链路测不到
  s.research.done = [...TECH_IDS]
  return s
}

const ids = (s: GameState): string[] => s.construction.map((c) => c.buildingId ?? c.id)

console.log('\n=== 建造队列引擎自检 ===\n')

// ---- 1. 下单顺序 = 队列顺序，调序只挪位置 --------------------------------
const s1 = freshState()
for (const id of [A, B, C]) {
  const r = tryBuild(s1, ctx, id)
  ok(`下单 ${id}`, r.ok, String(r.reason ?? ''))
}
ok('队列顺序 = 下单顺序', JSON.stringify(ids(s1)) === JSON.stringify([A, B, C]), ids(s1).join(' → '))
ok('每条 id 唯一', new Set(s1.construction.map((c) => c.id)).size === 3)

const idB = s1.construction[1]!.id
const workBefore = s1.construction.map((c) => c.totalRequired).join(',')
const startedBefore = s1.construction.filter((c) => c.started).length
const goodsBefore = JSON.stringify(s1.goods)
ok('上移一条：B 到队首',
  moveConstruction(s1, idB, -1).ok && s1.construction[0]!.id === idB, ids(s1).join(' → '))
const up1 = moveConstruction(s1, idB, -1)
ok('再上移 → 拒绝（已经是队首）', !up1.ok && up1.reason === '已经是队首', String(up1.reason))
ok('下移两次：B 回队尾',
  moveConstruction(s1, idB, 1).ok && moveConstruction(s1, idB, 1).ok && s1.construction[2]!.id === idB,
  ids(s1).join(' → '))
const down1 = moveConstruction(s1, idB, 1)
ok('再下移 → 拒绝（已经是队尾）', !down1.ok && down1.reason === '已经是队尾', String(down1.reason))
const gone = moveConstruction(s1, 'c#99-不存在', -1)
ok('不存在的 id → 拒绝', !gone.ok && gone.reason === '该工程已不在队列里', String(gone.reason))
const zero = moveConstruction(s1, idB, 0)
ok('delta = 0 → 拒绝（没有移动）', !zero.ok && zero.reason === '没有移动', String(zero.reason))
ok('调序不重算工期', s1.construction.map((c) => c.totalRequired).join(',') === workBefore)
ok('调序不动 started', s1.construction.filter((c) => c.started).length === startedBefore)
ok('调序不退料', JSON.stringify(s1.goods) === goodsBefore)

// ---- 2. 调序真的改变"谁先吃到建造力" --------------------------------------
// 把 B 挪到队首（两次上移），然后投 10 点产能：只有队首该动。
moveConstruction(s1, idB, -1)
moveConstruction(s1, idB, -1)
ok('B 已在队首', s1.construction[0]!.id === idB, ids(s1).join(' → '))
const wood0 = s1.goods['wood']!
const stone0 = s1.goods['stone']!
s1.constructionRateToday = 10
const hourLogs = applyConstructionHours(s1, ctx, 1.0)
ok('产能只投给队首：B 剩 26（36 − 10）', s1.construction[0]!.remaining === 26,
  String(s1.construction[0]!.remaining))
ok('后面的两条一点没动',
  s1.construction[1]!.remaining === 36 && s1.construction[2]!.remaining === 36,
  `${s1.construction[1]!.remaining} / ${s1.construction[2]!.remaining}`)
ok('只有队首写了「开工」日志', hourLogs.length === 1 && hourLogs[0]!.text.includes('开工'),
  hourLogs.map((l) => l.text).join(' | '))
ok('材料在开工那一刻才扣（木 6 / 石 3）',
  s1.goods['wood'] === wood0 - 6 && s1.goods['stone'] === stone0 - 3,
  `木 ${wood0} → ${s1.goods['wood']}，石 ${stone0} → ${s1.goods['stone']}`)

// ---- 3. 取消：没开工退 0，开工了按"还没干完的那份"退 ------------------------
const idC = s1.construction[2]!.id
const woodNotStarted = s1.goods['wood']!
const rUnstarted = cancelConstruction(s1, ctx, idC)
ok('取消未开工的：成功', rUnstarted.ok, String(rUnstarted.reason ?? ''))
ok('取消未开工的：一分料都不退（它**没扣过**）',
  rUnstarted.refund.length === 0 && s1.goods['wood'] === woodNotStarted,
  `退 ${JSON.stringify(rUnstarted.refund)}`)
ok('取消未开工的：文案说清"还没开工"',
  rUnstarted.text.includes('还没开工'), rUnstarted.text)
ok('取消未开工的：队列短一条', s1.construction.length === 2, String(s1.construction.length))

const head = s1.construction[0]!
const woodBefore = s1.goods['wood']!
const stoneBefore = s1.goods['stone']!
const rStarted = cancelConstruction(s1, ctx, head.id)
// 已扣：木 6 / 石 3；还剩 26/36 → 退 6×26/36 = 4.33、3×26/36 = 2.17
ok('取消已开工的：按 remaining / totalRequired 退',
  JSON.stringify(rStarted.refund) === JSON.stringify([['wood', 4.33], ['stone', 2.17]]),
  JSON.stringify(rStarted.refund))
ok('退回的料真的进了国库',
  s1.goods['wood'] === woodBefore + 4.33 && s1.goods['stone'] === stoneBefore + 2.17,
  `木 ${woodBefore} → ${s1.goods['wood']}，石 ${stoneBefore} → ${s1.goods['stone']}`)
ok('报告里写明已投入 10 / 36', rStarted.used === 10 && rStarted.total === 36,
  `${rStarted.used} / ${rStarted.total}`)
ok('文案写明进度与退回明细',
  rStarted.text.includes('28%') && rStarted.text.includes('退回'), rStarted.text)
ok('取消后队列里没有它了', !s1.construction.some((c) => c.id === head.id))
const again = cancelConstruction(s1, ctx, head.id)
ok('重复取消 → 拒绝', !again.ok && again.reason === '该工程已不在队列里', String(again.reason))

// ---- 4. 走完整的黎明：命令次日生效 + 进公告 --------------------------------
let s2 = freshState()
for (const id of [A, B, C]) tryBuild(s2, ctx, id)
s2.hour = TIME.dawnHour
const movedId = s2.construction[2]!.id
const rMove = advanceHour(s2, [{ type: 'move_construction', id: movedId, delta: -1 }])
ok('调序在黎明生效（命令不是立刻生效的）',
  rMove.state.construction[1]!.id === movedId,
  rMove.state.construction.map((c) => c.id).join(' → '))
ok('applied 里报 ok',
  rMove.applied.some((a) => a.type === 'move_construction' && a.ok), JSON.stringify(rMove.applied))

let s3 = rMove.state
s3.hour = TIME.dawnHour
const rCancel = advanceHour(s3, [{ type: 'cancel_construction', id: movedId }])
const cancelLogs = rCancel.state.log.filter((l) => l.text.includes('取消'))
ok('取消写进 state.log（公告页与存档读的就是它）', cancelLogs.length > 0,
  cancelLogs.map((l) => l.text).slice(-1)[0] ?? '（没有）')
ok('applied 的 reason 就是那句话',
  rCancel.applied.some((a) => a.type === 'cancel_construction' && a.ok &&
    (a.reason ?? '').includes('取消')), JSON.stringify(rCancel.applied))

// ---- 5. 取消在建工程 → 土地名额跟着放出来 ----------------------------------
const s4 = freshState()
const slots0 = usedSlots(s4)
tryBuild(s4, ctx, A)
ok('在建工程占土地名额', usedSlots(s4) === slots0 + 1, `${slots0} → ${usedSlots(s4)}`)
cancelConstruction(s4, ctx, s4.construction[0]!.id)
ok('取消后名额放出来', usedSlots(s4) === slots0, `${slots0} → ${usedSlots(s4)}`)

// ===========================================================================
// 研究队列（与建造队列同构，见 docs/spec.md §10.7）
// ===========================================================================

/**
 * 三项开局就能研究的科技。
 *
 * ⚠️ 2026-10：「薪柴」改成依赖「石作」了（用户："可以让薪材依赖石作，这样后续不会有
 * 一次依赖 3-4 个科技的科技出现"），所以下面那些"三项一起排"的用例改用
 * 真正无前置的「揘土」替代；要用薪柴的地方先把石作研完。
 */
const T1 = 'stonework'   // 木 15
const T2 = 'digging'     // 木 15
const T3 = 'hunting'     // 木（无前置）

/** 研究用的村子：木材管够、科技一个没完成（不然没得排）。 */
function freshResearch(): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261017 })
  s.goods['wood'] = 5000
  s.research.done = []
  return s
}

const techs = (s: GameState): string[] => s.research.queue.map((p) => p.id)

console.log('\n--- 研究队列 ---')
const r1 = freshResearch()
for (const t of [T1, T2, T3]) {
  const r = startResearch(r1, ctx, t)
  ok(`排入研究 ${t}`, r.ok, String(r.reason ?? ''))
}
ok('队列顺序 = 下单顺序', JSON.stringify(techs(r1)) === JSON.stringify([T1, T2, T3]), techs(r1).join(' → '))

const q1 = r1.research.queue[1]!
const rup1 = moveResearch(r1, q1.id, -1)
ok('上移一条：第 2 项到队首', rup1.ok && r1.research.queue[0]!.id === q1.id, techs(r1).join(' → '))
const rup2 = moveResearch(r1, q1.id, -1)
ok('队首再上移 → 拒绝（已经是队首）', !rup2.ok && rup2.reason === '已经是队首', String(rup2.reason))
moveResearch(r1, q1.id, 1)
moveResearch(r1, q1.id, 1)
const dn = moveResearch(r1, q1.id, 1)
ok('挪回队尾后下移 → 拒绝（已经是队尾）', !dn.ok && dn.reason === '已经是队尾', String(dn.reason))
const zg = moveResearch(r1, q1.id, 0)
ok('delta = 0 → 拒绝（没有移动）', !zg.ok && zg.reason === '没有移动', String(zg.reason))
const miss = moveResearch(r1, 'nope', -1)
ok('不在队列里 → 拒绝', !miss.ok && miss.reason === '不在研究队列中', String(miss.reason))
ok('调序不重算进度', r1.research.queue.every((p) => p.totalRequired === 20),
  r1.research.queue.map((p) => p.totalRequired).join(','))
ok('调序不退料', r1.goods['wood'] === 5000, String(r1.goods['wood']))
ok('调序不动 started', r1.research.queue.every((p) => !p.started))

// 调序真的改变"谁先吃到科研力"：把第 2 项挪到队首，投 8 点 → 只有它动
moveResearch(r1, q1.id, -1)
const wood0r = r1.goods['wood']!
r1.researchRateToday = 8
r1.researchWorkToday = 0
const rLogs = applyResearchHours(r1, ctx, 1)
ok('科研力只投给队首：20 → 12', r1.research.queue[0]!.remaining === 12,
  String(r1.research.queue[0]!.remaining))
ok('后面的两条一点没动',
  r1.research.queue[1]!.remaining === 20 && r1.research.queue[2]!.remaining === 20,
  `${r1.research.queue[1]!.remaining} / ${r1.research.queue[2]!.remaining}`)
ok('只有队首写了「开始研究」', rLogs.length === 1 && rLogs[0]!.text.includes('开始研究'),
  rLogs.map((l) => l.text).join(' | '))
ok('材料在开工那一刻才扣（木 −15）', r1.goods['wood'] === wood0r - 15,
  `木 ${wood0r} → ${r1.goods['wood']}`)

const tail = r1.research.queue[2]!.id
const rUn = cancelResearch(r1, ctx, tail)
ok('取消没开工的：一分料都不退', rUn.ok && rUn.refund.length === 0, JSON.stringify(rUn.refund))
ok('取消没开工的：文案说清「还没开工」', rUn.text.includes('还没开工'), rUn.text)
ok('取消没开工的：队列短一条', r1.research.queue.length === 2, String(r1.research.queue.length))

const rHead = r1.research.queue[0]!
const wood1r = r1.goods['wood']!
const rSt = cancelResearch(r1, ctx, rHead.id)
// 已扣木 15、还剩 12/20 → 退 15 × 12/20 = 9
ok('取消已开工的：按 remaining / totalRequired 退',
  JSON.stringify(rSt.refund) === JSON.stringify([['wood', 9]]), JSON.stringify(rSt.refund))
ok('退回的料真的进了国库', r1.goods['wood'] === wood1r + 9,
  `木 ${wood1r} → ${r1.goods['wood']}`)
ok('报告里写明已投入 8 / 20', rSt.used === 8 && rSt.total === 20, `${rSt.used} / ${rSt.total}`)
ok('文案写明进度与退回明细', rSt.text.includes('40%') && rSt.text.includes('退回'), rSt.text)
const againR = cancelResearch(r1, ctx, rHead.id)
ok('重复取消 → 拒绝', !againR.ok && againR.reason === '不在研究队列中', String(againR.reason))

// 走完整的黎明：命令次日生效 + 进公告
const r2 = freshResearch()
for (const t of [T1, T2, T3]) startResearch(r2, ctx, t)
r2.hour = TIME.dawnHour
const r2id = r2.research.queue[2]!.id
const rMove2 = advanceHour(r2, [{ type: 'move_research', id: r2id, delta: -1 }])
ok('研究调序在黎明生效', rMove2.state.research.queue[1]!.id === r2id,
  rMove2.state.research.queue.map((p) => p.id).join(' → '))
let r3 = rMove2.state
r3.hour = TIME.dawnHour
r3.researchWorkToday = 0
const rCancel2 = advanceHour(r3, [{ type: 'cancel_research', techId: r2id }])
ok('取消研究写进 state.log（公告页与存档读的就是它）',
  rCancel2.state.log.some((l) => l.text.includes('取消研究')),
  rCancel2.state.log.filter((l) => l.text.includes('取消研究')).slice(-1)[0]?.text ?? '（没有）')

// 跑完的科技**不在队首也要在黎明生效**（调序能把它挪到后面）
const r4 = freshResearch()
for (const t of [T1, T2]) startResearch(r4, ctx, t)
r4.research.queue[1]!.remaining = 0
r4.research.queue[1]!.started = true
const aLogs = activateResearch(r4, ctx, 5)
ok('跑完的科技不在队首也生效（扫全队列）',
  r4.research.done.includes(T2) && !techs(r4).includes(T2),
  `done=${r4.research.done.join(',')} queue=${techs(r4).join(',')}`)
ok('它留了一条「研究完成」日志', aLogs.some((l) => l.text.includes('研究完成') && l.text.includes('掘土')),
  aLogs.map((l) => l.text).join(' | '))

// ---- 即时生效（2026-10）：研究队列的三条动作不等黎明 ------------------------
//
// 用户："我白天点了一个研究……结果队列里没有，没有实时出现。要到第二天才能调整顺序太蠢了。"
// 研究的三条动作不花资源（材料在开工时才扣），所以当场应用；建造类仍然次日黎明生效。
{
  const s5 = freshResearch()
  const before = techs(s5).length
  s5.researchWorkToday = 0
  const r = advanceHour(s5, [{ type: 'research', techId: T1 }])
  ok('点「研究」当场进队列（不用等黎明）',
    techs(r.state).length === before + 1 && techs(r.state).includes(T1),
    techs(r.state).join(',') || '（空）')
  ok('它没有留在 pending 里', r.state.pending.length === 0, JSON.stringify(r.state.pending))

  // 调序也当场生效：再排一条，然后把它往上挪
  const r2b = advanceHour(r.state, [{ type: 'research', techId: T2 }])
  ok('第二条也能当场排进去', techs(r2b.state).join(',') === [T1, T2].join(','),
    techs(r2b.state).join(','))
  const r3b = advanceHour(r2b.state, [{ type: 'move_research', id: T2, delta: -1 }])
  ok('↑ 当场改顺序（不用等黎明）', techs(r3b.state).join(',') === [T2, T1].join(','),
    techs(r3b.state).join(','))

  // 撤单也当场生效（材料按进度退）
  const r4b = advanceHour(r3b.state, [{ type: 'cancel_research', techId: T2 }])
  ok('× 当场撤单', techs(r4b.state).join(',') === [T1].join(','), techs(r4b.state).join(','))

  // 反例：**建造**仍然等黎明（一天一结算的核心口径不能被这条改动带偏）
  const s6 = freshState()
  const r5 = advanceHour(s6, [{ type: 'build', buildingId: A }])
  ok('建造类的动作仍然留在 pending（次日黎明才生效）',
    r5.state.pending.some((a) => a.type === 'build') && r5.state.construction.length === 0,
    `pending=${r5.state.pending.length} construction=${r5.state.construction.length}`)
}

console.log(failed === 0 ? '\n两条队列自检通过 🎉\n' : `\n两条队列自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
