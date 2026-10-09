import { createServer } from 'node:http'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { advanceDay, createInitialState, observe } from '../engine/index.ts'
import type { Action, GameState, PackID } from '../engine/index.ts'

// ---------------------------------------------------------------------------
// AI HTTP 接口
//
//   GET  /health           健康检查
//   GET  /state            当前观测（Observation）
//   POST /reset  { seed?, pack? }   重开局（保证可复现）
//   POST /act    { actions: [...] } 应用动作；含 end_turn 则结算一天
//
// 单会话：服务进程内保存一份 GameState。
// ---------------------------------------------------------------------------

let state: GameState = createInitialState({ pack: 'v0.1', seed: 12345 })

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type',
  'access-control-allow-methods': 'GET,POST,OPTIONS',
} as const

function send(res: ServerResponse, code: number, body: unknown): void {
  const data = JSON.stringify(body)
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', ...CORS })
  res.end(data)
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  for await (const chunk of req) chunks.push(chunk as Buffer)
  if (chunks.length === 0) return {}
  const text = Buffer.concat(chunks).toString('utf8').trim()
  if (!text) return {}
  const parsed = JSON.parse(text)
  return typeof parsed === 'object' && parsed !== null ? (parsed as Record<string, unknown>) : {}
}

async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const method = req.method ?? 'GET'
  const url = req.url ?? '/'

  if (method === 'OPTIONS') {
    res.writeHead(204, CORS)
    res.end()
    return
  }

  if (method === 'GET' && url === '/health') {
    send(res, 200, { ok: true, day: state.day })
    return
  }

  if (method === 'GET' && url === '/state') {
    send(res, 200, { observation: observe(state) })
    return
  }

  if (method === 'POST' && url === '/reset') {
    const body = await readJson(req)
    const pack = (body.pack as PackID | undefined) ?? 'v0.1'
    const seed = typeof body.seed === 'number' ? body.seed : 12345
    state = createInitialState({ pack, seed })
    send(res, 200, { observation: observe(state) })
    return
  }

  if (method === 'POST' && url === '/act') {
    const body = await readJson(req)
    const raw = body.actions
    if (!Array.isArray(raw)) {
      send(res, 400, { error: 'body.actions 必须是动作数组' })
      return
    }
    const { state: next, log, applied } = advanceDay(state, raw as Action[])
    state = next
    send(res, 200, { observation: observe(state), applied, log })
    return
  }

  send(res, 404, { error: 'not found', method, url })
}

const port = Number(process.env.PORT ?? '8787')
const server = createServer((req, res) => {
  handle(req, res).catch((err: unknown) => {
    send(res, 500, { error: err instanceof Error ? err.message : String(err) })
  })
})

server.listen(port, () => {
  console.log(`Sovit API listening on http://localhost:${port}`)
  console.log('  GET  /state · POST /act · POST /reset · GET /health')
})
