import type { GameState, SceneDef, StoryTalk } from '../types.ts'
import type { ContentContext } from '../content/index.ts'

// ---------------------------------------------------------------------------
// 场次（"不挂任务的戏"）—— 用户 2026-10 · A1
//
// 以前的对话只有两个触发点：任务出现在追踪条上、一章全绿（`chapters[].outro`）。
// 艾莉丝 / 米拉 / 加雷斯这些"不挂任务、也不是章末"的登场就没地方放。
// 这个文件补的正是那一格：内容在 `content/scenes.json`，引擎只判"该不该播"。
//
// 三条口径（与任务对话完全一致，别另起一套）：
//   1. **状态比对，不是队列**：`state.scenes.shown` 里没有的就还没播过 ——
//      读档 / 退出重进都不重播、也不漏播（队列会丢）。
//   2. 播放**复用** `quest_talk.gd`：它要的东西（说话人 + 立绘 + 逐行台词 + 可选选项）
//      与任务对话同形，所以返回值直接用 `StoryTalk`。
//   3. 只记事、不演化：播不播都不改村子的任何数字（和 `prophet` / `townCenter` 一类）。
//
// ⚠️ 场次**不进**追踪条、不进任务面板 —— 它不是差事，是一段戏。
// ---------------------------------------------------------------------------

/** 这一场的记账键。 */
export function sceneKey(sc: SceneDef): string {
  return `s:${sc.id}`
}

/**
 * 这一场现在该播了吗（只读）。
 *
 * `when` 里写几个条件就要求几个，全部为真才开。`afterDays` 的起算点：
 *   · 有 `chapter` → 那一章**领奖那天**
 *   · 没有 `chapter` → 开局第 1 天
 */
export function sceneReady(state: GameState, ctx: ContentContext, sc: SceneDef): boolean {
  if (state.scenes.shown[sceneKey(sc)] === true) return false
  const w = sc.when
  let openDay = 1
  if (w.chapter !== undefined) {
    const chDay = state.quests.chapters[String(w.chapter)]
    // 那一章还没收尾 → 这一场还不到时候
    if (chDay === undefined) return false
    openDay = chDay
  }
  openDay += Math.max(0, Math.floor(w.afterDays ?? 0))
  if (state.day < openDay) return false
  if (w.minDay !== undefined && state.day < w.minDay) return false
  if (w.pop !== undefined && state.residents.length < w.pop) return false
  if (w.building !== undefined) {
    let n = 0
    for (const s of state.shops) if (s.defId === w.building) n += 1
    if (n < 1) return false
  }
  if (w.tech !== undefined && !state.research.done.includes(w.tech)) return false
  if (w.class !== undefined) {
    const need = Math.max(1, Math.floor(w.classMin ?? 1))
    let n = 0
    for (const r of state.residents) if (r.classId === w.class) n += 1
    if (n < need) return false
  }
  return true
}

/** 一场戏 → 一段对话（`StoryTalk`，与任务对话同形）。 */
export function sceneTalk(sc: SceneDef, chapter: number): StoryTalk {
  return {
    key: sceneKey(sc),
    kind: 'scene',
    id: sc.id,
    chapter,
    speaker: sc.speaker,
    portrait: sc.portrait,
    lines: sc.lines.slice(),
    ...(sc.choices ? { choices: sc.choices } : {}),
  }
}

/**
 * 该章节收尾**之后**该播的场次（按内容定义顺序）。
 *
 * `chapterId` = 刚刚收尾的那一章。排序由调用方（`quests.ts::questTalks`）负责：
 * 这些场次排在下章任务之前、本章收尾之后 —— 也就是"章与章之间"。
 */
export function scenesAfterChapter(state: GameState, ctx: ContentContext, chapterId: number): StoryTalk[] {
  const out: StoryTalk[] = []
  for (const id of ctx.sceneIds) {
    const sc = ctx.scenes[id]!
    if ((sc.when.chapter ?? 0) !== chapterId) continue
    if (!sceneReady(state, ctx, sc)) continue
    // 下一章号（只说"这段属于哪一章附近"，UI 不用它做判定）
    const i = ctx.chapters.findIndex((c) => c.id === chapterId)
    const near = i >= 0 && i + 1 < ctx.chapters.length ? ctx.chapters[i + 1]!.id : chapterId
    out.push(sceneTalk(sc, near))
  }
  return out
}

/** 记一笔"这一场播过了"（只记事，不改任何数字）。 */
export function markSceneShown(state: GameState, key: string): void {
  if (state.scenes === undefined) state.scenes = { shown: {} }
  state.scenes.shown[key] = true
}
