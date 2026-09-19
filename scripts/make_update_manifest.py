#!/usr/bin/env python3
# make_update_manifest.py —— 为自定义 makensis 产出的 NSIS 安装包生成
# electron-updater 所需的 latest.yml。
#
# 背景：标准 electron-builder 的 nsis target 会在发布时自动生成 latest.yml 与
# blockmap，但本机无 Wine、走的是 electron-builder --win dir + Linux 原生 makensis
# 的自定义链路，不会产出该文件。electron-updater 的 NSIS 更新只需要 latest.yml 中的
# 安装包 URL、sha512(base64) 与 size；缺少 blockmap 时自动退化为全量下载更新。
#
# 将本脚本生成的 latest.yml 与安装包一并上传到 GitHub Release（latest release），
# 客户端即可通过 https://github.com/<owner>/<repo>/releases/latest/download/latest.yml
# 发现并校验更新。
import argparse
import base64
import datetime
import hashlib
import os
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--setup", required=True, help="NSIS 安装包路径")
    ap.add_argument("--version", required=True, help="语义化版本，如 0.3.0")
    ap.add_argument("--out", required=True, help="输出 latest.yml 路径")
    args = ap.parse_args()

    setup = Path(args.setup).resolve()
    data = setup.read_bytes()
    digest = base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")
    size = len(data)
    name = setup.name
    release_date = (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    )

    lines = [
        "target: nsis",
        f"version: {args.version}",
        "files:",
        f"  - url: {name}",
        f"    sha512: {digest}",
        f"    size: {size}",
        f"path: {name}",
        f"sha512: {digest}",
        f"releaseDate: '{release_date}'",
        "",
    ]
    out = Path(args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8", newline="\n")

    print(f"[manifest] {name}  size={size}  sha512(base64)={digest[:24]}…")
    print(f"[manifest] 已写入 {out}")


if __name__ == "__main__":
    main()
