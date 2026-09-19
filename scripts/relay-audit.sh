#!/usr/bin/env bash
# relay-audit.sh —— 自检「本地是否真的只是中转」
#
# 核对三件事：
#   1. 本地体积是否在合理范围（中转目录应为 KB～MB 量级）
#   2. 本地是否混入了本应只存在于服务器的东西（node_modules / dist / 依赖缓存）
#   3. 本地各目录的体积明细
#
# 用法: ./scripts/relay-audit.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== 1. 体积明细 =="
printf "%-24s %s\n" "目录" "体积"
printf "%-24s %s\n" "----" "----"
for d in scripts docs assets .relay .runtime; do
  [ -e "$d" ] && printf "%-24s %s\n" "$d/" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
printf "%-24s %s\n" "合计" "$(du -sh . 2>/dev/null | cut -f1)"

echo
echo "== 2. 违规目录检查（本应只存在于服务器）=="
VIOL=0
for p in node_modules dist out build artifacts .cache coverage; do
  hits=$(find . -maxdepth 3 -type d -name "$p" -not -path "./.relay/*" 2>/dev/null)
  if [ -n "$hits" ]; then
    echo "  ✗ 发现 $p :"
    echo "$hits" | sed 's/^/      /'
    VIOL=$((VIOL + 1))
  fi
done
if [ "$VIOL" -eq 0 ]; then
  echo "  ✓ 未发现依赖目录或构建产物"
else
  echo "  → 共 $VIOL 类违规。这些应由服务器端生成，本地出现说明流程被破坏。"
fi

echo
echo "== 3. 白名单之外的顶层条目 =="
ALLOW="scripts docs assets .relay .runtime .workbuddy-ai"
for e in * .*; do
  case "$e" in
    .|..|.git) continue ;;
  esac
  case " $ALLOW " in
    *" $e "*) ;;
    *) echo "  ? $e （不在白名单，请确认是否必要）" ;;
  esac
done

echo
echo "== 4. 隧道状态 =="
if netstat -ano 2>/dev/null | grep -q "127.0.0.1:6080"; then
  echo "  ✓ 画面隧道在运行 → http://127.0.0.1:6080/witseek.html"
else
  echo "  · 画面隧道未运行（需要时执行 ./scripts/wtunnel.sh --daemon）"
fi

echo
echo "== 5. 服务器连通性 =="
if ssh -F .relay/ssh_config -o BatchMode=yes -o ConnectTimeout=10 witseek 'echo ok' >/dev/null 2>&1; then
  echo "  ✓ SSH 可达"
else
  echo "  ✗ SSH 不可达"
fi
