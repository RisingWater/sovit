#!/usr/bin/env bash
# Sovit Godot 门槛：import → 逐脚本解析检查 → gdUnit4 → 冒烟 → 移动建筑
#
# ⚠️ 为什么不能只看退出码：
#   Godot 的**运行时**脚本错误（SCRIPT ERROR）不会让它返回非 0。
#   曾经"移动建筑"直接抛 Trying to assign invalid previously freed instance，
#   而所有门槛照过 —— 因为 smoke 不移动建筑，退出码也是 0。
#   所以这里额外扫每步的输出，出现脚本错误一律判失败。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

GODOT_BIN="${GODOT_BIN:-D:/wangxu/game/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe}"

if [ ! -f "$GODOT_BIN" ]; then
  echo "找不到 Godot：$GODOT_BIN（用环境变量 GODOT_BIN 指定）" >&2
  exit 1
fi

FAIL=0
ERR_RE='SCRIPT ERROR|Parse Error|Unicode parsing error|Trying to assign invalid|Invalid access to property or key|Cannot call method .* on a null'

# Godot / gdUnit4 会输出 ANSI 颜色码（例如 "Overall Summary:" 和数字之间夹着
# \x1b[38;2;...m），不去掉的话正则匹配不上。
strip_ansi() {
  sed -E 's/\x1B\[[0-9;]*[mK]//g' "$1"
}

# 跑一条命令：回显输出 → 查退出码 → 扫脚本错误
#
# 带耗时：全套要跑二十来条命令，哪一条突然变慢（比如某次 --import 重新导入
# 全部资源、或某个测试卡在 await 上）光看输出看不出来，所以每条都报时。
step() {
  local name="$1"; shift
  echo "== $name =="
  local tmp rc t0 t1
  tmp=$(mktemp)
  t0=$(date +%s%N)
  # ⚠️ 必须加超时。曾经有个测试引用了已被删掉的 hud._info，运行时报错后
  # `_run()` 提前中断、永远走不到 quit()，进程就**挂着不退**，
  # 整个 verify.sh 卡在那一关不动 —— 看起来像"门槛很慢"，其实是死等。
  # 有超时的话 120 秒后返回 124，step 会明确报 FAIL。
  timeout -k 5 "${STEP_TIMEOUT:-120}" "$@" >"$tmp" 2>&1
  rc=$?
  t1=$(date +%s%N)
  echo "   ($(( (t1 - t0) / 1000000 )) ms)"
  if [ "$rc" -eq 124 ]; then
    echo "FAIL: $name 超时（>${STEP_TIMEOUT:-120}s）—— 多半是测试里出错后没走到 quit()，进程挂住了" >&2
    FAIL=1
  fi
  strip_ansi "$tmp"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name 退出码 $rc" >&2
    FAIL=1
  fi
  # 不用管道接 grep -q：配合 pipefail 时 grep 提前退出会让管道返回非 0
  if strip_ansi "$tmp" | grep -qE "$ERR_RE"; then
    echo "FAIL: $name 的输出里出现脚本错误（见上）" >&2
    FAIL=1
  fi
  rm -f "$tmp"
}

step "import" "$GODOT_BIN" --headless --path . --import

echo "== parse check (changed .gd) =="
changed=$(git -C .. diff --name-only --diff-filter=d HEAD 2>/dev/null | grep '^godot/.*\.gd$' || true)
if [ -z "$changed" ]; then
  echo "  （无改动脚本）"
fi
for f in $changed; do
  rel="${f#godot/}"
  echo "  $rel"
  step "parse $rel" "$GODOT_BIN" --headless --path . --check-only --script "res://$rel"
done

# gdUnit4 的 runtest 即使全绿也可能返回非 0，所以不看退出码，只看汇总行
echo "== gdUnit4 =="
gd_tmp=$(mktemp)
if [ -f addons/gdUnit4/runtest.sh ]; then
  bash ./addons/gdUnit4/runtest.sh --godot_binary "$GODOT_BIN" -a res://tests --continue >"$gd_tmp" 2>&1
else
  cmd.exe //c "addons\\gdUnit4\\runtest.cmd" --godot_binary "$GODOT_BIN" -a res://tests --continue >"$gd_tmp" 2>&1
fi
cat "$gd_tmp"
if strip_ansi "$gd_tmp" | grep -qE 'Overall Summary: .*\| 0 errors \| 0 failures'; then
  echo "  gdUnit4 全绿"
else
  echo "FAIL: gdUnit4 未全绿（找不到 '0 errors | 0 failures' 的汇总行）" >&2
  FAIL=1
fi
if strip_ansi "$gd_tmp" | grep -qE "$ERR_RE"; then
  echo "FAIL: gdUnit4 的输出里出现脚本错误" >&2
  FAIL=1
fi
rm -f "$gd_tmp"

step "smoke" "$GODOT_BIN" --headless --path . -s res://tools/smoke_test.gd
step "move" "$GODOT_BIN" --headless --path . -s res://tools/move_test.gd
step "music" "$GODOT_BIN" --headless --path . -s res://tools/music_test.gd
step "sfx" "$GODOT_BIN" --headless --path . -s res://tools/sfx_test.gd
step "daylight" "$GODOT_BIN" --headless --path . -s res://tools/daylight_test.gd
step "bartab" "$GODOT_BIN" --headless --path . -s res://tools/bartab_test.gd
step "buildlock" "$GODOT_BIN" --headless --path . -s res://tools/buildlock_test.gd
step "panel" "$GODOT_BIN" --headless --path . -s res://tools/panel_test.gd
step "consumetip" "$GODOT_BIN" --headless --path . -s res://tools/consumetip_test.gd
step "chiptip" "$GODOT_BIN" --headless --path . -s res://tools/chiptip_test.gd
step "workerdemolish" "$GODOT_BIN" --headless --path . -s res://tools/worker_demolish_test.gd
step "tech" "$GODOT_BIN" --headless --path . -s res://tools/tech_test.gd
step "efficiency" "$GODOT_BIN" --headless --path . -s res://tools/efficiency_test.gd
step "tools" "$GODOT_BIN" --headless --path . -s res://tools/tool_test.gd
step "sitetip" "$GODOT_BIN" --headless --path . -s res://tools/sitetip_test.gd
step "keys" "$GODOT_BIN" --headless --path . -s res://tools/keys_test.gd
step "doortest" "$GODOT_BIN" --headless --path . -s res://tools/door_test.gd
step "footprint" "$GODOT_BIN" --headless --path . -s res://tools/footprint_test.gd
step "iron" "$GODOT_BIN" --headless --path . -s res://tools/iron_test.gd
step "coal" "$GODOT_BIN" --headless --path . -s res://tools/coal_test.gd
step "needs" "$GODOT_BIN" --headless --path . -s res://tools/needs_test.gd
step "merchant" "$GODOT_BIN" --headless --path . -s res://tools/merchant_test.gd
step "roofclick" "$GODOT_BIN" --headless --path . -s res://tools/roofclick_test.gd
step "multisite" "$GODOT_BIN" --headless --path . -s res://tools/multisite_test.gd
step "upgrade" "$GODOT_BIN" --headless --path . -s res://tools/upgrade_test.gd
step "housingupgrade" "$GODOT_BIN" --headless --path . -s res://tools/housingupgrade_test.gd
step "logsave" "$GODOT_BIN" --headless --path . -s res://tools/logsave_test.gd
step "queue" "$GODOT_BIN" --headless --path . -s res://tools/queue_test.gd
step "sitecancel" "$GODOT_BIN" --headless --path . -s res://tools/sitecancel_test.gd
step "quest" "$GODOT_BIN" --headless --path . -s res://tools/quest_test.gd
step "questpanel" "$GODOT_BIN" --headless --path . -s res://tools/questpanel_test.gd
step "ai" "$GODOT_BIN" --headless --path . -s res://tools/ai_test.gd
step "glyph" "$GODOT_BIN" --headless --path . -s res://tools/glyph_test.gd
step "construction" "$GODOT_BIN" --headless --path . -s res://tools/construction_test.gd
step "research" "$GODOT_BIN" --headless --path . -s res://tools/research_test.gd
step "imm" "$GODOT_BIN" --headless --path . -s res://tools/imm_test.gd
step "minimap" "$GODOT_BIN" --headless --path . -s res://tools/minimap_test.gd
step "esc" "$GODOT_BIN" --headless --path . -s res://tools/esc_test.gd
step "savedlg" "$GODOT_BIN" --headless --path . -s res://tools/save_dialog_test.gd
step "inspector" "$GODOT_BIN" --headless --path . -s res://tools/inspector_test.gd
step "newgame" "$GODOT_BIN" --headless --path . -s res://tools/newgame_test.gd
step "title" "$GODOT_BIN" --headless --path . -s res://tools/title_test.gd
step "intro" "$GODOT_BIN" --headless --path . -s res://tools/intro_test.gd
step "questtalk" "$GODOT_BIN" --headless --path . -s res://tools/questtalk_test.gd
step "occlusion" "$GODOT_BIN" --headless --path . -s res://tools/occlusion_test.gd

if [ "$FAIL" -ne 0 ]; then
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
echo "ALL CHECKS PASSED"
