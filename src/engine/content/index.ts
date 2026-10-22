import type {
  BuildingDef,
  BuildingID,
  ClassDef,
  ClassID,
  ContentPack,
  FactionDef,
  FactionID,
  FactionsConfig,
  GoodDef,
  GoodID,
  HousingDef,
  PackID,
  QuestChapterDef,
  QuestDef,
  QuestID,
  RecipeDef,
  RecipeID,
  RoutesConfig,
  SceneDef,
  TechDef,
  TechID,
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

export const ALL_TECHS: Record<TechID, TechDef> = CONTENT.technologies
export const TECH_IDS: TechID[] = CONTENT.techIds
export const ERA_IDS: number[] = CONTENT.eraIds

export const ALL_QUESTS: Record<QuestID, QuestDef> = CONTENT.quests
export const QUEST_IDS: QuestID[] = CONTENT.questIds
export const QUEST_CHAPTERS: QuestChapterDef[] = CONTENT.chapters
export const ALL_SCENES: Record<string, SceneDef> = CONTENT.scenes
export const SCENE_IDS: string[] = CONTENT.sceneIds

export const ROUTES = CONTENT.routes

// 邦交（B4）：13 个势力 + 好感档位表。见 docs/diplomacy.md
export const FACTIONS: FactionsConfig = CONTENT.factions
export const ALL_FACTIONS: Record<FactionID, FactionDef> = Object.fromEntries(
  CONTENT.factions.factions.map((f) => [f.id, f]),
)
export const FACTION_IDS: FactionID[] = CONTENT.factions.factionIds

/** 某座城归哪个势力（outes.json.cities[].faction，查不到返回 undefined）。 */
export function factionOfCity(cityId: string): FactionDef | undefined {
  const city = ROUTES.cities.find((c) => c.id === cityId)
  return city === undefined ? undefined : ALL_FACTIONS[city.faction]
}

/** 某建筑由哪项科技解锁；返回 undefined 表示「开局即可建」（没有科技锁）。 */
export function techUnlockingBuilding(buildingId: BuildingID): TechID | undefined {
  for (const id of TECH_IDS) {
    if (ALL_TECHS[id]!.unlocks.buildings.includes(buildingId)) return id
  }
  return undefined
}

/** 某种住房由哪项科技解锁；undefined = 开局即可建。 */
export function techUnlockingHousing(housingId: GoodID): TechID | undefined {
  for (const id of TECH_IDS) {
    if (ALL_TECHS[id]!.unlocks.housing.includes(housingId)) return id
  }
  return undefined
}

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
  technologies: Record<TechID, TechDef>
  /** 任务定义（与 pack 无关：所有 pack 共用一套引导任务，见 docs/quests.md）。 */
  quests: Record<QuestID, QuestDef>
  questIds: QuestID[]
  chapters: QuestChapterDef[]
  /** 场次（不挂任务的戏，见 `content/scenes.json` 与 `systems/scenes.ts`）。 */
  scenes: Record<string, SceneDef>
  sceneIds: string[]
  /** 商路（B3）：目的地 + 距离价表 + 商队 / 市场数值。见 `docs/trade-routes.md`。 */
  routes: RoutesConfig
  /** 邦交（B4）：势力表与好感档位，见 `docs/diplomacy.md`。 */
  factions: FactionsConfig
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
    technologies: ALL_TECHS,
    quests: ALL_QUESTS,
    questIds: QUEST_IDS,
    chapters: QUEST_CHAPTERS,
    scenes: ALL_SCENES,
    sceneIds: SCENE_IDS,
    routes: ROUTES,
    factions: FACTIONS,
    goodSet: new Set(pack.goods),
    buildingSet: new Set(pack.buildings),
    classSet: new Set(pack.classes),
  }
}
