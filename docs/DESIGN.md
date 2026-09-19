# Witseek · DeepSeek Harness 桌面端 — 开发方案

> 版本：v0.1（方案确认稿）
> 更新：2026-09-18
> 开发与运行位置：`dengxin:/media/hnu/hnu2021/dengxin/xuanwentao/Witseek`（唯一）
> 本地位置：`D:\Witseek`（仅中转，不含依赖与构建产物）

---

## 0. 一句话定位

Witseek 是一个 **DeepSeek 模型驱动的桌面 Agent 工作台**：把 DeepSeek 的对话/推理能力，套上工具调用、文件读写、命令执行、审批与回滚这些"外壳"（即 harness），装进一个像 Codex / Claude Desktop 那样的本地桌面应用里。

**harness 的含义**：模型本身只会输出文本。harness 负责把文本变成动作——解析工具调用、执行、把结果喂回、控制权限、管理上下文、记录可回滚的变更。它是产品的主体，模型只是可替换的引擎。

---

## 1. 环境实测基线

以下均为在服务器上**实测确认**的结果，不是推测。

| 项目 | 实测结果 | 影响 |
| --- | --- | --- |
| 主机 | `PowerEdge-R740-70`，Ubuntu 24.04.3，x86_64 | — |
| 算力 | 40 核 / 503 GB 内存 / RTX 4090 24 GB（驱动 580，CUDA 13.0） | 构建与并行测试无压力；如后续做本地模型推理亦有余量 |
| 磁盘 | `/media/hnu` 4.2 T，已用 3.4 T，**剩余 796 G（82%）** | 够用，但需把依赖缓存收进项目目录并定期清理 |
| Node | 系统 v18.19.1；**nvm 内有 v22.22.2**（含 npm 10.9.7、corepack 0.34.6） | **必须显式用 v22**，18 带不动现代 Electron/Vite 工具链 |
| Python | 系统 3.12.3；conda base 3.13.12 | — |
| 网络 | 服务器**可直连外网**（registry.npmjs.org 200，GitHub 可达但偏慢） | 不需要走本地代理；npm 走官方源即可 |
| sudo | **`dengxin` 不在 sudoers 中**（`sudo: 需要密码` 后确认"未出现在 sudoers 文件"） | **任何 apt install 都不可行**，所有系统级依赖必须走用户态方案 |
| 图形 | 无显示器接入（显卡 DP/HDMI 全 disconnected），无 Xorg 运行，`graphical.target` | 需要自建虚拟显示 |
| 远程画面 | `X11Forwarding yes` + `xauth` 存在；本地无 X Server / VNC 客户端 | 采用「服务器渲染 + 浏览器看画面」方案，本地零安装 |
| 网络延迟 | ping 10.157.197.70 = **3–5 ms**（校园内网） | 交互式远程桌面完全可行，VNC 不卡 |

### 1.1 已解决的关键障碍

开发过程中撞到并已修复的四个问题，全部有据可查：

**① 全局 SSH 配置会直接断连**
`~/.ssh/config` 中 `dengxin` 块带 `RemoteForward 127.0.0.1:17894 127.0.0.1:7890` + `ExitOnForwardFailure yes`。当远端 17894 已被占用时，ssh 直接报 `remote port forwarding failed` 并终止，**连命令都执行不了**。
→ 解决：新建项目专用 `.relay/ssh_config`，不改动用户全局配置（原文件保持原样）。

**② `ClearAllForwardings=yes` 会静默吃掉 `-L`**
为绕开①的转发冲突，我一度加了 `ClearAllForwardings=yes`。结果是 `ssh -L 6080:...` 正常退出、**本地却没有任何监听**，`curl` 直接连接被拒。
→ 解决：项目 ssh_config 的 `witseek` 主机块本身不含 RemoteForward，因此完全不需要该选项，已从所有脚本移除。

**③ conda 版 xpra 无法提供虚拟显示**
`conda install xpra` 成功，但其 `xpra_Xdummy` 实为 **Xorg + dummy 驱动**，启动即报 `parse_vt_settings: Cannot open /dev/tty0 (Permission denied)`——普通用户无 VT 访问权。
且 conda-forge **未捆绑 HTML5 网页客户端**（日志：`cannot find the html web root`），`xpra-html5` 既不在 conda-forge 也不在 PyPI。
→ 解决：放弃 xpra，改用 **Xvfb + x11vnc + noVNC** 组合，全部用户态。

**④ 无 sudo 也能装 Xvfb / x11vnc**
→ 解决：`apt-get download <pkg>`（下载不需要 root）+ `dpkg-deb -x` 解包到项目内目录。已成功取得 Xvfb 与 x11vnc，直接可执行。

---

## 2. 总体架构

```
┌──────────────────── 本地 Windows（D:\Witseek，仅中转） ────────────────────┐
│  scripts/*.sh        发起命令的包装器（不执行任何开发动作）                 │
│  docs/ assets/       方案文档、图标原件                                    │
│  浏览器 :6080        查看服务器端画面 ← 唯一的"本地资源占用"               │
└───────────────────────────────┬───────────────────────────────────────────┘
                                │ SSH（内网 3–5ms）
                                │  · 命令通道：wssh.sh
                                │  · 文件通道：wpush.sh / wpull.sh
                                │  · 画面通道：wtunnel.sh（-L 6080）
┌───────────────────────────────┴───────────────────────────────────────────┐
│              服务器 dengxin:/media/hnu/.../Witseek（唯一开发与运行位置）    │
│                                                                            │
│  ① 显示层（用户态）                                                        │
│     Xvfb :100 1920×1080x24  →  x11vnc 127.0.0.1:5900  →  websockify :6080  │
│                                                          + noVNC 宿主页     │
│  ② 应用层                                                                  │
│     Electron 主进程 ──IPC── Electron 渲染进程（React）                     │
│  ③ 内核层（纯 Node，与 UI 解耦，可独立测试）                               │
│     harness-core  ·  provider-deepseek  ·  tools  ·  protocol              │
│  ④ 工具链                                                                  │
│     node v22.22.2（nvm） · pnpm（corepack） · conda env xwt_seek           │
│     Xvfb/x11vnc/noVNC/websockify（.tools，用户态）                         │
└────────────────────────────────────────────────────────────────────────────┘
```

**分层原则**：内核层（③）不依赖 Electron，可在纯 Node 下跑单测和端到端脚本。UI 只是内核的一个消费者。这样即使将来换掉 Electron 外壳，harness 逻辑可以整体复用。

---

## 3. 开发流程与阶段划分

### 阶段总览

| 阶段 | 名称 | 产出物 | 完成判据 |
| --- | --- | --- | --- |
| **P0** | 环境基线 | SSH 通路、conda env `xwt_seek`、虚拟显示栈、图标资源 | **✅ 已完成**（见 §1、§6、§7） |
| **P1** | 工程骨架 | pnpm workspace、TS/构建配置、Electron 应用、脚本体系 | **✅ 已完成**：应用在 `:100` 渲染成功，IPC 往返生效（见 §10） |
| **P2** | Harness 内核 | DeepSeek 适配、Agent 循环、工具注册表、上下文管理、会话持久化 | **✅ 已完成**：单测 80/80 通过，5 个包 typecheck 全绿，`pnpm demo:kernel` 离线跑通"读文件→改文件→回显"闭环（见 §10） |
| **P3** | 主界面 | 三栏布局、侧边栏（会话列表 + 文件树）、对话流、文件预览 | 在虚拟显示上完成一次真实对话并预览工作区文件 |
| **P4** | 闭环能力 | 审批策略、diff 审查卡、集成终端、检查点与回滚 | 改动可预览、可批准、可撤销 |
| **P5** | 打包交付（**Windows 优先**） | ✅ Windows NSIS 安装包（免 Wine：electron-builder dir + resedit 改 PE + Linux 原生 makensis，见 §9.1）；Linux AppImage/deb、代码签名待做 | 产物在 `artifacts/Witseek-Setup-0.1.0.exe`；Windows 实机安装/启动/图标/终端/卸载待在真实 Windows 验证 |
| **P6** | 验收回归 | 单测 + e2e + 截图基线 | 全绿；截图与基线一致 |

### 各阶段要点

**P1 — 工程骨架**
- 用 `corepack` 启用 pnpm，`pnpm-workspace.yaml` 划分 `apps/*` 与 `packages/*`
- Electron + Vite + React + TypeScript；主进程用 `electron-vite` 或自建双构建
- 先把"窗口能在 Xvfb 上起来 + 截图能看到"作为第一个里程碑——**图形链路先于业务逻辑验证**
- 依赖缓存全部重定向到项目内 `.cache/`（见 §7）

**P2 — Harness 内核**（本项目的技术核心，工作量最大）
- DeepSeek 适配：`deepseek-chat` 与 `deepseek-reasoner` 两条线；SSE 流式解析；reasoning_content 与 content 分离
- Agent 循环：模型输出 → 工具调用解析 → 权限判定 → 执行 → 结果回灌 → 继续，直到收敛或达上限
- 工具集：`read_file` / `write_file` / `edit_file`（精确串替换）/ `list_dir` / `glob` / `grep` / `run_command` / `apply_patch`
- 上下文管理：token 预算、历史裁剪、超长时摘要压缩
- 会话持久化：JSONL 追加式记录（便于回放与调试），索引存 SQLite
- **可测性**：内核层提供 headless 入口，不依赖 UI

**P3 — 主界面**
- 三栏 + 底部终端 + 命令面板（详见 §8）
- 侧边栏是本阶段的重点：会话列表、文件树、文件预览三者要联动顺畅

**P4 — 闭环能力**
- 审批策略：`只读` / `逐次确认` / `工作区内自动` 三档
- diff 卡：改动前/后对照，支持逐块接受或拒绝
- 检查点：每轮对话前对工作区打快照（轻量方式：git stash 或文件副本），支持一键回滚
- 终端：node-pty + xterm.js，工作目录锁定在工作区

**P5 — 打包**
- electron-builder 出 Linux AppImage/deb 与 Windows NSIS
- **图标**：用 §7 生成的 `icon.png`（1024）与 `icon.ico`

**P6 — 验收**
- 内核层：vitest 单测（工具执行、上下文裁剪、权限判定）
- 端到端：Playwright 驱动 Electron，配合 `shot.sh` 产出截图基线

---

## 4. 服务器端目录结构

```
/media/hnu/hnu2021/dengxin/xuanwentao/Witseek/
├── Witseek.jpg                  # 原始图标（用户提供，保留不动）
├── warning.md                   # 原有文件，保留不动
├── README.md                    # 服务器端工程说明
├── package.json                 # workspace 根
├── pnpm-workspace.yaml
├── tsconfig.base.json
│
├── assets/
│   ├── source/Witseek.jpg       # 图标归档（副本）
│   └── icons/                   # 自动生成：icon-{16,32,48,64,128,256,512,1024}.png + icon.ico
│
├── apps/
│   └── desktop/                 # Electron 应用（electron-vite 单包布局）
│       ├── electron.vite.config.ts   # 一份配置同时管主进程/preload/渲染进程
│       ├── tsconfig.json
│       ├── resources/           #   打包期资源（由 assets/icons 生成）
│       └── src/
│           ├── main/            #   主进程：窗口、菜单、托盘、IPC、密钥、生命周期
│           ├── preload/         #   contextBridge 暴露的受限 API
│           └── renderer/        #   React 渲染进程
│               ├── index.html
│               └── src/
│                   ├── components/  # 通用组件
│                   ├── features/    # chat / sidebar / preview / terminal / settings
│                   └── styles/      # 主题与令牌
│
├── packages/                    # 与 UI 解耦的内核（P2 已落地，纯 Node，不依赖 Electron）
│   ├── protocol/                #   共享类型 + IPC 契约（单一事实来源）
│   ├── harness-core/            #   Agent 循环、工具注册表、上下文裁剪、审批策略、会话持久化
│   ├── provider-deepseek/       #   DeepSeek API 适配（chat / reasoner，SSE）+ MockProvider
│   ├── tools/                   #   工具实现：paths / glob / fs / search / shell
│   └── ui-kit/                  #   可复用 UI 原语（P3 落地）
│
├── scripts/                     # 全部可复现的操作入口
│   ├── bootstrap_server.sh      #   建骨架（幂等）
│   ├── setup_gui_stack.sh       #   装用户态图形栈
│   ├── gui-up.sh / gui-down.sh  #   虚拟显示栈启停
│   ├── shot.sh                  #   截图（自解析 XWD）
│   ├── dev.sh / build.sh        #   开发与打包（P1 落地）
│   ├── test.sh                  #   单测入口（P2 落地）
│   ├── demo-kernel.mts          #   离线演示：MockProvider 驱动完整 Agent 循环
│   ├── scaffold_p1.sh           #   生成 Electron 工程骨架（声明式，唯一事实来源）
│   ├── scaffold_p2_kernel.sh    #   生成 protocol / provider-deepseek / tools
│   ├── scaffold_p2_core.sh      #   生成 harness-core + vitest 配置 + 离线演示
│   ├── scaffold_p2_tests.sh     #   生成根 package.json + 全部单测
│   └── web/novnc-host.html      #   noVNC 宿主页（带 Witseek 品牌）
│
├── tests/{unit,e2e}/
├── docs/                        # 设计文档（本文件所在）
│
├── artifacts/                   # 打包产物
├── .tools/                      # 用户态二进制（Xvfb / x11vnc / noVNC）——可整体删除重建
├── .setup/                      # 环境安装日志
├── .runtime/                    # 运行期：logs / pids / shots / xdg——可随时清空
├── .cache/                      # pnpm store / electron 下载缓存——可随时清空
└── .relay-inbox/                # 与本地中转的暂存区
```

**设计取向**：`.tools` / `.runtime` / `.cache` 三个目录全部可删除重建，互不污染源码；用户原文件（`Witseek.jpg`、`warning.md`）原样保留。

---

## 5. SSH 连接与远程操作方式

### 5.1 连接配置

**不改动用户全局 `~/.ssh/config`**（原文件保持原样）。项目自带一份专用配置：

`D:\Witseek\.relay\ssh_config`
```
Host witseek
  HostName 10.157.197.70
  User dengxin
  ServerAliveInterval 30
  ServerAliveCountMax 6
  TCPKeepAlive yes
  ExitOnForwardFailure no
```

用 `ssh -F .relay/ssh_config witseek` 调用。好处：与全局配置隔离，用户原有的 `dengxin` 主机块及其代理转发行为不受影响。

### 5.2 三条通道

| 通道 | 脚本 | 作用 | 要点 |
| --- | --- | --- | --- |
| **命令** | `scripts/wssh.sh` | 执行任何开发/构建/测试命令 | 自动注入 `WITSEEK_ROOT`、node22、conda、项目内缓存路径，并 `cd` 到项目根 |
| **文件** | `scripts/wpush.sh` / `wpull.sh` | 本地↔服务器 按需中转 | **双向白名单**：推送禁止依赖/产物；回收默认仅放行文档、截图、安装包 |
| **画面** | `scripts/wtunnel.sh` | 本地 6080 → 服务器 6080 | 浏览器打开 `http://127.0.0.1:6080/witseek.html` |

### 5.3 典型操作序列

```bash
# 1) 看远端环境
./scripts/wssh.sh 'node -v && pnpm -v'

# 2) 跑开发模式（服务器上启动，画面走隧道）
./scripts/wssh.sh 'bash scripts/dev.sh'

# 3) 开画面隧道（另开一个本地终端）
./scripts/wtunnel.sh --daemon
#    → 浏览器打开 http://127.0.0.1:6080/witseek.html

# 4) 截图核对（不依赖浏览器）
./scripts/wssh.sh 'bash scripts/shot.sh .runtime/shots/latest.png 1280'
./scripts/wpull.sh .runtime/shots/latest.png --force

# 5) 回收最终产物
./scripts/wpull.sh artifacts/ --to dist
```

### 5.4 并发与稳定性

- 服务器 40 核 / 503 GB，与现有用户共用无压力；本项目所有进程均为普通用户进程，**不写系统目录、不占系统端口**（仅监听 127.0.0.1 的 5900 / 6080）
- 长任务一律用 `setsid ... < /dev/null` 完全脱离 SSH 会话，避免命令收尾时通道被重置
- `gui-down.sh` 只按 `.runtime/pids` 里记录的 pid 精确停止，**不会误杀其他用户的进程**

---

## 6. 图标资源

原始图标：`Witseek.jpg`（用户提供，蓝色鲸鱼 + Witseek 字样）。原件**保留不动**，另存副本到 `assets/source/`。

已自动生成到 `assets/icons/`：

| 文件 | 用途 |
| --- | --- |
| `icon-16/32/48/64/128/256/512/1024.png` | 窗口图标、托盘、Linux 桌面项、商店素材 |
| `icon.png`（1024） | electron-builder 主图标 |
| `icon.ico`（16–256 多尺寸） | Windows 打包与任务栏 |

生成方式为**方形裁切 + 透明留白 + LANCZOS 重采样**，脚本内嵌在 `bootstrap_server.sh` 中（依赖 Pillow，环境已有）。重新生成只需重跑该脚本。

---

## 7. 本地仅作中转的保障机制

这一条是硬约束，用四道机制落实：

**① 目录白名单**
本地 `D:\Witseek` 只允许存在：

| 目录 | 内容 | 体积量级 |
| --- | --- | --- |
| `scripts/` | 操作脚本（纯文本） | KB |
| `docs/` | 方案与设计文档 | KB |
| `assets/` | 图标原件 | 52 KB |
| `.relay/` | SSH 配置、隧道 pid/log、中转暂存 | KB |
| `.runtime/shots/` | 按需回收的截图 | MB |

本地**不存在**且不应存在：`node_modules/`、`dist/`、`out/`、`artifacts/`、任何依赖缓存。

**② 脚本层硬拦截**
`wpush.sh` 拒绝推送 `node_modules` / `dist` / `out` / `.cache` / `artifacts`；`wpull.sh` 默认只放行 `docs/*`、`*.md`、`.runtime/shots/*`、`artifacts/*.{AppImage,deb,exe,zip}`，其余需显式 `--force`。

**③ 环境变量重定向到服务器**
`wssh.sh` 在远端注入，确保所有缓存都落在服务器项目内、绝不回流本地：
```
npm_config_store_dir = $WITSEEK_ROOT/.cache/pnpm-store
ELECTRON_CACHE       = $WITSEEK_ROOT/.cache/electron
ELECTRON_BUILDER_CACHE = $WITSEEK_ROOT/.cache/electron-builder
XDG_RUNTIME_DIR      = $WITSEEK_ROOT/.runtime/xdg
```

**④ 可自检**
本地一条命令即可核对"本地是否真的只是中转"（体积、禁用目录是否存在）。

> 唯一的本地资源占用是**浏览器标签页**（看远程画面）。若不想用浏览器，也可只靠 `shot.sh` 截图核对，本地占用趋近于零。

---

## 8. 桌面端界面设计（参考 Codex / Claude）

### 8.1 设计基调

借鉴 Codex 与 Claude Desktop 已被验证的交互范式：**左侧上下文、中间对话、右侧产物**，一切以"工作区"为中心。差异点在于 Witseek 需要同时暴露**推理过程**（DeepSeek reasoner 的思维链）与**变更审查**（diff + 审批），因此中间栏的信息密度更高。

### 8.2 主窗口布局

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ① 标题栏  [Witseek]  ⌄ 工作区: class_table   模型: deepseek-reasoner  ▓▓▓░░ 42% │
├───────────────┬──────────────────────────────────────┬───────────────────────┤
│ ② 侧边栏       │ ③ 对话区                              │ ④ 预览 / 编辑器        │
│               │                                      │                       │
│ ▸ 会话         │  ┌────────────────────────────────┐  │  MainActivity.java    │
│   · 修崩溃     │  │ ▸ 推理过程（可折叠）            │  │  ─────────────────    │
│   · 加节假日   │  │   分析 Tab 切换失败的根因…      │  │   1  package com…     │
│   · 重构工具集 │  └────────────────────────────────┘  │   2                  │
│               │                                      │   3  public class…    │
│ ▸ 文件         │  ┌────────────────────────────────┐  │                       │
│   📁 app/      │  │ 🔧 read_file  app/…/Main.java  │  │  ┌─ diff ─────────┐  │
│   📁 res/      │  │    ✓ 读取 214 行                │  │  │ - 旧行          │  │
│   📄 build.gradle│ └────────────────────────────────┘  │  │ + 新行          │  │
│   M gradle…    │                                      │  └────────────────┘  │
│               │  ┌────────────────────────────────┐  │                       │
│ ▸ 搜索         │  │ ✎ edit_file  (待批准)           │  │  [接受] [拒绝] [全部] │
│   🔍          │  │   + 12  - 3                     │  │                       │
│               │  │   [批准] [拒绝] [查看 diff]      │  │                       │
│               │  └────────────────────────────────┘  │                       │
│               │                                      │                       │
│               │  回答正文…                            │                       │
│               │                                      │                       │
│               ├──────────────────────────────────────┤                       │
│               │ ⑤ 输入框  [@文件] [/命令] [⚙ 策略]  ➤ │                       │
│               │ ⑥ 终端面板（可折叠）                  │                       │
└───────────────┴──────────────────────────────────────┴───────────────────────┘
```

### 8.3 各区域职责

**① 标题栏**
工作区切换、模型选择（chat / reasoner）、上下文用量条（实时反映 token 预算占用）、窗口控制。上下文用量条是刚需——DeepSeek 长上下文场景下用户必须能看到还剩多少空间。

**② 侧边栏（可折叠，三视图切换）**
- **会话列表**：历史线程、重命名、置顶、归档；支持按工作区过滤
- **文件浏览器**（重点）：
  - "打开文件夹"入口，选定后成为当前工作区根
  - 目录树懒加载，`node_modules` / `.git` 等按规则折叠
  - 搜索框：文件名模糊匹配 + 内容全文检索（走内核的 `glob` / `grep` 工具，与大模型看到的检索结果一致）
  - Git 状态角标：`M` 修改 / `A` 新增 / `?` 未跟踪 / `U` 冲突
  - 右键菜单：新建、重命名、删除（**删除一律进回收站**）、在终端中打开、复制路径、加入对话上下文
  - **点击文件 → 右侧预览**；双击 → 进入编辑
- **搜索**：全局搜索，结果可直接拖入对话作为上下文

**③ 对话区**
按时间顺序排列的区块流：
- **用户消息**
- **推理过程块**：`deepseek-reasoner` 的 `reasoning_content`，默认折叠、可展开，流式追加
- **工具调用卡**：工具名 + 关键参数 + 状态（执行中 / 成功 / 失败）+ 可展开的原始输出
- **变更卡**：diff 摘要（`+N -M`）+ 批准 / 拒绝 / 查看完整 diff
- **回答正文**：Markdown 渲染，代码块带语法高亮与"复制/插入到文件"操作
- 每条消息可**从此处分支**（fork），便于对比不同解法

**④ 预览 / 编辑器**
- 文件预览：代码（CodeMirror 6）、Markdown（渲染/源码切换）、图片、PDF
- Diff 视图：并排或行内，逐块接受/拒绝
- 编辑态与预览态共用同一面板，避免窗口割裂

**⑤ 输入框**
多行输入、`@` 引用文件/目录、`/` 唤起命令（如 `/clear`、`/compact`、`/review`）、策略快捷切换、发送/停止

**⑥ 终端面板**
xterm.js + node-pty，工作目录锁定在工作区。**默认只读展示大模型执行的命令**，用户可切换为可交互模式。

### 8.4 全局能力

| 功能 | 说明 |
| --- | --- |
| 命令面板 `Ctrl+K` | 所有操作可检索执行 |
| 审批策略三档 | `只读`（只允许读）/ `逐次确认`（每个写操作弹批准）/ `工作区内自动`（工作区内自动执行，越界仍确认） |
| 检查点与回滚 | 每轮对话前打快照，可整体回滚到任一历史点 |
| 通知 | 长任务完成、需要审批时系统通知 + 托盘角标 |
| 设置 | API Key（存 OS 密钥链，**不落明文**）、Base URL、模型与温度、代理、主题、默认策略、快捷键 |
| 主题 | 明/暗双主题，跟随系统 |

### 8.5 核心模块清单

**主进程（Electron Main）**
`WindowManager` 窗口与多显示器 · `MenuService` 原生菜单 · `TrayService` 托盘 · `IpcRouter` IPC 路由 · `SecretStore` 密钥（safeStorage） · `Updater` 更新 · `Lifecycle` 生命周期

**内核（packages/，与 UI 解耦）**
`harness-core`：`AgentLoop` 循环编排 · `ContextManager` 上下文与压缩 · `PermissionEngine` 审批策略 · `CheckpointService` 快照回滚 · `SessionStore` 会话持久化 · `ToolRegistry` 工具注册
`provider-deepseek`：`DeepSeekClient` HTTP/SSE · `StreamParser` 流解析 · `ReasoningChannel` 思维链分离 · `TokenCounter` 计量
`tools`：文件读写/精确替换 · 目录列举 · glob/grep · 命令执行 · patch 应用 · Web 抓取
`protocol`：共享类型、IPC 契约、事件定义（单一事实来源）

**渲染进程（React）**
`features/chat` 对话流 · `features/sidebar` 会话列表/文件树/搜索 · `features/preview` 预览与 diff · `features/terminal` 终端 · `features/settings` 设置 · `stores/*` 状态管理 · `ui-kit` 组件原语

**安全基线**
`contextIsolation: true`、`nodeIntegration: false`、preload 走 `contextBridge` 暴露白名单 API、所有文件操作限定在工作区根内（路径规范化后校验）、命令执行走策略引擎。

---

## 9. 风险与待确认项

| 项 | 说明 | 建议 |
| --- | --- | --- |
| 磁盘余量 796 G（82% 已用） | 共享盘，非本项目独占 | 依赖缓存收在 `.cache/`，阶段结束可清；打包产物及时回收后清理 |
| Electron 下载体积 | 首次 `pnpm install` 需拉 Electron 二进制（约 100+ MB） | 已重定向到 `.cache/electron`，只下一次 |
| 无窗口管理器 | **已解决**：解包 openbox 3.6.1（免 sudo，递归解析后仅缺 5 个依赖包），EWMH 已就绪 | 窗口可拖动/缩放，模态对话框受管理，键盘焦点路由可靠 |
| 桌面端口暴露 | 已强制仅监听 `127.0.0.1` | 保持现状；隧道是唯一入口 |
| DeepSeek API Key | 用户已确认暂不处理 | P2 用环境变量占位；正式版写入 OS 密钥链，不落盘明文 |
| 打包目标平台 | **Windows 优先**。但 electron-builder 在 Linux 上出 Windows 包时 `rcedit` 需要 Wine，而 Wine 依赖树庞大且无 sudo 装不了 | **方案**：用纯 JS 的 `resedit`（3.1.0，已确认存在）直接改写 PE 资源的图标与版本信息，完全绕开 Wine。详见 §9.1 |
| pnpm 12 配置语义 | `onlyBuiltDependencies` 已废弃，改为 `allowBuilds` 映射；且不再读 package.json 的 `pnpm` 字段。写错名字会**静默无效**（表现为 Electron 装完但没有二进制） | 已固化到 `pnpm-workspace.yaml`，并在 `install_deps.sh` 里加了二进制存在性校验 |

### 9.1 Windows 优先打包的技术路线（P5 已落地）

服务器是 Linux，无 Wine、无 sudo、未启用 i386，但目标是 Windows 安装包。`electron-builder`
默认路径有两个环节依赖 Wine：`rcedit`（改 exe 图标/版本）与 NSIS 编译（其 `makensis.exe`
是 32 位 PE）。**P5 实测两者均已绕开，全链路无需 Wine**，最终采用两段式：

1. `electron-builder --win dir` 生成 `win-unpacked`（配置 `win.signAndEditExecutable:false` 跳过 rcedit）；
2. electron-builder 的 `afterPack` 钩子里用纯 JS 的 **resedit 3.1.0** 改写 `Witseek.exe`
   的图标组与 `VS_VERSIONINFO`（替代 rcedit；resedit 是纯 ESM，`.cjs` 钩子内动态 import）；
3. `scripts/make_nsis.py` 遍历 win-unpacked 生成**只用 NSIS 内置指令与 MUI2、零第三方插件**的 `.nsi`
   （per-user 免 UAC、开始菜单/可选桌面快捷方式、卸载器、HKCU 卸载注册表项、lzma solid、中英双语）；
4. 用 conda-forge 的 **Linux 原生 makensis（nsis 3.11，ELF）** 编译出
   `Witseek-Setup-0.1.0.exe`（约 112 MiB，`file` 识别为 Nullsoft Installer）。

关键认知：makensis 本质是编译器，输出 Windows PE 安装程序，与运行平台无关；只要 `.nsi`
不引用在 Linux makensis 下无法加载的 Windows 插件 DLL，就能在 Linux 交叉编译。node-pty 的
win32-x64 N-API prebuilds 随包 `asarUnpack`，Windows 终端无需现场编译。

产物、PE/asar 校验数据与踩坑详见 `docs/P5-验收记录.md`。

仍需 Windows 侧验证：产物在真实 Windows 上安装、启动、任务栏图标、ConPTY 终端、卸载是否正常
（当前仅有 Linux 侧静态/PE 层验证）。Linux AppImage/deb 与代码签名为 P5 后续项。

---

## 10. 当前进度

### P0 — 环境基线 ✅ 已完成

- SSH 通路（含四处踩坑修复）、conda env `xwt_seek`
- 用户态图形栈：Xvfb + openbox + x11vnc + noVNC + websockify，**全部仅监听 127.0.0.1**
- 图标 8 尺寸 PNG + ICO，noVNC 宿主页（Witseek 品牌、自动连接）
- 通路端到端验证：虚拟显示上渲染窗口并截图成功；本地经隧道取到宿主页/图标/核心库，均 200

### P1 — 工程骨架 ✅ 已完成

- pnpm workspace（`apps/*` + `packages/*`）、TypeScript 配置、`.gitignore`
- Electron 44 + electron-vite 5 + Vite 8 + React 19，依赖已装（Electron 二进制 283 MB）
- 主进程：窗口创建、图标加载、CSP 响应头注入、`app:info` IPC
- preload：`contextBridge` 白名单 API
- 渲染进程：三栏骨架（标题栏 / 侧边栏 / 对话区 / 预览区 / 输入区），含推理折叠块、工具调用卡、diff 审批卡
- **验收通过**：应用在 `:100` 上成功渲染，openbox 正常加装饰；`app:info` 的 IPC 往返生效（界面显示了版本号与"无头渲染"标记）

### P1 阶段新踩的坑（均已修复）

| 坑 | 表现 | 根因与修法 |
| --- | --- | --- |
| pnpm 12 配置改名 | Electron 装完但**没有二进制**，`pnpm add` 报 `ERR_PNPM_IGNORED_BUILDS` | pnpm 10+ 默认不跑依赖安装脚本；pnpm 12 的设置名是 `allowBuilds`（映射），不是 `onlyBuiltDependencies`（列表），且不再读 package.json 的 `pnpm` 字段。**写错名字会静默无效** |
| 锁文件残留构建状态 | 改对配置后仍不下载二进制 | 旧 lockfile 已记录"未构建"。需 `rm -rf node_modules pnpm-lock.yaml` 后重装 |
| electron-vite 5 默认 ESM | `No electron app entry file found: out/main/index.js` | 产物是 `.mjs`。`package.json` 的 `main` 改为 `./out/main/index.mjs`，主进程内 `__dirname` 改为 `import.meta.dirname` |
| devDependency 被打进主进程 | `Electron failed to install correctly`（electron 的 npm 包被 bundle 进去了） | `externalizeDepsPlugin` 默认只外置 `dependencies`，而 electron 在 `devDependencies`。需在 main/preload 的 `rollupOptions.external` 里显式加 `['electron']` |
| SUID 沙箱 | `The SUID sandbox helper binary was found, but is not configured correctly`（FATAL） | `chrome-sandbox` 需 root 属主 + 4755，无 sudo 做不到。用官方环境变量 `ELECTRON_DISABLE_SANDBOX=1`；在主进程里 `appendSwitch('no-sandbox')` **太晚** |
| CSP 挡住 Vite 开发模式 | 页面白屏 | `script-src 'self'` 会拦掉 Vite/React 注入的内联脚本。改为生产环境通过 `onHeadersReceived` 注入 CSP，`index.html` 不写 meta |
| 脚手架覆盖 package.json | 依赖被抹掉，报 `ERR_PNPM_OUTDATED_LOCKFILE` | 脚手架改为**声明式**：依赖直接写在脚手架里，成为唯一事实来源，而不是靠 `pnpm add` 命令式添加 |
| 渲染进程图标 404 | 标题栏图标不显示 | 图标要放进 Vite 静态目录 `src/renderer/public/`，引用 `/icon-256.png` |
| `pkill -f` 自伤（复现） | SSH `Connection reset by peer` | 模式串出现在自己的命令行里会匹配到自己。**一律用 `pkill -x <进程名>`** |

### P2 — Harness 内核 ✅ 已完成

四个**纯 Node 包**，不依赖 Electron，可脱离 UI 独立单测：

| 包 | 内容 |
| --- | --- |
| `packages/protocol` | 全部跨包类型：`ChatMessage` / `ToolCall` / `ToolDefinition` / `ModelProvider` / `AgentEvent` / `PermissionMode` / `ToolContext` |
| `packages/provider-deepseek` | `sse.ts`（逐行 SSE 解析）、`client.ts`（`DeepSeekClient`，reasoning 不回传）、`mock.ts`（`MockProvider` + `textTurn` / `toolTurn`） |
| `packages/tools` | `paths.ts`（`resolveInWorkspace`，工作区隔离唯一入口）、`glob.ts`（自实现）、`fs.ts`、`search.ts`、`shell.ts` |
| `packages/harness-core` | `registry.ts`、`permission.ts`、`context.ts`、`session.ts`、`agent.ts`（`runAgent` 主循环） |

设计取舍：

- **包以 TypeScript 源码形式导出**（`exports` 指向 `src/index.ts`），由 vitest / Vite 负责转译。
  省掉一层构建，也就没有 dist 与 src 不同步的问题。
- **零第三方运行时依赖**：glob / grep 自己实现，减少环境风险。
- **`MockProvider` 是关键设计**——它让内核在没有 API Key、没有 UI 的情况下被完整验证。

**验收结果（全部通过）**

| 判据 | 结果 |
| --- | --- |
| 内核层单测通过 | **80/80**，10 个测试文件 |
| 类型检查 | `pnpm typecheck` 5 个包全部 `Done` |
| 无 UI 跑通闭环 | `pnpm demo:kernel` 用 MockProvider 驱动三轮脚本：`read_file` → `edit_file`（经审批）→ 输出结论，改后文件内容正确，`stopReason=completed` |

### P2 阶段被测试逮到的真实缺陷（均已修复）

| 缺陷 | 表现 | 根因与修法 |
| --- | --- | --- |
| `sse.ts` 丢尾事件 | 末尾无换行的最后一条 `data:` 收不到 | 流结束后缓冲区里残留的最后一行从未被处理；真实服务端最后一条数据后常直接断流。抽出 `feed(line)`，流结束后先喂残余再 flush |
| `session.ts` 校验被吞 | `read('../../etc/passwd')` 静默返回 `[]` 而非报错 | `this.#file(id)` 写在 `try` 内部，非法 id 抛的错被 `catch` 当成"文件不存在"。路径解析提到 `try` 之前 |
| `context.ts` 裁剪后仍超预算 | 实测 `finalTokens=405 > maxTokens=400` | 丢弃循环带了 `messages.length > keepRecent + 1`，在"最近 keepRecent 条自身就超预算"时提前收手。条件只看预算，底线改为保留 system + 最后一条 |
| `context.test.ts` 夹具不可满足 | 断言 `stubbed > 0` 永远失败 | `keepRecent: 3` 的保护窗口把待裁剪的 tool 结果包了进去。夹具加长，让 tool 结果真正落在保护窗口外，并补上"只降质不减量"与"结构保留"的断言 |
| `search.test.ts` 漏赋 `ctx` | 5 个用例抛 `TypeError` | `beforeEach` 只赋了 `root`。只有"提前返回"的两个用例侥幸通过——极易被误读成实现 bug |

另有 8 例属纯夹具问题：`node:fs` 的 `writeFile` **不会补建中间目录**，
`fs.test.ts` / `search.test.ts` 写 `sub/b.ts`、`node_modules/x.txt` 前没 `mkdir`，报的是 ENOENT 而非断言失败。

### 脚手架层面的设计缺陷（已修复）

`scaffold_p2_core.sh` 与 `scaffold_p2_tests.sh` **同时拥有** `harness-core/package.json`：
tests 脚本读改写它来注入 `typecheck`，core 脚本又从零写一遍。结果是**后跑的覆盖先跑的**——
单独重跑 core 会静默抹掉 typecheck 脚本，下一次 `pnpm typecheck` 只表现为"某个包没被检查"，没有任何报错。
→ 改为 core 脚本独家写全，tests 脚本不再碰它。

### P2 阶段新踩的环境/工具链坑（均已修复）

| 坑 | 表现 | 根因与修法 |
| --- | --- | --- |
| `CI=1` 触发冻结锁文件 | `ERR_PNPM_OUTDATED_LOCKFILE` | 环境变量 `CI=1` 让 `pnpm install` 默认 `--frozen-lockfile`，改过 `package.json` 就失败。加 `--no-frozen-lockfile` |
| `@types/node` 不可达 | `error TS2688: Cannot find type definition file for 'node'` | pnpm 的 `node_modules` 严格隔离，根目录装了子包也看不见。**必须逐包声明** |
| React 19 移除全局 `JSX` 命名空间 | 6 个组件报 `TS2503: Cannot find namespace 'JSX'` | `@types/react` 19 起不再提供 `global.JSX`。各文件显式 `import type { JSX } from 'react'` |
| CSS 副作用导入缺类型 | `TS2882: Cannot find module or type declarations for side-effect import of './styles.css'` | 该包 tsconfig 的 `types` 里加 `"vite/client"` |

### 下一步（P3 — 主界面）

把 P2 内核接到 P1 的 Electron 三栏 UI 上：

- 侧边栏（会话列表 + 文件树）、对话流、文件预览真正消费 `AgentEvent` 流
- 替换的只是 provider 与事件消费方，**内核不动**
- 三栏 + 底部终端 + 命令面板（详见 §8）

### P4 — 闭环能力 ✅ 已完成

在 P3 主界面上补齐"改动可预览、可批准、可撤销"的四项闭环能力（详见 `docs/P4-验收记录.md`）：

- **审批策略三档可切换并持久化**：只读 / 逐次确认 / 工作区内自动。新增内核 `settings.ts`（`SettingsStore`，
  落盘 `userData/settings.json`，tmp+rename 原子写，损坏安全回落 confirm），主进程启动时恢复、切换时落盘。
- **diff 逐块（hunk）接受 / 拒绝**：内核 `diff.ts` 新增 `diffHunks(context=3)`（相邻段合并、标注 hunkId）
  与 `rebuildText`（不变量：全受==newText、全拒==oldText）。审批卡按 hunk 渲染复选框/全选/N-M 计数，
  主进程按接受集把原工具调用重写为只含选中块的 `edit_file`/`write_file`，全拒转 deny。
- **每轮检查点 + 一键回滚**：新增内核 `checkpoint.ts`，每轮对话开始前对工作区打**文件副本快照**
  （不用 git，目标目录不保证是仓库）+ sha256 清单；护栏单文件 5MB / 总量 200MB / 3000 文件 / 保留 10 个；
  回滚前自动打 rollback-backup，回滚本身也可撤销。侧栏新增"检查点"页签。
- **集成终端**：node-pty + xterm.js/addon-fit，主进程侧把 `cwd` 锁定为工作区（渲染层无法逃逸），
  面板可折叠（折叠时 PTY 存活），无原生模块时在 Linux 回退 util-linux `script` 伪终端。

验收：`pnpm -r typecheck` 5 包全过；`CI=1 pnpm test --run` **19 个测试文件 / 193 例全绿**
（P3 基线 162，P4 新增 31）；node-pty 已按 Electron 44 ABI 经 `electron-rebuild` 重编译；
虚拟显示 `:100` 上真实交互验证了 hunk 审批卡、检查点列表、终端 `ls` 执行回显、三档下拉。

实现与原设计的一处取舍：检查点采用文件副本而非 git stash（见验收记录 §五）。

### P5 — Windows 安装包 ✅ 已完成（实机验证待补）

在无 Wine / 无 sudo / 无显示器的 Linux 上产出正规 Windows NSIS 安装包（详见 `docs/P5-验收记录.md`）：

- **产物**：`artifacts/Witseek-Setup-0.1.0.exe`（约 112 MiB，`file` 识别为 Nullsoft Installer 自解压 PE），
  安装目标 `%LOCALAPPDATA%\Programs\Witseek`（per-user 免 UAC），MUI2 中英双语向导、开始菜单/可选桌面
  快捷方式、卸载器、"添加删除程序"注册表项。
- **免 Wine 两段式**：`electron-builder --win dir`（`signAndEditExecutable:false` 跳过 rcedit）
  → afterPack 用 resedit 3.1.0 改 `Witseek.exe` 图标/版本 → `make_nsis.py` 生成零第三方插件 `.nsi`
  → conda-forge Linux 原生 makensis 3.11 编译。electron-builder 自带 NSIS target 需 wine 跑 32 位
  makensis.exe（实测 `spawn wine ENOENT`），故不使用。
- **校验**：resedit 回读主程序（10 RT_ICON / 版本串）与安装包（6 图标 / 中英版本）；app.asar 354 条目
  含全部产物与工作区包、无杂散平台文件；node-pty win32-x64 N-API prebuilds 经 asarUnpack 进包且无 ELF；
  `pnpm -r typecheck` 5 包全过、**193/193** 测试全绿。
- **遗留**：无 Windows 环境，**未做实机安装/启动/ConPTY 终端/卸载验证**；Linux AppImage/deb、代码签名未做。

### 已确认的决策

1. **API Key** — 暂不处理，先用环境变量占位（`WITSEEK_API_KEY`）
2. **窗口管理器** — 已解包 openbox 3.6.1 并集成（见 §9）
3. **打包优先级** — **Windows 优先，已完成免 Wine NSIS 路线**（resedit 改 PE + conda Linux makensis，见 §9.1）；不再需要"本地 Windows 一次性打包机"备选
