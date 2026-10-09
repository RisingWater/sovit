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

export const PACKS: Record<PackID, ContentPack> = {
  'v0.1': {
    id: 'v0.1',
    nameZh: 'v0.1 面包与蔬菜',
    goods: V01_GOODS,
    buildings: V01_BUILDINGS,
    classes: V01_CLASSES,
    housing: [],
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
