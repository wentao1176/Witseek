#!/usr/bin/env bash
# gui-up.sh —— 启动远程可视桌面（Xvfb + x11vnc + noVNC）
#
# 全部为普通用户进程，无 root 依赖，产物都在项目目录内。
# 幂等：重复执行不会重复启动。
#
# 本地查看方式（另开一个本地终端）:
#   ssh -F .relay/ssh_config -N -L 6080:127.0.0.1:6080 witseek
#   然后浏览器打开 http://127.0.0.1:6080/witseek.html
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
DISPLAY_NUM="${WITSEEK_DISPLAY:-100}"
GEOMETRY="${WITSEEK_GEOMETRY:-1920x1080x24}"
VNC_PORT="${WITSEEK_VNC_PORT:-5900}"
WEB_PORT="${WITSEEK_WEB_PORT:-6080}"

TOOLS="$ROOT/.tools"
LOGS="$ROOT/.runtime/logs"
PIDS="$ROOT/.runtime/pids"
XVFB="$TOOLS/xvfb/prefix/usr/bin/Xvfb"
X11VNC="$TOOLS/x11vnc/prefix/usr/bin/x11vnc"
VNC_LIB="$TOOLS/x11vnc/prefix/usr/lib/x86_64-linux-gnu"
OPENBOX="$TOOLS/openbox/prefix/usr/bin/openbox"
OB_LIB="$TOOLS/openbox/prefix/usr/lib/x86_64-linux-gnu"
OB_DATA="$TOOLS/openbox/prefix/usr/share"
NOVNC="$TOOLS/novnc"
WSOCK="$HOME/miniconda3/envs/xwt_seek/bin/websockify"

cd "$ROOT"
mkdir -p "$LOGS" "$PIDS" "$NOVNC"

[ -x "$XVFB" ]  || { echo "缺少 Xvfb，请先运行 scripts/setup_gui_stack.sh" >&2; exit 1; }
[ -x "$X11VNC" ] || { echo "缺少 x11vnc，请先运行 scripts/setup_gui_stack.sh" >&2; exit 1; }
[ -x "$WSOCK" ]  || { echo "缺少 websockify，请先运行 scripts/setup_gui_stack.sh" >&2; exit 1; }

# 宿主页与图标（每次覆盖，保证与本地脚本一致）
cp -f "$ROOT/scripts/web/novnc-host.html" "$NOVNC/witseek.html"
cp -f "$ROOT/assets/icons/icon-256.png"   "$NOVNC/witseek-icon.png"

# 后台进程统一用 setsid + </dev/null 完全脱离 SSH 会话：
# 否则子进程会持有 ssh 通道的 stdout，导致命令收尾时出现 "Connection reset by peer"。
spawn() {  # spawn <logfile> <command...>
  local log="$1"; shift
  setsid "$@" > "$log" 2>&1 < /dev/null &
  echo $!
}

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# ---- 1. Xvfb ----
if alive "$PIDS/xvfb.pid"; then
  echo "  Xvfb      : 已在运行 (pid $(cat "$PIDS/xvfb.pid"))"
else
  pid=$(spawn "$LOGS/xvfb.log" "$XVFB" ":$DISPLAY_NUM" -screen 0 "$GEOMETRY" -nolisten tcp)
  echo "$pid" > "$PIDS/xvfb.pid"
  sleep 2
  echo "  Xvfb      : 已启动 (:$DISPLAY_NUM, $GEOMETRY, pid $pid)"
fi

# ---- 2. openbox（窗口管理器）----
# 没有 WM 时窗口无法移动/缩放、模态对话框不受管理、焦点路由不可靠。
# openbox 从 .deb 解包而来（免 sudo），需要 LD_LIBRARY_PATH 找自身库、XDG_DATA_DIRS 找主题。
if [ -x "$OPENBOX" ]; then
  if alive "$PIDS/openbox.pid"; then
    echo "  openbox   : 已在运行 (pid $(cat "$PIDS/openbox.pid"))"
  else
    mkdir -p "$ROOT/.runtime/openbox"
    pid=$(DISPLAY=":$DISPLAY_NUM" LD_LIBRARY_PATH="$OB_LIB" XDG_DATA_DIRS="$OB_DATA:/usr/share" \
      spawn "$LOGS/openbox.log" "$OPENBOX")
    echo "$pid" > "$PIDS/openbox.pid"
    sleep 2
    if DISPLAY=":$DISPLAY_NUM" xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q WINDOW; then
      echo "  openbox   : 已启动 (pid $pid, EWMH 已就绪)"
    else
      echo "  openbox   : 启动异常，见 $LOGS/openbox.log"
    fi
  fi
else
  echo "  openbox   : 未安装（可选，跳过）"
fi

# ---- 3. x11vnc ----
if alive "$PIDS/x11vnc.pid"; then
  echo "  x11vnc    : 已在运行 (pid $(cat "$PIDS/x11vnc.pid"))"
else
  pid=$(LD_LIBRARY_PATH="$VNC_LIB" spawn "$LOGS/x11vnc.log" "$X11VNC" \
    -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" \
    -localhost -forever -shared -nopw -noxdamage -repeat -quiet)
  echo "$pid" > "$PIDS/x11vnc.pid"
  sleep 2
  echo "  x11vnc    : 已启动 (127.0.0.1:$VNC_PORT, pid $pid)"
fi

# ---- 4. websockify + noVNC ----
if alive "$PIDS/websockify.pid"; then
  echo "  websockify: 已在运行 (pid $(cat "$PIDS/websockify.pid"))"
else
  # 仅监听回环：共享服务器上不得对外暴露桌面端口
  pid=$(spawn "$LOGS/websockify.log" "$WSOCK" --web "$NOVNC" \
    "127.0.0.1:$WEB_PORT" "127.0.0.1:$VNC_PORT")
  echo "$pid" > "$PIDS/websockify.pid"
  sleep 2
  echo "  websockify: 已启动 (127.0.0.1:$WEB_PORT, pid $pid)"
fi

echo
echo "==> 远程桌面就绪"
echo "    本地隧道: ssh -F .relay/ssh_config -N -L $WEB_PORT:127.0.0.1:$WEB_PORT witseek"
echo "    浏览器  : http://127.0.0.1:$WEB_PORT/witseek.html"
