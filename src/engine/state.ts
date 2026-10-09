import type {
  ClassID,
  GameState,
  PackID,
  Resident,
  Shop,
} from './types.ts'
import { ALL_BUILDINGS, ALL_GOODS, buildContext } from './content/index.ts'
import { ECONOMY } from './config.ts'
import { createRng } from './rng.ts'

// ---------------------------------------------------------------------------
// 初始状态
// ---------------------------------------------------------------------------

/** 各 pack 的开局建筑布局。 */
const START_LAYOUT: Record<PackID, Array<[string, number]>> = {
  'v0.1': [
    ['wheat_farm', 1],
    ['coarse_mill', 1],
    ['coarse_bakery', 1],
    ['vegetable_farm', 1],
  ],
  'v0.2': [
    ['wheat_farm', 1],
    ['coarse_mill', 1],
    ['coarse_bakery', 1],
    ['vegetable_farm', 1],
    ['lumberjack', 2],
    ['quarry', 1],
    ['clay_pit', 1],
  ],
  'v0.3': [], // 空开局：只有资源与几间茅屋，其余全靠建造
  'v1.0': [
    ['wheat_farm', 1],
    ['coarse_mill', 1],
    ['coarse_bakery', 1],
    ['vegetable_farm', 1],
    ['lumberjack', 1],
    ['quarry', 1],
    ['clay_pit', 1],
    ['construction_works', 1],
  ],
}

const START_GOODS: Record<string, number> = {
  wheat: 20,
  coarse_flour: 10,
  coarse_bread: 20,
  vegetable: 10,
  wood: 30,
  stone: 15,
  clay: 15,
}

/** v0.3 空开局：给大量资源，让玩家自己建。 */
const START_GOODS_V03: Record<string, number> = {
  coarse_bread: 200,
  vegetable: 100,
  wood: 300,
  stone: 150,
  clay: 150,
  firewood: 80,
  brick: 80,
  build_power: 80,
}

/** 开局住房存量：足够容纳初始人口的茅屋。 */
const START_HOUSING: Record<string, number> = { hut: 6 }
const START_HOUSING_V03: Record<string, number> = { hut: 3 }

/** 各 pack 的初始人口。 */
const START_POP_BY_PACK: Record<PackID, number> = {
  'v0.1': 16,
  'v0.2': 24,
  'v0.3': 12,
  'v1.0': 16,
}

/** 各 pack 的初始资金。 */
const START_MONEY_BY_PACK: Record<PackID, number> = {
  'v0.1': 1000,
  'v0.2': 1000,
  'v0.3': 2000,
  'v1.0': 1000,
}

/** 开局阶层分布：v0.1 只启用穷人。 */
const START_DISTRIBUTION: ClassID[] = ['poor']

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

  const startGoods = packId === 'v0.3' ? START_GOODS_V03 : START_GOODS
  const goods: Record<string, number> = {}
  const prices: Record<string, number> = {}
  for (const gid of ctx.pack.goods) {
    goods[gid] = startGoods[gid] ?? 0
    if (ALL_GOODS[gid]?.category === 'housing') continue
    prices[gid] = ALL_GOODS[gid]?.baseValue ?? 1
  }
  // 住房售价（私有化价格，玩家可调）
  for (const gid of ctx.pack.housing) {
    prices[gid] = ctx.housing[gid]?.salePrice ?? ALL_GOODS[gid]?.baseValue ?? 1
  }

  const startHousing = packId === 'v0.3' ? START_HOUSING_V03 : START_HOUSING
  const housing: Record<string, number> = {}
  const privateHousing: Record<string, number> = {}
  for (const gid of ctx.pack.housing) {
    housing[gid] = startHousing[gid] ?? 0
    privateHousing[gid] = 0
  }

  const shops: Shop[] = []
  for (const [defId, count] of START_LAYOUT[packId]) {
    if (!ctx.buildingSet.has(defId)) continue
    for (let i = 0; i < count; i++) {
      const def = ALL_BUILDINGS[defId]
      if (!def) continue
      shops.push({
        id: `${defId}#${i + 1}`,
        defId,
        owner: 'state',
        targetWorkers: def.workers,
        wage: ECONOMY.refWage,
        wageCap: ECONOMY.defaultWageCap,
        level: 1,
        active: true,
        profit: 0,
        skill: 50,
      })
    }
  }

  const population = options.population ?? START_POP_BY_PACK[packId]
  const residents: Resident[] = []
  for (let i = 0; i < population; i++) {
    const classId = START_DISTRIBUTION[i % START_DISTRIBUTION.length] ?? 'poor'
    residents.push({
      id: `res#${i + 1}`,
      classId,
      savings: 12,
      satisfaction: 65,
      skill: 30 + Math.floor(rng.next() * 40),
      employed: false,
    })
  }

  const money = options.money ?? START_MONEY_BY_PACK[packId]

  return {
    pack: packId,
    seed,
    rngState: rng.state,
    day: 0,
    government: {
      money,
      taxBrackets: ECONOMY.defaultTaxBrackets.map((b) => ({ ...b })),
      rent: ECONOMY.defaultRent,
      subsidyBudget: 0,
      immigrationAllowance: 1e9,
    },
    goods,
    housing,
    privateHousing,
    prices,
    shops,
    residents,
    construction: [],
    history: [
      {
        day: 0,
        population,
        avgSatisfaction: 65,
        money,
        hungry: 0,
        employed: 0,
      },
    ],
    log: [],
    alerts: [],
    arrivals: 0,
  }
}
