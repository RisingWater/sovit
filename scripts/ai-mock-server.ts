import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { appendFileSync } from 'node:fs'

// ---------------------------------------------------------------------------
// 假的 OpenAI 兼容服务端 —— 用来**不花一分钱**验证「AI 辅助」的接入层与多轮协议。
//
// 为什么要有它：真模型要 key、要联网、要钱，而且回答**不确定**（今天说东明天说西）。
// 端到端那一小段（拼提示词 → 发 HTTP → 解析 → 画到面板上）最不该依赖这些东西。
//
// 它现在还会**假装成一个会用工具的模型**（这是重点）：
//   · 请求带 `tools`   → 回 `tool_calls`（第 1 轮 3 个方案、第 2 轮 2 个、第 3 轮 1 个）
//   · 请求不带 `tools`（收尾轮）→ 读完前面那几条 `role:"tool"` 的沙盘结果，
//     挑出最好的一条，按预言家的口吻给结论，并**引用沙盘跑出来的数字**
// 于是"跑一遍"这件事在测试里是真的发生了：方案真的下到了沙盘、结果真的回到了模型手里。
//
// 用法：
//   node --experimental-strip-types scripts/ai-mock-server.ts
//   # 游戏里：ESC 菜单 → AI 辅助 → 设置
//   #   base_url = http://127.0.0.1:8765/v1   model_name = mock-advisor   api_key 随便填
//
// 它只实现 `POST /v1/chat/completions`。**不是**生产代码 —— 没有并发、没有超时、没有鉴权。
// ---------------------------------------------------------------------------

const PORT = Number(process.env.PORT ?? '8765')
const PATH = '/v1/chat/completions'
/**
 * 把收到的提示词整份追加到这个文件（可选）：
 *   AI_MOCK_DUMP=shots/last-prompt.txt npm run ai:mock
 * 调提示词的时候比猜有用 —— 模型"答得不对"十有八九是提示词里没写清楚。
 */
const DUMP = process.env.AI_MOCK_DUMP ?? ''

interface ChatMessage {
  role?: string
  content?: string | null
  tool_calls?: unknown[]
  tool_call_id?: string
}

interface ChatBody {
  model?: string
  messages?: ChatMessage[]
  temperature?: number
  max_tokens?: number
  stream?: boolean
  tools?: unknown[]
}

interface Plan {
  label: string
  days: number
  actions: Array<Record<string, unknown>>
}

/** 三轮的方案脚本（每轮换思路，模拟"看了结果再调整"）。 */
const ROUNDS: Plan[][] = [
  [
    {
      label: '先补粮',
      days: 5,
      actions: [
        { day: 1, type: 'build', id: 'wheat_farm', count: 2 },
        { day: 2, type: 'build', id: 'coarse_mill' },
        { day: 3, type: 'build', id: 'coarse_bakery' },
        { day: 4, type: 'build', id: 'vegetable_farm' },
      ],
    },
    {
      label: '先盖房',
      days: 5,
      actions: [
        { day: 1, type: 'build_housing', id: 'hut', count: 3 },
        { day: 3, type: 'build_housing', id: 'hut', count: 2 },
      ],
    },
    {
      label: '先扩产',
      days: 5,
      actions: [
        { day: 1, type: 'expand', id: 'wheat_farm' },
        { day: 1, type: 'expand', id: 'vegetable_farm' },
      ],
    },
  ],
  [
    {
      label: '粮房并进',
      days: 5,
      actions: [
        { day: 1, type: 'build', id: 'wheat_farm', count: 2 },
        { day: 1, type: 'build_housing', id: 'hut', count: 2 },
        { day: 2, type: 'build', id: 'coarse_mill' },
        { day: 3, type: 'build', id: 'coarse_bakery' },
      ],
    },
    {
      label: '先派人不盖房',
      days: 5,
      actions: [
        { day: 1, type: 'set_workers', id: 'wheat_farm', value: 6 },
        { day: 1, type: 'set_workers', id: 'vegetable_farm', value: 4 },
      ],
    },
  ],
  [
    {
      label: '粮仓与炉子一起上',
      days: 5,
      actions: [
        { day: 1, type: 'build', id: 'wheat_farm', count: 3 },
        { day: 1, type: 'build_housing', id: 'hut', count: 2 },
        { day: 2, type: 'build', id: 'coarse_mill', count: 2 },
        { day: 4, type: 'build', id: 'coarse_bakery', count: 2 },
      ],
    },
  ],
]

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []
  for await (const chunk of req) chunks.push(chunk as Buffer)
  const text = Buffer.concat(chunks).toString('utf8').trim()
  if (!text) return {}
  try {
    return JSON.parse(text) as unknown
  } catch {
    return null
  }
}

function send(res: ServerResponse, code: number, body: unknown): void {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(body))
}

function pick(text: string, re: RegExp, fallback: string): string {
  const m = re.exec(text)
  const got = m?.[1]
  return got === undefined || got === '' ? fallback : got
}

/** 玩家在面板上写的那一行问话（默认「我下一步要做什么」）。 */
function question(userText: string): string {
  return pick(userText, /【村民的问话】\n([^\n]+)/, '我下一步要做什么')
}

/** 沙盘结果（每条 `role:"tool"` 的内容）。 */
interface TrialResult {
  label?: string
  days?: number
  end?: Record<string, unknown>
  delta?: Record<string, unknown>
  rejected?: string[]
}

function readTrials(messages: ChatMessage[]): TrialResult[] {
  const out: TrialResult[] = []
  for (const m of messages) {
    if (m.role !== 'tool' || typeof m.content !== 'string') continue
    try {
      const v = JSON.parse(m.content) as TrialResult
      if (v && typeof v === 'object' && v.delta) out.push(v)
    } catch {
      /* 不是 JSON 就算了 */
    }
  }
  return out
}

/** 给沙盘结果打分：先看有没有饿死人，再看人口/满意度/钱的增量。 */
function score(t: TrialResult): number {
  const d = (t.delta ?? {}) as Record<string, number>
  const hungry = Number(d.hungry ?? 0)
  const pop = Number(d.pop ?? 0)
  const sat = Number(d.sat ?? 0)
  const money = Number(d.money ?? 0)
  return (hungry > 0 ? -100 * hungry : 0) + pop * 10 + sat * 2 + money / 1000
}

function best(trials: TrialResult[]): TrialResult | undefined {
  let b: TrialResult | undefined
  for (const t of trials) if (!b || score(t) > score(b)) b = t
  return b
}

function fmt(v: unknown): string {
  const n = Number(v ?? 0)
  return Number.isInteger(n) ? String(n) : n.toFixed(1)
}

function sgn(v: unknown): string {
  const n = Number(v ?? 0)
  const s = Number.isInteger(n) ? String(Math.abs(n)) : Math.abs(n).toFixed(1)
  return `${n < 0 ? '-' : '+'}${s}`
}

/** 收尾：读完水晶球里那几卦，挑最好的一卦，按**瑟拉菲娜**的口吻给结论。
 *  ⚠️ 这个假模型是拿来截图/联调的，所以它说的话也要在戏里、也要照**当前格式**：
 *  我明白了 → 我看见了，你应该 → 一条一句措施。
 *  不写"沙盘 / 模拟 / 引擎 / 方案"，也不写"征兆 / 应对 / 预言"，更不教人点哪里 ——
 *  那都会破坏沉浸（用户 2026-10 的要求）。 */
function conclusion(userText: string, messages: ChatMessage[]): string {
  const q = question(userText)
  const trials = readTrials(messages)
  const b = best(trials)
  if (!b || !b.end || !b.delta) {
    return [
      `我明白了，你想要知道「${q}」`,
      '我看见了，你应该先补上最缺的那样东西 —— 球里这趟雾没散开，哼，别指望我凭空编',
      '先把最缺的那条产线补起来，村里人的脸色才会缓过来',
    ].join('\n')
  }
  const end = b.end as Record<string, unknown>
  const d = b.delta as Record<string, unknown>
  const food = (end.food ?? {}) as Record<string, Record<string, number>>
  const foodName = Object.keys(food)[0] ?? '粗面包'
  const f = food[foodName] ?? { stock: 0, daysLeft: 99 }
  const left = Number(f.daysLeft ?? 99)
  const foodText = left >= 99 ? `${foodName} 够吃` : `${foodName} 还够 ${fmt(left)} 天`
  const base = pick(userText, /· 人口 (\d+) ·/, '?')
  const housey = (b.label ?? '').includes('房')
  return [
    `我明白了，你想要知道「${q}」……哼，才不是特意替你拨的`,
    `我看见了，你应该${housey ? '先让人住得下' : '先把嘴填上'} —— 球里那一片雾散开，` +
      `${housey ? '空房冷冷清清，人都在门口站着' : '粮缸见了底，门口等饭的排成串'}`,
    `让工匠照「${b.label ?? '?'}」那么做，球里第 ${b.days ?? 5} 天${foodText}，` +
      `人口 ${fmt(end.pop)} 人、笑意 ${fmt(end.sat)}，什么都不动的话只剩 ${base} 人`,
    `头几天别再逼工匠加新活，国库这 ${fmt(b.days ?? 5)} 天只进 ${sgn(d.money)}，` +
      `木石要留给已经在排队的工程`,
  ].join('\n')
}

function toolCallsFor(round: number, ids: string[]): unknown[] {
  const plans = ROUNDS[Math.min(round, ROUNDS.length - 1)] ?? []
  return (plans as Plan[]).map((p, i) => ({
    id: ids[i] ?? `call_${round}_${i}`,
    type: 'function',
    function: { name: 'scry', arguments: JSON.stringify(p) },
  }))
}

async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const method = req.method ?? 'GET'
  const url = (req.url ?? '/').split('?')[0] ?? '/'

  if (method === 'GET' && url === '/health') {
    send(res, 200, { ok: true, mock: true })
    return
  }
  if (method !== 'POST' || url !== PATH) {
    send(res, 404, { error: { message: `只实现了 POST ${PATH}，收到 ${method} ${url}` } })
    return
  }

  const raw = await readJson(req)
  if (raw === null) {
    send(res, 400, { error: { message: 'body 不是合法 JSON' } })
    return
  }
  const body = raw as ChatBody
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    send(res, 400, { error: { message: 'messages 必须是非空数组' } })
    return
  }
  const model = body.model ?? '(未指定)'
  const userText = body.messages
    .filter((m) => m.role === 'user')
    .map((m) => m.content ?? '')
    .join('\n')
  const trials = readTrials(body.messages)
  const hasTools = Array.isArray(body.tools) && body.tools.length > 0
  const auth = req.headers.authorization ?? ''
  console.log(
    `[ai-mock] POST ${PATH} model=${model} messages=${body.messages.length} ` +
      `userBytes=${Buffer.byteLength(userText, 'utf8')} auth=${auth ? '有' : '无'} ` +
      `tools=${hasTools ? '有' : '无'} 已有沙盘结果=${trials.length}`,
  )

  if (DUMP !== '') {
    try {
      appendFileSync(
        DUMP,
        `\n===== ${new Date().toISOString()} model=${model} tools=${hasTools} =====\n` +
          body.messages
            .map((m) => `----- role=${m.role ?? '?'} -----\n${m.content ?? ''}`)
            .join('\n') + '\n',
        'utf8',
      )
    } catch (err: unknown) {
      console.log(`[ai-mock] 提示词存不下来：${err instanceof Error ? err.message : String(err)}`)
    }
  }

  // 收尾轮（工具被关掉）→ 给结论
  if (!hasTools) {
    const text = conclusion(userText, body.messages)
    console.log(`[ai-mock]   → 结论（读了 ${trials.length} 条沙盘结果）`)
    send(res, 200, {
      id: 'chatcmpl-mock', object: 'chat.completion', model,
      choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
    })
    return
  }

  // 还有方案没试完 → 回 tool_calls
  const round = trials.length === 0 ? 0 : trials.length <= 3 ? 1 : 2
  const ids = trials.map((_, i) => `call_${i + 1}`)
  const calls = toolCallsFor(round, [...ids, `call_${ids.length + 1}`, `call_${ids.length + 2}`,
    `call_${ids.length + 3}`])
  console.log(`[ai-mock]   → 第 ${round + 1} 轮：给 ${calls.length} 个方案（沙盘待跑）`)
  send(res, 200, {
    id: 'chatcmpl-mock', object: 'chat.completion', model,
    choices: [{
      index: 0,
      message: { role: 'assistant', content: '', tool_calls: calls },
      finish_reason: 'tool_calls',
    }],
    usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  })
}

const server = createServer((req, res) => {
  handle(req, res).catch((err: unknown) => {
    send(res, 500, { error: { message: err instanceof Error ? err.message : String(err) } })
  })
})

server.listen(PORT, () => {
  console.log(`[ai-mock] 假模型服务已起：http://127.0.0.1:${PORT}${PATH}`)
  console.log('[ai-mock] 会假装成"会用工具的模型"：先给方案让你跑沙盘，再看结果给结论')
  console.log('[ai-mock] 游戏里的「设置」页填 base_url = http://127.0.0.1:%d/v1', PORT)
})
