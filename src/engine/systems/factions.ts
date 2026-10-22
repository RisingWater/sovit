import type {
  FactionDef,
  FactionID,
  FactionState,
  GameState,
  LogEntry,
  RelationBand,
} from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_FACTIONS, FACTIONS, FACTION_IDS } from '../content/index.ts'
import { completedChapter } from './caravan.ts'
import { techBonuses } from './tech_bonus.ts'

// ---------------------------------------------------------------------------
// 邦交（B4）—— 好感 · 送礼 · 结盟 · 宣战 · 商路门槛
//
// 设计唯一契约是 docs/diplomacy.md。这里只做"数值与判定"，一行 UI 都没有。
// 镜像实现：godot/scripts/sim/sim_core.gd 的邦交那一段
// （`faction_band` / `faction_gift` / `faction_ally` / `faction_attack` / `_update_factions`），
// 两边口径必须一致 —— `tools/factions_test.gd` 与 `scripts/check-factions.ts` 对着它写。
//
// 三条硬规则（用户 2026-10 口述）：
//   1. **只有中立及以上才开得了商路**（附庸视为中立；敌对 / 冷淡按钮灰掉）
//   2. **主动开战 = 直接打到 -6000（敌对）**，不是"减 6000"
//   3. **打赢之后**按势力的 `defeat` 规则收场：默认冷淡+附庸，铁峰直接变 6000（尊重）
// ---------------------------------------------------------------------------

const REL = FACTIONS.relation

/** 所有势力 id（顺序 = `factions.json` 里的顺序，UI 就按它排）。 */
export function factionIds(): FactionID[] {
  return FACTION_IDS
}

export function factionDef(id: FactionID): FactionDef | undefined {
  return ALL_FACTIONS[id]
}

/** 开局的邦交状态：好感取 `initial`，其余记账全空。 */
export function emptyFactions(): FactionState {
  const rep: Record<string, number> = {}
  const ally: Record<string, boolean> = {}
  const vassal: Record<string, boolean> = {}
  const gifts: Record<string, number> = {}
  const flipped: Record<string, boolean> = {}
  const defeated: Record<string, boolean> = {}
  for (const id of FACTION_IDS) {
    rep[id] = ALL_FACTIONS[id]!.initial
    ally[id] = false
    vassal[id] = false
    gifts[id] = 0
    flipped[id] = false
    defeated[id] = false
  }
  return { rep, ally, vassal, gifts, flipped, defeated }
}

/**
 * 老存档兜底：把缺的字段补上（**不动已有的好感**）。
 *
 * 与 Godot 侧 `SimCore.repair_factions()` 同口径；v6 及更早的存档没有 `state.factions`，
 * 不补的话 `bandOf()` 会读 undefined（B3 的 `routes` 就是这么崩过一次的）。
 */
export function repairFactions(raw: unknown): FactionState {
  const cur = (raw ?? {}) as Partial<FactionState>
  const out = emptyFactions()
  const rep = cur.rep ?? {}
  for (const id of FACTION_IDS) {
    const v = rep[id]
    if (typeof v === 'number' && Number.isFinite(v)) out.rep[id] = v
    out.ally[id] = cur.ally?.[id] === true
    out.vassal[id] = cur.vassal?.[id] === true
    out.gifts[id] = typeof cur.gifts?.[id] === 'number' ? cur.gifts![id]! : 0
    out.flipped[id] = cur.flipped?.[id] === true
    out.defeated[id] = cur.defeated?.[id] === true
  }
  return out
}

/** 状态段（缺了就补一个；所有读写都从这里过，老的 v6 存档才不炸）。 */
export function factions(state: GameState): FactionState {
  const holder = state as unknown as { factions?: FactionState }
  const cur = holder.factions
  if (!cur || typeof cur !== 'object') {
    const fresh = emptyFactions()
    holder.factions = fresh
    return fresh
  }
  if (!cur.defeated || typeof cur.defeated !== 'object') cur.defeated = {}
  return cur
}

/** 某势力当前的天花板（数值）：打服过按 `defeat.cap`，否则按 `cap`。 */
export function capOf(state: GameState, id: FactionID): number {
  const def = ALL_FACTIONS[id]
  if (!def) return REL.max
  const band = factions(state).defeated[id] === true && def.defeat ? def.defeat.cap : def.cap
  return REL.capByBand[band]
}

/** 好感夹到 [min, 天花板]。 */
export function clampRep(rep: number, cap: number): number {
  return Math.max(REL.min, Math.min(cap, Math.round(rep)))
}

/**
 * 好感 → 档位。
 *
 * ⚠️ 边界照用户口述：敌对 `≤ -6000`、冷淡 `(−6000, −2000]`、中立 `(−2000, 2000)`、
 * 友善 `[2000, 6000)`、尊重 `[6000, 10000)`、同盟 `≥ 10000`。
 * `bands[i].incl` 决定这一档含不含上界 —— **负的两档含、正的三档不含**。
 */
export function bandOf(rep: number): RelationBand {
  for (const b of REL.bands) {
    if (b.incl ? rep <= b.max : rep < b.max) return b.id
  }
  return 'ally'
}

/** 档位的中文名。 */
export function bandNameZh(band: RelationBand): string {
  return REL.bands.find((b) => b.id === band)?.nameZh ?? band
}

/** 某势力当前对外的称呼：附庸 > 好感档。 */
export function relationLabel(state: GameState, id: FactionID): string {
  const st = factions(state)
  if (st.vassal[id] === true) return REL.vassalNameZh
  return bandNameZh(bandOf(st.rep[id] ?? 0))
}

/** 这一档起能不能通商（档位先后按 `bands` 的顺序）。 */
export function meetsTradeBand(band: RelationBand): boolean {
  const order = REL.bands.map((b) => b.id)
  return order.indexOf(band) >= order.indexOf(REL.tradeBand)
}

/** 某座城（它的势力）现在能不能开商路。`why` = 不能开的原因（能给玩家看的话）。 */
export function factionCanTrade(
  state: GameState,
  factionId: FactionID,
): { ok: boolean; why: string } {
  const st = factions(state)
  const def = ALL_FACTIONS[factionId]
  if (!def) return { ok: false, why: '没有这个势力' }
  if (st.vassal[factionId] === true) return { ok: true, why: '' }
  const band = bandOf(st.rep[factionId] ?? 0)
  if (meetsTradeBand(band)) return { ok: true, why: '' }
  return {
    ok: false,
    why: `${def.short}与我们的关系是「${bandNameZh(band)}」，先送钱缓和`,
  }
}

/** 商路每跑完一趟的好感（含科技加成：100 / 150 / 200 / 300）。 */
export function factionTradeGain(state: GameState, ctx: ContentContext): number {
  const bonus = techBonuses(state, ctx).trade.goodwill
  return Math.round(REL.tradeGain * (1 + bonus))
}

/**
 * 给某个势力加好感（夹到天花板）。返回实际涨了多少（写公告用）。
 *
 * ⚠️ 天花板是"**最多能推到哪**"，不是"此刻的上界"：开局好感可以高于它
 * （沙海汗国开局中立、天花板冷淡 —— 见 `factions.json` 的注释）。所以这里对
 * **加好感**取 `max(现值, min(天花板, 目标))`：高于天花板时既不涨也不掉，
 * 绝不能"送钱反而把关系送低"。
 */
export function addRep(state: GameState, id: FactionID, delta: number): number {
  const st = factions(state)
  const before = st.rep[id] ?? 0
  const cap = capOf(state, id)
  const target = clampRep(before + delta, cap)
  const after = delta >= 0 ? Math.max(before, target) : target
  st.rep[id] = clampRep(after, REL.max)
  return st.rep[id]! - before
}

// ---------------------------------------------------------------------------
// 三条命令（都是 IMMEDIATE_ACTIONS：当场生效）
// ---------------------------------------------------------------------------

export interface FactionCommandResult {
  ok: boolean
  reason?: string
  log?: LogEntry
}

/** 送钱给王都叫「进贡」——父王还在（第 6 章之前）才这么叫，之后就是「送礼」。 */
export function giftVerb(state: GameState, id: FactionID): string {
  if (id !== 'court') return '送礼'
  return completedChapter(state) < 6 ? '进贡' : '送礼'
}

/** 送礼 / 进贡：1 钱 = 1 好感，最少 `giftStep`。钱从国库扣。 */
export function factionGift(
  state: GameState,
  id: FactionID,
  amount: number,
  day: number,
): FactionCommandResult {
  const def = ALL_FACTIONS[id]
  if (!def) return { ok: false, reason: '没有这个势力' }
  const money = Math.floor(amount)
  if (!Number.isFinite(money) || money < REL.giftStep) {
    return { ok: false, reason: `一次至少送 ${REL.giftStep} 钱` }
  }
  if (state.government.money < money) return { ok: false, reason: '国库没有这么多钱' }
  const st = factions(state)
  if ((st.rep[id] ?? 0) >= capOf(state, id)) {
    return { ok: false, reason: `${def.short}对我们的好感已经到顶了` }
  }
  state.government.money -= money
  const gained = addRep(state, id, money * REL.giftRate)
  st.gifts[id] = (st.gifts[id] ?? 0) + 1
  return {
    ok: true,
    log: {
      day,
      kind: 'diplomacy',
      text: `${giftVerb(state, id)}：付 ¥${money}，${def.short}好感 +${gained}（${relationLabel(state, id)}）`,
    },
  }
}

/** 结盟：好感必须已到满分 10000、`allyable`、再花 `allyCost` 钱。 */
export function factionAlly(state: GameState, id: FactionID, day: number): FactionCommandResult {
  const def = ALL_FACTIONS[id]
  if (!def) return { ok: false, reason: '没有这个势力' }
  const st = factions(state)
  if (st.ally[id] === true) return { ok: false, reason: `${def.short}已经是盟友了` }
  if (!def.allyable) return { ok: false, reason: `${def.nameZh}不与我们结盟` }
  const rep = st.rep[id] ?? 0
  if (rep < REL.max) return { ok: false, reason: `好感还不够（要 ${REL.max}，现在 ${rep}）` }
  if (state.government.money < REL.allyCost) {
    return { ok: false, reason: `结盟要 ¥${REL.allyCost}，国库不够` }
  }
  state.government.money -= REL.allyCost
  st.ally[id] = true
  return {
    ok: true,
    log: {
      day,
      kind: 'diplomacy',
      text: `结盟：与${def.nameZh}立约，付 ¥${REL.allyCost}（同盟）`,
    },
  }
}

/** 派兵进攻：关系**直接**打到 `attackHit`（-6000，敌对）。B4 只宣战，不打仗。 */
export function factionAttack(state: GameState, id: FactionID, day: number): FactionCommandResult {
  const def = ALL_FACTIONS[id]
  if (!def) return { ok: false, reason: '没有这个势力' }
  const st = factions(state)
  if (st.vassal[id] === true) return { ok: false, reason: `${def.short}是我们的附庸，不能打` }
  if (st.ally[id] === true) return { ok: false, reason: `${def.short}是我们的盟友，先解盟` }
  if (bandOf(st.rep[id] ?? 0) === 'enemy') {
    return { ok: false, reason: `已经在和${def.short}交战了` }
  }
  st.rep[id] = clampRep(REL.attackHit, capOf(state, id))
  return {
    ok: true,
    log: {
      day,
      kind: 'diplomacy',
      text: `宣战：${def.nameZh}（关系变「${relationLabel(state, id)}」）`,
    },
  }
}

// ---------------------------------------------------------------------------
// 黎明：剧情翻转（只做一次）
// ---------------------------------------------------------------------------

/**
 * 每章奖励一记上，就来看看有没有势力的翻转条件满足了。
 *
 * 翻转 = 关系**直接**打到 `flip.to`（不叠加），并且只做一次（`flipped` 位）。
 * 幂等：已经翻过的跳过，所以读档 / 重进不会把关系反复打回敌对。
 */
export function updateFactions(state: GameState, day: number): LogEntry[] {
  const st = factions(state)
  const chapter = completedChapter(state)
  const logs: LogEntry[] = []
  for (const id of FACTION_IDS) {
    const def = ALL_FACTIONS[id]!
    const flip = def.flip
    if (!flip) continue
    if (st.flipped[id] === true) continue
    if (chapter < flip.chapter) continue
    st.flipped[id] = true
    st.rep[id] = clampRep(flip.to, capOf(state, id))
    st.ally[id] = false
    logs.push({
      day,
      kind: 'diplomacy',
      text: `${def.nameZh}与我们翻脸：${flip.reason}（${relationLabel(state, id)}）`,
    })
  }
  return logs
}

/**
 * 打赢之后的收场（B5 的讨伐战会调它；B4 只把它写好，没有调用点）。
 *
 * 按 `defeat` 规则：好感打到 `rep`、天花板换成 `defeat.cap`（靠 `defeated` 位）、
 * `vassal` 决定要不要变附庸。铁峰是特例：打赢**直接和好成 6000（尊重）**。
 */
export function applyFactionDefeat(state: GameState, id: FactionID, day: number): LogEntry[] {
  const def = ALL_FACTIONS[id]
  if (!def || !def.defeat) return []
  const st = factions(state)
  const rule = def.defeat
  st.defeated[id] = true
  st.rep[id] = clampRep(rule.rep, capOf(state, id))
  st.vassal[id] = rule.vassal
  st.ally[id] = false
  const tail = rule.vassal ? '，成为我们的附庸' : `，关系「${relationLabel(state, id)}」`
  return [
    {
      day,
      kind: 'diplomacy',
      text: rule.reason ?? `打赢了！${def.nameZh}${tail}`,
    },
  ]
}
