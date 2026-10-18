import { advanceHour, applyActions, buildContext, createInitialState } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import {
  questView,
  questProgress,
  questJournal,
  questTalks,
  markQuestTalkShown,
  splitSentences,
  chapterOpen,
  questReward,
} from '../src/engine/systems/quests.ts'
import {
  TOWN_CENTER_PATCH_COST,
  TOWN_CENTER_REPAIR_COST,
  townCenterStage,
} from '../src/engine/systems/investment.ts'
import { runDawn } from '../src/engine/tick.ts'
import { TIME } from '../src/engine/config.ts'

// ---------------------------------------------------------------------------
// 任务（引导系统）引擎自检
//
//   node --experimental-strip-types scripts/check-quests.ts
//
// 契约见 docs/quests.md，要盯住的五件事：
//   1. **渐进显示**：`requires` 没全完成的任务看不见（玩家不知道后面还有什么）
//   2. **黎明结算**：达成即完成、发钱、写公告 —— 不需要玩家"提交"
//   3. **可追溯**：玩家先干了、任务后出现（同一次黎明里连锁解锁）也当场算完成
//   4. **支线不挡主线**：章节奖励只数非支线任务
//   5. **不回退**：完成过就是完成过，钱不重复发
//
// GDScript 那份镜像由 `godot/tools/quest_test.gd` 对拍（同口径、同数字）。
// ---------------------------------------------------------------------------

let failed = 0
function ok(name: string, cond: boolean, detail = ''): void {
  if (!cond) failed++
  console.log(`${cond ? '  ok  ' : '  FAIL'} ${name}${detail ? '  —— ' + detail : ''}`)
}

const ctx = buildContext('v0.3')

function freshState(): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261016 })
  for (const g of ctx.pack.goods) s.goods[g] = 5000
  s.government.money = 10000
  return s
}

/** 直接塞一座"已建成"的建筑（任务判定看的是 `state.shops`，在途工地不算）。 */
function addShop(s: GameState, defId: string, n = 1): void {
  for (let i = 0; i < n; i++) {
    s.shops.push({
      id: `${defId}#q${s.shops.length + 1}`,
      defId,
      owner: 'state',
      targetWorkers: ctx.buildings[defId]?.workers ?? 1,
      wage: 3,
      wageCap: 6,
      level: 1,
      active: true,
      profit: 0,
      skill: 50,
      planned: 0,
      toolBoost: 1,
    })
  }
}

function addResidents(s: GameState, n: number, classId = 'poor', sat = 70): void {
  for (let i = 0; i < n; i++) {
    s.residents.push({
      id: `res#q${s.residents.length + 1}`,
      classId,
      savings: 10,
      satisfaction: sat,
      skill: 50,
      employed: false,
    })
  }
}

/**
 * 摆一个"**第 1~3 章主线全都已经干完了**"的村子（建筑 / 科技 / 住房 / 人口 / 台账）。
 *
 * 用来验两件事：① 同一次黎明里的**连锁结算**（含"玩家早就干完、任务才刚出现"）
 * ② 支线（石制工具：科技 + 工具坊 + 产 4 件）**没做**也照样拿章节奖励。
 */
function stageThroughChapter3(s: GameState): void {
  for (const id of [
    'wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm',
    'research_institute', 'quarry', 'clay_pit', 'firewood_works', 'brick_kiln', 'construction_works',
  ]) {
    addShop(s, id)
  }
  s.housing['hut'] = 8 // 容量 32 → 「住得下」
  addResidents(s, 60, 'poor', 70) // 人口 60 + 满意度均值约 69 → 「让人愿意来」/「五十人的村子」
  s.research.done = ['stonework', 'digging', 'firewood', 'brickmaking', 'construction']
  s.goods['brick'] = 100
  // 城镇中心：第 3 章多了「初步修缮」那条任务（q05e），先把这一步做掉
  s.townCenter = { stage: 'patched' }
  // 第 3 章多了「凿子崩了三把」（q05f_tools）：要有石制工具作坊 + 10 件石制工具
  s.shops.push({
    id: 'tool_works#probe',
    defId: 'tool_works',
    owner: 'state',
    targetWorkers: 0,
    wage: 3,
    wageCap: 6,
    level: 1,
    active: true,
    profit: 0,
    skill: 50,
    planned: 0,
  } as GameState['shops'][number])
  s.goods['stone_tools'] = 10
  // 单日产能看的是**台账**（history），不是库存 —— 所以这儿得塞一天的历史
  s.history.push({
    day: 1,
    population: 60,
    avgSatisfaction: 70,
    money: 0,
    hungry: 0,
    employed: 0,
    ledger: {
      day: 1,
      wages: 0,
      tax: 0,
      rent: 0,
      sales: 0,
    publicSubsidy: 0,
      produced: { coarse_bread: 40, vegetable: 20 },
      consumed: {},
      bought: {},
      consumedBy: {},
      boughtBy: {},
    },
  })
}

const viewIds = (s: GameState): string[] => questView(s, ctx).map((q) => q.def.id)

const texts = (s: GameState, id: string): string[] =>
  questProgress(s, ctx, ctx.quests[id]!).goals.map((g) => g.text)

console.log('\n=== 任务系统引擎自检 ===\n')

// ---- 1. 开局：只看得见第 1 章的两条主线（外加一条送物资支线） ------------
{
  const s = freshState()
  const ids = viewIds(s)
  ok('开局只看得到第 1 章的差事 + 一条送物资支线',
    JSON.stringify(ids) === JSON.stringify(['q01_bread_chain', 'q02_vegetable', 'q_s_sera_1']),
    ids.join(' → '))
  ok('未解锁的任务不可见（别让玩家知道后面干嘛）',
    !ids.includes('q03a_housing_capacity') && !ids.includes('q04_institute'))
  ok('开局进度文案：住房容量 24/32',
    texts(s, 'q03a_housing_capacity').join(' | ') === '住房容量 24/32',
    texts(s, 'q03a_housing_capacity').join(' | '))
  ok('开局进度文案：小麦农场 0/1',
    texts(s, 'q01_bread_chain')[0] === '小麦农场 0/1', String(texts(s, 'q01_bread_chain')[0]))
}

// ---- 2. 黎明结算：达成即完成、发钱、写公告、章节奖励一起发 ----------------
{
  const s = freshState()
  addShop(s, 'wheat_farm')
  addShop(s, 'coarse_mill')
  addShop(s, 'coarse_bakery')
  addShop(s, 'vegetable_farm')
  const before = s.government.money
  const { logs } = runDawn(s, ctx)
  const money = s.government.money - before
  ok('同一次黎明完成两条任务，一起结算', money === 1000 + 1000, `+${money} 金`)
  ok('第 1 章全绿 → 章节奖励也当场发', s.quests.chapters['1'] === s.day, `第 ${s.quests.chapters['1']} 天`)
  ok('完成记录写在 `quests.done` 里', s.quests.done['q01_bread_chain'] === s.day)
  const text = logs.map((l) => l.text).join(' / ')
  ok('公告里写明完成了什么、加了多少钱',
    text.includes('完成 2 项任务（+1000 金）：粗面包链、蔬菜农场'), text)
  ok('公告里报出被"顶"出来的新任务', text.includes('新任务：住得下、按人口配产能、让人愿意来'), text)
  ok('章节奖励也写公告', text.includes('章节「先吃饱」全部完成（+1000 金）'), text)
}

// ---- 3. 渐进显示：完成后才露出下一层，且是三条并行 ----------------------
{
  const s = freshState()
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) addShop(s, id)
  runDawn(s, ctx)
  const ids = viewIds(s)
  ok('第 2 章的三条任务同时可见（可并行）',
    ['q03a_housing_capacity', 'q03b_output', 'q03c_satisfaction'].every((x) => ids.includes(x)),
    ids.join(' → '))
  ok('第 3 章仍然不可见（前置没完成）', !ids.includes('q04_institute'), ids.join(' → '))
  ok('今天刚完成的任务还留在追踪条上（打勾）',
    ids.includes('q01_bread_chain') && ids.includes('q02_vegetable'), ids.join(' → '))

  // 再跑一天：昨天完成的那两条应当消失，只剩第 2 章的三条（+ 送物资支线）
  runDawn(s, ctx)
  const ids2 = viewIds(s)
  ok('隔天之后，已完成的任务从追踪条上收掉',
    JSON.stringify(ids2) ===
      JSON.stringify(['q03a_housing_capacity', 'q03b_output', 'q03c_satisfaction', 'q_s_sera_1']),
    ids2.join(' → '))
}

// ---- 4. 可追溯：先干了、任务后出现 —— 同一次黎明里连锁完成 ----------------
{
  const s = freshState()
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) addShop(s, id)
  // 玩家在接到"住得下"之前就把住房容量撑到 32 了（8 座茅屋 = 32）
  s.housing['hut'] = 8
  const before = s.government.money
  const { logs } = runDawn(s, ctx)
  const money = s.government.money - before
  ok('同一次黎明连锁完成 3 条（含那条"早就干完了"的）',
    s.quests.done['q03a_housing_capacity'] === s.day && money === 3 * 500 + 1000,
    `+${money} 金`)
  ok('公告把连锁的几条合并成一条',
    logs.map((l) => l.text).join(' / ').includes('完成 3 项任务（+1500 金）'),
    logs.map((l) => l.text).join(' / '))
}

// ---- 5. 没达成就不结算，而且钱不会重复发 --------------------------------
{
  const s = freshState()
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) addShop(s, id)
  runDawn(s, ctx)
  const money1 = s.government.money
  const { logs } = runDawn(s, ctx)
  const money2 = s.government.money
  ok('没达成 → 一分钱不发', money1 === money2, `${money1} → ${money2}`)
  ok('没达成 → 不写"完成"公告',
    !logs.some((l) => l.text.includes('完成任务：') || l.text.includes('完成 2 项任务')), '')

  // 人口掉回去也不算未完成 —— 用一个"先把 1~3 章主线全摆好"的村子来验
  const s2 = freshState()
  stageThroughChapter3(s2)
  const moneyA = s2.government.money
  runDawn(s2, ctx)
  ok('前置齐了 → 人口早过 50 也当场算完成（可追溯）',
    s2.quests.done['q06_pop50'] === s2.day, `第 ${s2.quests.done['q06_pop50']} 天`)
  ok('同一次黎明把 1~3 章主线连锁结算完（14 条任务 + 3 个章节奖励）',
    s2.government.money - moneyA === 14 * 500 + 3 * 1000, `+${s2.government.money - moneyA} 金`)
  const doneDay = s2.quests.done['q06_pop50']
  s2.residents.length = 10
  runDawn(s2, ctx)
  ok('人口掉回去也不回退（完成过就是完成过）',
    s2.quests.done['q06_pop50'] === doneDay, `第 ${s2.quests.done['q06_pop50']} 天`)
}

// ---- 6. 支线不挡主线（章节奖励只数非支线） ------------------------------
{
  const s = freshState()
  stageThroughChapter3(s)
  runDawn(s, ctx)
  ok('第 3 章支线没做也照样拿章节奖励',
    s.quests.chapters['3'] === s.day && s.quests.done['q08_tools'] === undefined,
    `chapter3 第 ${s.quests.chapters['3']} 天 / 支线 ${s.quests.done['q08_tools']}`)
  ok('支线本身仍可见（只是不挡路）', viewIds(s).includes('q08_tools'), viewIds(s).join(' → '))
}

// ---- 7. 进度文案与"看产量不看库存" --------------------------------------
{
  const s = freshState()
  s.goods['coarse_bread'] = 9999
  const p = questProgress(s, ctx, ctx.quests['q03b_output']!)
  ok('库存再多也不算：单日产量看的是台账', !p.met, p.goals.map((g) => g.text).join(' | '))
  s.ledgerToday.produced['coarse_bread'] = 31
  s.ledgerToday.produced['vegetable'] = 16
  const p2 = questProgress(s, ctx, ctx.quests['q03b_output']!)
  ok('当天产量达标 → 立刻显示达成（但要等黎明结算）',
    p2.met && !p2.done, p2.goals.map((g) => g.text).join(' | '))
  ok('产量文案：粗面包单日产量 31/30',
    p2.goals[0]!.text === '粗面包单日产量 31/30', p2.goals[0]!.text)

  // 关掉"科技"的进度文案
  const s3 = freshState()
  ok('科技目标显示成勾选项文案',
    questProgress(s3, ctx, ctx.quests['q05a_stone']!).goals[0]!.text === '研究「石作」',
    questProgress(s3, ctx, ctx.quests['q05a_stone']!).goals[0]!.text)
  ok('私有住房文案', questProgress(s3, ctx, ctx.quests['q15_private_housing']!).goals[0]!.text === '私有住房 0/5 户')
}

// ---- 8. 真的跑一天：advanceHour 走到黎明也不会重复结算 -------------------
{
  const s = freshState()
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) addShop(s, id)
  const before = s.government.money
  // 从 0 点走到第二天 0 点（跨过一次黎明）。`advanceHour` 是纯函数：每一步都要接返回值。
  let cur = s
  for (let i = 0; i < TIME.hoursPerDay; i++) cur = advanceHour(cur).state
  // ⚠️ 不能拿国库余额对账：这一天里还发了工资、收了税与房租、居民买了粮。
  //    所以这里只验"任务结算恰好发生一次"。
  ok('一整天下来：两条任务 + 第 1 章的完成记录各只记一次',
    Object.keys(cur.quests.done).length === 2 &&
      cur.quests.done['q01_bread_chain'] !== undefined &&
      cur.quests.done['q02_vegetable'] !== undefined &&
      Object.keys(cur.quests.chapters).length === 1,
    JSON.stringify(cur.quests.done))
  ok('完成公告在这一天里只出现一次',
    cur.log.filter((l) => l.text.includes('完成 2 项任务')).length === 1,
    String(before))
}

// ---- 9. 任务面板的数据源：questJournal（做过的都要留着）------------------
{
  // 面板与追踪条**不是**一回事：追踪条只要"当前该做 / 今天刚做完"，面板要把
  // 做过的历史都留着给玩家翻（用户："此面板记录之前完成的所有任务"）。
  const s = freshState()
  ok('开局：面板里是那两条主线 + 一条送物资支线', questJournal(s, ctx).length === 3,
    questJournal(s, ctx).map((q) => q.def.id).join('、'))
  ok('每条任务都带 brief（面板右侧的描述）',
    questJournal(s, ctx).every((q) => q.def.brief.length > 0))
  ok('里程碑不发钱（reward = 0），其余任务都发',
    questJournal(s, ctx).every((q) => (q.def.kind === 'milestone' ? q.def.reward === 0 : q.def.reward > 0)))
  ok('锁着的仍然不进面板（渐进显示在面板上也要守）',
    !questJournal(s, ctx).some((q) => q.def.id === 'q04_institute'))

  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) addShop(s, id)
  runDawn(s, ctx)
  ok('第 1 章两条都完成之后：面板里多了第 2 章那三条（已解锁）',
    questJournal(s, ctx).some((q) => q.def.id === 'q03a_housing_capacity'),
    questJournal(s, ctx).map((q) => q.def.id).join('、'))

  // 走够一天：追踪条会把"今天刚完成"的收掉，面板必须留着
  let cur = s
  for (let i = 0; i < TIME.hoursPerDay; i++) cur = advanceHour(cur).state
  ok('隔天：追踪条收掉了 q01（不是今天完成的了）',
    !questView(cur, ctx).some((q) => q.def.id === 'q01_bread_chain'))
  const jq = questJournal(cur, ctx).find((q) => q.def.id === 'q01_bread_chain')
  ok('隔天：面板里 q01 还在，并且记着第几天完成', jq !== undefined && jq.done && (jq.day ?? -1) >= 0,
    jq === undefined ? '（没了）' : `day=${jq.day}`)
  ok('面板里的顺序 = 内容定义顺序（左树按章节分组后就是章节内顺序）',
    questJournal(cur, ctx).every((q, i, arr) => i === 0 || ctx.questIds.indexOf(arr[i - 1]!.def.id) < ctx.questIds.indexOf(q.def.id)))
}

// ---- 10. 修缮城镇中心：两段（初步修缮 → 修好）+ `building_repaired.stage` ------
{
  const s = freshState()
  const patchDef = ctx.quests['q05e_townhall_patch']!
  const fullDef = ctx.quests['q10f_townhall_repair']!
  const patchText = (): string => questProgress(s, ctx, patchDef).goals[0]!.text
  const fullText = (): string => questProgress(s, ctx, fullDef).goals[0]!.text

  ok('第 3 章那条是「初步修缮」（building_repaired + stage=patched）',
    patchDef.goals[0]!.type === 'building_repaired' &&
      (patchDef.goals[0] as { stage?: string }).stage === 'patched',
    JSON.stringify(patchDef.goals[0]))
  ok('第 4 章那条是「修好」（不带 stage = restored）',
    fullDef.goals[0]!.type === 'building_repaired' &&
      (fullDef.goals[0] as { stage?: string }).stage === undefined,
    JSON.stringify(fullDef.goals[0]))
  ok('两条的进度文案不同：初步 0/1 / 修好 0/1',
    patchText() === '城镇中心 已初步修复 0/1' && fullText() === '城镇中心 已修复 0/1',
    `${patchText()} | ${fullText()}`)

  // 材料不够 → 白下这一单
  s.goods['wood'] = 5
  s.goods['stone'] = 10
  applyActions(s, ctx, [{ type: 'repair_town_center', stage: 'patched' }])
  ok('初步修缮材料不够 → 不扣料、还是废墟',
    townCenterStage(s) === 'ruined' && s.goods['wood'] === 5, `wood=${s.goods['wood']}`)

  // 材料刚好够 → patched，且**正好扣光**
  s.goods['wood'] = TOWN_CENTER_PATCH_COST['wood']!
  s.goods['stone'] = TOWN_CENTER_PATCH_COST['stone']!
  const r1 = applyActions(s, ctx, [{ type: 'repair_town_center', stage: 'patched' }])
  ok('材料够了 → 初步修缮生效', r1[0]!.ok && townCenterStage(s) === 'patched')
  ok('初步修缮把料正好扣光',
    s.goods['wood'] === 0 && s.goods['stone'] === 0,
    `wood=${s.goods['wood']} stone=${s.goods['stone']}`)
  ok('初步修缮之后：第 3 章那条 1/1 且达成、第 4 章那条还没到',
    patchText() === '城镇中心 已初步修复 1/1' && questProgress(s, ctx, patchDef).met &&
      fullText() === '城镇中心 已修复 0/1' && !questProgress(s, ctx, fullDef).met,
    `${patchText()} | ${fullText()}`)

  // 不能跳级：废墟状态直接点「修好」要被拒
  const s2 = freshState()
  s2.goods['wood'] = TOWN_CENTER_REPAIR_COST['wood']!
  s2.goods['stone'] = TOWN_CENTER_REPAIR_COST['stone']!
  s2.goods['brick'] = TOWN_CENTER_REPAIR_COST['brick']!
  const rSkip = applyActions(s2, ctx, [{ type: 'repair_town_center', stage: 'restored' }])
  ok('废墟状态不能直接修好（要先初步修缮）',
    !rSkip[0]!.ok && townCenterStage(s2) === 'ruined' &&
      s2.goods['wood'] === TOWN_CENTER_REPAIR_COST['wood'], String(rSkip[0]!.reason))

  // 第二步：patched → restored
  s.goods['wood'] = TOWN_CENTER_REPAIR_COST['wood']!
  s.goods['stone'] = TOWN_CENTER_REPAIR_COST['stone']!
  s.goods['brick'] = TOWN_CENTER_REPAIR_COST['brick']!
  const r2 = applyActions(s, ctx, [{ type: 'repair_town_center', stage: 'restored' }])
  ok('第二步材料够了 → 修好', r2[0]!.ok && townCenterStage(s) === 'restored')
  ok('修好之后：两条都达成',
    fullText() === '城镇中心 已修复 1/1' && questProgress(s, ctx, fullDef).met, fullText())

  // 内容里的 hint 是**文字**，改价只能人肉对齐 —— 两条各钉一次
  ok('初步修缮的 hint 与引擎那份价格一致（木 20 / 石 10）',
    patchDef.hint.includes(`木材 ${TOWN_CENTER_PATCH_COST['wood']}`) &&
      patchDef.hint.includes(`石块 ${TOWN_CENTER_PATCH_COST['stone']}`),
    patchDef.hint)
  ok('修好的 hint 与引擎那份价格一致（木 30 / 石 20 / 砖 15）',
    fullDef.hint.includes(`木材 ${TOWN_CENTER_REPAIR_COST['wood']}`) &&
      fullDef.hint.includes(`石块 ${TOWN_CENTER_REPAIR_COST['stone']}`) &&
      fullDef.hint.includes(`砖 ${TOWN_CENTER_REPAIR_COST['brick']}`),
    fullDef.hint)

  // 已经修好了再点一次 → 不重复扣
  s.goods['wood'] = 50
  const again = applyActions(s, ctx, [{ type: 'repair_town_center', stage: 'restored' }])
  ok('修好了再点一次不会重复扣料', !again[0]!.ok && s.goods['wood'] === 50)

  // 前置：q11_middle 挂着第 4 章那条（内容里用户指定）
  ok('q11_middle 的前置就是「修复城镇中心」',
    ctx.quests['q11_middle']!.requires.join(',') === 'q10f_townhall_repair',
    ctx.quests['q11_middle']!.requires.join(','))
}
// ---- 11. 剧情对话：任务触发 / 章节收尾 -----------------------------------
{
  const s = freshState()
  const talks = questTalks(s, ctx)
  ok('开局有三段对话要播（第 1 章两条主线 + 送物资支线）',
    talks.length === 3 && talks[0]!.key === 'q:q01_bread_chain', talks.map((t) => t.key).join(' → '))
  ok('说话人/立绘取内容里的 giver / giverPortrait',
    talks[0]!.speaker === ctx.quests['q01_bread_chain']!.giver &&
      talks[0]!.portrait === ctx.quests['q01_bread_chain']!.giverPortrait,
    `${talks[0]!.speaker} / ${talks[0]!.portrait}`)
  ok('台词 = brief 逐句切开（至少 3 页）',
    talks[0]!.lines.length === splitSentences(ctx.quests['q01_bread_chain']!.brief).length &&
      talks[0]!.lines.length >= 3,
    `${talks[0]!.lines.length} 页`)
  ok('切句不会把逗号/冒号当句末',
    splitSentences('殿下，仓里那点存粮是死数：十二口人。靠余粮不行！').length === 2,
    JSON.stringify(splitSentences('殿下，仓里那点存粮是死数：十二口人。靠余粮不行！')))

  for (const t of talks) markQuestTalkShown(s, t.key)
  ok('播过的就不再返回（记在 quests.shown 里）', questTalks(s, ctx).length === 0)

  // 第 1 章全绿 → 收尾对话（瑟拉菲娜），并且**排在**第 2 章任务之前
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) addShop(s, id)
  runDawn(s, ctx)
  const t2 = questTalks(s, ctx)
  ok('第 1 章收尾排在第 2 章任务之前（瑟拉菲娜登场不该被插在后面）',
    t2[0]!.key === 'c:1', t2.map((t) => t.key).join(' → '))
  ok('收尾那段是瑟拉菲娜出场', t2[0]!.speaker === 'seraphina', t2[0]!.speaker)
  // 用户 2026-10：那两个选项删了 —— 她送的预言不许拒绝，后面直接接 5 行固定预言
  ok('第一章收尾**没有**选项了（预言不能拒绝）', (t2[0]!.choices ?? []).length === 0,
    JSON.stringify(t2[0]!.choices ?? []))
  ok('第一条预言是固定台词：6 行登场 + 5 行含糊预言 = 11 页',
    t2[0]!.lines.length === 11 && t2[0]!.lines[6] === '我看见的都不清楚……' &&
      t2[0]!.lines[10] === '……别问我什么时候。我要是知道，就不会住在这种地方了。',
    `${t2[0]!.lines.length} 页 / 第 7 页「${t2[0]!.lines[6]}」`)
  ok('后面跟着的是第 2 章那三条任务',
    t2.slice(1).every((t) => t.kind === 'quest') && t2.length === 4,
    t2.map((t) => t.key).join(' → '))
  markQuestTalkShown(s, 'c:1')
  ok('收尾播过也不再返回', !questTalks(s, ctx).some((t) => t.key === 'c:1'))
}

// ---- 12. 剧情时钟（B1）：章与章之间隔 3–5 天 ------------------------------
{
  const s = freshState()
  s.day = 5
  for (const c of ['1', '2', '3', '4']) s.quests.chapters[c] = 1
  ok('章 5 还没收尾 → 章 6 一律不开', !chapterOpen(s, ctx, 6))
  s.quests.chapters['5'] = 1
  ok('章 5 第 1 天收尾、章 6 的 gapDays = 5 → 第 5 天还没到点',
    !chapterOpen(s, ctx, 6), `第 ${s.day} 天`)
  s.day = 6
  ok('第 6 天开', chapterOpen(s, ctx, 6))
  ok('章 1–5 的 gapDays 全是 0（前五章不闸）',
    ctx.chapters.filter((c) => c.id <= 5).every((c) => c.gapDays === 0),
    ctx.chapters.filter((c) => c.id <= 5).map((c) => `${c.id}:${c.gapDays}`).join(' '))
  ok('章 6–17 每章都填了 3–5 天（固定值，不随机）',
    ctx.chapters.filter((c) => c.id >= 6).every((c) => c.gapDays >= 3 && c.gapDays <= 5),
    ctx.chapters.filter((c) => c.id >= 6).map((c) => `${c.id}:${c.gapDays}`).join(' '))

  // 间隔期：章 6 的主线不下发，但里程碑照样看得见（就是拿来填条的）
  const s2 = freshState()
  s2.quests.done['q12_pop250'] = 1
  for (const c of ['1', '2', '3', '4']) s2.quests.chapters[c] = 1
  s2.quests.chapters['5'] = 1
  s2.day = 5
  ok('间隔期内章 6 的主线不下发', !viewIds(s2).includes('q18_pop1000'), viewIds(s2).join(' → '))
  ok('间隔期不空：里程碑照样看得见', viewIds(s2).includes('q16_pop500'), viewIds(s2).join(' → '))
  s2.day = 6
  ok('隔够天数之后章 6 的主线才下发', viewIds(s2).includes('q18_pop1000'), viewIds(s2).join(' → '))
}

// ---- 13. 里程碑（B2）：不发钱、不挡剧情 ----------------------------------
{
  ok('三条人口 / 产能任务改成了里程碑',
    ['q16_pop500', 'q17_output_mid', 'q45_pop2000'].every((id) => ctx.quests[id]!.kind === 'milestone'))
  ok('里程碑不发钱（reward = 0）',
    ['q16_pop500', 'q17_output_mid', 'q45_pop2000'].every((id) => questReward(ctx.quests[id]!) === 0))
  ok('千人之村仍是章 6 的主线（不然章 6 永远收不了尾）',
    ctx.quests['q18_pop1000']!.kind === 'main')
  ok('主线不许依赖里程碑（里程碑不挡剧情）',
    ctx.questIds.every((id) => {
      const d = ctx.quests[id]!
      if (d.kind !== 'main') return true
      return d.requires.every((r) => ctx.quests[r]!.kind === 'main')
    }))

  // 完成一条里程碑：不发钱，公告里也不写金额
  const s = freshState()
  for (const id of ctx.questIds) {
    const d = ctx.quests[id]!
    if (d.chapter <= 5 && d.kind === 'main') s.quests.done[id] = 1
  }
  // 章 1–5 的章节奖励也先记掉，免得那 5 × 1000 混进这一笔账里
  for (const c of ['1', '2', '3', '4', '5']) s.quests.chapters[c] = 1
  addResidents(s, 520)
  const before = s.government.money
  const { logs } = runDawn(s, ctx)
  ok('人口过 500 → 里程碑当场完成', s.quests.done['q16_pop500'] === s.day,
    `第 ${s.quests.done['q16_pop500']} 天`)
  ok('里程碑完成一分钱不发', s.government.money === before, `${before} → ${s.government.money}`)
  const txt = logs.map((l) => l.text).join(' / ')
  ok('公告写「完成任务：五百人的村子」但不带金额',
    txt.includes('完成任务：五百人的村子') && !txt.includes('五百人的村子（+'), txt)
}

// ---- 14. 送物资（A4）：gift 命令 + gifted 目标 ---------------------------
{
  const def = ctx.quests['q_s_sera_1']!
  const s = freshState()
  s.goods['coarse_bread'] = 100
  const before = s.goods['coarse_bread']!
  const r = applyActions(s, ctx, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 20 }])
  ok('送物资：命令生效、当场扣货', r[0]!.ok && s.goods['coarse_bread'] === before - 20,
    `bread=${s.goods['coarse_bread']}`)
  ok('送出去的量记在 `gifts` 上', s.gifts['serafina']?.['coarse_bread'] === 20,
    JSON.stringify(s.gifts))
  const p = questProgress(s, ctx, def)
  ok('gifted 只认送出去的量：送 20 → 刚好达成',
    p.met && p.goals[0]!.text === '粗面包 已送出 20/20', p.goals[0]!.text)
  ok('再送一趟会累加', (() => {
    applyActions(s, ctx, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 10 }])
    return s.gifts['serafina']?.['coarse_bread'] === 30
  })(), JSON.stringify(s.gifts))

  const s2 = freshState()
  s2.goods['coarse_bread'] = 999
  ok('库存再多也不算送出（库存 ≠ 送礼）',
    !questProgress(s2, ctx, def).met && questProgress(s2, ctx, def).goals[0]!.have === 0)

  const s3 = freshState()
  s3.goods['coarse_bread'] = 5
  const r2 = applyActions(s3, ctx, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 20 }])
  ok('仓库不够 → 整单不送（不退一半）',
    !r2[0]!.ok && s3.goods['coarse_bread'] === 5 && (s3.gifts['serafina']?.['coarse_bread'] ?? 0) === 0,
    String(r2[0]!.reason))
  const r3 = applyActions(s3, ctx, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 0 }])
  ok('数量 0 → 拒', !r3[0]!.ok, String(r3[0]!.reason))
  ok('17 条送物资都是支线，且每章一条',
    ctx.questIds.filter((id) => id.startsWith('q_s_sera_')).length === 17 &&
      ctx.questIds.filter((id) => id.startsWith('q_s_sera_')).every((id) => ctx.quests[id]!.kind === 'side'),
    String(ctx.questIds.filter((id) => id.startsWith('q_s_sera_')).length))
}

// ---- 15. 提交要"当场"生效（2026-10-20）----------------------------------
// 用户："提交任务，要马上减少物资怎么能次日生效呢？……提交了任务直接完成。任务完成不用
// 等到 6:00 吧，这样游戏体验很差。" 所以：① 只花**没被锁定的**货；② 交完当场结算。
{
  // ① 被当天排产锁住的不能动
  const s = freshState()
  s.goods['coarse_bread'] = 30
  s.reserved['coarse_bread'] = 25
  const r = applyActions(s, ctx, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 10 }])
  ok('被当天排产锁住的货不能交（可用 = 库存 − 锁定）',
    !r[0]!.ok && s.goods['coarse_bread'] === 30, String(r[0]!.reason))
  const r2 = applyActions(s, ctx, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 5 }])
  ok('可用量够就能交（5 = 库存 30 − 锁定 25）',
    r2[0]!.ok && s.goods['coarse_bread'] === 25, `bread=${s.goods['coarse_bread']}`)

  // ② 交完当场完成，不用等下一个黎明
  const s2 = freshState()
  s2.goods['coarse_bread'] = 100
  const money0 = s2.government.money
  const tick = advanceHour(s2, [{ type: 'gift', to: 'serafina', goodId: 'coarse_bread', qty: 20 }])
  ok('gift 是即时动作：不进待生效队列',
    tick.state.pending.every((a) => a.type !== 'gift'), JSON.stringify(tick.state.pending))
  ok('交完当场完成（不用等 6:00）',
    tick.state.quests.done['q_s_sera_1'] === tick.state.day,
    `day=${tick.state.quests.done['q_s_sera_1']} / 现在第 ${tick.state.day} 天`)
  ok('奖励当场进国库（+150）',
    Math.abs(tick.state.government.money - (money0 + 150)) < 1e-6,
    `${money0} → ${tick.state.government.money}`)
  ok('公告里既有"送物资"也有"完成任务"',
    tick.log.some((l) => l.text.includes('送物资：粗面包')) &&
      tick.log.some((l) => l.text.includes('完成任务：一趟面包')),
    tick.log.map((l) => l.text).join(' / '))

  // ③ 其它任务也不等到 6:00：判定**每小时**都跑（`stepHour` 末尾）
  const s3 = freshState()
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery']) addShop(s3, id)
  ok('（前置）这时候还没结算过', s3.quests.done['q01_bread_chain'] === undefined)
  const t3 = advanceHour(s3)
  ok('达成即结算：白天的小时里也会判任务（不必等下一个 6:00）',
    t3.state.quests.done['q01_bread_chain'] === t3.state.day,
    `day=${t3.state.quests.done['q01_bread_chain']}（小时 ${t3.state.hour}）`)
}

console.log('')
if (failed > 0) {
  console.error(`任务系统自检失败 ${failed} 条 ❌`)
  process.exit(1)
}
console.log('任务系统自检通过 🎉')
