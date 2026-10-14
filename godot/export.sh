#!/usr/bin/env bash
# Sovit 导出可执行文件（Windows / Linux 桌面）。
#
#   bash export.sh              # 导出 Windows release 到 builds/windows/sovit.exe
#   bash export.sh debug        # 导出带调试符号的版本（能看脚本调用栈）
#   bash export.sh linux        # 导出 Linux release
#
# 产物在 `builds/`（已在 .gitignore 里，不会进仓库）。
#
# ⚠️ 一次性前提：**导出模板**。没装的话 Godot 只会说
#   "在预期路径处未找到导出模板：.../export_templates/4.7.2.stable/windows_release_x86_64.exe"
# 装法二选一：
#   1. 编辑器 → 编辑器菜单 → 管理导出模板… → 从文件安装 → 选 Godot_v4.7.2-stable_export_templates.tpz
#   2. 直接把 .tpz 解压到 %APPDATA%\Godot\export_templates\4.7.2.stable\
#      （.tpz 就是个 zip，根下是 `templates/`，**去掉这层前缀**放进去）
set -uo pipefail
cd "$(dirname "$0")" || exit 1

GODOT_BIN="${GODOT_BIN:-D:/wangxu/game/Godot_v4.7.2/Godot_v4.7.2-stable_win64_console.exe}"
MODE="${1:-release}"

if [ ! -f "$GODOT_BIN" ]; then
  echo "找不到 Godot：$GODOT_BIN（用环境变量 GODOT_BIN 指定）" >&2
  exit 1
fi

# 模板目录名 = 引擎版本号（4.7.2.stable）。从 Godot 自己的版本串里取，别写死。
VER="$("$GODOT_BIN" --headless --version 2>/dev/null | head -1 | tr -d '\r' | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+)\.(stable|dev|beta|rc).*/\1.\2/')"
TPL_DIR="${APPDATA:-$HOME/.local/share}/Godot/export_templates/$VER"
case "$VER" in
  *.*.*) ;;
  *) echo "解析不出引擎版本（拿到的是 '$VER'），导出模板没法定位" >&2; exit 1 ;;
esac
if [ ! -f "$TPL_DIR/windows_release_x86_64.exe" ] && [ ! -f "$TPL_DIR/linux_release.x86_64" ]; then
  echo "没找到导出模板：$TPL_DIR" >&2
  echo "把 Godot_v${VER}_export_templates.tpz 解压到这里（包内 templates/ 这层要去掉）" >&2
  exit 1
fi

# 导出前先导入一遍：新加的贴图/场景没导入的话，导出会静默缺资源。
"$GODOT_BIN" --headless --path . --import >/dev/null 2>&1

case "$MODE" in
  debug) PRESET="Windows Desktop"; OUT="builds/windows/sovit-debug.exe"; FLAG=--export-debug ;;
  linux) PRESET="Linux";           OUT="builds/linux/sovit.x86_64";   FLAG=--export-release ;;
  *)     PRESET="Windows Desktop"; OUT="builds/windows/sovit.exe";    FLAG=--export-release ;;
esac

mkdir -p "$(dirname "$OUT")"
"$GODOT_BIN" --headless --path . "$FLAG" "$PRESET" "$OUT"
RC=$?
if [ $RC -ne 0 ] || [ ! -f "$OUT" ]; then
  echo "导出失败（exit=$RC）" >&2
  exit 1
fi
SIZE="$(du -h "$OUT" | cut -f1)"
echo "导出完成：$OUT（$SIZE）"
echo "  自带 pck（预设里 embed_pck=true）—— 单文件就能发，旁边的 .pck 不需要。"
