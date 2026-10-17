import type {
  GameState,
  LogEntry,
  QuestChapterDef,
  QuestChoice,
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

/**
 * `building_repaired` 的 id 归一：内容里写的是口语名 `townhall`，
 * 而建筑表里叫 `town_center`。两个写法都认，统一成建筑表里的那个（用于取中文名）。
 * 与 GDScript `sim_core.gd::_repair_target_building` 同表。
 */
function repairTargetBuilding(id: string): string {
  return id === 'townhall' ? 'town_center' : id
}

/** 这座"塌了的"建筑修好了吗（目前只有城镇中心这一座）。 */
function repairedOf(state: GameState, id: string): boolean {
  const b = repairTargetBuilding(id)
  if (b === 'town_center') return state.townCenter?.ruined === false
  return false
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
      // `repaired: true` 换个口径：数的是"这座塌了的建筑修好了吗"，不是"建了几座"。
      if (goal.repaired === true) {
        have = repairedOf(state, goal.id) ? 1 : 0
        need = 1
        text = `${nameOf(goal.id, 'building')} 已修复 ${have}/${need}`
        break
      }
      let n = 0
      for (const s of state.shops) if (s.defId === goal.id) n += 1
      have = n
      need = goal.min
      text = `${nameOf(goal.id, 'building')} ${shown(have)}/${need}`
      break
    }
    case 'building_repaired': {
      have = repairedOf(state, goal.id) ? 1 : 0
      need = 1
      text = `${nameOf(repairTargetBuilding(goal.id), 'building')} 已修复 ${have}/${need}`
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

// ---------------------------------------------------------------------------
// 剧情对话（用户 2026-10）
//
// 两处要弹 galgame 对话，都用「说话人 + 立绘 + 逐行台词（+ 可选选项）」这同一个形状：
//   1. **任务触发**：任务一出现在追踪条上，发布人（`giver`）就把这条任务的
//      `brief` 逐句说一遍 —— 所以 `brief` 必须是能当台词念的话
//   2. **章节完成**：内容里的 `chapters[].outro`
//
// 判定"该播哪一条"的方式是**状态比对**，不是事件队列：`quests.shown` 里没有的
// 就还没播过。好处是读档 / 退出重进都不会重播，也不会漏播（队列会丢）。
// ⚠️ `shown` 只记事、不参与演化 —— 和 `prophet` / `townCenter` 同一类字段。
// ---------------------------------------------------------------------------

/** 一段剧情对话（引擎说"该播这个"，UI 只管画）。 */
export interface QuestTalk {
  /** 记账键：`q:<questId>` / `c:<chapterId>`。播完调 `markQuestTalkShown()`。 */
  key: string
  kind: 'quest' | 'outro'
  /** 任务 id 或章节 id（数字章节转成字符串）。 */
  id: string
  chapter: number
  /** 说话的 NPC id（`sebastian` / `luna` / `vila` …）。 */
  speaker: string
  /** 立绘 id（`<id>_<mood>`）。 */
  portrait: string
  lines: string[]
  choices?: QuestChoice[]
}

/**
 * 把一段话按**句末标点**切成"一页一句"的台词。
 *
 * 切分只认 `。！？…`（含「……」这种连写），标点跟着前一句走；
 * `：` `，` `、` 不切 —— 切了会把一句话拆成两截，念起来就不是人话了。
 */
export function splitSentences(text: string): string[] {
  const out: string[] = []
  let cur = ''
  for (const ch of text) {
    cur += ch
    if ('。！？…'.includes(ch)) {
      const t = cur.trim()
      if (t.length > 0) out.push(t)
      cur = ''
    }
  }
  const rest = cur.trim()
  if (rest.length > 0) out.push(rest)
  return out
}

/**
 * 还没播过的对话，**按内容顺序**排好（第 1 章的任务 → 第 1 章收尾 → 第 2 章 …）。
 *
 * 为什么按章节交错而不是"先全部任务、再全部收尾"：第一章一结束，第二章的任务
 * 当晚会一起解锁 —— 收尾那段必须**排在**下一章任务之前，不然瑟拉菲娜的登场
 * 会插在露娜的"蔬菜农场"后面。
 */
export function questTalks(state: GameState, ctx: ContentContext): QuestTalk[] {
  const out: QuestTalk[] = []
  const shown = state.quests.shown ?? {}
  const done = state.quests.done
  for (const ch of ctx.chapters) {
    const cid = String(ch.id)
    for (const id of ctx.questIds) {
      const def = ctx.quests[id]!
      if (def.chapter !== ch.id) continue
      if (done[id] !== undefined) continue
      if (!isUnlocked(state, def)) continue
      const key = `q:${id}`
      if (shown[key] === true) continue
      out.push({
        key,
        kind: 'quest',
        id,
        chapter: ch.id,
        speaker: def.giver,
        portrait: def.giverPortrait,
        lines: splitSentences(def.brief),
      })
    }
    if (state.quests.chapters[cid] === undefined) continue
    if (ch.outro === undefined) continue
    const key = `c:${cid}`
    if (shown[key] === true) continue
    out.push({
      key,
      kind: 'outro',
      id: cid,
      chapter: ch.id,
      speaker: ch.outro.speaker,
      portrait: ch.outro.portrait,
      lines: ch.outro.lines.slice(),
      ...(ch.outro.choices ? { choices: ch.outro.choices } : {}),
    })
  }
  return out
}

/** 记一笔"这段播过了"（只记事，不改任何数字）。 */
export function markQuestTalkShown(state: GameState, key: string): void {
  state.quests.shown[key] = true
}
