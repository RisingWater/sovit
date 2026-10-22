import type {
  GameState,
  LogEntry,
  RepairStage,
  QuestChapterDef,
  QuestDef,
  QuestGoal,
  QuestGoalProgress,
  QuestID,
  QuestProgress,
  StoryTalk,
} from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_FACTIONS } from '../content/index.ts'

/** 势力短名（任务文案用；查不到就原样返回 id）。 */
function factionShort(id: string): string {
  return ALL_FACTIONS[id]?.short ?? id
}
import { housingCapacity } from './housing.ts'
import { TOWN_CENTER_STAGES, townCenterStage } from './investment.ts'
import { markSceneShown, scenesAfterChapter } from './scenes.ts'
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

/**
 * 这座"塌了的"建筑修到了要求的段位吗（目前只有城镇中心这一座）。
 * `stage` 缺省 = `restored`；`patched` = **至少**初步修缮过（已修好的也算）。
 * 与 GDScript `sim_core.gd::_quest_repaired` 同口径。
 */
function repairedOf(state: GameState, id: string, wantStage: RepairStage = 'restored'): boolean {
  const b = repairTargetBuilding(id)
  if (b !== 'town_center') return false
  const cur = TOWN_CENTER_STAGES.indexOf(townCenterStage(state))
  const want = TOWN_CENTER_STAGES.indexOf(wantStage)
  return cur >= 0 && want >= 0 && cur >= want
}

/** 进度文案里的那个词（两段不同措辞；GDScript `_repair_stage_word` 必须逐字一致）。 */
function repairStageWord(wantStage: RepairStage): string {
  return wantStage === 'patched' ? '已初步修复' : '已修复'
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
        const want: RepairStage = goal.stage ?? 'restored'
        have = repairedOf(state, goal.id, want) ? 1 : 0
        need = 1
        text = `${nameOf(goal.id, 'building')} ${repairStageWord(want)} ${have}/${need}`
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
      // `stage` 缺省 = 修好；`patched` = 至少初步修缮过（第三章那条任务）
      const want: RepairStage = goal.stage ?? 'restored'
      have = repairedOf(state, goal.id, want) ? 1 : 0
      need = 1
      text = `${nameOf(repairTargetBuilding(goal.id), 'building')} ${repairStageWord(want)} ${have}/${need}`
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
    case 'gifted': {
      // 判的是"送出去多少"，不是"仓库里有多少"（见 docs/quests.md §四）。
      have = state.gifts?.[goal.to]?.[goal.id] ?? 0
      need = goal.min
      text = `${nameOf(goal.id, 'good')} 已送出 ${shown(have)}/${need}`
      break
    }
    case 'caravan_trade': {
      // 和游商成交过几次（B4 章 3）。两个计数器都只记事、不演化。
      const sell = goal.side === 'sell'
      have = sell ? (state.trade?.soldTimes ?? 0) : (state.trade?.boughtTimes ?? 0)
      need = goal.min
      text = `${sell ? '卖给' : '买自'}游商 ${shown(have)}/${need} 次`
      break
    }
    case 'route_created': {
      // 累计创建过几条商路（B4 章 4）：取消不减。
      have = state.routes?.created ?? 0
      need = goal.min
      text = `创建商路 ${shown(have)}/${need} 条`
      break
    }
    case 'faction_gift': {
      // 给势力送过几次钱（B4 章 5）；没写 id = 任意一家都算。
      const st = (state as unknown as { factions?: { gifts?: Record<string, number> } }).factions
      const gifts = st?.gifts ?? {}
      have = goal.id
        ? (gifts[goal.id] ?? 0)
        : Object.values(gifts).reduce((a, b) => a + b, 0)
      need = goal.min
      text = goal.id
        ? `给${factionShort(goal.id)}送礼 ${shown(have)}/${need} 次`
        : `送礼 ${shown(have)}/${need} 次`
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

/**
 * 这一章最早哪一天开（用户 2026-10 · B1 · 剧情时钟）。
 *
 * 口径：`chapters[i].gapDays` = **上一章领奖那天**起再隔几天。
 * 章 1–5 填 0（等于不闸），章 6 起填 3–5 的固定值。
 *
 * 返回 `0` = 不闸；`Infinity` = 上一章还没收尾，这一章根本还没到点。
 * ⚠️ 只闸 `kind: "main"`：支线与里程碑不受剧情时钟管（见 `questAvailable`）。
 */
export function chapterOpenDay(state: GameState, ctx: ContentContext, chapterId: number): number {
  const i = ctx.chapters.findIndex((c) => c.id === chapterId)
  if (i <= 0) return 0
  const gap = Math.max(0, Math.floor(ctx.chapters[i]!.gapDays ?? 0))
  if (gap <= 0) return 0
  const prevDay = state.quests.chapters[String(ctx.chapters[i - 1]!.id)]
  if (prevDay === undefined) return Infinity
  return prevDay + gap
}

/** 这一章开没开（见 `chapterOpenDay`）。 */
export function chapterOpen(state: GameState, ctx: ContentContext, chapterId: number): boolean {
  return state.day >= chapterOpenDay(state, ctx, chapterId)
}

/**
 * 这条任务现在**存在**吗：前置全完成 + 它自己那一道时间闸 + 还没完成。
 *
 * 渐进显示与两道闸都收在这一处 —— 追踪条、面板、黎明结算、对话播报四个入口
 * 必须问同一个函数，否则会出现"条上看得见、结算却不算"这种鬼事。
 *
 * 闸分三种（`kind`）：
 *   · `main`      —— 剧情时钟：上一章领奖那天 + `gapDays`（`chapterOpen`）
 *   · `side`      —— 上一章**主线全绿**就露（不看 gapDays；见 `prevChapterMainDone`）
 *   · `milestone` —— 只认 `requires`，不受任何时间闸管（它要一直挂在追踪条上填空档）
 */
export function questAvailable(state: GameState, ctx: ContentContext, def: QuestDef): boolean {
  if (!isUnlocked(state, def)) return false
  if (def.kind === 'milestone') return true
  if (def.kind === 'side') return prevChapterMainDone(state, ctx, def.chapter)
  return chapterOpen(state, ctx, def.chapter)
}

/** 追踪条要显示的东西：**当前可见**的任务（未完成的 + 今天刚完成的）。 */
export function questView(state: GameState, ctx: ContentContext): QuestProgress[] {
  const out: QuestProgress[] = []
  for (const id of ctx.questIds) {
    const def = ctx.quests[id]!
    const day = state.quests.done[id]
    if (day === undefined) {
      // 没解锁的 / 还没到点的**不返回** —— 玩家不该看到后面还有什么（见 docs/quests.md）
      if (!questAvailable(state, ctx, def)) continue
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
    if (state.quests.done[id] === undefined && !questAvailable(state, ctx, def)) continue
    out.push(questProgress(state, ctx, def))
  }
  return out
}

/** 某一章里"算进章节奖励"的任务（支线与里程碑都不算）。 */
function chapterQuests(ctx: ContentContext, chapter: number): QuestID[] {
  return ctx.questIds.filter((id) => {
    const q = ctx.quests[id]!
    return q.chapter === chapter && q.kind === 'main'
  })
}

/**
 * 上一章的**主线**是否全绿（用户 2026-10-20：支线的开关）。
 *
 * 为什么支线要这个：瑟拉菲娜的送物资支线原来第一条挂在章 1，可她**章 1 收尾才登场** ——
 * 开局就摊出来等于剧透。所以支线统一等"上一章主线走完"再露（同一瞬间她就登场了）。
 *
 * ⚠️ 与 `chapterOpenDay` 不是一回事：这里**不看 `gapDays`**（那是主线的剧情时钟）。
 * ⚠️ 上一章**一条主线都没有**（还没写内容的占位章）→ 视为"还没到"，
 *    否则章 7 之后那几条送物资会在章 6 一结束就一口气全摊出来。
 */
function prevChapterMainDone(state: GameState, ctx: ContentContext, chapterId: number): boolean {
  const i = ctx.chapters.findIndex((c) => c.id === chapterId)
  if (i <= 0) return true
  const list = chapterQuests(ctx, ctx.chapters[i - 1]!.id)
  if (list.length === 0) return false
  return list.every((id) => state.quests.done[id] !== undefined)
}

/**
 * 这条任务完成时实际发多少钱。
 *
 * 里程碑一律 0（内容校验也拦：`kind: "milestone"` 不许写 `reward`）。
 * 单独一个函数，是为了让"发了多少"与"公告怎么说"永远同一个数。
 */
export function questReward(def: QuestDef): number {
  return def.kind === 'milestone' ? 0 : def.reward
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
      if (!questAvailable(state, ctx, def)) continue
      if (!questProgress(state, ctx, def).met) continue
      done[id] = day
      // 里程碑**不发钱**（用户 2026-10 · B2）：它们只是"把追踪条填住"，
      // 而且目标故意设得很远 —— 发钱会变成一台躺赚的机器。
      state.government.money = round2(state.government.money + questReward(def))
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
    // 里程碑不发钱 —— 公告也就不能写「（+0 金）」，不然玩家会去查账
    let sum = 0
    for (const q of finished) sum += questReward(q)
    if (finished.length === 1) {
      const q = finished[0]!
      logs.push({
        day,
        kind: 'info',
        text: sum > 0 ? `完成任务：${q.title}（+${sum} 金）` : `完成任务：${q.title}`,
      })
    } else {
      const titles = finished.map((q) => q.title).join('、')
      logs.push({
        day,
        kind: 'info',
        text: sum > 0
          ? `完成 ${finished.length} 项任务（+${sum} 金）：${titles}`
          : `完成 ${finished.length} 项任务：${titles}`,
      })
    }

    // 这次结算把哪些任务"顶"了出来 —— 只报这些，别把早就可见的再报一遍
    const justDone = new Set(finished.map((q) => q.id))
    const opened: string[] = []
    for (const id of ctx.questIds) {
      if (done[id] !== undefined) continue
      const def = ctx.quests[id]!
      if (!def.requires.some((r) => justDone.has(r))) continue
      if (!questAvailable(state, ctx, def)) continue
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

/**
 * 一段剧情对话（引擎说"该播这个"，UI 只管画）。
 *
 * 形状定义在 `types.ts` 的 `StoryTalk` —— 因为场次（`systems/scenes.ts`）也用它，
 * 而场次不能反过来 import 这个文件（会成环）。这个名字留着是给读代码的人对口径。
 */
export type QuestTalk = StoryTalk

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
 * 还没播过的对话，**按内容顺序**排好（章与章之间 → 第 1 章任务 → 第 1 章收尾 → 第 2 章 …）。
 *
 * 为什么按章节交错而不是"先全部任务、再全部收尾"：第一章一结束，第二章的任务
 * 当晚会一起解锁 —— 收尾那段必须**排在**下一章任务之前，不然瑟拉菲娜的登场
 * 会插在露娜的"蔬菜农场"后面。
 *
 * 场次（用户 2026-10 · A1）排在下章任务**之前**：`when.chapter: N` 的场次说的是
 * "第 N 章收尾之后发生的事"，也就是章与章之间那段 —— 它得比下一章的差事先到。
 */
export function questTalks(state: GameState, ctx: ContentContext): QuestTalk[] {
  const out: QuestTalk[] = []
  const shown = state.quests.shown ?? {}
  const done = state.quests.done
  for (const [ci, ch] of ctx.chapters.entries()) {
    // "上一章收尾之后"的场次：排在本章任务前面
    const prev = ci > 0 ? ctx.chapters[ci - 1]! : undefined
    if (prev !== undefined) out.push(...scenesAfterChapter(state, ctx, prev.id))
    const cid = String(ch.id)
    for (const id of ctx.questIds) {
      const def = ctx.quests[id]!
      if (def.chapter !== ch.id) continue
      if (done[id] !== undefined) continue
      if (!questAvailable(state, ctx, def)) continue
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
  // 最后一章收尾之后的场次（之后就没有"下一章"了）
  const last = ctx.chapters[ctx.chapters.length - 1]
  if (last !== undefined) out.push(...scenesAfterChapter(state, ctx, last.id))
  return out
}

/**
 * 记一笔"这段播过了"（只记事，不改任何数字）。
 *
 * 键前缀决定记在哪本账上：`s:` 是场次（`state.scenes.shown`），其余是任务对话
 * （`quests.shown`）。两份账分开是因为场次不属于任务系统，但入口**只有一个** ——
 * 播放器（`quest_talk.gd` / `main.gd`）不需要知道这件事。
 */
export function markQuestTalkShown(state: GameState, key: string): void {
  if (key.startsWith('s:')) {
    markSceneShown(state, key)
    return
  }
  state.quests.shown[key] = true
}
