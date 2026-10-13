import type {
  BuildingArt,
  BuildingDef,
  BuildingID,
  BuildingTier,
  ClassDef,
  ClassID,
  ContentPack,
  GoodCategory,
  GoodDef,
  GoodID,
  GoodTier,
  HousingDef,
  NeedDef,
  PackID,
  PackStart,
  RecipeDef,
  RecipeID,
} from '../types.ts'
import type { DefaultsConfig, EconomyConfig, TimeConfig, TuningConfig } from '../config.ts'
import type { RawContent } from './load.ts'

// ---------------------------------------------------------------------------
// 内容校验 + 组装
//
// 把 JSON（unknown）逐个字段校验后转成引擎用的强类型表。
// 任何错误都带「字段路径」抛出，方便改 JSON 时定位。
// ---------------------------------------------------------------------------

export interface ParsedContent {
  goods: Record<GoodID, GoodDef>
  goodIds: GoodID[]
  buildings: Record<BuildingID, BuildingDef>
  buildingIds: BuildingID[]
  recipes: Record<RecipeID, RecipeDef>
  recipeByBuilding: Record<string, RecipeDef>
  classes: Record<ClassID, ClassDef>
  classIds: ClassID[]
  housing: Record<GoodID, HousingDef>
  housingIds: GoodID[]
  packs: Record<PackID, ContentPack>
  packIds: PackID[]
  economy: EconomyConfig
  defaults: DefaultsConfig
  tuning: TuningConfig
  time: TimeConfig
}

const SCHEMA_VERSION = 1

const CATEGORIES: readonly GoodCategory[] = [
  'raw', 'food', 'clothing', 'household', 'fuel', 'material', 'housing', 'investment', 'service', 'entertainment',
]

function fail(msg: string): never {
  throw new Error(`[content] ${msg}`)
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asObj(v: unknown, p: string): Record<string, unknown> {
  if (!isRecord(v)) fail(`${p} 必须是对象`)
  return v
}

function asArr(v: unknown, p: string): unknown[] {
  if (!Array.isArray(v)) fail(`${p} 必须是数组`)
  return v
}

function asStr(v: unknown, p: string): string {
  if (typeof v !== 'string' || v.length === 0) fail(`${p} 必须是非空字符串`)
  return v
}

function asNum(v: unknown, p: string): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) fail(`${p} 必须是数字`)
  return v
}

function asPos(v: unknown, p: string): number {
  const n = asNum(v, p)
  if (n <= 0) fail(`${p} 必须 > 0`)
  return n
}

function asNonNeg(v: unknown, p: string): number {
  const n = asNum(v, p)
  if (n < 0) fail(`${p} 不能为负`)
  return n
}

function asRate(v: unknown, p: string): number {
  const n = asNum(v, p)
  if (n < 0 || n > 1) fail(`${p} 必须在 0–1`)
  return n
}

function asBool(v: unknown, p: string): boolean {
  if (typeof v !== 'boolean') fail(`${p} 必须是布尔值`)
  return v
}

function asEnum<T extends string>(v: unknown, allowed: readonly T[], p: string): T {
  const s = asStr(v, p)
  if (!(allowed as readonly string[]).includes(s)) {
    fail(`${p} 取值非法：${s}（允许：${allowed.join(' / ')}）`)
  }
  return s as T
}

function asNumEnum<T extends number>(v: unknown, allowed: readonly T[], p: string): T {
  const n = asNum(v, p)
  if (!(allowed as readonly number[]).includes(n)) {
    fail(`${p} 取值非法：${n}（允许：${allowed.join(' / ')}）`)
  }
  return n as T
}

/** 商品数量表（inputs / output / buildCost）。 */
function numMap(v: unknown, p: string, goodSet: Set<string>): Record<string, number> {
  if (v === undefined) return {}
  const o = asObj(v, p)
  const out: Record<string, number> = {}
  for (const [k, val] of Object.entries(o)) {
    if (!goodSet.has(k)) fail(`${p}.${k} 引用了未定义的商品`)
    out[k] = asNonNeg(val, `${p}.${k}`)
  }
  return out
}

function strArr(v: unknown, p: string, set?: Set<string>): string[] {
  return asArr(v, p).map((x, i) => {
    const s = asStr(x, `${p}[${i}]`)
    if (set && !set.has(s)) fail(`${p}[${i}] 引用了未定义的内容：${s}`)
    return s
  })
}

// ---------------------------------------------------------------------------
// 外观规格
// ---------------------------------------------------------------------------

const ART_ARCHS = ['house', 'extract', 'mill', 'bakery', 'kiln', 'workshop', 'grand', 'warehouse', 'field', 'prop'] as const
const ART_ROOFS = ['blue', 'red', 'green'] as const
const ART_WALLS = ['wood', 'stone', 'barn', 'plank'] as const
const ART_FEATS = ['windmill', 'wheel', 'logs', 'rocks'] as const
const ART_CROPS = ['wheat', 'cabbage', 'sprout', 'bush', 'corn', 'tomato'] as const
const ART_SOILS = ['row5', 'row6'] as const

function parseArt(v: unknown, p: string): BuildingArt | undefined {
  if (v === undefined) return undefined
  const o = asObj(v, p)
  const arch = asEnum(o.arch, ART_ARCHS, `${p}.arch`)
  const art: BuildingArt = { arch }

  if (o.roof !== undefined) art.roof = asEnum(o.roof, ART_ROOFS, `${p}.roof`)
  if (o.wall !== undefined) art.wall = asEnum(o.wall, ART_WALLS, `${p}.wall`)
  if (o.w !== undefined) {
    const w = asNum(o.w, `${p}.w`)
    if (!Number.isInteger(w) || w < 2 || w > 12) fail(`${p}.w 必须是 2–12 的整数`)
    art.w = w
  }
  if (o.rows !== undefined) {
    const r = asNum(o.rows, `${p}.rows`)
    if (!Number.isInteger(r) || r < 1 || r > 12) fail(`${p}.rows 必须是 1–12 的整数`)
    art.rows = r
  }
  if (o.chimney !== undefined) art.chimney = asBool(o.chimney, `${p}.chimney`)
  if (o.feat !== undefined) {
    art.feat = asArr(o.feat, `${p}.feat`).map((x, i) => asEnum(x, ART_FEATS, `${p}.feat[${i}]`))
  }
  if (o.soil !== undefined) art.soil = asEnum(o.soil, ART_SOILS, `${p}.soil`)
  if (o.crop !== undefined) art.crop = asEnum(o.crop, ART_CROPS, `${p}.crop`)
  if (o.sprite !== undefined) {
    const s = asStr(o.sprite, `${p}.sprite`)
    if (!/^[a-z0-9_]+$/.test(s)) fail(`${p}.sprite 只能用小写字母/数字/下划线：${s}`)
    art.sprite = s
  }

  if (arch === 'field') {
    if (!art.soil) fail(`${p}：arch=field 必须给 soil`)
    if (!art.crop) fail(`${p}：arch=field 必须给 crop`)
    if (art.roof || art.wall) fail(`${p}：arch=field 不应给 roof / wall`)
  } else if (arch === 'prop') {
    if (!art.sprite) fail(`${p}：arch=prop 必须给 sprite`)
    if (art.w) fail(`${p}：arch=prop 的 w 由 gen-art 按图算出，不要手填`)
    if (art.rows) fail(`${p}：arch=prop 的 rows 由 gen-art 按图算出，不要手填`)
    if (art.roof || art.wall || art.soil || art.crop) {
      fail(`${p}：arch=prop 不应给 roof / wall / soil / crop`)
    }
  } else {
    if (!art.roof) fail(`${p}：arch=${arch} 必须给 roof`)
    if (!art.wall) fail(`${p}：arch=${arch} 必须给 wall`)
    if (art.soil || art.crop) fail(`${p}：arch=${arch} 不应给 soil / crop`)
  }
  return art
}

// ---------------------------------------------------------------------------

function parseGoods(raw: unknown): { goods: Record<GoodID, GoodDef>; ids: GoodID[] } {
  const list = asArr(asObj(raw, 'goods.json').goods, 'goods.json.goods')
  const goods: Record<GoodID, GoodDef> = {}
  const ids: GoodID[] = []
  list.forEach((item, i) => {
    const p = `goods[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`)
    if (goods[id]) fail(`${p}.id 重复：${id}`)
    const perishRate = o.perishRate === undefined ? undefined : asNonNeg(o.perishRate, `${p}.perishRate`)
    if (perishRate !== undefined && perishRate > 1) fail(`${p}.perishRate 必须在 0–1`)
    goods[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      tier: asNumEnum(o.tier, [0, 1, 2, 3], `${p}.tier`) as GoodTier,
      category: asEnum(o.category, CATEGORIES, `${p}.category`),
      storable: asBool(o.storable, `${p}.storable`),
      baseValue: asNonNeg(o.baseValue, `${p}.baseValue`),
      luxury: o.luxury === undefined ? false : asBool(o.luxury, `${p}.luxury`),
      ...(perishRate !== undefined ? { perishRate } : {}),
    }
    ids.push(id)
  })
  return { goods, ids }
}

function parseBuildings(
  raw: unknown,
  goodSet: Set<string>,
): {
  buildings: Record<BuildingID, BuildingDef>
  ids: BuildingID[]
  recipes: Record<RecipeID, RecipeDef>
  recipeByBuilding: Record<string, RecipeDef>
} {
  const list = asArr(asObj(raw, 'buildings.json').buildings, 'buildings.json.buildings')
  const buildings: Record<BuildingID, BuildingDef> = {}
  const ids: BuildingID[] = []
  const recipes: Record<RecipeID, RecipeDef> = {}
  const recipeByBuilding: Record<string, RecipeDef> = {}

  list.forEach((item, i) => {
    const p = `buildings[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`)
    if (buildings[id]) fail(`${p}.id 重复：${id}`)

    const workers = asPos(o.workers, `${p}.workers`)
    const maxWorkers = o.maxWorkers === undefined ? undefined : asPos(o.maxWorkers, `${p}.maxWorkers`)
    if (maxWorkers !== undefined && maxWorkers < workers) {
      fail(`${p}.maxWorkers（${maxWorkers}）不能小于 workers（${workers}）`)
    }

    const r = asObj(o.recipe, `${p}.recipe`)
    const output = numMap(r.output, `${p}.recipe.output`, goodSet)
    if (Object.keys(output).length === 0) fail(`${p}.recipe.output 不能为空`)
    const fuel = r.fuel === undefined ? undefined : asNonNeg(r.fuel, `${p}.recipe.fuel`)
    const recipe: RecipeDef = {
      id: `r_${id}`,
      building: id,
      inputs: numMap(r.inputs, `${p}.recipe.inputs`, goodSet),
      output,
      baseRate: asPos(r.baseRate, `${p}.recipe.baseRate`),
      ...(fuel !== undefined ? { fuel } : {}),
    }

    const buildCost = numMap(o.buildCost, `${p}.buildCost`, goodSet)
    const art = parseArt(o.art, `${p}.art`)
    // 施工工时（人·天）。设计见 docs/construction.md。
    // 目前引擎尚未使用它（施工仍走 constructionDays），先入库以便逐步迁移。
    const buildWork = o.buildWork === undefined ? undefined : asPos(o.buildWork, `${p}.buildWork`)
    buildings[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      tier: asNumEnum(o.tier, [1, 2, 3], `${p}.tier`) as BuildingTier,
      workers,
      ...(maxWorkers !== undefined ? { maxWorkers } : {}),
      recipe: recipe.id,
      ...(buildWork !== undefined ? { buildWork } : {}),
      ...(Object.keys(buildCost).length > 0 ? { buildCost } : {}),
      ...(art !== undefined ? { art } : {}),
    }
    if (recipes[recipe.id]) fail(`${p}.recipe 与其它建筑 id 冲突：${recipe.id}`)
    ids.push(id)
    recipes[recipe.id] = recipe
    recipeByBuilding[id] = recipe
  })

  return { buildings, ids, recipes, recipeByBuilding }
}

function parseClasses(
  raw: unknown,
  goodSet: Set<string>,
): { classes: Record<ClassID, ClassDef>; ids: ClassID[] } {
  const list = asArr(asObj(raw, 'classes.json').classes, 'classes.json.classes')
  const classes = {} as Record<ClassID, ClassDef>
  const ids: ClassID[] = []

  list.forEach((item, i) => {
    const p = `classes[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`) as ClassID
    if (classes[id]) fail(`${p}.id 重复：${id}`)

    const needs: NeedDef[] = asArr(o.needs, `${p}.needs`).map((n, j) => {
      const np = `${p}.needs[${j}]`
      const no = asObj(n, np)
      const good = asStr(no.good, `${np}.good`)
      if (!goodSet.has(good)) fail(`${np}.good 引用了未定义的商品：${good}`)
      const fallbacks = no.fallbacks === undefined ? undefined : strArr(no.fallbacks, `${np}.fallbacks`, goodSet)
      return {
        good,
        perCapita: asPos(no.perCapita, `${np}.perCapita`),
        ...(fallbacks ? { fallbacks } : {}),
      }
    })

    classes[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      incomeBase: asNonNeg(o.incomeBase, `${p}.incomeBase`),
      satBonus: asNum(o.satBonus, `${p}.satBonus`),
      housingLevel: asNumEnum(o.housingLevel, [1, 2, 3], `${p}.housingLevel`),
      wealthThreshold: asNonNeg(o.wealthThreshold, `${p}.wealthThreshold`),
      needs,
    }
    ids.push(id)
  })

  return { classes, ids }
}

function parseHousing(
  raw: unknown,
  classSet: Set<string>,
  goodSet: Set<string>,
): { housing: Record<GoodID, HousingDef>; ids: GoodID[] } {
  const list = asArr(asObj(raw, 'housing.json').housing, 'housing.json.housing')
  const housing: Record<GoodID, HousingDef> = {}
  const ids: GoodID[] = []

  list.forEach((item, i) => {
    const p = `housing[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`)
    if (housing[id]) fail(`${p}.id 重复：${id}`)
    const classId = asStr(o.classId, `${p}.classId`) as ClassID
    if (!classSet.has(classId)) fail(`${p}.classId 引用了未定义的阶层：${classId}`)
    const buildCost = numMap(o.buildCost, `${p}.buildCost`, goodSet)
    const salePrice = o.salePrice === undefined ? undefined : asNonNeg(o.salePrice, `${p}.salePrice`)
    const art = parseArt(o.art, `${p}.art`)
    const buildWork = o.buildWork === undefined ? undefined : asPos(o.buildWork, `${p}.buildWork`)
    housing[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      quality: asNumEnum(o.quality, [1, 2, 3], `${p}.quality`),
      capacity: asPos(o.capacity, `${p}.capacity`),
      classId,
      ...(buildWork !== undefined ? { buildWork } : {}),
      ...(Object.keys(buildCost).length > 0 ? { buildCost } : {}),
      ...(salePrice !== undefined ? { salePrice } : {}),
      ...(art !== undefined ? { art } : {}),
    }
    ids.push(id)
  })

  return { housing, ids }
}

function parseStart(
  raw: unknown,
  p: string,
  goodSet: Set<string>,
  buildingSet: Set<string>,
  housingSet: Set<string>,
): PackStart {
  const s = asObj(raw, p)
  return {
    population: asNonNeg(s.population, `${p}.population`),
    money: asNonNeg(s.money, `${p}.money`),
    shops: numMap(s.shops, `${p}.shops`, buildingSet),
    housing: numMap(s.housing, `${p}.housing`, housingSet),
    goods: numMap(s.goods, `${p}.goods`, goodSet),
  }
}

function parsePacks(
  raw: unknown,
  goodSet: Set<string>,
  buildingSet: Set<string>,
  classSet: Set<string>,
  housingSet: Set<string>,
): { packs: Record<PackID, ContentPack>; ids: PackID[] } {
  const list = asArr(asObj(raw, 'packs.json').packs, 'packs.json.packs')
  const packs = {} as Record<PackID, ContentPack>
  const ids: PackID[] = []

  list.forEach((item, i) => {
    const p = `packs[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`) as PackID
    if (packs[id]) fail(`${p}.id 重复：${id}`)
    packs[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      goods: strArr(o.goods, `${p}.goods`, goodSet),
      buildings: strArr(o.buildings, `${p}.buildings`, buildingSet),
      classes: strArr(o.classes, `${p}.classes`, classSet) as ClassID[],
      housing: strArr(o.housing, `${p}.housing`, housingSet),
      start: parseStart(o.start, `${p}.start`, goodSet, buildingSet, housingSet),
    }
    ids.push(id)
  })

  return { packs, ids }
}

function parsePerson(o: Record<string, unknown>, p: string): DefaultsConfig['newResident'] {
  return {
    savings: asNonNeg(o.savings, `${p}.savings`),
    satisfaction: asNonNeg(o.satisfaction, `${p}.satisfaction`),
    skillBase: asNonNeg(o.skillBase, `${p}.skillBase`),
    skillRandom: asNonNeg(o.skillRandom, `${p}.skillRandom`),
  }
}

function parseEconomy(
  raw: unknown,
  goodSet: Set<string>,
  classSet: Set<string>,
): { economy: EconomyConfig; defaults: DefaultsConfig; tuning: TuningConfig; time: TimeConfig } {
  const root = asObj(raw, 'economy.json')
  const sv = asNonNeg(root.schemaVersion, 'economy.json.schemaVersion')
  if (sv !== SCHEMA_VERSION) {
    fail(`content schemaVersion = ${sv}，本引擎只支持 ${SCHEMA_VERSION}`)
  }
  const e = asObj(root.economy, 'economy.json.economy')
  const d = asObj(root.defaults, 'economy.json.defaults')
  const t = asObj(root.tuning, 'economy.json.tuning')
  const tc = asObj(root.time, 'economy.json.time')

  const hoursPerDay = asPos(tc.hoursPerDay, 'time.hoursPerDay')
  const dawnHour = asNum(tc.dawnHour, 'time.dawnHour')
  const workStart = asNum(tc.workStart, 'time.workStart')
  const workEnd = asNum(tc.workEnd, 'time.workEnd')
  const settleHour = asNum(tc.settleHour, 'time.settleHour')
  for (const [k, v] of Object.entries({ dawnHour, workStart, workEnd, settleHour })) {
    if (!Number.isInteger(v) || v < 0 || v >= hoursPerDay) {
      fail(`time.${k} 必须是 [0,${hoursPerDay}) 内的整数`)
    }
  }
  if (workEnd <= workStart) fail('time.workEnd 必须大于 workStart')
  const time: TimeConfig = {
    hoursPerDay,
    dawnHour,
    workStart,
    workEnd,
    settleHour,
    tickSec: asPos(tc.tickSec, 'time.tickSec'),
  }

  const weights = asObj(e.weights, 'economy.weights')
  const bmt = asObj(e.buildMoneyByTier, 'economy.buildMoneyByTier')
  const maxSlots =
    e.maxBuildingSlots === null || e.maxBuildingSlots === undefined
      ? Infinity
      : asNonNeg(e.maxBuildingSlots, 'economy.maxBuildingSlots')

  const economy: EconomyConfig = {
    refWage: asNonNeg(e.refWage, 'economy.refWage'),
    welfareRate: asNonNeg(e.welfareRate, 'economy.welfareRate'),
    defaultTaxBrackets: asArr(e.defaultTaxBrackets, 'economy.defaultTaxBrackets').map((b, i) => {
      const bp = `economy.defaultTaxBrackets[${i}]`
      const bo = asObj(b, bp)
      const upTo = bo.upTo === null || bo.upTo === undefined ? null : asNonNeg(bo.upTo, `${bp}.upTo`)
      const rate = asNum(bo.rate, `${bp}.rate`)
      if (rate < 0 || rate > 0.95) fail(`${bp}.rate 必须在 0–0.95`)
      return { upTo, rate }
    }),
    priceElasticity: asNonNeg(e.priceElasticity, 'economy.priceElasticity'),
    luxuryElasticity: asNonNeg(e.luxuryElasticity, 'economy.luxuryElasticity'),
    luxuryPriceMarkup: asNonNeg(e.luxuryPriceMarkup, 'economy.luxuryPriceMarkup'),
    satisfactionSmoothing: asRate(e.satisfactionSmoothing, 'economy.satisfactionSmoothing'),
    weights: {
      food: asNum(weights.food, 'economy.weights.food'),
      wage: asNum(weights.wage, 'economy.weights.wage'),
      price: asNum(weights.price, 'economy.weights.price'),
      employment: asNum(weights.employment, 'economy.weights.employment'),
      comfort: asNum(weights.comfort, 'economy.weights.comfort'),
    },
    priceIntercept: asNum(e.priceIntercept, 'economy.priceIntercept'),
    priceSlope: asNum(e.priceSlope, 'economy.priceSlope'),
    immigrationSatThreshold: asNum(e.immigrationSatThreshold, 'economy.immigrationSatThreshold'),
    immigrationRate: asNonNeg(e.immigrationRate, 'economy.immigrationRate'),
    emigrationSatThreshold: asNum(e.emigrationSatThreshold, 'economy.emigrationSatThreshold'),
    hungerDeathRate: asRate(e.hungerDeathRate, 'economy.hungerDeathRate'),
    minPopulation: asNonNeg(e.minPopulation, 'economy.minPopulation'),
    buildMoneyByTier: {
      1: asNonNeg(bmt['1'], 'economy.buildMoneyByTier.1'),
      2: asNonNeg(bmt['2'], 'economy.buildMoneyByTier.2'),
      3: asNonNeg(bmt['3'], 'economy.buildMoneyByTier.3'),
    },
    expandMoneyBase: asNonNeg(e.expandMoneyBase, 'economy.expandMoneyBase'),
    maxBuildingSlots: maxSlots,
    constructionDays: asNonNeg(e.constructionDays, 'economy.constructionDays'),
    defaultRent: asNonNeg(e.defaultRent, 'economy.defaultRent'),
    privateHousingSatBonus: asNum(e.privateHousingSatBonus, 'economy.privateHousingSatBonus'),
    privateTenantSatBonus: asNum(e.privateTenantSatBonus, 'economy.privateTenantSatBonus'),
    rentSatPenalty: asNonNeg(e.rentSatPenalty, 'economy.rentSatPenalty'),
    privateHousingNeedThreshold: asNum(e.privateHousingNeedThreshold, 'economy.privateHousingNeedThreshold'),
    privateHousingPerDay: asNonNeg(e.privateHousingPerDay, 'economy.privateHousingPerDay'),
    skillIncomeBase: asNonNeg(e.skillIncomeBase, 'economy.skillIncomeBase'),
    defaultWageCap: asNonNeg(e.defaultWageCap, 'economy.defaultWageCap'),
    housingQualityPenalty: asNonNeg(e.housingQualityPenalty, 'economy.housingQualityPenalty'),
    skillGainPerDay: asNonNeg(e.skillGainPerDay, 'economy.skillGainPerDay'),
    skillMax: asNonNeg(e.skillMax, 'economy.skillMax'),
    promotionSavings: asNonNeg(e.promotionSavings, 'economy.promotionSavings'),
    promotionSatThreshold: asNonNeg(e.promotionSatThreshold, 'economy.promotionSatThreshold'),
  }

  const newShop = asObj(d.newShop, 'defaults.newShop')
  const defaults: DefaultsConfig = {
    newShop: {
      level: asPos(newShop.level, 'defaults.newShop.level'),
      skill: asNonNeg(newShop.skill, 'defaults.newShop.skill'),
    },
    newResident: parsePerson(asObj(d.newResident, 'defaults.newResident'), 'defaults.newResident'),
    startResident: parsePerson(asObj(d.startResident, 'defaults.startResident'), 'defaults.startResident'),
    startDistribution: strArr(d.startDistribution, 'defaults.startDistribution') as ClassID[],
  }

  const tuning: TuningConfig = {
    skillEffectBase: asNonNeg(t.skillEffectBase, 'tuning.skillEffectBase'),
    skillEffectSlope: asNonNeg(t.skillEffectSlope, 'tuning.skillEffectSlope'),
    unemployedEmploymentScore: asNonNeg(t.unemployedEmploymentScore, 'tuning.unemployedEmploymentScore'),
    wageScoreCap: asPos(t.wageScoreCap, 'tuning.wageScoreCap'),
    hungryThreshold: asRate(t.hungryThreshold, 'tuning.hungryThreshold'),
    priceFactorMin: asNonNeg(t.priceFactorMin, 'tuning.priceFactorMin'),
    priceFactorMax: asPos(t.priceFactorMax, 'tuning.priceFactorMax'),
    basicFoods: strArr(t.basicFoods, 'tuning.basicFoods'),
    foodChainSeedClass: asStr(t.foodChainSeedClass, 'tuning.foodChainSeedClass') as ClassID,
  }

  // 交叉引用
  for (const g of tuning.basicFoods) {
    if (!goodSet.has(g)) fail(`tuning.basicFoods 引用了未定义的商品：${g}`)
  }
  if (!classSet.has(tuning.foodChainSeedClass)) {
    fail(`tuning.foodChainSeedClass 引用了未定义的阶层：${tuning.foodChainSeedClass}`)
  }
  for (const c of defaults.startDistribution) {
    if (!classSet.has(c)) fail(`defaults.startDistribution 引用了未定义的阶层：${c}`)
  }

  return { economy, defaults, tuning, time }
}

/** 校验并组装全部内容表。 */
export function parseContent(files: RawContent): ParsedContent {
  const { goods, ids: goodIds } = parseGoods(files.goods)
  const goodSet = new Set(goodIds)

  const { buildings, ids: buildingIds, recipes, recipeByBuilding } = parseBuildings(files.buildings, goodSet)
  const buildingSet = new Set(buildingIds)

  const { classes, ids: classIds } = parseClasses(files.classes, goodSet)
  const classSet = new Set(classIds)

  const { housing, ids: housingIds } = parseHousing(files.housing, classSet, goodSet)
  const housingSet = new Set(housingIds)

  const { packs, ids: packIds } = parsePacks(files.packs, goodSet, buildingSet, classSet, housingSet)
  const { economy, defaults, tuning, time } = parseEconomy(files.economy, goodSet, classSet)

  if (packIds.length === 0) fail('packs.json 至少要有一个内容包')

  return {
    goods, goodIds,
    buildings, buildingIds,
    recipes, recipeByBuilding,
    classes, classIds,
    housing, housingIds,
    packs, packIds,
    economy, defaults, tuning, time,
  }
}
