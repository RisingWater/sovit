import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { appendFileSync } from 'node:fs'

// ---------------------------------------------------------------------------
// 假的 OpenAI 兼容服务端 —— 用来**不花一分钱**验证「AI 辅助」的接入层。
//
// 为什么要有它：真模型要 key、要联网、要钱，而且回答**不确定**（今天说东明天说西）。
// 端到端那一小段（拼提示词 → 发 HTTP → 解析响应 → 画到面板上）最不该依赖这些东西：
// 拿一个本地假服务端着，就能确认
//   · 请求真的发出去了、URL 拼对了、Authorization 头带上了
//   · prompt 真的把局势装进去了（服务端把收到多少字节打出来）
//   · 响应解析 / Markdown 清理 / 缺字形替换 / 面板排版都对
//
// 用法：
//   node --experimental-strip-types scripts/ai-mock-server.ts
//   # 然后在游戏里：ESC 菜单 → AI 辅助 → 设置
//   #   base_url = http://127.0.0.1:8765/v1
//   #   model_name = mock-advisor
//   #   api_key 随便填（这个服务端只检查有没有带，不校验内容）
//
// 它只实现 `POST /v1/chat/completions`：认 OpenAI 的请求体，按 OpenAI 的响应形状回话。
// **不是**生产代码，别拿它当网关 —— 没有并发、没有超时、没有鉴权。
// ---------------------------------------------------------------------------

const PORT = Number(process.env.PORT ?? '8765')
const PATH = '/v1/chat/completions'
/**
 * 把收到的提示词整份追加到这个文件（可选）：
 *   AI_MOCK_DUMP=shots/last-prompt.txt npm run ai:mock
 * 调提示词的时候比猜有用 —— 模型"答得不对"十有八九是提示词里没写清楚，
 * 而不是模型不行。默认不开（免得在仓库里留文件）。
 */
const DUMP = process.env.AI_MOCK_DUMP ?? ''

interface ChatMessage {
  role?: string
  content?: string
}

interface ChatBody {
  model?: string
  messages?: ChatMessage[]
  temperature?: number
  max_tokens?: number
  stream?: boolean
}

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

/** 提示词里「当前任务」那一段里，第一条**还没达成**的任务名（去掉「（今天刚完成）」这类前缀）。 */
function nextQuest(userText: string): string {
  const block = /当前任务：\n([\s\S]*?)\n可建清单/.exec(userText)?.[1] ?? ''
  for (const rawLine of block.split('\n')) {
    const line = rawLine.trim()
    if (!line.includes('未达成')) continue
    const title = /^(?:（[^）]*）)?([^：]+)：/.exec(line)?.[1]
    if (title !== undefined && title !== '') return title
  }
  return pick(userText, /当前任务：\n\s+([^：\n]+)：/, '当前任务')
}

/**
 * 假回答：**从提示词里抠几个数字回来**，按游戏要求的格式（`N.` / `为什么：` / `怎么做：`）输出。
 *
 * 这么做有两个好处：一眼就能看出"提示词确实送到了"（数字是从 prompt 里来的，
 * 不是写死的），而且排版会走真实的分支（标题行深色、为什么/怎么做暗色）。
 * 正则都**锚在局势包那几行的固定格式上** —— 松了会误配到规则段里的说明文字。
 */
function answer(userText: string): string {
  const pop = pick(userText, /· 人口 (\d+) ·/, '?')
  const need = pick(userText, /基础食物日需 ([\d.]+)、/, '?')
  const supply = pick(userText, /基础食物日需 [\d.]+、本日产 ([\d.]+)/, '?')
  const stock = pick(userText, /本日产 [\d.]+、库存 ([\d.]+)/, '?')
  const days = pick(userText, /（只够 ([\d.]+) 天）/, '够用')
  const vacant = pick(userText, /住房：容量 \d+ \/ 人口 \d+（空 (-?\d+)）/, '?')
  const job = pick(userText, /岗位 (\d+) \/ 人口/, '?')
  const wood = pick(userText, /关键物资：木材 ([\d.]+)/, '?')
  const quest = nextQuest(userText)
  return [
    `1. 我看见了：先把「${quest}」要的产线补齐`,
    `征兆：人口 ${pop} 人，基础食物日需 ${need}、本日产 ${supply}、库存 ${stock}，只够 ${days} 天`,
    '应对：建造栏「农场」页放 1 座小麦农场（木材 4）',
    '2. 灶上的火还太少',
    `征兆：岗位 ${job} / 人口 ${pop}，不少人空着手；就业在满意度里占 0.1 的权重`,
    '应对：接着放粗面粉磨坊与粗面包房，一条链一次占 10 个工位',
    '3. 屋顶的账还没到紧的时候',
    `征兆：现在空 ${vacant} 个床位、木材 ${wood}，够撑一阵`,
    '应对：等满意度过 55、有人想来的时候再盖茅屋',
    '预言：先立食链，再添灶口，屋顶等人来。',
  ].join('\n')
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
  const auth = req.headers.authorization ?? ''
  const promptBytes = Buffer.byteLength(userText, 'utf8')
  console.log(
    `[ai-mock] POST ${PATH} model=${model} messages=${body.messages.length} ` +
      `userBytes=${promptBytes} auth=${auth ? '有' : '无'} stream=${String(body.stream)}`,
  )
  // 把提示词的头尾各露一点：确认**局势数据**真的装进去了（不然"回答对"可能是巧合）
  console.log(`[ai-mock]   头: ${userText.slice(0, 80).replace(/\n/g, ' / ')}`)
  console.log(`[ai-mock]   尾: ${userText.slice(-80).replace(/\n/g, ' / ')}`)
  if (DUMP !== '') {
    try {
      appendFileSync(
        DUMP,
        `\n===== ${new Date().toISOString()} model=${model} bytes=${promptBytes} =====\n` +
          body.messages
            .map((m) => `----- role=${m.role ?? '?'} -----\n${m.content ?? ''}`)
            .join('\n') +
          '\n',
        'utf8',
      )
    } catch (err: unknown) {
      console.log(`[ai-mock] 提示词存不下来：${err instanceof Error ? err.message : String(err)}`)
    }
  }

  send(res, 200, {
    id: 'chatcmpl-mock',
    object: 'chat.completion',
    model,
    choices: [
      {
        index: 0,
        message: { role: 'assistant', content: answer(userText) },
        finish_reason: 'stop',
      },
    ],
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
  console.log('[ai-mock] 游戏里的「设置」页填 base_url = http://127.0.0.1:%d/v1', PORT)
})
