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
step() {
  local name="$1"; shift
  echo "== $name =="
  local tmp rc
  tmp=$(mktemp)
  "$@" >"$tmp" 2>&1
  rc=$?
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
changed=$(git -C .. diff --name-only HEAD 2>/dev/null | grep '^godot/.*\.gd$' || true)
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
step "panel" "$GODOT_BIN" --headless --path . -s res://tools/panel_test.gd
step "imm" "$GODOT_BIN" --headless --path . -s res://tools/imm_test.gd
step "minimap" "$GODOT_BIN" --headless --path . -s res://tools/minimap_test.gd

if [ "$FAIL" -ne 0 ]; then
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
echo "ALL CHECKS PASSED"
