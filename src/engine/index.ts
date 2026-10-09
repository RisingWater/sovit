// ---------------------------------------------------------------------------
// Sovit 引擎公开 API
// ---------------------------------------------------------------------------

export * from './types.ts'
export { ECONOMY } from './config.ts'
export type { EconomyConfig } from './config.ts'
export { createRng, randInt, chance } from './rng.ts'
export type { Rng } from './rng.ts'
export {
  PACKS,
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
} from './content/index.ts'
export type { ContentContext } from './content/index.ts'
export { createInitialState } from './state.ts'
export type { CreateOptions } from './state.ts'
export { advanceDay, runDay } from './tick.ts'
export { applyActions } from './actions.ts'
export { observe } from './observe.ts'
export { housingCapacity, privateCapacity, splitOccupancy } from './systems/housing.ts'
export { usedSlots } from './systems/investment.ts'
