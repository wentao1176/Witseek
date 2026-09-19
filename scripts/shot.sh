#!/usr/bin/env bash
# shot.sh —— 对虚拟显示截图并输出 PNG
#
# 用途：无需图形界面即可验证「服务器端 GUI 是否真的渲染出来了」。
#
# 为什么自己解码 XWD：
#   本机环境缺少可用截图工具链（ffmpeg 无 x11grab、ImageMagick/scrot/maim 均不可用）。
#   可用的只有 xwd，而 Ubuntu 版 xwd 写出的 header_size=107（含窗口名），
#   Pillow 的 XwdImagePlugin 按 header_size=100 的假设识别，会直接 UnidentifiedImageError。
#   因此这里按 XWD 规范自行解析：100 字节头 + (header_size-100) 窗口名 + ncolors*12 色表 + 像素数据。
#
# 用法:
#   bash scripts/shot.sh                          # 自动命名
#   bash scripts/shot.sh out.png                  # 指定输出
#   bash scripts/shot.sh out.png 960              # 指定输出并缩放到宽 960
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
ENV_PREFIX="$HOME/miniconda3/envs/xwt_seek"
DISPLAY_NUM="${WITSEEK_DISPLAY:-100}"

OUT="${1:-$ROOT/.runtime/shots/shot-$(date +%Y%m%d-%H%M%S).png}"
SCALE_W="${2:-0}"
mkdir -p "$(dirname "$OUT")"

export DISPLAY=":$DISPLAY_NUM"

TMP="$(mktemp /tmp/witseek-shot-XXXXXX.xwd)"
trap 'rm -f "$TMP"' EXIT

xwd -root -silent > "$TMP"

"$ENV_PREFIX/bin/python" - "$TMP" "$OUT" "$SCALE_W" <<'PY'
import struct, sys
from PIL import Image

src, dst, scale_w = sys.argv[1], sys.argv[2], int(sys.argv[3])

data = open(src, 'rb').read()
h = struct.unpack('>25I', data[:100])

header_size   = h[0]
file_version  = h[1]
pixmap_format = h[2]
depth         = h[3]
width, height = h[4], h[5]
byte_order    = h[7]
bpp           = h[11]
bytes_per_line= h[12]
ncolors       = h[19]

if file_version != 7:
    raise SystemExit("非预期 XWD 版本: %s" % file_version)
if pixmap_format != 2:
    raise SystemExit("仅支持 ZPixmap(2)，实际 %s" % pixmap_format)

offset = header_size + ncolors * 12
need   = bytes_per_line * height
raw    = data[offset:offset + need]
if len(raw) < need:
    raise SystemExit("像素数据不足: %d < %d" % (len(raw), need))

# byte_order: 0=LSBFirst → 内存序 B,G,R,X ; 1=MSBFirst → X,R,G,B
mode = 'BGRX' if byte_order == 0 else 'XRGB'
if bpp == 32:
    im = Image.frombytes('RGB', (width, height), raw, 'raw', mode, bytes_per_line)
elif bpp == 24:
    im = Image.frombytes('RGB', (width, height), raw, 'raw', 'BGR' if byte_order == 0 else 'RGB', bytes_per_line)
else:
    raise SystemExit("暂不支持 bpp=%s" % bpp)

if scale_w > 0 and width > scale_w:
    im = im.resize((scale_w, max(1, round(height * scale_w / width))), Image.LANCZOS)

im.save(dst)
print("PNG %s  %dx%d  bpp=%d depth=%d" % (dst, im.size[0], im.size[1], bpp, depth))
PY
