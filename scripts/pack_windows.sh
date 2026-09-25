#!/usr/bin/env bash
# pack_windows.sh —— 在无 Wine 的 Linux 服务器上产出 Witseek(内置官方 dsh) 的
# Windows NSIS 安装包（.exe）与 electron-updater 更新清单（latest.yml）。
#
# 产物形态：Electron 壳（Witseek）+ 内置官方 DeepSeek Harness(dsh) win32-x64 生产
# 运行时与一份 Windows 上游 node.exe。启动时壳用 node.exe 跑 `dsh web`，主视图加载
# 官方 Web UI，右侧带壳自带的工作区文件预览栏；模型 API Key 在界面 设置 → 模型 配置。
#
# 全程免 Wine：
#   1) runtime/stage-win32/dsh：pnpm hoisted 交叉安装 win32-x64 dsh 树（幂等）；
#   2) apps/desktop/scripts/prepare-runtime-win.mjs：裁剪 dsh 树 + 下载 node.exe
#      到 apps/desktop/.runtime-build/win（原生模块全是官方预编译件，无需编译）；
#   3) electron-builder --win dir 出 win-unpacked，afterPack.cjs 用纯 JS resedit
#      改写 exe 图标/版本（signAndEditExecutable=false 跳过依赖 Wine 的 rcedit）；
#   4) make_nsis.py 生成零插件 .nsi，conda-forge 的 Linux 原生 makensis 编译安装包；
#   5) make_update_manifest.py 生成 latest.yml（GitHub Releases 自动更新，全量包）。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"
export PNPM_HOME="$ROOT/.cache/pnpm"
export PATH="$PNPM_HOME:$PATH"
export npm_config_store_dir="$ROOT/.cache/pnpm-store"
export ELECTRON_CACHE="$ROOT/.cache/electron"
export ELECTRON_BUILDER_CACHE="$ROOT/.cache/electron-builder"
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export ELECTRON_BUILDER_BINARIES_MIRROR="${ELECTRON_BUILDER_BINARIES_MIRROR:-https://npmmirror.com/mirrors/electron-builder-binaries/}"
export USE_HARD_LINKS=false

# Linux 原生 makensis（conda-forge nsis）
# shellcheck disable=SC1091
source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate xwt_seek

cd "$ROOT"
VERSION="$(node -p "require('./apps/desktop/package.json').version")"
SETUP="$ROOT/artifacts/Witseek-Setup-${VERSION}.exe"
NSI="$ROOT/artifacts/witseek.nsi"
YML="$ROOT/artifacts/latest.yml"

echo "== 1/8 准备 win32-x64 dsh 生产树（hoisted，幂等） =="
if [ ! -f runtime/stage-win32/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js ]; then
  bash scripts/stage_win_runtime.sh
else
  echo "runtime/stage-win32/dsh 已存在，跳过安装"
fi

echo "== 2/8 安装桌面壳依赖（含 electron-updater / marked / highlight.js） =="
pnpm install --no-frozen-lockfile --registry https://registry.npmmirror.com || pnpm install --no-frozen-lockfile

echo "== 3/8 编译壳主进程 / preload / 预览栏 renderer =="
(cd apps/desktop && pnpm build)

echo "== 4/8 准备内置 node.exe + 裁剪 dsh 树（.runtime-build/win） =="
(cd apps/desktop && node scripts/prepare-runtime-win.mjs)

echo "== 5/8 从用户提供的鲸鱼图重新生成图标（大圆角） =="
python3 scripts/make_icons.py \
  --src assets/source/Witseek.jpg \
  --out assets/icons \
  --app-resources apps/desktop/resources
test -f apps/desktop/resources/icon.ico || { echo "图标生成失败：缺少 apps/desktop/resources/icon.ico"; exit 1; }
test -f apps/desktop/resources/icon.png || { echo "图标生成失败：缺少 apps/desktop/resources/icon.png"; exit 1; }

echo "== 6/8 electron-builder 产出 win-unpacked（dir，免 Wine；resedit 改 PE 资源） =="
rm -rf artifacts/win-unpacked
(cd apps/desktop && pnpm exec electron-builder --win dir)

echo "== 7/8 生成并编译 NSIS 安装程序（lzma solid） =="
python3 scripts/make_nsis.py \
  --src artifacts/win-unpacked \
  --ico apps/desktop/resources/icon.ico \
  --nsi "$NSI" \
  --setup "$SETUP" \
  --version "$VERSION"
rm -f "$SETUP"
makensis -V2 "$NSI"

echo "== 8/8 生成 electron-updater 更新清单 latest.yml =="
python3 scripts/make_update_manifest.py --setup "$SETUP" --version "$VERSION" --out "$YML"
echo "----- latest.yml -----"
cat "$YML"

echo "===== 产物校验 ====="
ls -lh "$SETUP" "$YML"
file "$SETUP"
echo "PACK_WINDOWS_DONE"
