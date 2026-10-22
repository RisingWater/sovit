import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import type { Caravan, GameState, GoodID, LogEntry } from '../types.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 游商（M4，2026-10 定稿见 docs/needs.md §9 / buildings-batch2.md §6）
//
// 规则（用户口径）：
//   · **第 3 章完成**后开始有游商，**每周一批**；第 4 章 2 个 / 第 5 章 3 个（同时在场）
//   · 每个游商**停留 7 天**（第 D 天到 → 第 D+6 天最后一天 → D+7 黎明离开）
//   · 每个游商：**收 4 种**（玩家卖给他，他按 baseValue×1.6 付现金）+ **卖 4 种**
//     （玩家从他买，按 baseValue×1.3 付钱）
//   · 他有"**货值池**"和"**现金池**"：现金池是他能收你货的上限；玩家买他的货 → 他现金变多
//     （"你买的越多，他就越有钱可以收购越多"）
//   · **他收的没有数量上限**（用户 2026-10："游商本来就为了收购这个货物来的，所以是多多益善，
//     阻止他收购这个货物的唯一就是自己钱不够了"）—— 一次能收多少只看 `floor(cash / price)`；
//     他卖的才有 `qty`（带来的货有限）
//   · 商品池只用本内容包、且**玩家已解锁**的商品（不剧透后期商品）
//   · 全部**确定性**：`seed = day × 1000 + 序号`（golden / AI 沙盘可复现）
//
// GDScript 同口径：`sim_core.gd::_spawn_caravans()/_expire_caravans()`。
// ---------------------------------------------------------------------------

const STAY_DAYS = 7
const WAVE_PERIOD = 7
const BUY_MARKUP = 1.6
const SELL_MARKUP = 1.3
const OFFERS = 4
const CASH_BASE = 400
const CASH_SPREAD = 400
const GOODS_VALUE_BASE = 600
const GOODS_VALUE_SPREAD = 400

/** 一小段确定性 PRNG（mulberry32）—— 不吃 `state.rngState`，别扰动黄金轨迹。 */
function seeded(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** 已完成到第几章（章节奖励记录里最大的那章）；0 = 还没完成任何章节。 */
export function completedChapter(state: GameState): number {
  let max = 0
  for (const k of Object.keys(state.quests.chapters)) max = Math.max(max, Number(k) || 0)
  return max
}

/** 这一批同时来几个游商（第 3 章 1 个 / 第 4 章 2 个 / 第 5 章 3 个）。 */
export function waveSize(chapter: number): number {
  // ⚠️ 2026-10（B4）：闸从"完成第 3 章"前移到**"完成第 2 章"**。
  // 章 3 的任务要"和游商买卖各一次"，如果第 3 章结算之后他才来，那两条任务
  // 在章 3 期间永远做不了（见 docs/trade-routes.md §12.4）。
  if (chapter >= 5) return 3
  if (chapter >= 4) return 2
  if (chapter >= 2) return 1
  return 0
}

/**
 * 可交易的商品池：本包内、且**存得住**的商品。
 *
 * 排除三类：
 *   · `category` = service / military / tool —— 服务点数、军备、工具不是流通品
 *   · **`perishRate >= 1`** —— 当天归零的东西（娱乐 / 家政 / 治安 / 医疗 / 教育），
 *     买进来第二天就没了，"存货"那一栏永远是 0，纯属骗人
 *     （用户 2026-10："娱乐可以出售，我建议你改一下，那种不能储存的商品，不要进游商的目录"）
 *
 * ⚠️ `storable: false` 的蔬菜 / 肉 / 鱼**不排除**：它们只是不占仓储格子，能放几天
 * （perishRate 0.1~0.15），是正经能买卖的鲜货。判据只认"存不存得住"。
 * GDScript 同口径：`sim_core.gd::_tradeable_goods()`。
 */
function tradeableGoods(state: GameState, ctx: ContentContext): GoodID[] {
  const out: GoodID[] = []
  for (const gid of ctx.pack.goods) {
    const def = ALL_GOODS[gid]
    if (!def) continue
    if (def.category === 'service' || def.category === 'military') continue
    if (def.category === 'tool') continue
    if ((def.perishRate ?? 0) >= 1) continue
    out.push(gid)
  }
  out.sort()
  return out
}

function pick<T>(rnd: () => number, arr: T[], n: number): T[] {
  const pool = [...arr]
  const out: T[] = []
  while (out.length < n && pool.length > 0) {
    const i = Math.floor(rnd() * pool.length)
    out.push(pool.splice(i, 1)[0]!)
  }
  return out
}

/**
 * 黎明：到货 / 离开。
 *
 * - `day > leaveDay` 的游商离开
 * - `day >= nextWaveDay` 且章节够 → 来一批（`waveSize` 个），下一批 +7 天
 * - 章节不够就把 `nextWaveDay` 推到明天（等玩家推完第 3 章）
 */
export function updateCaravans(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  const trade = state.trade

  const before = trade.caravans.length
  trade.caravans = trade.caravans.filter((c) => day <= c.leaveDay)
  if (before > trade.caravans.length) {
    logs.push({ day, kind: 'finance', text: `游商离开：${before - trade.caravans.length} 队` })
  }

  const want = waveSize(completedChapter(state))
  if (want === 0) {
    trade.nextWaveDay = day + 1
    return logs
  }
  if (day < trade.nextWaveDay) return logs

  const pool = tradeableGoods(state, ctx)
  if (pool.length < OFFERS * 2) return logs

  trade.wave += 1
  const used = new Set<string>()
  for (let i = 0; i < want; i++) {
    const rnd = seeded(day * 1000 + trade.wave * 100 + i)
    const cash = round2(CASH_BASE + rnd() * CASH_SPREAD)
    const goodsValue = round2(GOODS_VALUE_BASE + rnd() * GOODS_VALUE_SPREAD)
    const free = pool.filter((g) => !used.has(g))
    const sells = pick(rnd, free, Math.min(OFFERS, free.length))
    for (const g of sells) used.add(g)
    const free2 = pool.filter((g) => !used.has(g)).length >= OFFERS ? pool.filter((g) => !used.has(g)) : pool
    const buys = pick(rnd, free2, Math.min(OFFERS, free2.length))

    const caravan: Caravan = {
      id: `cv#${trade.wave}-${i + 1}`,
      arriveDay: day,
      leaveDay: day + STAY_DAYS - 1,
      cash,
      goodsValue,
      // 他卖的：每种按"货值池 ÷ 4 ÷ 卖价"定量，至少有 1 件
      sell: sells.map((g) => {
        const price = round2((ALL_GOODS[g]?.baseValue ?? 1) * SELL_MARKUP)
        const qty = Math.max(1, Math.floor(goodsValue / OFFERS / Math.max(0.01, price)))
        return { good: g, price, qty }
      }),
      // 他收的：现金池封顶，单价 ×1.6。**不带 qty** —— 多多益善，只受他的现金限制。
      buy: buys.map((g) => ({
        good: g,
        price: round2((ALL_GOODS[g]?.baseValue ?? 1) * BUY_MARKUP),
      })),
    }
    state.trade.caravans.push(caravan)
  }
  trade.nextWaveDay = day + WAVE_PERIOD
  logs.push({
    day,
    kind: 'finance',
    text: `游商到货：${want} 队（停留 ${STAY_DAYS} 天）`,
  })
  return logs
}

/**
 * 玩家卖给游商（`sell_to_caravan`）。返回失败原因或空串。
 *
 * 能收多少：**库存**与**他的现金**取小 —— 没有"每种只收 20 件"这种配额
 * （用户 2026-10："游商本来就为了收购这个货物来的，所以是多多益善，阻止他收购这个货物的
 * 唯一就是自己钱不够了"）。卖完之后 `c.cash` 立刻变少，所以下一单能收的更少。
 */
export function sellToCaravan(
  state: GameState,
  caravanId: string,
  goodId: string,
  qty: number,
): string {
  const c = state.trade.caravans.find((x) => x.id === caravanId)
  if (!c) return '游商不在了'
  const offer = c.buy.find((o) => o.good === goodId)
  if (!offer) return '他这次不收这个'
  const stock = state.goods[goodId] ?? 0
  const afford = Math.floor(c.cash / Math.max(0.01, offer.price))
  const want = Math.max(0, Math.floor(qty))
  const n = Math.min(want, Math.floor(stock), afford)
  if (n <= 0) return '库存不够 / 他没那么多钱收'
  const money = round2(n * offer.price)
  state.goods[goodId] = round2(stock - n)
  state.government.money = round2(state.government.money + money)
  c.cash = round2(c.cash - money)
  // ⚠️ 单列一栏，不再混进 `sales`（居民消费回款）—— 用户 2026-10："游商的收益"要单独一行。
  state.ledgerToday.merchantSell = round2(state.ledgerToday.merchantSell + money)
  return ''
}

/** 玩家从游商买（`buy_from_caravan`）。返回失败原因或空串。 */
export function buyFromCaravan(
  state: GameState,
  caravanId: string,
  goodId: string,
  qty: number,
): string {
  const c = state.trade.caravans.find((x) => x.id === caravanId)
  if (!c) return '游商不在了'
  const offer = c.sell.find((o) => o.good === goodId)
  if (!offer) return '他没带这个'
  const afford = Math.floor(state.government.money / Math.max(0.01, offer.price))
  const want = Math.max(0, Math.floor(qty))
  const n = Math.min(want, offer.qty, afford)
  if (n <= 0) return '国库不够 / 他卖完了'
  const money = round2(n * offer.price)
  state.government.money = round2(state.government.money - money)
  state.goods[goodId] = round2((state.goods[goodId] ?? 0) + n)
  // 他收钱 → 现金变多 → 能收你更多货（用户 2026-10 的原话）
  c.cash = round2(c.cash + money)
  offer.qty = round2(offer.qty - n)
  return ''
}
