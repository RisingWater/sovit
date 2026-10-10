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
import { CONTENT } from './bundle.ts'

// ---------------------------------------------------------------------------
// 内容表（由仓库根 content/*.json 驱动）
//
// 全量数据始终存在，pack 只是「当前这局允许出现什么」的过滤清单。
// 改内容 = 改 JSON，无需改代码。
// ---------------------------------------------------------------------------

export const ALL_GOODS: Record<GoodID, GoodDef> = CONTENT.goods
export const GOOD_IDS: GoodID[] = CONTENT.goodIds

export const ALL_BUILDINGS: Record<BuildingID, BuildingDef> = CONTENT.buildings
export const BUILDING_IDS: BuildingID[] = CONTENT.buildingIds

export const ALL_RECIPES: Record<RecipeID, RecipeDef> = CONTENT.recipes
export const RECIPE_BY_BUILDING: Record<string, RecipeDef> = CONTENT.recipeByBuilding

export const ALL_CLASSES: Record<ClassID, ClassDef> = CONTENT.classes
export const CLASS_IDS: ClassID[] = CONTENT.classIds

export const ALL_HOUSING: Record<GoodID, HousingDef> = CONTENT.housing
export const HOUSING_IDS: GoodID[] = CONTENT.housingIds

export const PACKS: Record<PackID, ContentPack> = CONTENT.packs
export const PACK_IDS: PackID[] = CONTENT.packIds

export function getPack(id: PackID): ContentPack {
  const pack = PACKS[id]
  if (!pack) throw new Error(`unknown content pack: ${id}`)
  return pack
}

/** 奢侈品（低价格弹性，可提价抽取富人财富）：由 goods.json 的 luxury 标志决定。 */
export function isLuxuryGood(gid: GoodID): boolean {
  return ALL_GOODS[gid]?.luxury === true
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
