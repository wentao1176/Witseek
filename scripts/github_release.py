#!/usr/bin/env python3
# github_release.py —— 创建/更新 GitHub Release 并上传 Windows 安装包与 latest.yml。
#
# 为什么不用 gh CLI：构建机可能未安装/未登录 gh。代码推送走 SSH（git@github.com:...），
# 但 Release 与资产上传走 HTTPS API，必须提供一个有 repo 权限的 PAT：
#
#   export GH_TOKEN=ghp_xxx   # 或 GITHUB_TOKEN
#   python3 scripts/github_release.py v0.3.0 --notes docs/release-v0.3.0.md
#
# 行为幂等：release 已存在则复用；同名资产已存在会先删除再上传（便于重发）。
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

OWNER = "wentao1176"
REPO = "Witseek"
API = "https://api.github.com"
UPLOAD = "https://uploads.github.com"


class GitHub:
    def __init__(self, token: str) -> None:
        self.token = token

    def request(self, method: str, url: str, payload=None, raw=None, content_type="application/json"):
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "witseek-release",
        }
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = content_type
        elif raw is not None:
            body = raw
            headers["Content-Type"] = content_type
        else:
            body = None
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                raw_body = resp.read()
                return json.loads(raw_body.decode("utf-8")) if raw_body else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise SystemExit(f"GitHub API {method} {url} 失败 {exc.code}: {detail}") from exc

    def get_or_create_release(self, tag: str, notes: str) -> dict:
        try:
            return self.request("GET", f"{API}/repos/{OWNER}/{REPO}/releases/tags/{tag}")
        except SystemExit:
            payload = {
                "tag_name": tag,
                "target_commitish": "main",
                "name": tag,
                "body": notes,
                "draft": False,
                "prerelease": False,
            }
            return self.request("POST", f"{API}/repos/{OWNER}/{REPO}/releases", payload)

    def replace_asset(self, release_id: int, path: Path, content_type: str) -> None:
        assets = self.request("GET", f"{API}/repos/{OWNER}/{REPO}/releases/{release_id}/assets")
        for asset in assets:
            if asset.get("name") == path.name:
                self.request("DELETE", asset["url"])
                print(f"[release] 删除旧资产 {path.name}")
        url = f"{UPLOAD}/repos/{OWNER}/{REPO}/releases/{release_id}/assets?name={path.name}"
        data = path.read_bytes()
        result = self.request("POST", url, raw=data, content_type=content_type)
        print(f"[release] 已上传 {path.name}（{len(data)} 字节）-> {result.get('browser_download_url')}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("tag", help="release tag，如 v0.3.0")
    ap.add_argument("--notes", help="release notes 的 Markdown 文件")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    args = ap.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("缺少 GH_TOKEN / GITHUB_TOKEN（需要 repo 权限的 PAT）。")

    root = Path(args.root)
    version = args.tag.lstrip("v")
    setup = root / "artifacts" / f"Witseek-Setup-{version}.exe"
    manifest = root / "artifacts" / "latest.yml"
    for f in (setup, manifest):
        if not f.exists():
            raise SystemExit(f"缺少发布资产：{f}")

    notes = ""
    if args.notes:
        notes = Path(args.notes).read_text(encoding="utf-8")

    gh = GitHub(token)
    release = gh.get_or_create_release(args.tag, notes)
    release_id = release["id"]
    print(f"[release] {args.tag} id={release_id}")

    gh.replace_asset(release_id, setup, "application/vnd.microsoft.portable-executable")
    gh.replace_asset(release_id, manifest, "text/yaml; charset=utf-8")

    print(f"[release] 完成：{release.get('html_url')}")
    print("[release] 更新索引："
          f"https://github.com/{OWNER}/{REPO}/releases/latest/download/latest.yml")


if __name__ == "__main__":
    main()
