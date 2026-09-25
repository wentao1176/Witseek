# Witseek

**Witseek** 是 [DeepSeek 官方 Harness（`dsh`）](https://github.com/deepseek-ai/deepseek-harness) 的 Windows 桌面封装。它用一个极简的 Electron 薄壳承载官方 dsh 运行时与其 Web UI——模型、插件、工具、会话、终端等能力**全部来自官方 Harness（一切皆插件）**，外壳只负责进程托管、窗口、品牌化，以及一个工作区文件预览边栏和 GitHub 自动更新。

> 内部对话界面仍为官方 DeepSeek Harness；Witseek 是其外层桌面容器与分发形态。

## 特性

- **官方内核**：内置官方 `dsh` win32-x64 生产运行时与一份独立的 Windows Node，无需用户自行安装 Node / Python / 依赖。
- **开箱即用**：启动即用，单实例、本地随机端口 + 随机 token，仅绑定 `127.0.0.1`。
- **API Key 可自行配置**：在界面的 **设置 → 模型** 中填写 / 修改 DeepSeek API 密钥，即时生效并持久化；首次启动也有引导。
- **右侧文件预览边栏**：`Ctrl+B` 开关，可拖拽调宽；工作区文件树 + 代码语法高亮、Markdown 渲染、图片预览，深色主题与主界面适配。
- **GitHub Releases 自动更新**：基于 `electron-updater`，启动后台静默检查，下载完成后引导重启。
- **正规 Windows 安装包**：per-user、免 UAC 的 NSIS 安装程序，带开始菜单 / 桌面快捷方式与卸载器。

## 架构

```
BrowserWindow
 ├─ 底层 webContents：启动 / 错误本地页（loading.html / error.html）
 ├─ mainView (WebContentsView)  ── 官方 dsh Web UI
 │     http://127.0.0.1:<随机端口>/?token=<随机令牌>
 └─ previewView (WebContentsView) ── 壳自带的右侧文件预览栏（preview.html）

主进程 spawn：
  <resources/runtime/node.exe> <resources/runtime/dsh/node_modules/
        @deepseek-ai/dsh/lib/bin.js> web --no-open --host 127.0.0.1 --port 0
```

- 主进程：`apps/desktop/src/main`
  - `runtime.ts` 子进程状态机与就绪 URL 解析；`views.ts` 双视图布局；
    `preview-fs.ts` 工作区只读浏览（含路径越权防护）；`updater.ts` 自动更新。
- 预览栏渲染层：`apps/desktop/src/renderer`（marked + highlight.js 在构建时打包，离线可用）。
- 数据目录（菜单“应用 → 打开数据目录”）：Witseek 的 dsh 配置、凭据（API Key）、插件与 profile 位于 `%USERPROFILE%\.dsh\witseek`；默认工作区位于其 `workspace` 子目录，可用环境变量 `WITSEEK_WORKSPACE` 指定其他工作区。

## Windows 数据与安装位置

- Witseek 的 dsh 配置和凭据：`%USERPROFILE%\.dsh\witseek`
- Electron 壳设置：`%USERPROFILE%\.dsh\witseek\electron`
- 默认工作区：`%USERPROFILE%\.dsh\witseek\workspace`
- 默认安装目录：`%USERPROFILE%\.dsh\WitseekApp`；安装时仍可选择其他当前用户可写的位置。
- 浏览器会话、临时文件和更新下载缓存：所选安装目录旁的 `<安装目录名>-cache` 文件夹。

首次升级时，旧版本的 dsh 配置和默认工作区只会在目标目录为空且可以同盘移动时迁移；旧的默认程序目录会在新版本安装成功后清理。遇到数据冲突时，启动页会显示相关路径；解决后可重试。应用成功启动后，旧桌面数据中剩余的文件会移入 `legacy-desktop-backup-*` 备份目录。卸载会移除程序和由本次安装创建并记录归属的旁置缓存，保留预先存在的缓存目录、Witseek dsh 数据和工作区。

安装包目前未使用 Authenticode 证书签名。Windows SmartScreen 可能显示保护提示；这不会触发管理员权限请求。需要签名分发时，需另行配置可信代码签名证书。

## 目录结构

```
apps/desktop/            Electron 薄壳（主进程 / preload / 预览栏 renderer）
  scripts/prepare-runtime-win.mjs   裁剪 win32 dsh 树 + 下载内置 node.exe
  afterPack.cjs                     免 Wine：resedit 改写 exe 图标/版本 + 复制运行时
scripts/
  stage_win_runtime.sh    交叉准备 win32-x64 hoisted dsh 生产树
  pack_windows.sh         一键产出 Windows 安装包与 latest.yml（Linux，免 Wine）
  make_nsis.py            由 win-unpacked 生成零插件 NSIS 脚本
  make_update_manifest.py 生成 electron-updater 的 latest.yml
  make_icons.py           由源图生成大圆角 PNG/ICO 图标
assets/source/            图标源图；assets/icons 与 apps/desktop/resources 为生成结果
packages/                 早期自研实验内核（当前桌面端不依赖，仅保留存档）
```

## 从源码构建 Windows 安装包（Linux，免 Wine）

依赖：Node 22、pnpm（corepack）、conda 环境（含 `nsis` 的 `makensis`、`7zip`、Pillow）。

```bash
bash scripts/pack_windows.sh
# 产物：
#   artifacts/Witseek-Setup-<version>.exe
#   artifacts/latest.yml
```

流程：交叉安装 win32-x64 dsh 树 → electron-vite 构建 → 准备内置 node.exe 与裁剪后的 dsh 树 →
electron-builder `--win dir`（`afterPack.cjs` 用纯 JS 的 resedit 改 PE 图标/版本，跳过依赖 Wine 的 rcedit）→
Linux 原生 `makensis` 编译安装包 → 生成 `latest.yml`。

开发模式（需要虚拟显示，见 `scripts/dev.sh`）：

```bash
pnpm install
pnpm --filter @witseek/desktop dev
```

## 发布与自动更新

1. 在 GitHub 创建仓库（默认 `wentao1176/Witseek`，可在 `src/main/updater.ts` 与
   `apps/desktop/package.json` 的 `build.publish` 中修改 owner/repo）。
2. 推送代码（见下）。
3. 打包后把 `Witseek-Setup-<version>.exe` 与 `latest.yml` 一并上传到同一个
   **Release**（需为最新 release，tag 如 `v0.4.3`）。客户端经
   `…/releases/latest/download/latest.yml` 发现更新，校验 sha512 后全量下载安装。

```bash
# 需要有 repo 权限的 PAT：export GH_TOKEN=ghp_xxx
python3 scripts/github_release.py v0.4.3 --notes docs/release-v0.4.3.md
```

## 配置 API Key

首次启动按引导填写；或进入 **设置 → 模型**，在 DeepSeek 提供方卡片中填入 API 密钥并保存。
凭据保存在 `%USERPROFILE%\.dsh\witseek\.credentials.yaml`。

## 致谢与许可

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：本项目的内核，遵循其 MIT 许可。
- “DeepSeek”等商标归各自权利人所有。
- Witseek 外壳代码以 [MIT License](LICENSE) 发布。
