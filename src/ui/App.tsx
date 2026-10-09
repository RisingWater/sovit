import { BottomPanel, BuildPanel, BuildingPanel, Hud, PolicyPanel, VillageMap } from './components.tsx'
import { useGame } from './store.ts'

export default function App() {
  const nextDay = useGame((s) => s.nextDay)
  const reset = useGame((s) => s.reset)
  const tab = useGame((s) => s.tab)
  const setTab = useGame((s) => s.setTab)
  return (
    <div className="app">
      <Hud />
      <div className="main">
        <VillageMap />
        <div className="side">
          <div className="tabs">
            <button className={tab === 'build' ? 'on' : ''} onClick={() => setTab('build')}>
              🔨 建造
            </button>
            <button className={tab === 'detail' ? 'on' : ''} onClick={() => setTab('detail')}>
              🏗️ 详情
            </button>
            <button className={tab === 'policy' ? 'on' : ''} onClick={() => setTab('policy')}>
              🏛️ 政策
            </button>
          </div>
          <div className="tabbody">
            {tab === 'build' && <BuildPanel />}
            {tab === 'detail' && <BuildingPanel />}
            {tab === 'policy' && <PolicyPanel />}
          </div>
        </div>
      </div>
      <BottomPanel />
      <div className="footer">
        <button className="nextday" onClick={nextDay}>
          ▶ NEXT DAY · 下一天
        </button>
        <button className="reset" onClick={reset} title="重新开局">
          重开
        </button>
      </div>
    </div>
  )
}
