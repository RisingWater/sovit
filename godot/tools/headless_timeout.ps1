# 跑一个 headless Godot 脚本，带**硬超时**，输出完整回传。
#
# ⚠️⚠️ 本文件必须存成 **UTF-8 带 BOM**（EF BB BF），改完务必检查一次！
#   Windows PowerShell 5.1 读无 BOM 的脚本时按 **ANSI/GBK** 解码。中文注释里的
#   字节会两两配对，**把后面的换行吃掉** —— 于是 `param(` 被并进上一行注释里，
#   报出来的是 "param 块不存在 / Unexpected token ')'" 这种完全指错方向的语法错。
#   （`pwsh` 7 默认 UTF-8，不受影响；本机只有 powershell.exe 5.1，所以必须带 BOM。）
#   加 BOM 一行命令：
#     $t=[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false));
#     [IO.File]::WriteAllText($p,$t,[Text.UTF8Encoding]::new($true))
#
# 为什么需要它（踩过的坑）：
#   GDScript 里一旦有**运行时**错误，`_run()` 会在中途中断、永远走不到 `quit()`，
#   而 SceneTree 就这么一直跑下去 —— 进程挂着不退，看起来像"门槛很慢"，
#   实际是在死等（有人因此白等过 15 分钟）。`--check-only` 只查语法，抓不到这种错。
#
# 所以：**独立进程 + WaitForExit(超时)**，超时就 Kill 并以 124 退出。
#   powershell -NoProfile -File tools/headless_timeout.ps1 -Script res://tools/door_test.gd
#   （本机没有 pwsh，用 powershell.exe；两者这段代码都能跑）
#
# ⚠️ 为什么不用 `Start-Process -PassThru -RedirectStandardOutput ...`：
#   Windows PowerShell 5.1 里那样拿到的 Process 对象 **ExitCode 永远是空的**
#   （实测 `cmd /c exit 3` 出来也是空），拿不到退出码就分不清"失败"和"没失败"。
#   这里直接用 System.Diagnostics.Process（Start-Process 本身就是它的包装）：
#   同样有 WaitForExit(毫秒) 超时，而且 ExitCode 是真的；顺带能按 UTF-8 读输出
#   （重定向出来的中文否则会整片乱码）。
#
# 退出码：Godot 的退出码；超时 = 124（与 GNU timeout 同口径，verify.sh 的 step 也认它）。
param(
  [Parameter(Mandatory = $true)][string]$Script,
  [int]$TimeoutMs = 90000,
  [string]$GodotBin = "D:/wangxu/game/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe",
  [string]$ProjectPath = ".",
  [string[]]$ExtraArgs = @()
)

if (-not (Test-Path $GodotBin)) {
  Write-Error "找不到 Godot：$GodotBin（用 -GodotBin 指定）"
  exit 1
}

$argList = @("--headless", "--path", $ProjectPath) + $ExtraArgs + @("-s", $Script)
Write-Host "== godot $($argList -join ' ')"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $GodotBin
# GodotBin / ProjectPath 都不含空格（默认值就是），直接拼成一行即可
$psi.Arguments = ($argList -join ' ')
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

$proc = [System.Diagnostics.Process]::Start($psi)
# 必须**异步**把两条管道抽干：输出一超过管道缓冲区，子进程就会卡在写上面，
# 于是变成一次假的"超时"（这正是要避免的）。
$outTask = $proc.StandardOutput.ReadToEndAsync()
$errTask = $proc.StandardError.ReadToEndAsync()

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$done = $proc.WaitForExit($TimeoutMs)
$sw.Stop()
$ms = $sw.ElapsedMilliseconds

if (-not $done) {
  try { $proc.Kill() } catch { }
  Write-Host "--- stdout ---"
  $outTask.Result
  Write-Host "--- stderr ---"
  $errTask.Result
  Write-Host "TIMEOUT: $Script 跑了 $ms ms 还没退出（> ${TimeoutMs}ms）—— 多半是脚本里出错后没走到 quit()"
  exit 124
}

Write-Host "--- stdout (${ms} ms) ---"
$outTask.Result
$errText = $errTask.Result
if ($errText) {
  Write-Host "--- stderr ---"
  $errText
}
Write-Host "== exit $($proc.ExitCode)"
exit $proc.ExitCode
