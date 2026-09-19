#!/usr/bin/env bash
# build.sh —— 构建 Witseek
#
# 用法:
#   bash scripts/build.sh              # 编译主进程/preload/渲染进程到 apps/desktop/out
#   bash scripts/build.sh --pack       # 额外产出 Windows 免安装目录到 artifacts/
#   bash scripts/build.sh --typecheck  # 只做类型检查
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"
export PNPM_HOME="$ROOT/.cache/pnpm"
export PATH="$PNPM_HOME:$PATH"
export npm_config_store_dir="$ROOT/.cache/pnpm-store"
export ELECTRON_CACHE="$ROOT/.cache/electron"
export ELECTRON_BUILDER_CACHE="$ROOT/.cache/electron-builder"
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export XDG_RUNTIME_DIR="$ROOT/.runtime/xdg"
export DISPLAY=":${WITSEEK_DISPLAY:-100}"
export WITSEEK_HEADLESS=1

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
cd "$ROOT"

MODE="${1:-build}"

if [ "$MODE" = "--typecheck" ]; then
  echo "== 类型检查 =="
  cd apps/desktop && pnpm typecheck
  echo "类型检查通过"
  exit 0
fi

echo "== 编译 =="
cd "$ROOT/apps/desktop"
pnpm build

echo
echo "== 产物 =="
find "$ROOT/apps/desktop/out" -maxdepth 2 -type f | head -20
du -sh "$ROOT/apps/desktop/out"/* 2>/dev/null || true

if [ "$MODE" = "--pack" ]; then
  echo
  echo "== Windows 免安装目录打包 =="
  bash "$ROOT/scripts/pack_windows.sh"
fi
