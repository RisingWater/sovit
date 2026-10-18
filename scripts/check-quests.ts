import { advanceHour, applyActions, buildContext, createInitialState } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import {
  questView,
  questProgress,
  questJournal,
  questTalks,
  markQuestTalkShown,
  splitSentences,
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

// ---- 1. 开局：只看得见两条并行任务，后面的一律不可见 ---------------------
{
  const s = freshState()
  const ids = viewIds(s)
  ok('开局只看得到第 1 章的两条任务',
    JSON.stringify(ids) === JSON.stringify(['q01_bread_chain', 'q02_vegetable']), ids.join(' → '))
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

  // 再跑一天：昨天完成的那两条应当消失，只剩第 2 章的三条
  runDawn(s, ctx)
  const ids2 = viewIds(s)
  ok('隔天之后，已完成的任务从追踪条上收掉',
    JSON.stringify(ids2) === JSON.stringify(['q03a_housing_capacity', 'q03b_output', 'q03c_satisfaction']),
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
  ok('同一次黎明把 1~3 章主线连锁结算完（13 条任务 + 3 个章节奖励）',
    s2.government.money - moneyA === 13 * 500 + 3 * 1000, `+${s2.government.money - moneyA} 金`)
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
  ok('开局：面板里就是那两条并行任务', questJournal(s, ctx).length === 2,
    questJournal(s, ctx).map((q) => q.def.id).join('、'))
  ok('每条任务都带 brief（面板右侧的描述）与 reward',
    questJournal(s, ctx).every((q) => q.def.brief.length > 0 && q.def.reward > 0))
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
  ok('开局有两条任务对话要播（第 1 章两条任务）',
    talks.length === 2 && talks[0]!.key === 'q:q01_bread_chain', talks.map((t) => t.key).join(' → '))
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
  ok('第一章收尾带选项（accept 免费预言 / decline 关闭）',
    (t2[0]!.choices ?? []).map((c) => c.id).join(',') === 'accept,decline' &&
      (t2[0]!.choices ?? [])[0]!.action === 'free_prophecy',
    JSON.stringify(t2[0]!.choices ?? []))
  ok('后面跟着的是第 2 章那三条任务',
    t2.slice(1).every((t) => t.kind === 'quest') && t2.length === 4,
    t2.map((t) => t.key).join(' → '))
  markQuestTalkShown(s, 'c:1')
  ok('收尾播过也不再返回', !questTalks(s, ctx).some((t) => t.key === 'c:1'))
}

console.log('')
if (failed > 0) {
  console.error(`任务系统自检失败 ${failed} 条 ❌`)
  process.exit(1)
}
console.log('任务系统自检通过 🎉')
