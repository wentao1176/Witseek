#!/usr/bin/env bash
# dev.sh —— 在服务器虚拟显示上启动开发模式
#
# 前置：图形栈已就绪（本脚本会自动调用 gui-up.sh）
# 查看画面：本地执行 ./scripts/wtunnel.sh --daemon，浏览器打开 http://127.0.0.1:6080/witseek.html
#
# 用法:
#   bash scripts/dev.sh              # 前台运行（Ctrl+C 退出）
#   bash scripts/dev.sh --daemon     # 后台运行，日志写入 .runtime/logs/dev.log
#   bash scripts/dev.sh --stop       # 停止后台的开发进程
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"
export PNPM_HOME="$ROOT/.cache/pnpm"
export PATH="$PNPM_HOME:$PATH"
export npm_config_store_dir="$ROOT/.cache/pnpm-store"
export ELECTRON_CACHE="$ROOT/.cache/electron"
export ELECTRON_BUILDER_CACHE="$ROOT/.cache/electron-builder"
export XDG_RUNTIME_DIR="$ROOT/.runtime/xdg"
export DISPLAY=":${WITSEEK_DISPLAY:-100}"
# 无头环境：让主进程关掉硬件加速与沙箱（见 main/index.ts）
export WITSEEK_HEADLESS=1
export ELECTRON_DISABLE_SECURITY_WARNINGS=1
# 关键：chrome-sandbox 需要 root 属主 + 4755 权限，而本账号没有 sudo。
# Electron 官方的 ELECTRON_DISABLE_SANDBOX 环境变量是唯一可行的关闭方式
# （在主进程里 appendSwitch('no-sandbox') 太晚，Chromium 初始化时就已 FATAL）。
export ELECTRON_DISABLE_SANDBOX=1

# ---- P3：工作区与审批 ----
# 默认指向演示工作区，避免 agent 一上手就去改真工程源码。
# 换目标：WITSEEK_WORKSPACE=/path/to/project bash scripts/dev.sh
export WITSEEK_WORKSPACE="${WITSEEK_WORKSPACE:-$ROOT/.runtime/demo-workspace}"
if [ ! -d "$WITSEEK_WORKSPACE" ]; then
  echo "== 工作区不存在，先生成演示工作区 =="
  bash "$ROOT/scripts/make-demo-workspace.sh" >/dev/null
fi
# 默认关闭自动批准：无头服务器上用户是经 noVNC 交互的，
# 自动放行会让审批卡片形同虚设。跑无人值守脚本时显式传 WITSEEK_AUTO_APPROVE=1。
export WITSEEK_AUTO_APPROVE="${WITSEEK_AUTO_APPROVE:-0}"

mkdir -p "$XDG_RUNTIME_DIR" "$ROOT/.runtime/logs" "$ROOT/.runtime/pids"
chmod 700 "$XDG_RUNTIME_DIR"

cd "$ROOT"

PIDFILE="$ROOT/.runtime/pids/dev.pid"
LOGFILE="$ROOT/.runtime/logs/dev.log"

case "${1:-}" in
  --stop)
    stopped=0
    if [ -f "$PIDFILE" ]; then
      pid="$(cat "$PIDFILE")"
      # electron-vite dev 会拉起子进程，按进程组一起收掉
      kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      rm -f "$PIDFILE"
      stopped=1
    fi

    # 兜底：按进程组 kill 偶尔会漏掉已经 setsid 出去的 Electron 子进程。
    # 留下的残骸会和新起的实例抢同一个 DISPLAY 与日志文件，
    # 表现为"日志里混着上一个实例的崩溃信息" —— 很难一眼看穿。
    # 模式必须以 [e] 起头：pkill -f 会匹配执行本脚本的那个 shell 的命令行，
    # 直接写 electron-vite 的话，pkill 会把自己的调用者一起杀掉。
    sleep 1
    if pkill -f '[e]lectron-vite' 2>/dev/null; then stopped=1; fi
    if pkill -f '[e]lectron/dist' 2>/dev/null; then stopped=1; fi

    if [ "$stopped" = 1 ]; then
      echo "开发进程已停止"
    else
      echo "没有在运行的开发进程"
    fi
    exit 0
    ;;
esac

# 确保图形栈在线
if ! DISPLAY="$DISPLAY" xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q WINDOW; then
  echo "== 图形栈未就绪，先启动 =="
  bash "$ROOT/scripts/gui-up.sh"
  echo
fi

echo "== 启动开发模式 =="
echo "   DISPLAY = $DISPLAY"
echo "   HEADLESS = $WITSEEK_HEADLESS"
echo

cd "$ROOT/apps/desktop"

if [ "${1:-}" = "--daemon" ]; then
  setsid pnpm dev > "$LOGFILE" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"
  sleep 6
  echo "已后台启动 (pid $(cat "$PIDFILE"))，日志: $LOGFILE"
  echo "查看画面: ./scripts/wtunnel.sh --daemon  然后浏览器打开 http://127.0.0.1:6080/witseek.html"
else
  exec pnpm dev
fi
