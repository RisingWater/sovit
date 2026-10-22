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
 *   7. **他收的多多益善**（用户 2026-10）：报价里没有每种 20 件的配额，
 *      一次能卖多少只由"库存 + 他的现金"决定
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
  // ⚠️ B4 起闸前移到「完成第 2 章」：章 3 的任务要和游商买卖各一次，
  // 第 3 章结算之后他再来就永远做不了（见 docs/trade-routes.md §12.4）。
  check(waveSize(0) === 0 && waveSize(1) === 0, '第 2 章之前不来游商')
  check(waveSize(3) === 1, `第 3 章 1 队（实际 ${waveSize(3)}）`)
  check(waveSize(4) === 2, `第 4 章 2 队（实际 ${waveSize(4)}）`)
  check(waveSize(5) === 3, `第 5 章 3 队（实际 ${waveSize(5)}）`)

  const s1 = village(1)
  updateCaravans(s1, ctx, 5)
  check(s1.trade.caravans.length === 0, '第 1 章跑 5 天：一队都没有')

  const s = village(2)
  updateCaravans(s, ctx, 5)
  check(s.trade.caravans.length === 1, '第 2 章：1 队（章 3 的任务要靠他）')

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

    // 存不住的东西不许进目录（用户 2026-10："娱乐可以出售，我建议你改一下，
    // 那种不能储存的商品，不要进游商的目录"）。
    // 判据：`perishRate >= 1`（当天归零）与服务 / 军备 / 工具这三类。
    // ⚠️ 蔬菜 / 肉 / 鱼是 `storable: false` 但 perishRate 只有 0.1~0.15，属于**能放几天的鲜货**，
    //    照常可交易 —— 所以别把 `storable` 当判据。
    for (const o of [...c.sell, ...c.buy]) {
      const def = ctx.goods[o.good]
      const cat = def?.category
      const perish = def?.perishRate ?? 0
      check(
        perish < 1 && cat !== 'service' && cat !== 'military' && cat !== 'tool',
        `${o.good}（${def?.nameZh ?? o.good}）不该进游商目录：category=${cat} perishRate=${perish}`,
      )
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

// ---- 7. 他收的"多多益善"：没有每种配额 --------------------------------
//
// 用户 2026-10："游商本来就为了收购这个货物来的，所以是多多益善，阻止他收购这个货物的
// 唯一就是自己钱不够了。" —— 所以：① 他收的报价里没有 `qty`；
// ② 一次能卖多少只由"库存 + 他的现金"决定（旧规则每种只收 20 件，早没了）。
{
  const s = village(3)
  updateCaravans(s, ctx, 10)
  const c = s.trade.caravans[0]!
  const buy = c.buy[0]!
  check(!('qty' in buy), '他收的报价里没有 qty（每种配额已按用户要求删掉）')

  // 钱给足 → 一次卖 100 件应当全收（旧规则最多 20）
  c.cash = 100000
  s.goods[buy.good] = 500
  const why = sellToCaravan(s, c.id, buy.good, 100)
  check(why === '', `钱给足时卖 100 件：${why || '成功'}`)
  check(
    Math.abs((s.goods[buy.good] ?? 0) - 400) < 1e-6,
    `卖 100 件之后库存 ${s.goods[buy.good]}（应当 400；旧规则的 20 件配额不许回来）`,
  )

  // 只给 2.5 件的钱 → 成交 2 件（向下取整），他的钱花到买不起第 3 件
  c.cash = Math.round(buy.price * 2.5 * 100) / 100
  s.goods[buy.good] = 400
  const why2 = sellToCaravan(s, c.id, buy.good, 50)
  check(why2 === '', `现金只够 2 件时卖 50 件：${why2 || '部分成交'}`)
  const sold = 400 - (s.goods[buy.good] ?? 0)
  check(Math.abs(sold - 2) < 1e-6, `成交 ${sold} 件（他的现金只够 2 件）`)
  check(c.cash < buy.price, `钱花完了他的 cash 还剩 ${c.cash}（买不起第 3 件）`)
}

console.log(failed === 0 ? '\n游商自检通过 🎉\n' : `\n游商自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
