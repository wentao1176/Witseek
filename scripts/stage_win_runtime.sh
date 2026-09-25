#!/usr/bin/env bash
# stage_win_runtime.sh —— 在 runtime/stage-win32/dsh 用 hoisted 布局交叉安装
# win32-x64 的官方 @deepseek-ai/dsh 生产依赖树（含全部预编译原生模块）。
#
# 关键：nodeLinker=hoisted（Windows 上游 Node 不解析 pnpm isolated 符号链接，
# 这也是官方 wine-windows-gates 的做法）；supportedArchitectures 锁定 win32/x64；
# --ignore-scripts 跳过主机侧构建脚本（node-pty / koffi / sharp 等都随包带预编译件）。
set -euo pipefail

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
DSH_VERSION="${DSH_VERSION:-0.1.5-rc.1}"
ST="$ROOT/runtime/stage-win32/dsh"
mkdir -p "$ST"
cd "$ST"

cat > package.json <<JSON
{
  "name": "witseek-dsh-runtime-win32",
  "private": true,
  "version": "$DSH_VERSION",
  "dependencies": { "@deepseek-ai/dsh": "$DSH_VERSION" }
}
JSON

cat > pnpm-workspace.yaml <<'YAML'
packages: []
nodeLinker: hoisted
supportedArchitectures:
  os: [win32]
  cpu: [x64]
YAML

echo "[stage-win32] pnpm $(pnpm -v) / node $(node -v), target dsh $DSH_VERSION"
pnpm install --ignore-scripts --registry https://registry.npmmirror.com \
  || pnpm install --ignore-scripts --registry https://registry.npmjs.org

# 关键文件校验
test -f node_modules/@deepseek-ai/dsh/lib/bin.js || { echo "dsh bin.js 缺失"; exit 1; }
test -f node_modules/node-pty/prebuilds/win32-x64/conpty.node || { echo "node-pty win32 prebuild 缺失"; exit 1; }

# Witseek 的只读工作区同步使用 dsh 官方 Web 客户端扩展点。
PLUGIN_SRC="$ROOT/apps/desktop/resources/dsh-client-witseek-desktop"
PLUGIN_DST="$ST/node_modules/@witseek/dsh-client-witseek-desktop"
test -f "$PLUGIN_SRC/client.js" || { echo "Witseek dsh 客户端插件缺失"; exit 1; }
mkdir -p "$(dirname "$PLUGIN_DST")"
rm -rf "$PLUGIN_DST"
cp -a "$PLUGIN_SRC" "$PLUGIN_DST"

echo "[stage-win32] 就绪: $ST"
du -sh node_modules
