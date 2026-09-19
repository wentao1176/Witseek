#!/usr/bin/env bash
# fetch_deb_tree.sh —— 无 sudo 环境下递归拉取并解包 .deb 依赖树
#
# 场景：账号不在 sudoers 中，无法 apt install，但需要某个系统程序。
# 做法：apt-cache 解析依赖 → 跳过系统已装的 → 用 apt-cache show 的 Filename
#       字段拼出镜像地址 → curl 下载 → dpkg-deb -x 解包到项目内 prefix。
#
# 为什么不用 apt-get download：它会使用 sources.list 里排在前面但可能不可达的镜像
# （实测 cn.archive.ubuntu.com 会超时）。直接按 Filename 走清华源更稳。
#
# 用法:
#   bash scripts/fetch_deb_tree.sh .tools/openbox openbox
#   bash scripts/fetch_deb_tree.sh .tools/foo pkg1 pkg2 pkg3
set -uo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
PREFIX_REL="${1:?用法: fetch_deb_tree.sh <prefix相对路径> <包名...>}"
shift
[ $# -gt 0 ] || { echo "至少需要一个包名" >&2; exit 1; }

MIRROR="${WITSEEK_APT_MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/ubuntu}"
PREFIX="$ROOT/$PREFIX_REL"
DEBS="$PREFIX/debs"
mkdir -p "$DEBS" "$PREFIX/prefix"

cd "$ROOT"

is_installed() { dpkg -s "$1" 2>/dev/null | grep -q "^Status: install ok installed"; }

# 解析一个包的全部直接依赖名（展开 alternatives 的第一个选项）
deps_of() {
  apt-cache depends "$1" 2>/dev/null \
    | awk '
        /^ *依赖:|^ *Depends:/ { sub(/^[^:]*:[ ]*/, ""); print }
      ' \
    | sed 's/|//g' | awk '{print $1}' | grep -v '^<' | sort -u
}

declare -A SEEN
QUEUE=("$@")
DOWNLOADED=0
SKIPPED=0
FAILED=()

while [ ${#QUEUE[@]} -gt 0 ]; do
  pkg="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")

  [ -n "${SEEN[$pkg]:-}" ] && continue
  SEEN[$pkg]=1

  if is_installed "$pkg"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # apt-cache show 的 Filename 字段给出 pool 内的准确相对路径
  fn=$(apt-cache show "$pkg" 2>/dev/null | grep -m1 '^Filename:' | awk '{print $2}')
  if [ -z "$fn" ]; then
    # 可能是虚拟包，尝试从 Provides 反查真实包
    real=$(apt-cache showpkg "$pkg" 2>/dev/null | awk '/^Reverse Provides:/{getline; print $1; exit}')
    if [ -n "$real" ]; then
      QUEUE+=("$real")
      continue
    fi
    echo "  ? 无法定位 $pkg（可能是虚拟包或不存在）"
    continue
  fi

  out="$DEBS/$(basename "$fn")"
  if [ ! -f "$out" ]; then
    if ! curl -fsSL -o "$out" "$MIRROR/$fn"; then
      echo "  ✗ 下载失败 $pkg"
      FAILED+=("$pkg")
      rm -f "$out"
      continue
    fi
  fi
  dpkg-deb -x "$out" "$PREFIX/prefix" 2>/dev/null
  DOWNLOADED=$((DOWNLOADED + 1))
  echo "  ✓ $pkg"

  while read -r d; do
    [ -n "$d" ] && QUEUE+=("$d")
  done < <(deps_of "$pkg")
done

echo
echo "==> 解包 $DOWNLOADED 个，跳过已装 $SKIPPED 个"
[ ${#FAILED[@]} -gt 0 ] && echo "==> 失败: ${FAILED[*]}"
echo "==> prefix: $PREFIX/prefix"
ls "$PREFIX/prefix/usr/bin" 2>/dev/null | head -10
