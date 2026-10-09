import { create } from 'zustand'
import { advanceDay, createInitialState, observe } from '../engine/index.ts'
import type { Action, GameState, Observation } from '../engine/index.ts'

// ---------------------------------------------------------------------------
// 本地游戏状态（直接用引擎；人类操作，不走基线 AI）
// ---------------------------------------------------------------------------

const initial = createInitialState({ pack: 'v0.3', seed: 12345 })

interface GameStore {
  state: GameState
  obs: Observation
  selected: string | null
  tab: 'build' | 'detail' | 'policy'
  /** 立即应用一组动作（不含 end_turn，不推进天数）。 */
  run: (actions: Action[]) => void
  /** 结算一天。 */
  nextDay: () => void
  select: (id: string | null) => void
  setTab: (t: 'build' | 'detail' | 'policy') => void
  reset: () => void
}

export const useGame = create<GameStore>((set) => ({
  state: initial,
  obs: observe(initial),
  selected: null,
  tab: 'build',
  run: (actions) =>
    set((s) => {
      const next = advanceDay(s.state, actions).state
      return { state: next, obs: observe(next) }
    }),
  nextDay: () =>
    set((s) => {
      const next = advanceDay(s.state, [{ type: 'end_turn' }]).state
      return { state: next, obs: observe(next) }
    }),
  select: (id) => set((s) => ({ selected: id, tab: id ? 'detail' : s.tab })),
  setTab: (t) => set({ tab: t }),
  reset: () =>
    set(() => {
      const fresh = createInitialState({ pack: 'v0.3', seed: Math.floor(Math.random() * 1e6) })
      return { state: fresh, obs: observe(fresh), selected: null }
    }),
}))
