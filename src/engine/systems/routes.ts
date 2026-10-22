import type { ContentContext } from '../content/index.ts'
import type { GameState, GoodID, LogEntry, RouteCityDef, RouteMarket, TradeRoute } from '../types.ts'
import { ALL_GOODS } from '../content/index.ts'
import { round2 } from '../util.ts'
import { completedChapter } from './caravan.ts'
import {
  addRep,
  factionCanTrade,
  factionDef,
  factionTradeGain,
  relationLabel,
} from './factions.ts'
import { techBonuses, type TechBonuses } from './tech_bonus.ts'

// ---------------------------------------------------------------------------
// 商路（B3，设计见 docs/trade-routes.md）
//
// 一句话：**常设车队**。玩家给一支商队指定一座城、配好"卖什么 / 带多少钱去买"，
// 之后它自己循环：黎明锁货出发 → 走 days 天 → 到城卖货、用钱进货 → 再走 days 天
// → 回家入库。回程天数由 `caravan.roundTrip` 决定（默认 true = 往返 2×单程）。
//
// 三条硬规则（都写进 `docs/spec.md` §20）：
//   1. **只有特产买得到、只有需求卖得掉**，且内容校验保证 特产 ∩ 需求 = ∅
//      → 买了货只能回家用掉，不存在"A 城买、B 城卖"的倒卖
//   2. 锁货 = 把货**搬出仓库**记在商队名下（不是软预留），所以生产 / 消费都碰不到它
//   3. 一切确定性：没有随机数，市场库存是纯累积
//
// 与游商（`caravan.ts`）的关系：共用 `baseValue` 这一份价格锚，别另立价格表。
// GDScript 同口径：`sim_core.gd::_update_routes()` / `_route_price()` / `trade_bonuses()`。
// ---------------------------------------------------------------------------

/** 价格：`baseValue × 距离倍率 × (1 ± 议价)`。 */
export function routePrice(
  ctx: ContentContext,
  city: RouteCityDef,
  good: GoodID,
  side: 'buy' | 'sell',
  bonuses: TechBonuses,
): number {
  const base = ALL_GOODS[good]?.baseValue ?? 1
  const step = ctx.routes.distance[city.days]!
  const mul = side === 'sell' ? step.sellMul : step.buyMul
  const haggle = side === 'sell' ? bonuses.trade.haggleSell : bonuses.trade.haggleBuy
  const raw = side === 'sell' ? base * mul * (1 + haggle) : base * mul * (1 - haggle)
  return round2(Math.max(0.01, raw))
}

/** 单程载货上限（科技取最高，至少 1）。 */
export function cargoCap(ctx: ContentContext, bonuses: TechBonuses): number {
  return Math.max(1, Math.floor(Math.max(ctx.routes.caravan.cargo, bonuses.trade.cargo)))
}

/** 带钱上限（科技取最高）。 */
export function purseCap(ctx: ContentContext, bonuses: TechBonuses): number {
  return Math.max(0, Math.max(ctx.routes.caravan.purse, bonuses.trade.purse))
}

/** 现在有几支商队（基础 + 科技，封顶 maxCount）。 */
export function caravanCount(ctx: ContentContext, bonuses: TechBonuses): number {
  const n = ctx.routes.caravan.count + Math.floor(bonuses.trade.caravans)
  return Math.max(0, Math.min(ctx.routes.caravan.maxCount, n))
}

/** 商路系统解锁了没有（研究「常设商队」= 至少一支商队）。 */
export function routesUnlocked(ctx: ContentContext, bonuses: TechBonuses): boolean {
  return caravanCount(ctx, bonuses) > 0
}

export function cityOf(ctx: ContentContext, cityId: string | null): RouteCityDef | undefined {
  if (cityId === null) return undefined
  return ctx.routes.cities.find((c) => c.id === cityId)
}

/** 这座城现在能不能派（章节解锁）。 */
export function cityUnlocked(state: GameState, city: RouteCityDef): boolean {
  return completedChapter(state) >= city.unlockChapter
}

function emptyMarket(city: RouteCityDef, ctx: ContentContext): RouteMarket {
  const specialty: Record<string, number> = {}
  for (const g of city.specialty) specialty[g] = ctx.routes.market.specialtyStock
  const demand: Record<string, number> = {}
  for (const g of city.demand) demand[g] = ctx.routes.market.demandCap
  return { specialty, demand }
}

export function emptyRoutes(ctx: ContentContext): GameState['routes'] {
  const market: Record<string, RouteMarket> = {}
  for (const city of ctx.routes.cities) market[city.id] = emptyMarket(city, ctx)
  const routes: TradeRoute[] = []
  for (let i = 1; i <= ctx.routes.caravan.count; i++) routes.push(emptyRoute(i))
  return { routes, market, created: 0 }
}

function emptyRoute(index: number): TradeRoute {
  return {
    id: `route_${index}`,
    cityId: null,
    phase: 'home',
    departDay: 0,
    arriveDay: 0,
    backDay: 0,
    budget: 0,
    sellPlan: {},
    loaded: {},
    cash: 0,
    cart: {},
    revenue: 0,
    spent: 0,
    lastTripDay: 0,
    lastStuckDay: 0,
  }
}

/** 商队数跟着科技走：多了就补空槽位（不会撤掉已有的）。 */
export function syncRouteCount(state: GameState, ctx: ContentContext, bonuses: TechBonuses): void {
  const want = caravanCount(ctx, bonuses)
  while (state.routes.routes.length < want) {
    state.routes.routes.push(emptyRoute(state.routes.routes.length + 1))
  }
}

/** 这条商路配置齐了没有（货锁够 + 钱够）。给面板与派车共用。 */
export interface RouteReadiness {
  readyGoods: boolean
  readyMoney: boolean
  shortGoods: { good: GoodID; have: number; need: number }[]
  needMoney: number
}

export function routeReadiness(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  route: TradeRoute,
): RouteReadiness {
  const city = cityOf(ctx, route.cityId)
  if (!city) return { readyGoods: true, readyMoney: true, shortGoods: [], needMoney: 0 }
  const cargo = cargoCap(ctx, bonuses)
  const shortGoods: RouteReadiness['shortGoods'] = []
  let total = 0
  for (const good of city.demand) {
    const need = Math.min(cargo, Math.floor(route.sellPlan[good] ?? 0))
    const have = Math.floor(route.loaded[good] ?? 0)
    total += need
    if (have < need) shortGoods.push({ good, have, need })
  }
  const needMoney = Math.min(purseCap(ctx, bonuses), Math.max(0, route.budget))
  return {
    readyGoods: shortGoods.length === 0,
    readyMoney: state.government.money >= needMoney,
    shortGoods,
    needMoney,
  }
}

/**
 * 黎明：市场补给 → 结算（到达 / 回家）→ 派车。
 *
 * 顺序刻意固定：**先结算再派车** —— 昨天回来的货今天就得能装上车，
 * 而买到的货在结算时就进了仓库，后面的排产当天就能用上（见 spec §0 的黎明顺序）。
 */
export function updateRoutes(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  syncRouteCount(state, ctx, bonuses)
  const m = ctx.routes.market
  const cargo = cargoCap(ctx, bonuses)
  const purse = purseCap(ctx, bonuses)

  // 1) 市场补给（每座城：特产 + 需求池）
  for (const city of ctx.routes.cities) {
    const mk = state.routes.market[city.id]
    if (!mk) {
      state.routes.market[city.id] = emptyMarket(city, ctx)
      continue
    }
    for (const g of city.specialty) {
      mk.specialty[g] = Math.min(m.specialtyCap, round2((mk.specialty[g] ?? 0) + m.specialtyDaily))
    }
    for (const g of city.demand) {
      mk.demand[g] = Math.min(m.demandCap, round2((mk.demand[g] ?? 0) + m.demandDaily))
    }
  }

  for (const route of state.routes.routes) {
    const city = cityOf(ctx, route.cityId)
    if (!city) continue
    const mk = state.routes.market[city.id]!

    // 2) 到达：卖光卖货 → 用「带出的钱 + 卖得的钱」进货
    if (route.phase === 'out' && day >= route.arriveDay) {
      const parts: string[] = []
      let revenue = 0
      let soldQty = 0
      for (const good of city.demand) {
        const qty = Math.floor(route.loaded[good] ?? 0)
        if (qty <= 0) continue
        const room = Math.floor(mk.demand[good] ?? 0)
        const n = Math.min(qty, room)
        if (n <= 0) continue
        const money = round2(n * routePrice(ctx, city, good, 'sell', bonuses))
        revenue = round2(revenue + money)
        soldQty += n
        mk.demand[good] = round2(room - n)
        state.ledgerToday.routeOut[good] = round2((state.ledgerToday.routeOut[good] ?? 0) + n)
        parts.push(`${goodName(good)}×${n}`)
      }
      route.revenue = revenue
      state.ledgerToday.routeExport = round2(state.ledgerToday.routeExport + revenue)
      route.loaded = {}

      // 进货：载重、库存、钱三个闸
      let budget = round2(route.cash + revenue)
      let bought = 0
      let spent = 0
      const got: string[] = []
      for (const good of city.specialty) {
        const left = cargo - bought
        if (left <= 0) break
        const price = routePrice(ctx, city, good, 'buy', bonuses)
        const stock = Math.floor(mk.specialty[good] ?? 0)
        const afford = price > 0 ? Math.floor(budget / price) : 0
        const n = Math.max(0, Math.min(left, stock, afford))
        if (n <= 0) continue
        const money = round2(n * price)
        budget = round2(budget - money)
        spent = round2(spent + money)
        bought += n
        mk.specialty[good] = round2(stock - n)
        route.cart[good] = (route.cart[good] ?? 0) + n
        state.ledgerToday.routeIn[good] = round2((state.ledgerToday.routeIn[good] ?? 0) + n)
        got.push(`${goodName(good)}×${n}`)
      }
      route.spent = spent
      route.cash = budget
      state.ledgerToday.routeImport = round2(state.ledgerToday.routeImport + spent)

      logs.push({
        day,
        kind: 'trade',
        text: `商队抵达${city.nameZh}：售出 ${parts.length ? parts.join(' ') : '无'} → ¥${revenue.toFixed(0)}；买入 ${got.length ? got.join(' ') : '无'}`,
      })
      route.phase = 'back'
      route.arriveDay = day
      route.backDay = day + (ctx.routes.caravan.roundTrip ? city.days : 0)
      if (route.backDay <= day) finishReturn(state, ctx, route, day, logs)
      continue
    }

    // 3) 回家：货入库、余钱回国库
    if (route.phase === 'back' && day >= route.backDay) {
      finishReturn(state, ctx, route, day, logs)
      continue
    }

    // 4) 派车：锁货 → 钱够 → 出发
    if (route.phase === 'home') {
      for (const good of city.demand) {
        const need = Math.min(cargo, Math.floor(route.sellPlan[good] ?? 0))
        const have = Math.floor(route.loaded[good] ?? 0)
        if (have >= need) continue
        const take = Math.min(need - have, Math.floor(state.goods[good] ?? 0))
        if (take <= 0) continue
        state.goods[good] = round2((state.goods[good] ?? 0) - take)
        route.loaded[good] = have + take
      }
      const r = routeReadiness(state, ctx, bonuses, route)
      const needMoney = Math.min(purse, r.needMoney)
      if (r.readyGoods && r.readyMoney) {
        if (needMoney > 0) state.government.money = round2(state.government.money - needMoney)
        route.cash = needMoney
        route.revenue = 0
        route.spent = 0
        route.phase = 'out'
        route.departDay = day
        route.arriveDay = day + city.days
        route.backDay = route.arriveDay + (ctx.routes.caravan.roundTrip ? city.days : 0)
        logs.push({ day, kind: 'trade', text: `商队出发：${city.nameZh}（单程 ${city.days} 天）` })
      } else if (r.shortGoods.length > 0) {
        const s = r.shortGoods[0]!
        // 同一原因一天只写一条（否则每天黎明都刷一行）
        if (route.lastStuckDay !== day) {
          route.lastStuckDay = day
          logs.push({
            day,
            kind: 'trade',
            text: `商队停在村里：还缺 ${goodName(s.good)} ${Math.ceil(s.need - s.have)} 件`,
          })
        }
      }
    }
  }
  return logs
}

function finishReturn(
  state: GameState,
  ctx: ContentContext,
  route: TradeRoute,
  day: number,
  logs: LogEntry[],
): void {
  const city = cityOf(ctx, route.cityId)
  const moved: string[] = []
  for (const [good, qty] of Object.entries(route.cart)) {
    const n = Math.floor(qty)
    if (n <= 0) continue
    state.goods[good] = round2((state.goods[good] ?? 0) + n)
    moved.push(`${goodName(good)}×${n}`)
  }
  const cashBack = round2(route.cash)
  if (cashBack > 0) state.government.money = round2(state.government.money + cashBack)
  route.cart = {}
  route.cash = 0
  route.phase = 'home'
  route.departDay = 0
  route.arriveDay = 0
  route.backDay = 0
  route.lastTripDay = day
  logs.push({
    day,
    kind: 'trade',
    text: `商队回来了：携 ${moved.length ? moved.join(' ') : '空车'}、余钱 ¥${cashBack.toFixed(0)}` +
      (city ? `（${city.nameZh}）` : ''),
  })
  // 邦交（B4）：**跑完一趟**给这座城市的主子加好感（空跑不加 —— 这里就是"跑完了"）。
  // 一趟 = `tradeGain × (1 + goodwill)` → 100 / 150 / 200 / 300，夹到天花板。
  // 见 docs/diplomacy.md §3.2。镜像：sim_core.gd::_finish_return()。
  if (city) {
    const gain = factionTradeGain(state, ctx)
    const got = addRep(state, city.faction, gain)
    if (got !== 0) {
      const def = factionDef(city.faction)
      logs.push({
        day,
        kind: 'diplomacy',
        text: `${def?.short ?? city.nameZh}对我们的好感 +${got}（${relationLabel(state, city.faction)}）`,
      })
    }
  }
}

function goodName(gid: string): string {
  return ALL_GOODS[gid as GoodID]?.nameZh ?? gid
}

// ---------------------------------------------------------------------------
// 命令（都走 `IMMEDIATE_ACTIONS`，当场生效）
// ---------------------------------------------------------------------------

/** `route_assign`：派第一支空闲商队去这座城。返回失败原因（空串 = 成功）。 */
export function assignRoute(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  cityId: string,
): string {
  const city = cityOf(ctx, cityId)
  if (!city) return '没有这座城'
  if (!routesUnlocked(ctx, bonuses)) return '还没研究「常设商队」'
  if (!cityUnlocked(state, city)) return `${city.nameZh}还没通路`
  // 邦交门槛（B4）：只有**中立及以上**才开得了商路（附庸视为中立）。
  // 见 docs/diplomacy.md §3.1 —— 敌对 / 冷淡在这座城上「设为目的地」是灰的。
  const gate = factionCanTrade(state, city.faction)
  if (!gate.ok) return gate.why
  syncRouteCount(state, ctx, bonuses)
  if (state.routes.routes.some((r) => r.cityId === cityId)) return `${city.nameZh}已经在商路列表里了`
  const idle = state.routes.routes.find((r) => r.cityId === null)
  if (!idle) return '没有空闲商队（研究新的商队科技）'
  idle.cityId = cityId
  idle.phase = 'home'
  idle.budget = Math.min(idle.budget, purseCap(ctx, bonuses))
  // 任务 `route_created` 数这个（单调递增，取消不减；只记事、不演化）
  state.routes.created = (state.routes.created ?? 0) + 1
  return ''
}

/** `route_unassign`：取消一条商路，已锁的货与钱退回。 */
export function unassignRoute(
  state: GameState,
  ctx: ContentContext,
  routeId: string,
): string {
  const route = state.routes.routes.find((r) => r.id === routeId)
  if (!route) return '没有这条商路'
  for (const [good, qty] of Object.entries(route.loaded)) {
    const n = Math.floor(qty)
    if (n > 0) state.goods[good] = round2((state.goods[good] ?? 0) + n)
  }
  if (route.cash > 0) state.government.money = round2(state.government.money + route.cash)
  // 在途的商队取消：货已经在路上，按"回家"结算掉，别凭空蒸发
  if (route.phase !== 'home') {
    for (const [good, qty] of Object.entries(route.cart)) {
      const n = Math.floor(qty)
      if (n > 0) state.goods[good] = round2((state.goods[good] ?? 0) + n)
    }
  }
  route.cityId = null
  route.phase = 'home'
  route.loaded = {}
  route.cart = {}
  route.cash = 0
  route.budget = 0
  route.sellPlan = {}
  route.revenue = 0
  route.spent = 0
  route.departDay = 0
  route.arriveDay = 0
  route.backDay = 0
  return ''
}

/** `route_set_budget`：改购买预算（夹到钱箱上限）。 */
export function setRouteBudget(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  routeId: string,
  value: number,
): string {
  const route = state.routes.routes.find((r) => r.id === routeId)
  if (!route) return '没有这条商路'
  if (route.phase !== 'home') return '商队在途中，下一趟生效'
  route.budget = Math.max(0, Math.min(purseCap(ctx, bonuses), Math.floor(value)))
  return ''
}

/** `route_set_sell`：改某项出售数量（只能是这座城市的需求商品）。 */
export function setRouteSell(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  routeId: string,
  goodId: GoodID,
  qty: number,
): string {
  const route = state.routes.routes.find((r) => r.id === routeId)
  if (!route) return '没有这条商路'
  if (route.phase !== 'home') return '商队在途中，下一趟生效'
  const city = cityOf(ctx, route.cityId)
  if (!city) return '这条商路还没选目的地'
  if (!city.demand.includes(goodId)) return `${city.nameZh}不收这个`
  const n = Math.max(0, Math.min(cargoCap(ctx, bonuses), Math.floor(qty)))
  if (n === 0) delete route.sellPlan[goodId]
  else route.sellPlan[goodId] = n
  // 配置调小 → 多锁的立刻退回仓库（spec §20.3）
  const have = Math.floor(route.loaded[goodId] ?? 0)
  if (have > n) {
    const back = have - n
    state.goods[goodId] = round2((state.goods[goodId] ?? 0) + back)
    if (n === 0) delete route.loaded[goodId]
    else route.loaded[goodId] = n
  }
  return ''
}

// ---------------------------------------------------------------------------
// 面板数据源（只读快照）
// ---------------------------------------------------------------------------

export interface RouteCityView {
  id: string
  nameZh: string
  lord: string
  days: number
  unlocked: boolean
  /** 特产（买）：单价 + 可购数量。 */
  specialty: { good: GoodID; price: number; stock: number }[]
  /** 需求（卖）：单价 + 还能吃多少。 */
  demand: { good: GoodID; price: number; room: number }[]
}

export function routeCityView(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  cityId: string,
): RouteCityView | null {
  const city = cityOf(ctx, cityId)
  if (!city) return null
  const mk = state.routes.market[city.id]
  return {
    id: city.id,
    nameZh: city.nameZh,
    lord: city.lord,
    days: city.days,
    unlocked: cityUnlocked(state, city),
    specialty: city.specialty.map((g) => ({
      good: g,
      price: routePrice(ctx, city, g, 'buy', bonuses),
      stock: Math.floor(mk?.specialty[g] ?? 0),
    })),
    demand: city.demand.map((g) => ({
      good: g,
      price: routePrice(ctx, city, g, 'sell', bonuses),
      room: Math.floor(mk?.demand[g] ?? 0),
    })),
  }
}

/** 给面板用的整块快照。 */
export function routesSnapshot(
  state: GameState,
  ctx: ContentContext,
  bonuses: TechBonuses,
  day: number,
): Record<string, unknown> {
  const cargo = cargoCap(ctx, bonuses)
  const purse = purseCap(ctx, bonuses)
  const list = state.routes.routes.map((r) => {
    const city = cityOf(ctx, r.cityId)
    const ready = routeReadiness(state, ctx, bonuses, r)
    return {
      id: r.id,
      cityId: r.cityId,
      cityName: city?.nameZh ?? '',
      days: city?.days ?? 0,
      phase: r.phase,
      departDay: r.departDay,
      arriveDay: r.arriveDay,
      backDay: r.backDay,
      day,
      budget: r.budget,
      sellPlan: r.sellPlan,
      loaded: r.loaded,
      readyGoods: ready.readyGoods,
      readyMoney: ready.readyMoney,
      shortGoods: ready.shortGoods,
      needMoney: ready.needMoney,
      lastTripDay: r.lastTripDay,
      cargo,
      purse,
    }
  })
  return {
    unlocked: routesUnlocked(ctx, bonuses),
    count: list.length,
    maxCount: ctx.routes.caravan.maxCount,
    cargo,
    purse,
    routes: list,
    cities: ctx.routes.cities.map((c) => ({
      id: c.id,
      nameZh: c.nameZh,
      days: c.days,
      unlocked: cityUnlocked(state, c),
    })),
  }
}

/** 应用一次 `techBonuses`（省得调用方重复传 ctx）。 */
export function routeBonuses(state: GameState, ctx: ContentContext): TechBonuses {
  return techBonuses(state, ctx)
}
