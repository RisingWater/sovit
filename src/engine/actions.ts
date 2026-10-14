import type { Action, AppliedAction, GameState, TaxBracket } from './types.ts'
import type { ContentContext } from './content/index.ts'
import { clamp, round2 } from './util.ts'
import { tryBuild, tryBuildHousing, tryExpand } from './systems/investment.ts'
import { effectiveSlots } from './systems/labor.ts'
import {
  cancelResearch,
  isBuildingUnlocked,
  isHousingUnlocked,
  startResearch,
  techForBuilding,
  techForHousing,
} from './systems/research.ts'

/** 规范化税表：保证 upTo 递增、最后一档为 null、税率合法。 */
function sanitizeBrackets(bs: TaxBracket[]): void {
  for (let i = 0; i < bs.length; i++) {
    bs[i]!.rate = clamp(bs[i]!.rate, 0, 0.95)
    if (i === bs.length - 1) {
      bs[i]!.upTo = null
    } else {
      const prev = i > 0 ? bs[i - 1]!.upTo ?? 0 : 0
      let up = bs[i]!.upTo ?? prev + 1
      if (up <= prev) up = round2(prev + 1)
      bs[i]!.upTo = up
    }
  }
}

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
        // 上限用**有效工位数**，不是 maxWorkers —— 研究所升级会 +slotsPerLevel 个工位，
        // 按 maxWorkers 截断会把"拖满"静默夹回去。
        shop.targetWorkers = Math.round(clamp(action.value, 0, effectiveSlots(def, shop.level)))
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
        // 科技门槛放在最前面：理由最明确（"还没研究出来"）
        if (!isBuildingUnlocked(state, ctx, action.buildingId)) {
          const t = techForBuilding(ctx, action.buildingId)
          applied.push({
            type: action.type,
            ok: false,
            reason: `需要科技：${t?.nameZh ?? '未知'}`,
          })
          break
        }
        const res = tryBuild(state, ctx, action.buildingId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'build_housing': {
        if (!isHousingUnlocked(state, ctx, action.goodId)) {
          const t = techForHousing(ctx, action.goodId)
          applied.push({
            type: action.type,
            ok: false,
            reason: `需要科技：${t?.nameZh ?? '未知'}`,
          })
          break
        }
        const res = tryBuildHousing(state, ctx, action.goodId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'research': {
        const res = startResearch(state, ctx, action.techId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'cancel_research': {
        const res = cancelResearch(state, action.techId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'set_tax': {
        // 简化为单一税率（扁平税）；细粒度请用 set_tax_bracket。
        state.government.taxBrackets = [{ upTo: null, rate: clamp(action.value, 0, 0.95) }]
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_tax_bracket': {
        const bs = state.government.taxBrackets
        const i = Math.round(action.index)
        if (i < 0 || i >= bs.length) {
          applied.push({ type: action.type, ok: false, reason: '档位不存在' })
          break
        }
        if (action.upTo !== undefined) {
          bs[i]!.upTo = action.upTo === null ? null : round2(Math.max(0, action.upTo))
        }
        if (action.rate !== undefined) {
          bs[i]!.rate = clamp(action.rate, 0, 0.95)
        }
        sanitizeBrackets(bs)
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_rent': {
        state.government.rent = round2(clamp(action.value, 0, 99))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'set_population_cap': {
        // 人口上限：迁入到该数就停（防止一口气涌进来一堆人、粮食跟不上饿死）
        state.government.populationCap = Math.max(0, Math.floor(action.value))
        applied.push({ type: action.type, ok: true })
        break
      }

      case 'subsidy':
      case 'demolish': {
        const idx = state.shops.findIndex((s) => s.id === action.shopId)
        if (idx < 0) {
          applied.push({ type: action.type, ok: false, reason: '建筑不存在' })
          break
        }
        const shop = state.shops[idx]!
        const def = ctx.buildings[shop.defId]
        // **退建造资源**：按 buildCost 原样退回国库库存。
        // 不退「建造力」—— 那是每日产能/已经投进去的人工，没有"退"的概念。
        // 只退到 ctx.goodSet 里真实存在的商品（与 presentCost 同一口径）。
        const refunded: string[] = []
        if (def) {
          for (const [gid, qty] of Object.entries(def.buildCost ?? {})) {
            const n = Number(qty)
            if (!n || !ctx.goodSet.has(gid)) continue
            state.goods[gid] = round2((state.goods[gid] ?? 0) + n)
            refunded.push(`${gid}×${n}`)
          }
        }
        // 只从 shops 里摘掉：工人变回失业是 assignLabor 现算的自然结果（它每晚扫 shops）。
        state.shops.splice(idx, 1)
        applied.push({
          type: action.type,
          ok: true,
          ...(refunded.length ? { reason: `退回 ${refunded.join('、')}` } : {}),
        })
        break
      }

      case 'sell_shop':
      case 'retake_shop': {
        applied.push({ type: action.type, ok: false, reason: 'not_implemented（预留接口）' })
        break
      }

      default:
        applied.push({ type: (action as { type: string }).type, ok: false, reason: '未知动作' })
    }
  }

  return applied
}
