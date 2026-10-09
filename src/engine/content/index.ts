import type { BuildingID, ClassID, ContentPack, GoodID, PackID } from '../types.ts'
import { ALL_GOODS, GOOD_IDS } from './goods.ts'
import { ALL_RECIPES, RECIPE_BY_BUILDING } from './recipes.ts'
import { ALL_BUILDINGS, BUILDING_IDS } from './buildings.ts'
import { ALL_CLASSES, CLASS_IDS } from './classes.ts'
import { ALL_HOUSING } from './housing.ts'

export { ALL_GOODS, GOOD_IDS } from './goods.ts'
export { ALL_RECIPES, RECIPE_BY_BUILDING } from './recipes.ts'
export { ALL_BUILDINGS, BUILDING_IDS } from './buildings.ts'
export { ALL_CLASSES, CLASS_IDS } from './classes.ts'
export { ALL_HOUSING } from './housing.ts'

// ---------------------------------------------------------------------------
// Content packs
//
// v0.1 只启用面包链 + 蔬菜链；v1.0 启用全部内容。
// 全量数据始终存在，pack 只是「当前这局允许出现什么」的过滤清单。
// ---------------------------------------------------------------------------

const V01_GOODS: GoodID[] = ['wheat', 'coarse_flour', 'coarse_bread', 'vegetable']
const V01_BUILDINGS: BuildingID[] = ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']
const V01_CLASSES: ClassID[] = ['poor']

// v0.2：在 v0.1 之上加入「木材 / 粘土 → 燃料 / 砖 → 住房」建材链，解锁人口增长。
const V02_GOODS: GoodID[] = [
  'wheat', 'coarse_flour', 'coarse_bread', 'vegetable',
  'wood', 'stone', 'clay', 'firewood', 'brick', 'hut',
]
const V02_BUILDINGS: BuildingID[] = [
  'wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm',
  'lumberjack', 'quarry', 'clay_pit', 'firewood_works', 'brick_kiln',
]
const V02_CLASSES: ClassID[] = ['poor']

// v0.3：在 v0.2 之上加入中产/富人消费链（白面包 / 糕点 / 成衣）与三级住房，形成分层社会。
const V03_GOODS: GoodID[] = [
  'wheat', 'coarse_flour', 'coarse_bread', 'vegetable',
  'fine_flour', 'white_bread', 'sugarcane', 'sugar', 'pastry',
  'flax', 'cotton', 'dye', 'coarse_cloth', 'fine_cloth',
  'coarse_clothes', 'common_clothes', 'luxury_clothes', 'leather_clothes',
  'hide', 'meat', 'fish', 'smoked_fish', 'dried_meat', 'pottery',
  'wood', 'stone', 'clay', 'firewood', 'brick',
]
const V03_BUILDINGS: BuildingID[] = [
  'wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm',
  'fine_mill', 'white_bakery', 'sugarcane_farm', 'sugar_works', 'pastry_shop',
  'flax_farm', 'cotton_farm', 'dye_farm', 'coarse_weaver', 'fine_weaver',
  'coarse_clothes_shop', 'common_clothes_shop', 'luxury_clothes_shop', 'leather_shop',
  'hunting_camp', 'fishery', 'smokehouse', 'dried_meat_works', 'pottery_works',
  'lumberjack', 'quarry', 'clay_pit', 'firewood_works', 'brick_kiln',
]
const V03_CLASSES: ClassID[] = ['poor', 'middle', 'rich', 'boss']

export const PACKS: Record<PackID, ContentPack> = {
  'v0.1': {
    id: 'v0.1',
    nameZh: 'v0.1 面包与蔬菜',
    goods: V01_GOODS,
    buildings: V01_BUILDINGS,
    classes: V01_CLASSES,
    housing: [],
  },
  'v0.2': {
    id: 'v0.2',
    nameZh: 'v0.2 住房与建材',
    goods: V02_GOODS,
    buildings: V02_BUILDINGS,
    classes: V02_CLASSES,
    housing: ['hut'],
  },
  'v0.3': {
    id: 'v0.3',
    nameZh: 'v0.3 分层社会',
    goods: V03_GOODS,
    buildings: V03_BUILDINGS,
    classes: V03_CLASSES,
    housing: ['hut', 'wooden_house', 'brick_house'],
  },
  'v1.0': {
    id: 'v1.0',
    nameZh: 'v1.0 完整经济',
    goods: GOOD_IDS,
    buildings: BUILDING_IDS,
    classes: CLASS_IDS,
    housing: ['hut', 'wooden_house', 'brick_house'],
  },
}

export function getPack(id: PackID): ContentPack {
  const pack = PACKS[id]
  if (!pack) throw new Error(`unknown content pack: ${id}`)
  return pack
}

/** 奢侈品（衣物 / 日用 / 糕点）：低价格弹性，可通过对富人提价抽取财富。 */
export function isLuxuryGood(gid: GoodID): boolean {
  const g = ALL_GOODS[gid]
  if (!g) return false
  return g.category === 'clothing' || g.category === 'household' || g.id === 'pastry'
}

export interface ContentContext {
  pack: ContentPack
  goods: typeof ALL_GOODS
  buildings: typeof ALL_BUILDINGS
  recipes: typeof ALL_RECIPES
  classes: typeof ALL_CLASSES
  housing: typeof ALL_HOUSING
  goodSet: Set<GoodID>
  buildingSet: Set<BuildingID>
  classSet: Set<ClassID>
}

/** 为某一 pack 构造带快查集合的内容上下文。 */
export function buildContext(packId: PackID): ContentContext {
  const pack = getPack(packId)
  return {
    pack,
    goods: ALL_GOODS,
    buildings: ALL_BUILDINGS,
    recipes: ALL_RECIPES,
    classes: ALL_CLASSES,
    housing: ALL_HOUSING,
    goodSet: new Set(pack.goods),
    buildingSet: new Set(pack.buildings),
    classSet: new Set(pack.classes),
  }
}
