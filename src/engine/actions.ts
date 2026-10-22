import type { Action, AppliedAction, GameState, GoodID, LogEntry, RepairStage, TaxBracket } from './types.ts'
import type { ContentContext } from './content/index.ts'
import { clamp, round2 } from './util.ts'
import {
  cancelConstruction,
  moveConstruction,
  repairTownCenter,
  tryBuild,
  tryBuildHousing,
  tryExpand,
  tryUpgradeHousing,
} from './systems/investment.ts'
import { buyFromCaravan, sellToCaravan } from './systems/caravan.ts'
import { assignRoute, setRouteBudget, setRouteSell, unassignRoute } from './systems/routes.ts'
import { factionAlly, factionAttack, factionGift } from './systems/factions.ts'
import { techBonuses } from './systems/tech_bonus.ts'
import { effectiveSlots } from './systems/labor.ts'
import {
  cancelResearch,
  isBuildingUnlocked,
  isHousingUnlocked,
  moveResearch,
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

/**
 * **可用**量 = 库存 − 当天排产已经锁定（`reserved`）的那一份。
 *
 * 与 `systems/production.ts` 的 `state.reserved` 同一口径（GDScript 侧是
 * `sim_core.gd::available()`）。玩家可以花的是这一份：动了被锁定的，白天的生产线就会缺料。
 */
export function availableOf(state: GameState, gid: GoodID): number {
  return (state.goods[gid] ?? 0) - (state.reserved[gid] ?? 0)
}


// ---------------------------------------------------------------------------
// 动作应用
//
// 在 draft state 上就地执行；end_turn 由 tick 处理（此处忽略）。
// 预留动作（build 除外）：sell_shop / retake_shop / set_tax / subsidy → not_implemented。
//
// `logs`：可选的外部日志数组。绝大多数动作的结果由调用方（`runDawn`）在别处记账，
// 但**取消建造**必须让玩家在公告里看见"退回了什么" —— 那是唯一一处"扣了又还"的
// 动作，退料明细没有别的出口。写进这个数组就等于写进当小时的公告（`stepHour` 统一
// 往 `state.log` 里并），不需要在这里碰 `state.log`。
// ---------------------------------------------------------------------------

export function applyActions(
  state: GameState,
  ctx: ContentContext,
  actions: Action[],
  logs: LogEntry[] = [],
): AppliedAction[] {
  const applied: AppliedAction[] = []
  // 贸易科技加成（商队数 / 载重 / 钱箱 / 议价）—— 四条 route_* 命令都要用
  const bonuses = techBonuses(state, ctx)

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

      case 'upgrade_housing': {
        // 改建的**目标**房型要已解锁（原房型早就建出来了，不必再查）
        const target = ctx.housing[action.goodId]?.upgradeTo
        if (target && !isHousingUnlocked(state, ctx, target)) {
          const t = techForHousing(ctx, target)
          applied.push({
            type: action.type,
            ok: false,
            reason: `需要科技：${t?.nameZh ?? '未知'}`,
          })
          break
        }
        // `unitId`：玩家从某栋房的面板点「改建」时带上它（指名到栋，进度条才钉得住）
        const res = tryUpgradeHousing(state, ctx, action.goodId, action.unitId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'move_construction': {
        const res = moveConstruction(state, action.id, action.delta)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'cancel_construction': {
        const res = cancelConstruction(state, ctx, action.id)
        if (res.ok) logs.push({ day: state.day, kind: 'invest', text: res.text })
        applied.push({ type: action.type, ok: res.ok, reason: res.ok ? res.text : res.reason })
        break
      }

      case 'research': {
        const res = startResearch(state, ctx, action.techId)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'cancel_research': {
        const res = cancelResearch(state, ctx, action.techId)
        if (res.ok) logs.push({ day: state.day, kind: 'invest', text: res.text })
        applied.push({ type: action.type, ok: res.ok, reason: res.ok ? res.text : res.reason })
        break
      }

      case 'move_research': {
        const res = moveResearch(state, action.id, action.delta)
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

      case 'set_storage_caps': {
        // 每种物资的软上限（玩家逐项设置，见 docs/town.md §3.6）。
        // 整体替换：传什么就是什么，缺项 = 该项不限。只收本 pack 里真实存在的商品，
        // 数值取非负整数（0 = 一点都不许存）。
        const next: Partial<Record<GoodID, number>> = {}
        for (const [gid, v] of Object.entries(action.caps ?? {})) {
          if (!ctx.goodSet.has(gid)) continue
          const n = Math.max(0, Math.floor(Number(v) || 0))
          if (n > 0) next[gid as GoodID] = n
        }
        state.government.storageCaps = next
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

      case 'repair_town_center': {
        // 修缮城镇中心（用户 2026-10：开局废墟 → 初步修缮 → 修好）。材料不够 → 白下这一单。
        // `stage` 缺省 = 彻底修好；面板/内容会带 patched 或 restored。
        const res = repairTownCenter(state, (action.stage ?? 'restored') as RepairStage)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }

      case 'sell_to_caravan': {
        const why = sellToCaravan(state, action.caravanId, action.goodId, action.qty)
        applied.push({ type: action.type, ok: why === '', reason: why || undefined })
        break
      }
      case 'buy_from_caravan': {
        const why = buyFromCaravan(state, action.caravanId, action.goodId, action.qty)
        applied.push({ type: action.type, ok: why === '', reason: why || undefined })
        break
      }
      // ---- 商路（B3）：四条都走 IMMEDIATE_ACTIONS，当场生效 ----------------
      // 理由与研究队列 / `gift` 同一条：它们**不花任何资源**，只动"配置"和
      // "把货搬进搬出商队" —— 点完就该看到变化，等到 6:00 只会以为没点动。
      case 'route_assign': {
        const why = assignRoute(state, ctx, bonuses, action.cityId)
        applied.push({ type: action.type, ok: why === '', reason: why || undefined })
        break
      }
      case 'route_unassign': {
        const why = unassignRoute(state, ctx, action.routeId)
        applied.push({ type: action.type, ok: why === '', reason: why || undefined })
        break
      }
      case 'route_set_budget': {
        const why = setRouteBudget(state, ctx, bonuses, action.routeId, action.value)
        applied.push({ type: action.type, ok: why === '', reason: why || undefined })
        break
      }
      case 'route_set_sell': {
        const why = setRouteSell(state, ctx, bonuses, action.routeId, action.goodId, action.qty)
        applied.push({ type: action.type, ok: why === '', reason: why || undefined })
        break
      }
      // ---- 邦交（B4）：三条都当场生效（送钱 / 立约 / 宣战，没理由等 6:00）----
      // 见 docs/diplomacy.md §4。钱当场扣、好感当场涨，面板与公告立刻能看见。
      case 'faction_gift': {
        const res = factionGift(state, action.factionId, action.amount, state.day)
        if (res.log) logs.push(res.log)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }
      case 'faction_ally': {
        const res = factionAlly(state, action.factionId, state.day)
        if (res.log) logs.push(res.log)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }
      case 'faction_attack': {
        // ⚠️ B4 只做"宣战"：关系直接打到 -6000（敌对）。真正的战斗结算在 B5 的讨伐战。
        const res = factionAttack(state, action.factionId, state.day)
        if (res.log) logs.push(res.log)
        applied.push({ type: action.type, ok: res.ok, reason: res.reason })
        break
      }
      case 'gift': {
        // 送物资（用户 2026-10 · A4，2026-10-20 改成**即时生效**）：
        // 玩家当面交东西，货当场就出门、任务当场结算 —— 不能等到次日黎明。
        // ⚠️ 只能花**没被锁定的**那部分：`reserved` 是当天排产已经计划掉的原料，
        // 动了它，白天的生产线就会缺料（与 `spend()` / `availableOf()` 同一口径）。
        const qty = Math.floor(action.qty)
        if (!ctx.goodSet.has(action.goodId)) {
          applied.push({ type: action.type, ok: false, reason: '商品不在当前内容包内' })
          break
        }
        if (!Number.isFinite(qty) || qty <= 0) {
          applied.push({ type: action.type, ok: false, reason: '数量要大于 0' })
          break
        }
        if (String(action.to).trim() === '') {
          applied.push({ type: action.type, ok: false, reason: '没说送给谁' })
          break
        }
        const free = availableOf(state, action.goodId)
        if (free + 1e-9 < qty) {
          applied.push({ type: action.type, ok: false, reason: '没被锁定的没这么多' })
          break
        }
        state.goods[action.goodId] = round2((state.goods[action.goodId] ?? 0) - qty)
        const to = String(action.to)
        const bag = state.gifts[to] ?? {}
        bag[action.goodId] = round2((bag[action.goodId] ?? 0) + qty)
        state.gifts[to] = bag
        const nm = ctx.goods[action.goodId]?.nameZh ?? action.goodId
        if (logs) logs.push({ day: state.day, kind: 'invest', text: `送物资：${nm} ×${qty}` })
        applied.push({ type: action.type, ok: true })
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
