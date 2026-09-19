#!/usr/bin/env bash
# setup_gui_stack.sh —— 在服务器端以「纯用户态」方式搭建虚拟显示 + 远程画面通路
#
# 背景（实测约束）:
#   - dengxin 账号不在 sudoers 中，无法 apt install
#   - conda-forge 的 xpra 未捆绑 HTML5 网页客户端（xpra-html5 不在 PyPI/conda-forge）
#   - conda 版 xpra_Xdummy 实为 Xorg+dummy，需 /dev/tty0 权限，普通用户不可用
#
# 方案: Xvfb（从 .deb 解包） + x11vnc（从 .deb 解包） + noVNC（静态包） + websockify（pip）
#       全程无需 root，全部落在项目目录内，可整体删除。
#
# 执行: ssh -F .relay/ssh_config witseek 'bash -s' < scripts/setup_gui_stack.sh
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
ENV_PREFIX="$HOME/miniconda3/envs/xwt_seek"
TOOLS="$ROOT/.tools"
NOVNC_VER="${NOVNC_VER:-1.6.0}"

cd "$ROOT"
mkdir -p "$TOOLS" .runtime/logs .setup

echo "==> [1/5] Xvfb"
if [ ! -x "$TOOLS/xvfb/prefix/usr/bin/Xvfb" ]; then
  mkdir -p "$TOOLS/xvfb/debs" "$TOOLS/xvfb/prefix"
  ( cd "$TOOLS/xvfb/debs" && apt-get download xvfb xserver-common >/dev/null 2>&1 )
  for f in "$TOOLS/xvfb/debs"/*.deb; do dpkg-deb -x "$f" "$TOOLS/xvfb/prefix"; done
fi
echo "    Xvfb: $("$TOOLS/xvfb/prefix/usr/bin/Xvfb" -help 2>&1 | head -1 || true)"

echo "==> [2/5] x11vnc"
if [ ! -x "$TOOLS/x11vnc/prefix/usr/bin/x11vnc" ]; then
  mkdir -p "$TOOLS/x11vnc/debs" "$TOOLS/x11vnc/prefix"
  ( cd "$TOOLS/x11vnc/debs" && apt-get download x11vnc libvncserver1 libvncclient1 >/dev/null 2>&1 )
  for f in "$TOOLS/x11vnc/debs"/*.deb; do dpkg-deb -x "$f" "$TOOLS/x11vnc/prefix"; done
fi
VNC_LIB="$TOOLS/x11vnc/prefix/usr/lib/x86_64-linux-gnu"
echo "    x11vnc: $(LD_LIBRARY_PATH="$VNC_LIB" "$TOOLS/x11vnc/prefix/usr/bin/x11vnc" -version 2>&1 | head -1)"

echo "==> [3/5] noVNC $NOVNC_VER"
if [ ! -d "$TOOLS/novnc" ]; then
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/novnc.tar.gz" \
    "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VER}.tar.gz"
  tar -xzf "$TMP/novnc.tar.gz" -C "$TMP"
  mv "$TMP/noVNC-${NOVNC_VER}" "$TOOLS/novnc"
  rm -rf "$TMP"
fi
echo "    noVNC vnc.html: $([ -f "$TOOLS/novnc/vnc.html" ] && echo OK || echo MISSING)"

echo "==> [4/5] openbox 窗口管理器（可选但推荐）"
if [ ! -x "$TOOLS/openbox/prefix/usr/bin/openbox" ]; then
  bash "$ROOT/scripts/fetch_deb_tree.sh" .tools/openbox openbox 2>&1 | tail -4
fi
if [ -x "$TOOLS/openbox/prefix/usr/bin/openbox" ]; then
  echo "    openbox: $(LD_LIBRARY_PATH="$TOOLS/openbox/prefix/usr/lib/x86_64-linux-gnu" \
    "$TOOLS/openbox/prefix/usr/bin/openbox" --version 2>&1 | head -1)"
else
  echo "    openbox: 未安装（可跳过，但窗口将无法移动/缩放）"
fi

echo "==> [5/5] websockify (装入 xwt_seek 环境)"
if [ ! -x "$ENV_PREFIX/bin/websockify" ]; then
  "$ENV_PREFIX/bin/pip" install -q websockify 2>&1 | tail -3
fi
echo "    websockify: $("$ENV_PREFIX/bin/websockify" --version 2>&1 | head -1)"

echo
echo "==> GUI 栈就绪"
du -sh "$TOOLS"/* 2>/dev/null
