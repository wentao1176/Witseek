#!/usr/bin/env bash
# gui-down.sh —— 关闭远程可视桌面的全部进程
#
# 只关闭由 gui-up.sh 记录的 pid，不影响服务器上其他用户的进程。
set -uo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
PIDS="$ROOT/.runtime/pids"

stop() {
  local name="$1" pf="$PIDS/$1.pid"
  if [ -f "$pf" ]; then
    local pid; pid="$(cat "$pf")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      echo "  已停止 $name (pid $pid)"
    else
      echo "  $name 已不在运行"
    fi
    rm -f "$pf"
  else
    echo "  $name 无 pid 记录，跳过"
  fi
}

# 先停上层，再停底层
stop websockify
stop x11vnc
stop openbox
stop xvfb

echo "==> 远程桌面已关闭"
