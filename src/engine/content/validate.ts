import type {
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
  RecipeDef,
  RecipeID,
} from '../types.ts'
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
}

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
    buildings[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      tier: asNumEnum(o.tier, [1, 2, 3], `${p}.tier`) as BuildingTier,
      workers,
      ...(maxWorkers !== undefined ? { maxWorkers } : {}),
      recipe: recipe.id,
      ...(Object.keys(buildCost).length > 0 ? { buildCost } : {}),
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
    housing[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      quality: asNumEnum(o.quality, [1, 2, 3], `${p}.quality`),
      capacity: asPos(o.capacity, `${p}.capacity`),
      classId,
      ...(Object.keys(buildCost).length > 0 ? { buildCost } : {}),
      ...(salePrice !== undefined ? { salePrice } : {}),
    }
    ids.push(id)
  })

  return { housing, ids }
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
    }
    ids.push(id)
  })

  return { packs, ids }
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

  if (packIds.length === 0) fail('packs.json 至少要有一个内容包')

  return {
    goods, goodIds,
    buildings, buildingIds,
    recipes, recipeByBuilding,
    classes, classIds,
    housing, housingIds,
    packs, packIds,
  }
}
