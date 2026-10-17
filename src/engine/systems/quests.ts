import type {
  GameState,
  LogEntry,
  QuestChapterDef,
  QuestDef,
  QuestGoal,
  QuestGoalProgress,
  QuestID,
  QuestProgress,
} from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { housingCapacity } from './housing.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 任务（引导系统）
//
// 契约见 docs/quests.md。四条要点：
//   1. 任务 = 一组**对当前状态的只读谓词**（`goals` 全为真 = 完成），不接"提交"
//   2. 判定 + 发钱都在**黎明**（`runDawn` 末尾）—— 玩家先干了、任务后出现，照样算完成
//   3. 渐进显示：`requires` 没全完成的任务**看不见**（`questView` 不返回它）
//   4. 判定只看 `GameState`（含 `history` 台账），所以 TS 与 GDScript 能逐位对拍
//
// ⚠️ 显示文案（`QuestGoalProgress.text`）由**引擎**拼，UI 不自己拼：
//    两份实现必须产出同一个字符串，否则追踪条会在两边长得不一样。
// ---------------------------------------------------------------------------

/** 显示用的整数（进度数字）：一律向下取整，避免 TS / GDScript 浮点格式差异。 */
function shown(x: number): number {
  return Math.floor(x + 1e-9)
}

/** 历史上（含今天）某商品的单日产量峰值。 */
function producedPeak(state: GameState, gid: string): number {
  let peak = state.ledgerToday.produced[gid] ?? 0
  for (const snap of state.history) {
    const v = snap.ledger?.produced?.[gid]
    if (typeof v === 'number' && v > peak) peak = v
  }
  return peak
}

/** 平均满意度（与 `computeArrivals` 里那一处同口径：算术平均）。 */
export function avgSatisfaction(state: GameState): number {
  const pop = state.residents.length
  if (pop === 0) return 0
  let sum = 0
  for (const r of state.residents) sum += r.satisfaction
  return sum / pop
}

/** 单个目标的当前值 + 目标值 + 文案（只读）。 */
export function goalProgress(state: GameState, ctx: ContentContext, goal: QuestGoal): QuestGoalProgress {
  const nameOf = (id: string, kind: 'building' | 'housing' | 'class' | 'tech' | 'good'): string => {
    switch (kind) {
      case 'building':
        return ctx.buildings[id]?.nameZh ?? id
      case 'housing':
        return ctx.housing[id]?.nameZh ?? id
      case 'class':
        return ctx.classes[id]?.nameZh ?? id
      case 'tech':
        return ctx.technologies[id]?.nameZh ?? id
      case 'good':
        return ctx.goods[id]?.nameZh ?? id
    }
  }

  let have = 0
  let need = 1
  let text = ''

  switch (goal.type) {
    case 'building': {
      let n = 0
      for (const s of state.shops) if (s.defId === goal.id) n += 1
      have = n
      need = goal.min
      text = `${nameOf(goal.id, 'building')} ${shown(have)}/${need}`
      break
    }
    case 'housing':
      have = state.housing[goal.id] ?? 0
      need = goal.min
      text = `${nameOf(goal.id, 'housing')} ${shown(have)}/${need}`
      break
    case 'housing_capacity':
      have = housingCapacity(state, ctx)
      need = goal.min
      text = `住房容量 ${shown(have)}/${need}`
      break
    case 'population':
      have = state.residents.length
      need = goal.min
      text = `人口 ${shown(have)}/${need}`
      break
    case 'class': {
      let n = 0
      for (const r of state.residents) if (r.classId === goal.id) n += 1
      have = n
      need = goal.min
      text = `${nameOf(goal.id, 'class')} ${shown(have)}/${need}`
      break
    }
    case 'tech':
      have = state.research.done.includes(goal.id) ? 1 : 0
      need = 1
      text = `研究「${nameOf(goal.id, 'tech')}」`
      break
    case 'tech_count':
      have = state.research.done.length
      need = goal.min
      text = `完成科技 ${shown(have)}/${need}`
      break
    case 'good':
      have = state.goods[goal.id] ?? 0
      need = goal.min
      text = `${nameOf(goal.id, 'good')} ${shown(have)}/${need}`
      break
    case 'produced':
      have = producedPeak(state, goal.id)
      need = goal.min
      text = `${nameOf(goal.id, 'good')}单日产量 ${shown(have)}/${need}`
      break
    case 'avg_satisfaction':
      have = avgSatisfaction(state)
      need = goal.min
      text = `平均满意度 ${shown(have)}/${need}`
      break
    case 'private_housing': {
      let n = 0
      for (const v of Object.values(state.privateHousing)) n += Math.floor(v ?? 0)
      have = n
      need = goal.min
      text = `私有住房 ${shown(have)}/${need} 户`
      break
    }
  }

  return { goal, have, need, met: have + 1e-9 >= need, text }
}

/** 一条任务的进度（只读）。 */
export function questProgress(state: GameState, ctx: ContentContext, def: QuestDef): QuestProgress {
  const goals = def.goals.map((g) => goalProgress(state, ctx, g))
  const day = state.quests.done[def.id]
  return {
    def,
    goals,
    met: goals.every((g) => g.met),
    done: day !== undefined,
    day,
  }
}

/** 前置是否都完成过。 */
export function isUnlocked(state: GameState, def: QuestDef): boolean {
  return def.requires.every((r) => state.quests.done[r] !== undefined)
}

/** 追踪条要显示的东西：**当前可见**的任务（未完成的 + 今天刚完成的）。 */
export function questView(state: GameState, ctx: ContentContext): QuestProgress[] {
  const out: QuestProgress[] = []
  for (const id of ctx.questIds) {
    const def = ctx.quests[id]!
    const day = state.quests.done[id]
    if (day === undefined) {
      // 没解锁的**不返回** —— 玩家不该看到后面还有什么（见 docs/quests.md）
      if (!isUnlocked(state, def)) continue
      out.push(questProgress(state, ctx, def))
    } else if (day >= state.day) {
      // 今天刚完成：留一天，追踪条上打勾变绿
      out.push(questProgress(state, ctx, def))
    }
  }
  return out
}

/**
 * 任务**面板**要的东西：所有"玩家已经知道"的任务 —— 已完成的 + 已解锁未完成的。
 *
 * 与 `questView()` 的分工：
 *   · `questView()` 是**追踪条**用的，只给"当前该做/今天刚做完"的几条；
 *   · `questJournal()` 是**面板**用的，要把做过的历史也留着（玩家回头能翻），
 *     所以已完成的**不论第几天**都返回。
 *
 * ⚠️ 渐进显示这条契约两边都守：`requires` 没全完成、且自己也没完成的，
 *    **一律不返回** —— 面板上连"有个锁着的任务"都不该看得出来。
 * 返回顺序固定为内容定义顺序（面板左树按 `chapter` 分组后就是章节内顺序）。
 */
export function questJournal(state: GameState, ctx: ContentContext): QuestProgress[] {
  const out: QuestProgress[] = []
  for (const id of ctx.questIds) {
    const def = ctx.quests[id]!
    if (state.quests.done[id] === undefined && !isUnlocked(state, def)) continue
    out.push(questProgress(state, ctx, def))
  }
  return out
}

/** 某一章里"算进章节奖励"的任务（支线不算）。 */
function chapterQuests(ctx: ContentContext, chapter: number): QuestID[] {
  return ctx.questIds.filter((id) => {
    const q = ctx.quests[id]!
    return q.chapter === chapter && q.side !== true
  })
}

/**
 * 黎明结算：把**已经达成**的任务记账、发钱、写公告。
 *
 * ⚠️ 用 `while` 反复扫，因为同一次黎明里可能连锁完成（比如「建研究所」刚完成，
 * 而另一条早已达成、只差它当前置的任务应当**当场**一起结算）。
 * 遍历顺序固定为 `ctx.questIds`（内容里的定义顺序），保证 TS 与 GDScript 一致。
 */
export function checkQuests(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  const done = state.quests.done
  const finished: QuestDef[] = []

  for (let sweep = 0; sweep < ctx.questIds.length + 1; sweep++) {
    let progressed = false
    for (const id of ctx.questIds) {
      if (done[id] !== undefined) continue
      const def = ctx.quests[id]!
      if (!isUnlocked(state, def)) continue
      if (!questProgress(state, ctx, def).met) continue
      done[id] = day
      state.government.money = round2(state.government.money + def.reward)
      finished.push(def)
      progressed = true
    }
    if (!progressed) break
  }

  // 章节奖励：本章"算数"的任务全绿（支线不影响）
  const chapterDone: QuestChapterDef[] = []
  for (const ch of ctx.chapters) {
    if (state.quests.chapters[String(ch.id)] !== undefined) continue
    const list = chapterQuests(ctx, ch.id)
    if (list.length === 0) continue
    if (!list.every((id) => done[id] !== undefined)) continue
    state.quests.chapters[String(ch.id)] = day
    state.government.money = round2(state.government.money + ch.reward)
    chapterDone.push(ch)
  }

  if (finished.length > 0) {
    if (finished.length === 1) {
      const q = finished[0]!
      logs.push({ day, kind: 'info', text: `完成任务：${q.title}（+${q.reward} 金）` })
    } else {
      let sum = 0
      for (const q of finished) sum += q.reward
      const titles = finished.map((q) => q.title).join('、')
      logs.push({ day, kind: 'info', text: `完成 ${finished.length} 项任务（+${sum} 金）：${titles}` })
    }

    // 这次结算把哪些任务"顶"了出来 —— 只报这些，别把早就可见的再报一遍
    const justDone = new Set(finished.map((q) => q.id))
    const opened: string[] = []
    for (const id of ctx.questIds) {
      if (done[id] !== undefined) continue
      const def = ctx.quests[id]!
      if (!def.requires.some((r) => justDone.has(r))) continue
      if (!isUnlocked(state, def)) continue
      opened.push(def.title)
    }
    if (opened.length > 0) {
      logs.push({ day, kind: 'info', text: `新任务：${opened.join('、')}` })
    }
  }

  for (const ch of chapterDone) {
    logs.push({ day, kind: 'info', text: `章节「${ch.title}」全部完成（+${ch.reward} 金）` })
  }

  return logs
}
