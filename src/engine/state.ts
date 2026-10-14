import type { DayLedger, GameState, PackID, Resident, Shop } from './types.ts'
import { ALL_BUILDINGS, ALL_GOODS, buildContext } from './content/index.ts'
import { DEFAULTS, ECONOMY } from './config.ts'
import { createRng } from './rng.ts'

/** 空白台账 / 空白个人账目。逐人账目与每日台账分开放，方便将来做差异化分配。 */
export function emptyLedger(day: number): DayLedger {
  return { day, wages: 0, tax: 0, rent: 0, sales: 0, produced: {}, consumed: {}, bought: {} }
}

// ---------------------------------------------------------------------------
// 初始状态
//
// 开局场景（人口 / 资金 / 建筑 / 住房 / 库存）由 content/packs.json 的
// 每个 pack 的 start 定义；新建实体默认值来自 content/economy.json 的 defaults。
// ---------------------------------------------------------------------------

export interface CreateOptions {
  pack?: PackID
  seed?: number
  population?: number
  money?: number
}

export function createInitialState(options: CreateOptions = {}): GameState {
  const packId = options.pack ?? 'v0.3'
  const seed = options.seed ?? 12345
  const ctx = buildContext(packId)
  const rng = createRng(seed)
  const start = ctx.pack.start

  const goods: Record<string, number> = {}
  const prices: Record<string, number> = {}
  for (const gid of ctx.pack.goods) {
    goods[gid] = start.goods[gid] ?? 0
    if (ALL_GOODS[gid]?.category === 'housing') continue
    prices[gid] = ALL_GOODS[gid]?.baseValue ?? 1
  }
  // 住房售价（私有化价格，玩家可调）
  const housing: Record<string, number> = {}
  const privateHousing: Record<string, number> = {}
  for (const gid of ctx.pack.housing) {
    housing[gid] = start.housing[gid] ?? 0
    privateHousing[gid] = 0
    prices[gid] = ctx.housing[gid]?.salePrice ?? ALL_GOODS[gid]?.baseValue ?? 1
  }

  const shops: Shop[] = []
  for (const [defId, count] of Object.entries(start.shops)) {
    if (!ctx.buildingSet.has(defId)) continue
    const def = ALL_BUILDINGS[defId]
    if (!def) continue
    for (let i = 0; i < Math.floor(count); i++) {
      shops.push({
        id: `${defId}#${i + 1}`,
        defId,
        owner: 'state',
        targetWorkers: def.workers,
        wage: ECONOMY.refWage,
        wageCap: ECONOMY.defaultWageCap,
        level: DEFAULTS.newShop.level,
        active: true,
        profit: 0,
        skill: DEFAULTS.newShop.skill,
        planned: 0,
        toolBoost: 1,
      })
    }
  }

  const population = options.population ?? start.population
  const rd = DEFAULTS.startResident
  const distribution =
    DEFAULTS.startDistribution.length > 0 ? DEFAULTS.startDistribution : ['poor']
  const residents: Resident[] = []
  for (let i = 0; i < population; i++) {
    residents.push({
      id: `res#${i + 1}`,
      classId: distribution[i % distribution.length] ?? 'poor',
      savings: rd.savings,
      satisfaction: rd.satisfaction,
      skill: rd.skillBase + Math.floor(rng.next() * rd.skillRandom),
      employed: false,
    })
  }

  const money = options.money ?? start.money

  return {
    pack: packId,
    seed,
    villageName: 'sovit',
    rngState: rng.state,
    day: 0,
    hour: 0,
    pending: [],
    reserved: {},
    government: {
      money,
      taxBrackets: ECONOMY.defaultTaxBrackets.map((b) => ({ ...b })),
      rent: ECONOMY.defaultRent,
      subsidyBudget: 0,
      populationCap: 1e9,
      storageCaps: {},
    },
    goods,
    housing,
    privateHousing,
    prices,
    shops,
    residents,
    construction: [],
    // 开局已研究的科技来自 pack.start.techs（缺省空 = 只有无科技锁的建筑可建）
    research: { done: [...(start.techs ?? [])], queue: [] },
    ledgerToday: emptyLedger(0),
    // 当日建造力预算：由黎明 planConstructionDay 钉死（开局为 0，黎明那一小时算出来）
    constructionRateToday: 0,
    constructionWorkToday: 0,
    // 当日科研力预算：由黎明 planResearchDay 钉死（开局为 0，黎明那一小时算出来）
    researchRateToday: 0,
    researchWorkToday: 0,
    history: [
      {
        day: 0,
        population,
        avgSatisfaction: rd.satisfaction,
        money,
        hungry: 0,
        employed: 0,
        ledger: emptyLedger(0),
      },
    ],
    log: [],
    alerts: [],
    arrivals: 0,
  }
}
