import { createInitialState, runDawn, buildContext } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import { questTalks, markQuestTalkShown } from '../src/engine/systems/quests.ts'
import { sceneReady, scenesAfterChapter } from '../src/engine/systems/scenes.ts'

// ---------------------------------------------------------------------------
// 场次（"不挂任务的戏"）引擎自检 —— 用户 2026-10 · A1/A2
//
//   node --experimental-strip-types scripts/check-scenes.ts
//
// 契约见 docs/quests.md §八。要盯住的五件事：
//   1. 内容：五场戏都在、说话人 / 立绘 / 台词都不空
//   2. **状态比对**：播过的记在 `state.scenes.shown`（不是队列），读档不重播
//   3. 触发条件：`{ chapter, afterDays }` 的闸按"那一章领奖那天"起算
//   4. 排序：场次排在**下一章任务之前**（章与章之间那段戏）
//   5. 只记事不演化：一场戏播不播，村子的数字一个都不动
//
// GDScript 那份镜像由 `godot/tools/scene_test.gd` 对拍。
// ---------------------------------------------------------------------------

let failed = 0
function ok(name: string, cond: boolean, detail = ''): void {
  if (!cond) failed++
  console.log(`${cond ? '  ok  ' : '  FAIL'} ${name}${detail ? '  —— ' + detail : ''}`)
}

const ctx = buildContext('v0.3')

function freshState(): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261018 })
  for (const g of ctx.pack.goods) s.goods[g] = 5000
  s.government.money = 10000
  return s
}

/** 把第 1~n 章的"已经收尾"和"任务都做过"一起摆好（只为让后面的场次到点）。 */
function stageChapters(s: GameState, upto: number): void {
  for (const ch of ctx.chapters) {
    if (ch.id > upto) continue
    s.quests.chapters[String(ch.id)] = 1
    for (const id of ctx.questIds) {
      if (ctx.quests[id]!.chapter === ch.id) s.quests.done[id] = 1
    }
  }
}

const talkKeys = (s: GameState): string[] => questTalks(s, ctx).map((t) => t.key)

console.log('\n=== 场次（不挂任务的戏）引擎自检 ===\n')

// ---- 1. 内容齐不齐 -------------------------------------------------------
{
  const ids = ctx.sceneIds
  ok('五场戏都在（瑟拉菲娜的朋友 / 艾莉丝 / 米拉 / 加雷斯两次）',
    ids.length === 5 &&
      ['sc_serafina_friend', 'sc_elise_meet', 'sc_milla_arrive',
        'sc_gareth_nightwatch', 'sc_bandit'].every((id) => ids.includes(id)),
    ids.join(' → '))
  ok('每场都有说话人、立绘、台词（至少两页）',
    ids.every((id) => {
      const sc = ctx.scenes[id]!
      return sc.speaker !== '' && sc.portrait !== '' && sc.lines.length >= 2
    }))
  ok('场次一律没有选项（戏就是戏，不让玩家挑）',
    ids.every((id) => ctx.scenes[id]!.choices === undefined))
  ok('加雷斯 / 米拉 / 艾莉丝都在内容里露过面',
    ['gareth', 'milla', 'elise'].every((who) => ids.some((id) => ctx.scenes[id]!.speaker === who)))
}

// ---- 2. 触发条件：那一章收尾 + afterDays ---------------------------------
{
  const s = freshState()
  const friend = ctx.scenes['sc_serafina_friend']!
  s.day = 9
  ok('章 2 还没收尾 → 她不会来提"朋友"', !sceneReady(s, ctx, friend))
  s.quests.chapters['2'] = 9
  ok('章 2 当天还不播（afterDays = 1）', !sceneReady(s, ctx, friend))
  s.day = 10
  ok('章 2 收尾第二天 → 该播了', sceneReady(s, ctx, friend))

  // 章 4 收尾之后三场戏按 afterDays 陆续到
  const s2 = freshState()
  s2.quests.chapters['4'] = 10
  s2.day = 10
  ok('章 4 当天：艾莉丝 / 米拉 / 加雷斯都还没到',
    scenesAfterChapter(s2, ctx, 4).length === 0,
    scenesAfterChapter(s2, ctx, 4).map((t) => t.key).join(' → '))
  s2.day = 11
  ok('第 11 天只有艾莉丝（afterDays = 1）',
    scenesAfterChapter(s2, ctx, 4).map((t) => t.id).join(',') === 'sc_elise_meet',
    scenesAfterChapter(s2, ctx, 4).map((t) => t.id).join(','))
  s2.day = 12
  ok('第 12 天米拉也到了（afterDays = 2）',
    scenesAfterChapter(s2, ctx, 4).map((t) => t.id).join(',') === 'sc_elise_meet,sc_milla_arrive',
    scenesAfterChapter(s2, ctx, 4).map((t) => t.id).join(','))
  s2.day = 13
  ok('第 13 天加雷斯到（afterDays = 3，按内容顺序排）',
    scenesAfterChapter(s2, ctx, 4).map((t) => t.id).join(',') ===
      'sc_elise_meet,sc_milla_arrive,sc_gareth_nightwatch',
    scenesAfterChapter(s2, ctx, 4).map((t) => t.id).join(','))

  // 马匪只有一场戏：章 5 收尾当天就该播，而且**不结算**
  const s3 = freshState()
  s3.quests.chapters['5'] = 7
  s3.day = 7
  ok('章 5 收尾当天，加雷斯来讲马匪（不拖到第二天）',
    scenesAfterChapter(s3, ctx, 5).map((t) => t.id).join(',') === 'sc_bandit',
    scenesAfterChapter(s3, ctx, 5).map((t) => t.id).join(','))
  const lines = scenesAfterChapter(s3, ctx, 5)[0]!.lines.join('')
  ok('马匪那一场只"照了一面"，没有开打也没有战报',
    lines.includes('没打') && !lines.includes('战报') && !lines.includes('伤亡'), lines)
}

// ---- 3. 状态比对：播过就记一笔，读档不重播 -------------------------------
{
  const s = freshState()
  s.quests.chapters['2'] = 1
  s.day = 2
  const key = 's:sc_serafina_friend'
  ok('还没播过 → 该播', questTalks(s, ctx).some((t) => t.key === key), talkKeys(s).join(' → '))
  markQuestTalkShown(s, key)
  ok('播过之后记在 `state.scenes.shown` 里（不是 quests.shown）',
    s.scenes.shown[key] === true && s.quests.shown[key] === undefined,
    `${JSON.stringify(s.scenes.shown)} / ${JSON.stringify(s.quests.shown)}`)
  ok('播过就不再返回（读档 / 退出重进都不重播）',
    !questTalks(s, ctx).some((t) => t.key === key))
}

// ---- 4. 排序：场次排在下一章任务之前 -------------------------------------
{
  const s = freshState()
  stageChapters(s, 2)
  // 章 1 / 章 2 的收尾都先播过，免得它们挡在最前面
  s.quests.shown['c:1'] = true
  s.quests.shown['c:2'] = true
  s.quests.chapters['2'] = 1
  s.day = 2
  const keys = talkKeys(s)
  ok('章 2 收尾之后：场次排在第 3 章任务之前',
    keys[0] === 's:sc_serafina_friend' && keys[1]!.startsWith('q:q0'),
    keys.join(' → '))
  ok('场次不重复出现（同一场只播一次）',
    keys.filter((k) => k === 's:sc_serafina_friend').length === 1, keys.join(' → '))
}

// ---- 5. 只记事、不演化 ---------------------------------------------------
{
  const s = freshState()
  s.quests.chapters['2'] = 1
  s.day = 2
  const snap = (st: GameState): string => JSON.stringify({
    goods: st.goods,
    money: st.government.money,
    residents: st.residents.length,
    shops: st.shops,
    done: st.quests.done,
    chapters: st.quests.chapters,
  })
  const before = snap(s)
  // 判定、取列表、记账 —— 这三件事都不许碰村子的数字
  sceneReady(s, ctx, ctx.scenes['sc_serafina_friend']!)
  questTalks(s, ctx)
  markQuestTalkShown(s, 's:sc_serafina_friend')
  ok('判定 / 取列表 / 记账，村子的数字一个都不动', before === snap(s))
}

console.log('')
if (failed > 0) {
  console.error(`场次自检失败 ${failed} 条 ❌`)
  process.exit(1)
}
console.log('场次自检通过 🎉')
