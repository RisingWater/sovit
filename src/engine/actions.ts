import type { Action, AppliedAction, GameState } from './types.ts'
import type { ContentContext } from './content/index.ts'
import { clamp, round2 } from './util.ts'
import { tryBuild, tryBuildHousing, tryExpand } from './systems/investment.ts'

// ---------------------------------------------------------------------------
// 动作应用
//
// 在 draft state 上就地执行；end_turn 由 tick 处理（此处忽略）。
// 预留动作（build 除外）：sell_shop / retake_shop / set_tax / subsidy → not_implemented。
// ---------------------------------------------------------------------------

export function applyActions(
  state: GameState,
  ctx: ContentContext,
  actions: Action[],
): AppliedAction[] {
  const applied: AppliedAction[] = []

  for (const action of actions) {
    switch (action.type) {
      case 'end_turn':
        break

      case 'set_wage': {
        const shop = state.shops.find((s) => s.id === action.shopId)
        if (!shop) {
          applied.push({ type: action.type, ok: false, reason: '建筑不存在' })
          break
        }
        shop.wage = round2(clamp(action.value, 0, 999))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_wage_cap': {
        const shop = state.shops.find((s) => s.id === action.shopId)
        if (!shop) {
          applied.push({ type: action.type, ok: false, reason: '建筑不存在' })
          break
        }
        shop.wageCap = round2(clamp(action.value, 0, 999))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_workers': {
        const shop = state.shops.find((s) => s.id === action.shopId)
        const def = shop ? ctx.buildings[shop.defId] : undefined
        if (!shop || !def) {
          applied.push({ type: action.type, ok: false, reason: '建筑不存在' })
          break
        }
        shop.targetWorkers = Math.round(clamp(action.value, 0, def.workers))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_price': {
        if (!ctx.goodSet.has(action.goodId) && !ctx.pack.housing.includes(action.goodId)) {
          applied.push({ type: action.type, ok: false, reason: '商品不在当前内容包内' })
          break
        }
        state.prices[action.goodId] = round2(Math.max(0.01, action.value))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'toggle': {
        const shop = state.shops.find((s) => s.id === action.shopId)
        if (!shop) {
          applied.push({ type: action.type, ok: false, reason: '建筑不存在' })
          break
        }
        shop.active = action.active
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'expand': {
        const res = tryExpand(state, ctx, action.shopId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'build': {
        const res = tryBuild(state, ctx, action.buildingId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'build_housing': {
        const res = tryBuildHousing(state, ctx, action.goodId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'set_tax': {
        state.government.taxRate = clamp(action.value, 0, 0.95)
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_rent': {
        state.government.rent = round2(clamp(action.value, 0, 99))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'subsidy':
      case 'sell_shop':
      case 'retake_shop': {
        applied.push({ type: action.type, ok: false, reason: 'not_implemented（v0.1 预留）' })
        break
      }

      default:
        applied.push({ type: (action as { type: string }).type, ok: false, reason: '未知动作' })
    }
  }

  return applied
}
