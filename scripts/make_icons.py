#!/usr/bin/env python3
# make_icons.py —— 用用户提供的源图生成 Witseek 应用图标
#
# 需求：软件图标直接用源图（蓝色鲸鱼 + Witseek 文字），但要“大 R 角”。
# 做法：居中裁成正方形 → 留一圈白色安全边距（避免大圆角切到鲸鱼尾巴/波浪）→
#       对整张图加大圆角蒙版（圆角之外透明）→ 输出多尺寸 PNG 与多帧 ICO。
#
# 运行（conda env xwt_seek，含 Pillow）：
#   python scripts/make_icons.py \
#       --src assets/source/Witseek.jpg --out assets/icons \
#       --app-resources apps/desktop/resources
import argparse
import shutil
from pathlib import Path

from PIL import Image, ImageDraw


def rounded_square(size: int, radius_ratio: float) -> Image.Image:
    """边长 size、圆角半径 = size*radius_ratio 的 alpha 蒙版。"""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(round(size * radius_ratio))
    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True, help="图标输出目录 assets/icons")
    ap.add_argument("--app-resources", required=True, help="apps/desktop/resources")
    ap.add_argument("--base", type=int, default=1024)
    ap.add_argument("--radius", type=float, default=0.22, help="圆角半径占边长比例")
    ap.add_argument("--pad", type=float, default=0.05, help="白色安全边距占边长比例")
    args = ap.parse_args()

    src = Path(args.src)
    out = Path(args.out)
    app_res = Path(args.app_resources)
    out.mkdir(parents=True, exist_ok=True)
    app_res.mkdir(parents=True, exist_ok=True)

    im = Image.open(src).convert("RGBA")
    w, h = im.size
    side = min(w, h)
    left, top = (w - side) // 2, (h - side) // 2
    im = im.crop((left, top, left + side, top + side))

    base = args.base
    pad = int(round(base * args.pad))
    canvas = Image.new("RGBA", (base, base), (255, 255, 255, 255))
    inner = base - 2 * pad
    im = im.resize((inner, inner), Image.LANCZOS)
    canvas.paste(im, (pad, pad), im)

    mask = rounded_square(base, args.radius)
    canvas.putalpha(mask)

    png_sizes = [16, 32, 48, 64, 128, 256, 512, 1024]
    for z in png_sizes:
        canvas.resize((z, z), Image.LANCZOS).save(out / f"icon-{z}.png")

    # 主 PNG（窗口 / loading / error 页引用）
    canvas.resize((512, 512), Image.LANCZOS).save(out / "icon.png")

    # 多帧 ICO（Windows 可执行文件 / 安装程序）
    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    canvas.save(out / "icon.ico", format="ICO", sizes=ico_sizes)

    # 同步进桌面端资源目录
    shutil.copyfile(out / "icon.png", app_res / "icon.png")
    shutil.copyfile(out / "icon.ico", app_res / "icon.ico")
    shutil.copyfile(out / "icon-256.png", app_res / "icon-256.png")

    print(f"[make_icons] 源 {src} {w}x{h} -> 大圆角 r={args.radius} pad={args.pad}")
    print(f"[make_icons] PNG {png_sizes} + icon.png + icon.ico 写入 {out}")
    print(f"[make_icons] 已同步到 {app_res}: icon.png / icon.ico / icon-256.png")


if __name__ == "__main__":
    main()
