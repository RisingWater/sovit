/**
 * 游商（M4）自检 —— 2026-10。
 *
 * 盯六件事（用户口径见 docs/needs.md §9 / buildings-batch2.md §6）：
 *   1. 第 3 章之前不来、第 3 章 1 队、第 4 章 2 队、第 5 章 3 队
 *   2. 每个游商**停留 7 天**（第 D 天到、D+6 最后一天、D+7 黎明走）
 *   3. 报价：**收 4 种 + 卖 4 种**，买价 = baseValue×1.6、卖价 = ×1.3
 *   4. 现金池：玩家买他的货 → 他现金变多（"你买得越多他越有钱收你的货"）
 *   5. 确定性：同一 state 再跑一次，报价完全一样
 *   6. 交易守恒：卖给他 → 库存减、国库增、他现金减；从他买 → 反过来
 *
 * GDScript 镜像：`godot/tools/merchant_test.gd`。
 *
 * 用法：node --experimental-strip-types scripts/check-merchant.ts
 */
import { buildContext } from '../src/engine/content/index.ts'
import { createInitialState } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import {
  buyFromCaravan,
  completedChapter,
  sellToCaravan,
  updateCaravans,
  waveSize,
} from '../src/engine/systems/caravan.ts'
import { round2 } from '../src/engine/util.ts'

let failed = 0
function check(cond: boolean, msg: string): void {
  if (cond) console.log(`  ok   ${msg}`)
  else {
    console.error(`  FAIL ${msg}`)
    failed += 1
  }
}

const ctx = buildContext('v0.3')

function village(chapter: number): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261024 })
  if (chapter >= 1) s.quests.chapters['1'] = 1
  if (chapter >= 2) s.quests.chapters['2'] = 2
  if (chapter >= 3) s.quests.chapters['3'] = 3
  if (chapter >= 4) s.quests.chapters['4'] = 4
  if (chapter >= 5) s.quests.chapters['5'] = 5
  s.trade.nextWaveDay = 1
  return s
}

// ---- 1. 章节节奏 ---------------------------------------------------------
{
  check(waveSize(0) === 0 && waveSize(1) === 0 && waveSize(2) === 0, '第 3 章之前不来游商')
  check(waveSize(3) === 1, `第 3 章 1 队（实际 ${waveSize(3)}）`)
  check(waveSize(4) === 2, `第 4 章 2 队（实际 ${waveSize(4)}）`)
  check(waveSize(5) === 3, `第 5 章 3 队（实际 ${waveSize(5)}）`)

  const s = village(2)
  updateCaravans(s, ctx, 5)
  check(s.trade.caravans.length === 0, '第 2 章跑 5 天：一队都没有')

  const s3 = village(3)
  check(completedChapter(s3) === 3, `completedChapter = ${completedChapter(s3)}`)
  updateCaravans(s3, ctx, 5)
  check(s3.trade.caravans.length === 1, `第 3 章：1 队（实际 ${s3.trade.caravans.length}）`)

  const s5 = village(5)
  updateCaravans(s5, ctx, 5)
  check(s5.trade.caravans.length === 3, `第 5 章：3 队（实际 ${s5.trade.caravans.length}）`)
}

// ---- 2. 停留 7 天 + 每周一批 ---------------------------------------------
{
  const s = village(3)
  updateCaravans(s, ctx, 10)
  const c = s.trade.caravans[0]!
  check(c.arriveDay === 10 && c.leaveDay === 16, `停留 7 天：${c.arriveDay} → ${c.leaveDay}`)
  check(s.trade.nextWaveDay === 17, `下一批在第 ${s.trade.nextWaveDay} 天（应当 17）`)

  updateCaravans(s, ctx, 16)
  check(s.trade.caravans.length === 1, '第 16 天（最后一天）还在')
  updateCaravans(s, ctx, 17)
  const stillOld = s.trade.caravans.some((x) => x.id === c.id)
  check(!stillOld, '第 17 天黎明他走了')
}

// ---- 3. 报价：收 4 卖 4 + 价格加成 ---------------------------------------
{
  const s = village(4)
  updateCaravans(s, ctx, 10)
  for (const c of s.trade.caravans) {
    check(c.buy.length === 4, `${c.id} 收 4 种（实际 ${c.buy.length}）`)
    check(c.sell.length === 4, `${c.id} 卖 4 种（实际 ${c.sell.length}）`)
    for (const o of c.sell) {
      const base = ctx.goods[o.good]?.baseValue ?? 1
      check(Math.abs(o.price - round2(base * 1.3)) < 0.02, `${o.good} 卖价 ${o.price}（应当 ${round2(base * 1.3)}）`)
    }
    for (const o of c.buy) {
      const base = ctx.goods[o.good]?.baseValue ?? 1
      check(Math.abs(o.price - round2(base * 1.6)) < 0.02, `${o.good} 收价 ${o.price}（应当 ${round2(base * 1.6)}）`)
    }
  }
}

// ---- 4. 现金池：买得越多，他越有钱收 -------------------------------
{
  const s = village(3)
  updateCaravans(s, ctx, 10)
  const c = s.trade.caravans[0]!
  s.government.money = 5000
  const cash0 = c.cash
  const sellOffer = c.sell[0]!
  const why = buyFromCaravan(s, c.id, sellOffer.good, 2)
  check(why === '', `从他买 2 件 ${sellOffer.good}：${why || '成功'}`)
  check(c.cash > cash0, `他的现金 ${cash0} → ${c.cash}（买他的货让他更有钱）`)

  // 卖给他：国库增、库存减、他现金减
  const buyOffer = c.buy[0]!
  s.goods[buyOffer.good] = 50
  const money0 = s.government.money
  const stock0 = s.goods[buyOffer.good]!
  const why2 = sellToCaravan(s, c.id, buyOffer.good, 3)
  check(why2 === '', `卖给他 3 件 ${buyOffer.good}：${why2 || '成功'}`)
  check(s.government.money > money0, `国库 ${money0} → ${s.government.money}`)
  check(s.goods[buyOffer.good]! < stock0, `库存 ${stock0} → ${s.goods[buyOffer.good]}`)
}

// ---- 5. 确定性 -----------------------------------------------------------
{
  const a = village(4)
  const b = village(4)
  updateCaravans(a, ctx, 10)
  updateCaravans(b, ctx, 10)
  const ja = JSON.stringify(a.trade.caravans)
  const jb = JSON.stringify(b.trade.caravans)
  check(ja === jb, '同一个种子 / 同一天：两批报价完全一样')
}

// ---- 6. 拒绝说的话 ----------------------------------------------
{
  const s = village(3)
  updateCaravans(s, ctx, 10)
  const c = s.trade.caravans[0]!
  check(sellToCaravan(s, 'cv#nope', 'wood', 1) !== '', '不存在的游商 → 拒绝')
  check(buyFromCaravan(s, c.id, c.buy[0]!.good + 'x', 1) !== '', '他没带的商品 → 拒绝')
  s.goods['wood'] = 0
  const offer = c.buy.find((o) => o.good === 'wood')
  if (offer) check(sellToCaravan(s, c.id, 'wood', 1) !== '', '库存为 0 → 拒绝')
}

console.log(failed === 0 ? '\n游商自检通过 🎉\n' : `\n游商自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
