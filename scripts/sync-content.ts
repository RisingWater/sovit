import { cpSync, mkdirSync, readdirSync } from 'node:fs'

// 把仓库根 content/*.json 同步到 Godot 工程（res://content/，Godot 不能引用工程外文件）。
mkdirSync('godot/content', { recursive: true })
let n = 0
for (const f of readdirSync('content')) {
  if (f.endsWith('.json')) {
    cpSync(`content/${f}`, `godot/content/${f}`)
    n++
  }
}
console.log(`synced ${n} content files → godot/content/`)
