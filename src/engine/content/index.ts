import type {
  BuildingDef,
  BuildingID,
  ClassDef,
  ClassID,
  ContentPack,
  GoodDef,
  GoodID,
  HousingDef,
  PackID,
  RecipeDef,
  RecipeID,
} from '../types.ts'
import { loadContentFiles } from './load.ts'
import { parseContent } from './validate.ts'

// ---------------------------------------------------------------------------
// 内容表（由仓库根 content/*.json 驱动）
//
// 全量数据始终存在，pack 只是「当前这局允许出现什么」的过滤清单。
// 改内容 = 改 JSON，无需改代码。
// ---------------------------------------------------------------------------

const content = parseContent(loadContentFiles())

export const ALL_GOODS: Record<GoodID, GoodDef> = content.goods
export const GOOD_IDS: GoodID[] = content.goodIds

export const ALL_BUILDINGS: Record<BuildingID, BuildingDef> = content.buildings
export const BUILDING_IDS: BuildingID[] = content.buildingIds

export const ALL_RECIPES: Record<RecipeID, RecipeDef> = content.recipes
export const RECIPE_BY_BUILDING: Record<string, RecipeDef> = content.recipeByBuilding

export const ALL_CLASSES: Record<ClassID, ClassDef> = content.classes
export const CLASS_IDS: ClassID[] = content.classIds

export const ALL_HOUSING: Record<GoodID, HousingDef> = content.housing
export const HOUSING_IDS: GoodID[] = content.housingIds

export const PACKS: Record<PackID, ContentPack> = content.packs
export const PACK_IDS: PackID[] = content.packIds

export function getPack(id: PackID): ContentPack {
  const pack = PACKS[id]
  if (!pack) throw new Error(`unknown content pack: ${id}`)
  return pack
}

/** 奢侈品（衣物 / 日用 / 娱乐 / 糕点）：低价格弹性，可通过对富人提价抽取财富。 */
export function isLuxuryGood(gid: GoodID): boolean {
  const g = ALL_GOODS[gid]
  if (!g) return false
  return (
    g.category === 'clothing' ||
    g.category === 'household' ||
    g.category === 'entertainment' ||
    g.id === 'pastry'
  )
}

export interface ContentContext {
  pack: ContentPack
  goods: Record<GoodID, GoodDef>
  buildings: Record<BuildingID, BuildingDef>
  recipes: Record<RecipeID, RecipeDef>
  classes: Record<ClassID, ClassDef>
  housing: Record<GoodID, HousingDef>
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
