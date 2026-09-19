#!/usr/bin/env bash
# test.sh —— 运行内核单测
#
# 用法:
#   bash scripts/test.sh            # 跑一遍
#   bash scripts/test.sh --watch    # 监听模式
#   bash scripts/test.sh --demo     # 跑离线演示（不接 API）
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"
export PNPM_HOME="$ROOT/.cache/pnpm"
export PATH="$PNPM_HOME:$PATH"
cd "$ROOT"

case "${1:-}" in
  --watch) exec pnpm exec vitest ;;
  --demo)  exec pnpm exec tsx scripts/demo-kernel.mts ;;
  *)       exec pnpm exec vitest run ;;
esac
