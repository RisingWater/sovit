import { BottomPanel, BuildingPanel, Hud, PolicyPanel, VillageMap } from './components.tsx'
import { useGame } from './store.ts'

export default function App() {
  const nextDay = useGame((s) => s.nextDay)
  const reset = useGame((s) => s.reset)
  return (
    <div className="app">
      <Hud />
      <div className="main">
        <VillageMap />
        <div className="side">
          <BuildingPanel />
          <PolicyPanel />
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
