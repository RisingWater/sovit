// ---------------------------------------------------------------------------
// Sovit 引擎公开 API
// ---------------------------------------------------------------------------

export * from './types.ts'
export { ECONOMY, DEFAULTS, TUNING, TIME } from './config.ts'
export type { EconomyConfig, DefaultsConfig, TuningConfig, TimeConfig, PersonDefaults } from './config.ts'
export { createRng, randInt, chance } from './rng.ts'
export type { Rng } from './rng.ts'
export {
  PACKS,
  PACK_IDS,
  getPack,
  buildContext,
  ALL_GOODS,
  GOOD_IDS,
  ALL_RECIPES,
  RECIPE_BY_BUILDING,
  ALL_BUILDINGS,
  BUILDING_IDS,
  ALL_CLASSES,
  CLASS_IDS,
  ALL_HOUSING,
  HOUSING_IDS,
  ALL_TECHS,
  TECH_IDS,
  ERA_IDS,
  isLuxuryGood,
} from './content/index.ts'
export type { ContentContext } from './content/index.ts'
export { createInitialState } from './state.ts'
export type { CreateOptions } from './state.ts'
export { advanceDay, advanceHour, runDawn, runNight } from './tick.ts'
export { applyActions } from './actions.ts'
export { observe } from './observe.ts'
export { housingCapacity, privateCapacity, splitOccupancy } from './systems/housing.ts'
export { usedSlots, constructionRate, applyConstructionHours, settleConstruction } from './systems/investment.ts'
export { foodChainShopIds, assignedWorkers, effectiveSlots } from './systems/labor.ts'
export { applyStorageCap, storageCapacity, storedTotal } from './systems/storage.ts'
export {
  activateResearch,
  canResearch,
  cancelResearch,
  isBuildingUnlocked,
  isHousingUnlocked,
  isResearched,
  researchRate,
  settleResearch,
  startResearch,
  techForBuilding,
  techForHousing,
} from './systems/research.ts'
export { allocateTools, shopToolBoost } from './systems/tools.ts'
export { techBonuses, sectorOutputBoost, buildingSectorBoost } from './systems/tech_bonus.ts'
export type { TechBonuses } from './systems/tech_bonus.ts'
