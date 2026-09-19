#!/usr/bin/env bash
# install_deps.sh —— 在服务器端安装 P1 依赖
#
# 全部缓存都落在项目内 .cache/，不污染用户主目录，也不回流本地。
# 幂等：重复执行只会补齐缺失的依赖。
#
# 踩过的坑：
#   1. corepack enable --install-directory 要求目标目录已存在，否则 lstat ENOENT
#   2. pnpm 10+ 默认不执行依赖的安装脚本，Electron 的二进制就下不来，
#      必须在 package.json 的 pnpm.onlyBuiltDependencies 里放行 electron / esbuild
#   3. Electron 二进制走 GitHub 很慢，用国内镜像
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"
export PNPM_HOME="$ROOT/.cache/pnpm"
export PATH="$PNPM_HOME:$PATH"
export npm_config_store_dir="$ROOT/.cache/pnpm-store"
export ELECTRON_CACHE="$ROOT/.cache/electron"
export ELECTRON_BUILDER_CACHE="$ROOT/.cache/electron-builder"
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export npm_config_registry="${npm_config_registry:-https://registry.npmmirror.com}"

mkdir -p "$PNPM_HOME" "$npm_config_store_dir" "$ELECTRON_CACHE" "$ELECTRON_BUILDER_CACHE"
cd "$ROOT"

echo "== 启用 pnpm =="
if ! command -v pnpm >/dev/null 2>&1; then
  corepack enable --install-directory "$PNPM_HOME" 2>/dev/null || corepack enable
fi
echo "node $(node -v) / pnpm $(pnpm -v)"

echo
echo "== 安装 apps/desktop 依赖 =="
cd apps/desktop
pnpm add -D electron electron-vite vite @vitejs/plugin-react typescript @types/node @types/react @types/react-dom
pnpm add react react-dom

cd "$ROOT"
echo
echo "== 校验 Electron 二进制 =="
if [ -x apps/desktop/node_modules/electron/dist/electron ]; then
  echo "  ✓ $(du -sh apps/desktop/node_modules/electron/dist | cut -f1)  $(cat apps/desktop/node_modules/electron/path.txt 2>/dev/null)"
else
  echo "  ✗ Electron 二进制缺失 —— 检查 pnpm.onlyBuiltDependencies 与 ELECTRON_MIRROR"
  exit 1
fi

echo
echo "== 版本清单 =="
node -e "
const p = require('./apps/desktop/package.json');
const all = { ...p.dependencies, ...p.devDependencies };
for (const k of Object.keys(all).sort()) console.log('  ' + k.padEnd(26) + all[k]);
"

echo
echo "== 缓存占用 =="
du -sh "$ROOT/.cache"/* 2>/dev/null || true
