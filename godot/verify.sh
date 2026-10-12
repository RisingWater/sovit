#!/usr/bin/env bash
# Sovit Godot 门槛：import → 逐脚本解析检查 → gdUnit4 → headless 冒烟
set -e
cd "$(dirname "$0")"

GODOT_BIN="${GODOT_BIN:-D:/wangxu/game/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe}"

if [ ! -f "$GODOT_BIN" ]; then
  echo "找不到 Godot：$GODOT_BIN（用环境变量 GODOT_BIN 指定）" >&2
  exit 1
fi

echo "== import =="
"$GODOT_BIN" --headless --path . --import

echo "== parse check (changed .gd) =="
changed=$(git -C .. diff --name-only HEAD 2>/dev/null | grep '^godot/.*\.gd$' || true)
for f in $changed; do
  rel="${f#godot/}"
  echo "  $rel"
  "$GODOT_BIN" --headless --path . --check-only --script "res://$rel"
done

echo "== gdUnit4 =="
if [ -f addons/gdUnit4/runtest.sh ]; then
  bash ./addons/gdUnit4/runtest.sh --godot_binary "$GODOT_BIN" -a res://tests --continue
else
  cmd.exe //c "addons\\gdUnit4\\runtest.cmd" --godot_binary "$GODOT_BIN" -a res://tests --continue
fi

echo "== smoke =="
"$GODOT_BIN" --headless --path . -s res://tools/smoke_test.gd

echo "== move (移动建筑/住房) =="
"$GODOT_BIN" --headless --path . -s res://tools/move_test.gd

echo "ALL CHECKS PASSED"
