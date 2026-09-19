#!/usr/bin/env bash
# bootstrap_server.sh —— 在服务器端创建 Witseek 工程骨架
#
# 执行方式（本地发起，脚本在服务器上运行）:
#   ssh -F .relay/ssh_config witseek 'bash -s' < scripts/bootstrap_server.sh
#
# 特性:
#   - 幂等：重复执行不会破坏已有内容
#   - 不覆盖已有文件（warning.md / Witseek.jpg 原样保留）
#   - 不做任何需要 sudo 的操作
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

echo "==> 目标: $ROOT"

# ---- 目录骨架 ----
DIRS=(
  assets/source
  assets/icons
  apps/desktop/src/main
  apps/desktop/src/preload
  apps/desktop/resources
  apps/renderer/src/components
  apps/renderer/src/features/chat
  apps/renderer/src/features/sidebar
  apps/renderer/src/features/preview
  apps/renderer/src/features/terminal
  apps/renderer/src/features/settings
  apps/renderer/src/stores
  apps/renderer/src/styles
  apps/renderer/public
  packages/protocol/src
  packages/harness-core/src
  packages/provider-deepseek/src
  packages/tools/src
  packages/ui-kit/src
  scripts
  tests/unit
  tests/e2e
  docs
  artifacts
  .runtime/logs
  .runtime/shots
  .runtime/pids
  .runtime/xdg
  .setup
  .cache/pnpm-store
  .relay-inbox
)
for d in "${DIRS[@]}"; do mkdir -p "$d"; done
echo "==> 目录: ${#DIRS[@]} 个已就绪"

# ---- 归档原图标 ----
if [ -f Witseek.jpg ] && [ ! -f assets/source/Witseek.jpg ]; then
  cp -p Witseek.jpg assets/source/Witseek.jpg
  echo "==> 图标已归档到 assets/source/Witseek.jpg（原文件保留未动）"
fi

# ---- 生成图标多尺寸 ----
python3 - <<'PY'
import os
try:
    from PIL import Image
except Exception as e:
    print("==> 跳过图标转换: PIL 不可用", e); raise SystemExit(0)
src = "assets/source/Witseek.jpg"
if not os.path.exists(src):
    print("==> 跳过图标转换: 找不到源图"); raise SystemExit(0)
img = Image.open(src).convert("RGBA")
# 方形裁切 + 留白
w, h = img.size
side = max(w, h)
canvas = Image.new("RGBA", (side, side), (255, 255, 255, 0))
canvas.paste(img, ((side - w) // 2, (side - h) // 2))
os.makedirs("assets/icons", exist_ok=True)
sizes = [16, 32, 48, 64, 128, 256, 512, 1024]
for s in sizes:
    canvas.resize((s, s), Image.LANCZOS).save(f"assets/icons/icon-{s}.png")
canvas.resize((1024, 1024), Image.LANCZOS).save("assets/icons/icon.png")
canvas.save("assets/icons/icon.ico", sizes=[(s, s) for s in sizes if s <= 256])
print("==> 图标: PNG", len(sizes), "尺寸 + ICO 已生成")
PY

# ---- 写入服务器端 README ----
if [ ! -f README.md ]; then
cat > README.md <<'EOF'
# Witseek

DeepSeek harness 桌面端应用。

> 本目录是**唯一的开发与运行位置**。本地 `D:\Witseek` 仅作中转（SSH 脚本、文档副本、图标原件），
> 不安装依赖、不编译、不运行。

## 快速入口

```bash
# 远端环境（node22 + conda + 项目缓存）
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$HOME/miniconda3/bin:$PATH"

bash scripts/dev.sh          # 启动虚拟显示 + 开发模式
bash scripts/gui-up.sh       # 仅启动虚拟显示（xpra）
bash scripts/gui-down.sh     # 关闭虚拟显示
bash scripts/build.sh        # 打包安装包到 artifacts/
```

## 目录约定

| 路径 | 用途 |
| --- | --- |
| `apps/desktop` | Electron 主进程 + preload |
| `apps/renderer` | React 渲染进程（Vite） |
| `packages/harness-core` | Agent 内核：循环、上下文、审批策略 |
| `packages/provider-deepseek` | DeepSeek API 适配（chat / reasoner，SSE 流式） |
| `packages/tools` | 工具集：文件读写、检索、命令执行 |
| `assets/icons` | 由 `assets/source/Witseek.jpg` 生成的各尺寸图标 |
| `.runtime` | 运行期产物：xpra socket、日志、pid、截图（可随时清空） |
| `.cache` | pnpm store / electron 下载缓存（可随时清空） |
| `artifacts` | 打包产物 |
EOF
  echo "==> README.md 已写入"
else
  echo "==> README.md 已存在，跳过"
fi

# ---- 保留 warning.md ----
[ -f warning.md ] && echo "==> warning.md 原样保留（$(wc -c < warning.md) 字节）"

echo "==> 骨架完成"
find . -maxdepth 2 -type d -not -path "./.git*" | sort | head -40
