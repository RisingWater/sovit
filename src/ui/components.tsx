import { ALL_BUILDINGS, ALL_GOODS, ALL_RECIPES, isLuxuryGood } from '../engine/index.ts'
import type { ObserveShop } from '../engine/index.ts'
import { useGame } from './store.ts'
import { goodIcon, iconOf } from './icons.ts'

function fmt(n: number): string {
  return Math.round(n).toLocaleString('en-US')
}

// ---------------------------------------------------------------------------
// HUD
// ---------------------------------------------------------------------------
export function Hud() {
  const obs = useGame((s) => s.obs)
  const p = obs.population
  const sat = p.avgSatisfaction
  const satClass = sat >= 60 ? 'green' : sat >= 40 ? 'yellow' : 'red'
  const moneyClass = obs.government.money >= 0 ? 'gold' : 'red'
  return (
    <div className="hud">
      <div className="stat">
        <span className="k">📅 天</span>
        <span className="v">{obs.day}</span>
      </div>
      <div className="stat">
        <span className="k">👥 人口</span>
        <span className="v">{p.total}</span>
      </div>
      <div className="stat">
        <span className="k">😊 满意度</span>
        <span className={`v ${satClass}`}>{sat.toFixed(0)}</span>
      </div>
      <div className="stat">
        <span className="k">💰 政府余额</span>
        <span className={`v ${moneyClass}`}>¥{fmt(obs.government.money)}</span>
      </div>
      <div className="stat">
        <span className="k">⚠️ 饥饿</span>
        <span className={`v ${p.hungry > 0 ? 'red' : 'green'}`}>{p.hungry}</span>
      </div>
      <div className="stat">
        <span className="k">🚶 想来/放行</span>
        <span className="v">
          {p.arrivals}/{p.immigrationAllowance >= 1e8 ? '∞' : p.immigrationAllowance}
        </span>
      </div>
      <div className="spacer" />
      <span className="tag">就业 {p.employed} · 失业 {p.unemployed}</span>
      <span className="tag">住房容量 {p.housingCapacity}</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 村庄地图
// ---------------------------------------------------------------------------
function BuildingCard({ shop }: { shop: ObserveShop }) {
  const selected = useGame((s) => s.selected)
  const select = useGame((s) => s.select)
  return (
    <div
      className={`card ${shop.status} ${selected === shop.id ? 'sel' : ''}`}
      onClick={() => select(shop.id)}
      title={shop.nameZh}
    >
      <div className="title">
        <span className="ic">{iconOf(shop.type)}</span>
        <span>{shop.nameZh}</span>
        {shop.level > 1 && <span style={{ color: 'var(--gold)' }}>Lv{shop.level}</span>}
      </div>
      <div className="row">
        <span>
          👤 {shop.workers}/{shop.maxWorkers}
        </span>
        <span style={{ color: shop.profit >= 0 ? 'var(--green)' : 'var(--red)' }}>
          💰 {shop.profit >= 0 ? '+' : ''}
          {fmt(shop.profit)}
        </span>
      </div>
      {!shop.active && (
        <div className="row">
          <b style={{ color: 'var(--red)' }}>已停产</b>
        </div>
      )}
    </div>
  )
}

export function VillageMap() {
  const obs = useGame((s) => s.obs)
  return (
    <div className="map-wrap">
      <div className="map-ground">
        {obs.shops.map((shop) => (
          <BuildingCard key={shop.id} shop={shop} />
        ))}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 通用步进器
// ---------------------------------------------------------------------------
function Stepper(props: {
  value: number
  onChange: (v: number) => void
  step?: number
  min?: number
  max?: number
  fmt?: (v: number) => string
}) {
  const step = props.step ?? 1
  const min = props.min ?? 0
  const max = props.max ?? 1e9
  const v = props.value
  const set = (n: number) => props.onChange(Math.min(max, Math.max(min, n)))
  return (
    <div className="stepper">
      <button onClick={() => set(v - step)}>−</button>
      <span className="num">{props.fmt ? props.fmt(v) : v}</span>
      <button onClick={() => set(v + step)}>＋</button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 建筑详情面板
// ---------------------------------------------------------------------------
export function BuildingPanel() {
  const state = useGame((s) => s.state)
  const selected = useGame((s) => s.selected)
  const run = useGame((s) => s.run)

  const shop = state.shops.find((s) => s.id === selected)
  if (!shop) {
    return (
      <div className="panel">
        <h3>🏗️ 建筑详情</h3>
        <div className="empty">
          点击地图上的建筑
          <br />
          查看 / 调整它的用工与价格
        </div>
      </div>
    )
  }
  const def = ALL_BUILDINGS[shop.defId]
  const recipe = def ? ALL_RECIPES[def.recipe] : undefined
  const outputs = recipe ? Object.keys(recipe.output) : []
  const cap = def?.maxWorkers ?? def?.workers ?? 0

  return (
    <div className="panel">
      <h3>
        <span className="ic">{iconOf(shop.defId)}</span>
        {def?.nameZh ?? shop.defId}
        <span style={{ color: 'var(--muted)', fontSize: 12 }}>#{shop.id.split('#')[1]}</span>
      </h3>

      <div className="field">
        <span className="lab">👤 工人 / 工位</span>
        <Stepper
          value={shop.targetWorkers}
          min={0}
          max={cap}
          onChange={(v) => run([{ type: 'set_workers', shopId: shop.id, value: v }])}
          fmt={(v) => `${v}/${cap}`}
        />
      </div>
      <div className="field">
        <span className="lab">💵 每人工资</span>
        <Stepper
          value={shop.wage}
          step={0.5}
          onChange={(v) => run([{ type: 'set_wage', shopId: shop.id, value: v }])}
          fmt={(v) => `¥${v}`}
        />
      </div>

      {outputs.map((gid) => (
        <div className="field" key={gid}>
          <span className="lab">
            {goodIcon(gid)} {ALL_GOODS[gid]?.nameZh ?? gid} 售价
          </span>
          <Stepper
            value={state.prices[gid] ?? 0}
            step={0.1}
            onChange={(v) => run([{ type: 'set_price', goodId: gid, value: v }])}
            fmt={(v) => `¥${v.toFixed(2)}`}
          />
        </div>
      ))}

      <div className="field">
        <span className="lab">📈 昨日利润</span>
        <b style={{ color: shop.profit >= 0 ? 'var(--green)' : 'var(--red)' }}>¥{fmt(shop.profit)}</b>
      </div>

      <div className="btnrow">
        <button className="btn" onClick={() => run([{ type: 'expand', shopId: shop.id }])}>
          扩产 (Lv{shop.level}→{shop.level + 1})
        </button>
        <button
          className={`btn ${shop.active ? 'danger' : 'primary'}`}
          onClick={() => run([{ type: 'toggle', shopId: shop.id, active: !shop.active }])}
        >
          {shop.active ? '停产（释放劳动力）' : '开工'}
        </button>
      </div>
      <div className="hint">
        停产会释放工人；把工人调去林场/矿场可缓解材料瓶颈。扩产消耗材料 + 建造力。
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 政策面板
// ---------------------------------------------------------------------------
export function PolicyPanel() {
  const state = useGame((s) => s.state)
  const obs = useGame((s) => s.obs)
  const run = useGame((s) => s.run)
  const g = state.government
  const prices = obs.market.prices
  const goods = Object.keys(prices)

  return (
    <div className="panel">
      <h3>🏛️ 政策</h3>
      <div className="field">
        <span className="lab">🏠 国有住房租金 /人</span>
        <Stepper
          value={g.rent}
          step={0.05}
          onChange={(v) => run([{ type: 'set_rent', value: v }])}
          fmt={(v) => `¥${v.toFixed(2)}`}
        />
      </div>
      <div className="field">
        <span className="lab">🚶 移民放行上限</span>
        <Stepper
          value={Math.round(
            g.immigrationAllowance >= 1e8 ? Math.max(obs.population.arrivals, 0) : g.immigrationAllowance,
          )}
          min={0}
          max={1e8}
          step={1}
          onChange={(v) => run([{ type: 'set_immigration', value: v }])}
          fmt={(v) => (v >= 1e8 ? '∞' : `${v}`)}
        />
      </div>

      <div className="lab" style={{ marginTop: 10 }}>累进所得税（边际，第二列 = %）</div>
      <div className="brackets">
        {g.taxBrackets.map((b, i) => (
          <div className="bracket" key={i}>
            <span>{i === 0 ? '≤' : '>'}</span>
            {i < g.taxBrackets.length - 1 ? (
              <input
                type="number"
                value={b.upTo ?? 0}
                step={0.5}
                onChange={(e) =>
                  run([{ type: 'set_tax_bracket', index: i, upTo: Number(e.target.value) }])
                }
              />
            ) : (
              <span style={{ textAlign: 'center', color: 'var(--muted)' }}>以上</span>
            )}
            <input
              type="number"
              value={Math.round(b.rate * 100)}
              min={0}
              max={95}
              step={1}
              onChange={(e) =>
                run([{ type: 'set_tax_bracket', index: i, rate: Number(e.target.value) / 100 }])
              }
            />
          </div>
        ))}
      </div>

      <div className="lab" style={{ marginTop: 12 }}>商品价格</div>
      <div style={{ marginTop: 6 }}>
        {goods.map((gid) => {
          const base = ALL_GOODS[gid]?.baseValue ?? 1
          const p = prices[gid] ?? 0
          const cls = p > base * 1.2 ? 'gold' : p < base * 0.8 ? 'green' : ''
          return (
            <div className="field" key={gid}>
              <span className="lab">
                {goodIcon(gid)} {ALL_GOODS[gid]?.nameZh ?? gid}
                {isLuxuryGood(gid) && <span className="tag" style={{ marginLeft: 6 }}>奢</span>}
              </span>
              <span className={cls}>
                <Stepper
                  value={p}
                  step={0.1}
                  onChange={(v) => run([{ type: 'set_price', goodId: gid, value: v }])}
                  fmt={(v) => `¥${v.toFixed(2)}`}
                />
              </span>
            </div>
          )
        })}
      </div>
      <div className="hint">必需品涨了会少收且饿人；奢侈品（标「奢」）可狠涨来抽富人。</div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 趋势图 + 日志
// ---------------------------------------------------------------------------
function Spark({ values, color, label }: { values: number[]; color: string; label: string }) {
  const w = 260
  const h = 48
  if (values.length < 2) return <svg className="spark" viewBox={`0 0 ${w} ${h}`} />
  const min = Math.min(...values)
  const max = Math.max(...values)
  const span = max - min || 1
  const pts = values.map((v, i) => {
    const x = (i / (values.length - 1)) * w
    const y = h - ((v - min) / span) * (h - 8) - 4
    return `${x.toFixed(1)},${y.toFixed(1)}`
  })
  const last = values[values.length - 1]!
  const first = values[0]!
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, flex: 1, minHeight: 0 }}>
      <svg className="spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none">
        <polyline fill="none" stroke={color} strokeWidth="2" points={pts.join(' ')} />
      </svg>
      <div style={{ textAlign: 'right', minWidth: 64 }}>
        <div className="cap">{label}</div>
        <div style={{ fontSize: 18, fontWeight: 700, color }}>{Math.round(last)}</div>
        <div className="cap">
          {last >= first ? '▲' : '▼'} {Math.abs(Math.round(last - first))}
        </div>
      </div>
    </div>
  )
}

export function BottomPanel() {
  const obs = useGame((s) => s.obs)
  const state = useGame((s) => s.state)
  const hist = obs.history
  const logs = state.log.slice(-60).reverse()
  return (
    <div className="bottom">
      <div className="chart">
        <Spark values={hist.map((d) => d.population)} color="#5aa9ff" label="人口" />
        <Spark values={hist.map((d) => d.avgSatisfaction)} color="#46c37b" label="满意度" />
      </div>
      <div className="chart">
        <div className="cap">日志</div>
        <div className="log">
          {logs.map((l, i) => (
            <div key={i} className={`kind-${l.kind}`}>
              <span className="d">D{l.day}</span> {l.text}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
