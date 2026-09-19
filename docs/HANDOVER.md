# Witseek 项目交接文档

> 本文档面向接手 Witseek 项目的开发者。它假设你已有 Node.js / TypeScript / Electron 基础，但可能对项目的特殊约束（无 sudo 服务器、无头环境、脚手架体系）不熟悉。
>
> 写作时间：2026-09-18（P5）；**2026-09-19 P6 重大方向调整后更新**
> 项目状态：
> - **P6（当前）：自研内核已弃用，改为包装 DeepSeek 官方 Harness（`deepseek-ai/deepseek-harness`，CLI 名 `dsh`，Cordis 插件化、"一切皆插件"、自带 Web UI）。** 极简 Electron 壳（品牌 Witseek）内置官方 dsh win32 生产运行时 + 一份 Windows node.exe，启动后拉起 `dsh web` 并在窗口加载官方界面；模型 / 插件 / 工具 / 会话 / **API Key（设置 → 模型）** 全部是官方 dsh 能力。详见下方 **「P6：官方 dsh 内核重做」** 一章。
> - P5（旧方案，已被否定）：自研 harness-core/provider/tools + React 渲染层，曾打出 `Witseek-Setup-0.1.0.exe`，因"完全无法使用"被废弃，其免 Wine 打包链路（resedit + 原生 makensis）在 P6 复用。
> - 待办：Windows 实机安装/运行验证（构建机无 Wine、无 Windows）、安装包未签名、无自动更新。

---

# P6：官方 dsh 内核重做（2026-09-19，当前主线）

> 用户结论：P5 自研 Agent "完全无法使用"。要求**直接以 DeepSeek 官方 Harness 为内核**（"他自己都说了一切皆插件，请大改"），且 **API Key 必须能在设置界面自行修改**；交付物仍是 **Windows exe 安装包**。

## P6.1 方案：极简 Electron 壳 + 内置官方 dsh 运行时

不复刻官方重型桌面端，也不再自研 agent 内核。Witseek 退化为一个**容器壳**：

```
BrowserWindow（加载官方 dsh Web UI，标题后缀 “· Witseek”）
        │  http://127.0.0.1:<随机端口>/?token=<随机令牌>
        ▼
主进程 spawn：  <resources/runtime/node.exe>  <resources/runtime/dsh/node_modules/
                     @deepseek-ai/dsh/lib/bin.js>  web --no-open --host 127.0.0.1 --port 0
        │
        ▼
官方 dsh（Cordis 插件化，"一切皆插件"）：模型 / 插件 / 工具 / 会话 / 工作区 / 终端
```

- **能力全部来自官方 dsh**：会话、工具、审批、插件市场、终端、MCP、多模型提供方等。
- **API Key**：官方界面 **设置 → 模型**（Settings → Models），DeepSeek 官方提供方卡片里填"API 密钥"并保存，即时生效；还可"+ 添加提供方 / 添加自定义提供方"。凭据持久化在数据目录 `dsh-home/.credentials.yaml`。首次启动也会弹"添加一个 API Key 开始使用"引导。
- 外层只做：启动/停止 dsh 子进程、解析带 token 的就绪 URL、加载页面、启动/错误本地页、单实例、中文菜单、外链外跳、生命周期清理。**壳不含任何自研渲染层**（无 React、无 xterm、无 node-pty 直连）。

为什么不用官方自带的 Electron 桌面端（`apps/desktop`，@deepseek-ai/dsh-desktop）：其打包脚本在**参数解析阶段就硬性拒绝非 Windows x64 主机**出 win 包（Linux 直接 throw，`--dir` 也拦），还要建 Windows junction、签名资源/完整性校验/自动更新，强耦合 macOS/Windows CI，README 明确"Linux is not a supported Desktop release target"。官方 `scripts/wine-windows-gates.sh` 也只在 Wine 下跑编译门、不做 NSIS。故自研此薄壳，运行时则 100% 用官方 dsh。

## P6.2 关键路径

壳源码（`apps/desktop/`，version 0.2.0）：

| 文件 | 职责 |
|------|------|
| `src/main/index.ts` | 单实例锁、BrowserWindow(1320×860)、contextIsolation+sandbox、加载 loading→dsh URL、导航白名单(仅 127.0.0.1，外链 shell.openExternal)、IPC、标题改 `<原标题> · Witseek`、退出杀子进程 |
| `src/main/runtime.ts` | `DshRuntime`：spawn `dsh web --no-open --host 127.0.0.1 --port 0`，正则解析就绪 URL `/(https?:\/\/127\.0\.0\.1:(\d+)\/?\?token=[A-Za-z0-9_-]+)/`，状态 starting/ready/error/stopped，90s 超时，Win `taskkill /T /F`、Unix 进程组 SIGTERM，restart |
| `src/main/paths.ts` | 打包后运行时在 `process.resourcesPath/runtime/{node.exe,dsh/...}`、静态页在 `resources/shell/`；dev 用仓库根 `runtime/stage-<os>/dsh` 与 PATH 中的 node。数据写 `app.getPath('userData')` 下 `dsh-home/`（配置/凭据/插件）与 `workspace/`（cwd/默认文件系统位置） |
| `src/main/menu.ts` | 中文菜单；"重新启动后端"(Ctrl+Alt+R)、"打开数据目录（配置/API Key/插件）"、"打开工作区文件夹"、关于（注明 dsh MIT、设置→模型配 key）、官方仓库外链 |
| `src/preload/index.ts` | CJS（sandbox 兼容），contextBridge 暴露 `witseekShell`（getState/retry/openDataFolder/openWorkspace/onState/onLog），仅供本地 loading/error 页 |
| `resources/loading.html`、`error.html` | 深色自包含本地页（引用同目录 icon.png） |
| `scripts/prepare-runtime-win.mjs` | 裁剪 `runtime/stage-win32/dsh` → `.runtime-build/win/dsh`（排 `.bin`、`.pdb/.map/.d.ts/.tsbuildinfo`、非 win32-x64 prebuilds、win10-arm64），下载内置 Windows Node（默认最新 v24 LTS，npmmirror 优先 nodejs.org 兜底，缓存 `.cache/node-win`，`unzip -j` 取 node.exe），校验 bin.js/conpty/koffi/require-builtin/sharp/rg.exe/node.exe，写 `runtime-manifest.json` |
| `afterPack.cjs` | ① resedit 纯 JS 改写 `Witseek.exe` 图标(6 尺寸)+版本资源（免 rcedit/Wine）；② **`fs.cpSync(...,{dereference:true})` 把 `.runtime-build/win` 整树复制进 `resources/runtime`**（见坑 P6.5-1） |

运行时树（独立 pnpm workspace 阻断，`packages: []`）：

- `runtime/stage-linux/dsh`：Linux 生产树，供**服务器端 dev 验证**（Xvfb 跑 electron，主进程用系统 node 拉起它）。
- `runtime/stage-win32/dsh`：**win32-x64 生产树**，`nodeLinker: hoisted` + `supportedArchitectures:{os:[win32],cpu:[x64]}` + `--ignore-scripts`。所有原生模块均为官方预编译/optionalDeps，无需 Wine 编译：node-pty 自带 `prebuilds/win32-x64/conpty.node` 与 conpty/OpenConsole.exe、`@koromix/koffi-win32-x64`、`node-addon-require-builtin-win32-x64-msvc/prebuilt`、`@img/sharp-win32-x64`、`@vscode/ripgrep-win32-x64/bin/rg.exe`。
- 上游官方源码（备查/构建对照）：`upstream/deepseek-harness`（codeload tar.gz，因无 .git 已 vendor commit）。

## P6.3 一键打包（复现）

```bash
bash scripts/pack_windows.sh        # 全程免 Wine，产物 artifacts/Witseek-Setup-0.2.0.exe
```

七步：① 缺树则 `scripts/stage_win_runtime.sh` 装 win32 hoisted 树 → ② 根 `pnpm install --no-frozen-lockfile` → ③ `apps/desktop` 内 `electron-vite build`（出 `out/main/index.mjs`、`out/preload/index.cjs`，无 renderer）→ ④ `node scripts/prepare-runtime-win.mjs`（node.exe + 裁剪 dsh）→ ⑤ 备图标 → ⑥ `electron-builder --win dir`（`signAndEditExecutable:false`，afterPack 用 resedit 改 PE 并复制 runtime）→ ⑦ `scripts/make_nsis.py` 生成零插件 MUI2 `.nsi`，conda env `xwt_seek` 的 **Linux 原生 makensis** 编译。

NSIS 安装程序特性：per-user 免 UAC（`RequestExecutionLevel user`、装到 `$LOCALAPPDATA\Programs\Witseek`、HKCU 卸载项）、开始菜单 + 可选桌面快捷方式、自带卸载器、中英文、lzma solid、完成页直接启动。dsh 树文件上万，故顶层文件逐个 `File`、顶层目录用原生 `File /r <dir>/*` 递归。

## P6.4 已验证

- 官方源码树与 npm 生产树 `dsh web` 均实测可起、带 token cookie 会话返回 200（标题 DeepSeek Harness）。
- **Xvfb :100 下 `electron-vite dev` 实跑截图通过**：窗口标题"DeepSeek Harness · Witseek"、中文菜单、内测声明弹窗、首次"添加 API Key"引导、**设置 → 模型页可见 DeepSeek API 密钥输入框 + 自定义设置 + 保存 + 添加提供方**、设置侧栏含"插件/Agent 预设"。截图存服务器 `.runtime/shots/shell-dev-1..4.png`。
- win32 树原生件齐备性经 prepare 脚本逐项断言；`win-unpacked/resources/runtime` 含 node.exe(90MB) + dsh(157MB, 13538 文件)。

## P6.5 踩坑记录（复现时务必规避）

1. **electron-builder 的 extraResources 会忽略名为 `node_modules` 的目录**：配置 `from:.runtime-build/win/dsh` 只拷出顶层 `package.json`，13538 个文件全丢（目标 dsh 仅 4KB）。node.exe/shell 等普通文件正常。**解法**：runtime 改在 `afterPack.cjs` 里用 `fs.cpSync(src,dst,{recursive,force,dereference})` 整树复制并断言关键文件，extraResources 只留 shell 三个静态页。
2. **electron peer 变体 dist 缺失**：desktop 解析到 `.pnpm/electron@44.4.1_supports-color@7.2.0/...`，postinstall 只给另一实例解了压，electron-vite 报 `Error: Electron uninstall`。**解法**：对该变体目录 `node install.js`（走 ELECTRON_MIRROR=npmmirror）。
3. **pnpm 构建脚本门**：`pnpm-workspace.yaml` 用 `allowBuilds` map（pnpm 11.7 兼容）；其中 `electron-winstaller: set this to true or false` 是未改完的占位文本，落入"未决→忽略并 `ERR_PNPM_IGNORED_BUILDS`（rc=1）"。我们不用 Squirrel，显式 `electron-winstaller: false` 即 rc=0。注意 pnpm 11 **不读 package.json 的 `pnpm` 字段**，要写在 `pnpm-workspace.yaml`。
4. **frozen-lockfile**：desktop 依赖大改后需 `pnpm install --no-frozen-lockfile` 更新锁文件（CI 环境默认 frozen）。
5. **make_nsis.py 反斜杠**：含 Windows 路径的 NSIS 行一律用普通 Python 字符串、反斜杠写 `\\`；不要用 `r''`（raw 里 `\\` 会变成双反斜杠），也不要让 `\U` 落进普通字符串（unicodeescape SyntaxError）。
6. **prepare 脚本 `process.argv.indexOf('--node-version')` 为 -1 时取了 `argv[0]`（node 路径）当版本号**，拼出 404 URL；已修为仅当 flag 存在才取下一参。
7. ESM 主进程（`.mjs`）无 `__dirname`，preload 路径用 `path.dirname(fileURLToPath(import.meta.url))` 推导。
8. 服务器 `git clone github.com` 报 GnuTLS -110；用 `codeload.github.com` tar.gz、`api.github.com`、`raw.githubusercontent.com`、npmmirror 可达。在子目录装独立 pnpm 树必须放 `pnpm-workspace.yaml: packages: []` 阻断被父 workspace 收编。

## P6.6 已知限制 / 下一步

- **未在真正 Windows 上验证**（构建机无 Wine、无 Windows）：依据是原生件全为官方预编译 + hoisted 布局与官方 wine gate 一致 + Linux 同源树已 200。安装后需在 Windows 实机确认：首次解包、node.exe 拉起 dsh、conpty 终端、Sharp 图像、设置改 key 持久化。
- 安装包**未签名**（SmartScreen 首次会提示）；无自动更新；内部 Web UI 品牌仍为 "DeepSeek Harness"（仅外层 exe/窗口/安装包品牌化为 Witseek，未改官方内部 UI）。
- dsh 锁定 npm `0.1.5-rc.1`（developer preview，可能有破坏性变更），内置 Node `v24.21.0`、Electron `44.4.1`；升级策略待定。
- 旧自研包体（packages/harness-core|protocol|provider-deepseek|tools）仍在 workspace 但已不被桌面端引用/打包，可择机移除。

---

## 1. 项目定位

**Witseek** 是一个 **DeepSeek 模型驱动的桌面 Agent 工作台**。把 DeepSeek 的对话/推理能力，套上工具调用、文件读写、命令执行、审批与回滚这些"外壳"（即 harness），装进一个像 Codex / Claude Desktop 那样的本地桌面应用里。

**harness 的含义**：模型本身只会输出文本。harness 负责把文本变成动作——解析工具调用、执行、把结果喂回、控制权限、管理上下文、记录可回滚的变更。它是产品的主体，模型只是可替换的引擎。

### 1.1 关键约束（不可违反）

| 约束 | 说明 | 违反后果 |
|------|------|----------|
| **开发与运行唯一位置** | `dengxin:/media/hnu/hnu2021/dengxin/xuanwentao/Witseek` | 本地 `D:\Witseek` 仅中转，不装依赖、不编译、不运行 |
| **无 sudo** | 账号不在 sudoers 中 | 任何 `apt install` 都不可行，系统依赖必须走用户态解包 |
| **无显示器** | 服务器无 Xorg、无窗口管理器 | 所有 GUI 验证必须在虚拟显示 `:100` 上完成 |
| **脚手架是唯一事实来源** | 依赖和配置一律声明式写在 `scripts/scaffold_*.sh` 里 | 用 `pnpm add` 命令式添加会导致脚手架与实际状态不一致 |

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

## 3. 目录结构详解

### 3.1 本地（D:\Witseek）—— 仅中转

```
D:\Witseek/
├── scripts/              # 操作脚本（纯文本，全部在本地执行）
│   ├── wssh.sh           #   SSH 命令通道（自动注入环境变量）
│   ├── wpush.sh          #   本地→服务器推送（白名单拦截依赖/产物）
│   ├── wpull.sh          #   服务器→本地回收（默认只放行文档/截图/安装包）
│   ├── wtunnel.sh        #   SSH 画面隧道（-L 6080）
│   ├── relay-audit.sh    #   自检本地是否真的是"纯中转"
│   ├── scaffold_p*.sh    #   声明式脚手架（见 §5）
│   ├── scaffold_p3_tests.sh
│   ├── scaffold_p4.sh       #   P4 闭环能力（checkpoint/settings/terminal/TerminalPane + P4 测试）
│   ├── scaffold_p5.sh       #   P5 打包：生成 apps/desktop/afterPack.cjs（resedit 改 PE 资源）
│   ├── dev.sh            #   开发模式启动（服务器端执行）
│   ├── build.sh          #   生产构建（服务器端执行）
│   ├── pack_windows.sh   #   P5：免 Wine 产出 Windows NSIS exe（dir+resedit+Linux makensis）
│   ├── make_nsis.py      #   P5：遍历 win-unpacked 生成零第三方插件的 .nsi
│   ├── verify_asar.mjs   #   P5：零依赖解析 app.asar 文件树并校验关键条目
│   ├── shot.sh           #   虚拟显示截图（服务器端执行，自解析 XWD）
│   ├── xdrive.py         #   无头 GUI 自动化（python-xlib：点击/输入，服务器端执行）
│   ├── gui-up.sh         #   启动虚拟显示栈
│   ├── gui-down.sh       #   停止虚拟显示栈
│   └── web/novnc-host.html  # noVNC 宿主页
├── docs/                 # 设计文档与验收记录
│   ├── DESIGN.md         #   总设计文档（含进度、缺陷清单、决策记录）
│   ├── P2-验收记录.md     #   P2 Harness 内核验收
│   ├── P3-验收记录.md     #   P3 主界面验收
│   ├── P4-验收记录.md     #   P4 闭环能力验收
│   ├── P5-验收记录.md     #   P5 Windows 免 Wine 安装包验收
│   └── HANDOVER.md       #   本文档
├── assets/               # 图标原件
│   ├── Witseek.jpg       #   原始图标（用户提供，保留不动）
│   └── icons/            #   自动生成：8 尺寸 PNG + ICO
├── .relay/               # SSH 配置与隧道状态
│   └── ssh_config        #   项目专用 SSH 配置（不改动用户全局 ~/.ssh/config）
└── .runtime/shots/       # 回收的截图（按需清空）
```

**本地不存在且不应存在**：`node_modules/`、`dist/`、`out/`、任何依赖缓存。

### 3.2 服务器端（唯一开发与运行位置）

```
/media/hnu/hnu2021/dengxin/xuanwentao/Witseek/
├── package.json                 # workspace 根
├── pnpm-workspace.yaml          # 工作区定义（apps/* + packages/*）
├── tsconfig.base.json           # 共享 TS 配置
│
├── apps/
│   └── desktop/                 # Electron 应用
│       ├── electron.vite.config.ts   # 一份配置管主进程/preload/渲染进程
│       ├── afterPack.cjs       # P5：electron-builder afterPack 钩子（resedit 改 exe 图标/版本，scaffold_p5 生成）
│       ├── package.json        # P5：含 electron-builder build 段（win target=dir、signAndEditExecutable:false）
│       ├── tsconfig.json
│       ├── resources/          # P5：打包期资源（icon.ico 由 pack_windows.sh 从 assets/icons 复制）
│       └── src/
│           ├── main/            #   主进程（Node + Electron）
│           │   ├── env.ts       #     HEADLESS、AUTO_APPROVE、WORKSPACE_ROOT
│           │   ├── host.ts      #     AgentHost：会话、事件流、审批（含 hunk 重写）、检查点、状态
│           │   ├── terminal.ts  #     终端管理：node-pty（缺失时回退 script），cwd 锁定工作区
│           │   ├── ipc.ts       #     IPC 路由：把 HostSink 接到 webContents.send
│           │   ├── provider.ts  #     模型提供方：有 Key 走 DeepSeek，无 Key 走 Mock
│           │   ├── workspace.ts #     文件树、预览、检索
│           │   └── index.ts     #     入口：窗口创建、CSP、生命周期、终端退出清理
│           ├── preload/         #   contextBridge 暴露的受限 API
│           │   └── index.ts
│           └── renderer/        #   React 渲染进程
│               ├── index.html
│               ├── public/icon-256.png
│               └── src/
│                   ├── main.tsx
│                   ├── App.tsx
│                   ├── api.ts
│                   ├── util.ts
│                   ├── transcript.ts
│                   ├── styles.css
│                   ├── state/AgentContext.tsx
│                   └── components/
│                       ├── TitleBar.tsx
│                       ├── Sidebar.tsx      #   文件/会话/检查点/搜索 四个页签
│                       ├── ChatPane.tsx     #   含 hunk 逐块审批卡
│                       ├── PreviewPane.tsx  #   含按 hunk 分组的 DiffView
│                       ├── TerminalPane.tsx #   P4：xterm 集成终端（可折叠）
│                       └── Composer.tsx
│
├── packages/                    # 与 UI 解耦的内核（纯 Node，不依赖 Electron）
│   ├── protocol/                #   共享类型 + IPC 契约（单一事实来源）
│   │   └── src/index.ts
│   ├── harness-core/            #   Agent 循环、工具注册表、上下文裁剪、审批策略、会话持久化
│   │   └── src/{registry,permission,context,session,agent,diff,checkpoint,settings,index}.ts
│   │   #   diff.ts 含 diffHunks/rebuildText（P4 逐块审批）；checkpoint.ts 文件副本快照回滚；
│   │   #   settings.ts 审批模式持久化（P4）
│   ├── provider-deepseek/       #   DeepSeek API 适配 + MockProvider
│   │   └── src/{sse,client,mock,index}.ts
│   ├── tools/                   #   工具实现：paths / glob / fs / search / shell
│   │   └── src/{paths,glob,fs,search,shell,index}.ts
│   └── ui-kit/                  #   可复用 UI 原语（预留，P3 未启用）
│
├── tests/
│   └── unit/                    # 主进程单测（放在根目录，不依赖 Electron）
│       ├── agent-host.test.ts
│       ├── host-p4.test.ts      #   P4：模式持久化、自动检查点、回滚、hunk 部分接受
│       ├── transcript.test.ts
│       ├── util.test.ts
│       └── workspace.test.ts
│
├── scripts/                     # 服务器端脚本（与本地 scripts/ 同名但不同内容）
│   ├── demo-kernel.mts          #   离线演示：MockProvider 驱动完整 Agent 循环
│   ├── make-demo-workspace.sh   #   生成演示工作区
│   ├── pack_windows.sh          #   P5：免 Wine 打 Windows NSIS exe（一键）
│   ├── make_nsis.py             #   P5：win-unpacked → 零插件 .nsi
│   ├── verify_asar.mjs          #   P5：校验 app.asar 文件树
│   └── ...（同本地 scripts/）
│
├── artifacts/                   # 打包产物：Witseek-Setup-<ver>.exe、witseek.nsi、win-unpacked/
├── .tools/                      # 用户态二进制（Xvfb / x11vnc / openbox / xdotool / noVNC）
│   └── */prefix/usr/bin/        #   可整体删除重建
├── .runtime/                    # 运行期（logs / pids / shots / xdg / demo-workspace）
├── .cache/                      # 依赖缓存（pnpm store / electron / electron-builder）
└── .setup/                      # 环境安装日志
```

---

## 4. 核心代码逻辑

### 4.1 内核层（packages/）—— 纯 Node，可独立测试

**protocol** —— 全部跨包类型定义。`IPC` 常量对象定义了所有 IPC 通道名，`FileEntry` 带 `depth` 字段用于扁平树渲染，`ApprovalPrompt` 描述一次审批请求。这是**单一事实来源**：任何跨进程传递的数据结构都在这里定义，不许在别处重复声明。

**harness-core** —— 五个模块：
- `registry.ts`：工具注册表。工具以 `{ name, description, parameters, execute }` 形式注册，`runAgent` 按名查找并执行。
- `permission.ts`：审批引擎。`PermissionMode` 三档：`readonly`（只允许读）、`confirm`（每个写操作弹批准）、`auto`（工作区内自动执行，越界仍确认）。
- `context.ts`：上下文管理。按 token 预算裁剪历史，保留 system 消息 + 最近 N 条 + 被引用的 tool 结果。超预算时丢弃最老的非 system 消息。
- `session.ts`：会话持久化。JSONL 追加式记录（`{ kind: 'meta'|'message'|'usage', ... }`），便于回放与调试。路径穿越校验：非法 id 抛错而不是静默返回空数组。
- `agent.ts`：`runAgent` 主循环。模型输出 → 工具调用解析 → 权限判定 → 执行 → 结果回灌 → 继续，直到收敛或达上限。

**provider-deepseek** —— `DeepSeekClient` 处理 HTTP/SSE 流式响应，`sse.ts` 逐行解析（对分片边界免疫）。`reasoning_content` 与 `content` 分离。`MockProvider` 是关键设计：它让内核在没有 API Key、没有 UI 的情况下被完整验证。

**tools** —— 七个工具：
- `read_file` / `write_file` / `edit_file`：文件读写，`edit_file` 做精确串替换（支持 replaceAll）
- `list_dir` / `glob`：目录列举与文件匹配（glob 自实现，零第三方依赖）
- `grep`：内容检索（自实现）
- `run_command`：命令执行，带超时与输出截断

所有文件操作通过 `resolveInWorkspace` 校验，**禁止路径穿越**。

**P4 新增的内核模块**（同样不依赖 Electron，可纯 Node 单测）：
- `diff.ts`：在 P3 行级 diff 基础上新增 `diffHunks(oldText,newText,context=3)`，把改动切成带 `hunkId`、相邻段合并、带上下文的块；`rebuildText(oldText,hunks,acceptedIds)` 按接受集重建文本。不变量由测试锁死：**全部接受 == newText、全部拒绝 == oldText**。
- `checkpoint.ts`：`CheckpointService` 做文件副本快照（不依赖 git）+ `manifest.json`（相对路径/sha256/大小/mtime）。护栏：单文件 5MB、总量 200MB、3000 文件、保留 10 个；回滚前自动打 `rollback-backup`（建备份时 `skipPrune`，防止被当旧快照剪掉）。
- `settings.ts`：`SettingsStore` 把审批模式等设置原子写（tmp+rename）到 `userData/settings.json`，文件损坏安全回落 `confirm`。
- `agent.ts`：审批回调可返回 `ApprovalResolution`（`acceptedHunkIds` / `rewrittenArgs`），主循环执行 `resolution.rewrittenArgs ?? args`，从而支持逐块接受。

### 4.2 主进程（apps/desktop/src/main/）

**host.ts —— AgentHost**（512 行，核心；P3 时 365 行）

```typescript
class AgentHost {
  // 刻意不 import electron，只认 HostSink 回调
  // 这样它能在纯 Node 下被单测（tests/unit/agent-host.test.ts、host-p4.test.ts）
  async send(text: string): Promise<void> {
    // 0. 每轮开始前自动打工作区检查点，推 checkpoint 事件（P4）
    // 1. 置 running = true（避免按钮白闪）
    // 2. startSession（落盘 meta）
    // 3. runAgent（驱动内核循环）
    // 4. 写操作（edit_file/write_file）→ 预览 diff → 推 approval 挂起等待
    //    P4：审批可带逐块接受集，按 hunk 用 rebuildText 重写工具参数；全拒转 deny
    // 5. 落盘消息 → 推 done
  }
}
```

P4 关键接线：`init()` 从设置恢复审批模式；`setPermissionMode` 为 async 并落盘；
`listCheckpoints/createCheckpoint/rollbackCheckpoint` 委托内核 `CheckpointService`。

**terminal.ts —— 终端管理（P4）**：`TerminalManager` 用 `createRequire`（**变量名必须叫
`nodeRequire`，不能叫 `require`**，见 §10.1）动态探测 `node-pty`，主路径 `spawn('bash', ['-l'])`；
缺失时在 Linux 回退 `script -qec 'stty rows..; exec bash -l' /dev/null`。`cwd` 在主进程侧锁定为
工作区，渲染层只拿到一个终端 id，无法改工作目录。

**ipc.ts —— IPC 路由**
- `app:info`：返回应用信息（版本、平台、headless 标记、`permissionMode`、`terminalBackend`）
- `workspace.tree/read/search/choose`：文件树、预览、检索、选择文件夹
- `session.list/load`：会话列表、加载历史
- `agent.send/approve/reject`：发送消息、审批决议（P4：approve 可带 `acceptedHunkIds`）
- `settings.get/setPermissionMode`、`checkpoint.list/create/rollback`、`terminal.create/write/resize/kill`（P4）
- `push:approval`：独立通道，UI 在决策前弹卡片（P4：含 hunk 列表）
- `push:agent-event`：事件流（推理、工具调用、结果、检查点、done）
- `push:status`：状态变更（running / idle / deciding）；`push:terminal-data/exit`（P4）

**provider.ts —— 模型提供方选择**
- 有 `WITSEEK_API_KEY` → `DeepSeekClient`
- 无 Key → `MockProvider`（脚本化四轮剧本：glob → read_file → edit_file → 结论）
- 脚本化 provider 带 `[Witseek 演示]` 标记与幂等保护，避免重复写入

**workspace.ts —— 文件树**
- `listTree`：扁平数组 + `depth`，支持 `MAX_DEPTH` 截断与 `MAX_ENTRIES` 上限
- `readForPreview`：读文件，含二进制检测与截断
- `searchFiles`：复用内核 `grep` 工具，范围与大模型看到的完全一致

### 4.3 渲染进程（apps/desktop/src/renderer/src/）

**transcript.ts —— 纯函数事件归约器**

`AgentEvent` 流 → `Block[]`（可渲染块）：
- `user`：用户消息
- `reasoning`：推理过程（可折叠）
- `tool-call` / `tool-end`：工具调用与结果
- `approval`：审批卡片
- `text`：回答正文
- `done`：会话结束

**AgentContext.tsx —— 状态管理**
- 订阅 IPC 推送，维护 `tree` / `sessions` / `transcript` / `preview` / `collapsed` / `checkpoints` / 终端
- `refreshTree`：首次加载时按条目数决定是否默认折叠深层目录
- 写文件、回滚检查点后自动刷新文件树与预览，让用户看到真实结果
- `decide(decision, hunkIds?)`：审批决议，P4 可携带逐块接受集

**Sidebar.tsx —— 三栏之一**
- 文件 / 会话 / **检查点（P4）** / 搜索 四个页签
- 文件树用 `visibleTree(entries, collapsed)` 过滤，比递归组件少一层状态传递
- 点击文件 → 右侧预览；点击目录 → 展开/折叠
- 检查点页签：自动检查点列表（文件数/体积/相对时间）、手动创建、「回滚到此」（带 confirm）

**P4 渲染层增量**
- `transcript.ts`：Block 归约器新增 `checkpoint` 块；审批/工具块携带 hunk 与 `acceptedHunkIds`。
- `ChatPane.tsx`：待决审批卡按 hunk 渲染复选框、全选/全不选、N/M 计数，部分批准时按钮文案随选择变化。
- `PreviewPane.tsx`：DiffView 按 hunk 分组显示 `@@` 头与增删行。
- `TerminalPane.tsx`：xterm + FitAddon + ResizeObserver，默认折叠；StrictMode 双挂载在 cleanup 里 kill+dispose；展开时重新 fit 并按行列 `resize` PTY。

---

## 5. 脚手架体系（最重要）

**项目约定：脚手架脚本是唯一事实来源。** 所有依赖、配置、源码一律声明式写在 `scripts/scaffold_*.sh` 里，不靠 `pnpm add` 命令式添加。重跑脚手架即可完整重建工程。

### 5.1 脚手架清单

| 脚本 | 负责的文件 | 说明 |
|------|-----------|------|
| `scaffold_p1.sh` | 根 `package.json`、`pnpm-workspace.yaml`、`tsconfig.base.json`、`.gitignore`；`apps/desktop/package.json`、`electron.vite.config.ts`、`tsconfig.json`、`renderer/index.html` | P1 工程骨架 |
| `scaffold_p2_kernel.sh` | `packages/{protocol,provider-deepseek,tools}` 全部源码 + `tsconfig.json` | P2 内核包 |
| `scaffold_p2_core.sh` | `packages/harness-core` 全部源码 + `vitest.config.ts` + `scripts/demo-kernel.mts` | P2 核心引擎 |
| `scaffold_p2_tests.sh` | 根 `package.json`（补 type/module/devDeps）、全部内核单测 | P2 测试 |
| `scaffold_p3_host.sh` | `apps/desktop/src/main/*.ts`、`preload/index.ts`、`scripts/make-demo-workspace.sh` | P3 主进程 |
| `scaffold_p3_ui.sh` | `apps/desktop/src/renderer/src/**/*.tsx?` + `styles.css` | P3 渲染进程 |
| `scaffold_p3_tests.sh` | `tests/unit/{agent-host,transcript,util,workspace}.test.ts` | P3 测试 |
| `scaffold_p4.sh` | `harness-core/{checkpoint,settings}.ts`、`main/terminal.ts`、`renderer/components/TerminalPane.tsx`、P4 四个测试文件 | P4 闭环能力的**新增**文件（P4 对既有文件的改动分别落在 p1/p2_kernel/p2_core/p3_host/p3_ui 对应脚本里） |
| `scaffold_p5.sh` | `apps/desktop/afterPack.cjs` | P5 打包钩子（resedit 改 PE 图标/版本）。打包依赖与 electron-builder `build` 段在 p1 的 `apps/desktop/package.json`；`pack_windows.sh`、`make_nsis.py`、`verify_asar.mjs` 为直接维护的服务器端脚本，不经脚手架 |

> 没有 `scaffold_all.sh`：全量重建就是按下表顺序逐个执行（见 §6.1），顺序不能乱，**p2_tests / p3_tests 绝不能漏**。

### 5.2 关键规则

**同一个文件只能有一个脚本负责写。** 曾出现 `scaffold_p2_core.sh` 与 `scaffold_p2_tests.sh` 同时写 `harness-core/package.json`，后跑的静默覆盖先跑的，导致 typecheck 脚本消失且无任何报错。

**修改流程**：
1. 改本地 `scripts/scaffold_*.sh`
2. `wpush.sh scripts/scaffold_*.sh` 推上服务器
3. 在服务器上执行 `bash scripts/scaffold_*.sh`
4. `pnpm install --no-frozen-lockfile`
5. 验证 `pnpm typecheck` + `pnpm test`

**不要直接改服务器上的源码**（会被下一次重跑脚手架覆盖）。改脚手架，重跑。

---

## 6. 开发环境搭建

### 6.1 首次 setup（服务器上）

```bash
# 1. 确保环境
node -v    # 必须 v22.22.2（nvm 内）
pnpm -v    # 8.x+
conda activate xwt_seek   # Python 环境（截图脚本用 Pillow）

# 2. 生成全部代码
bash scripts/scaffold_p1.sh
bash scripts/scaffold_p2_kernel.sh
bash scripts/scaffold_p2_core.sh
bash scripts/scaffold_p2_tests.sh
bash scripts/scaffold_p3_host.sh
bash scripts/scaffold_p3_ui.sh
bash scripts/scaffold_p3_tests.sh
bash scripts/scaffold_p4.sh
bash scripts/scaffold_p5.sh

# 3. 安装依赖
pnpm install --no-frozen-lockfile

# 3b. 针对 Electron 重编译原生模块（node-pty；P4 起必需）
pnpm --filter @witseek/desktop rebuild-native

# 3c. 仅 P5 打包需要：conda 环境装 Linux 原生 makensis（一次性，用户态，免 Wine）
conda install -y -n xwt_seek -c conda-forge nsis

# 4. 验证
pnpm -r typecheck
CI=1 pnpm test --run
```

> 打包时 electron-builder 还会经 npmmirror 镜像下载 win32-x64 Electron 与 nsis/7zip 资源到
> `.cache/`（`pack_windows.sh` 已 export `ELECTRON_MIRROR` / `ELECTRON_BUILDER_BINARIES_MIRROR`）。

> `--no-frozen-lockfile` 是必需的：环境里 `CI=1` 会让 `pnpm install` 默认走冻结锁文件，任何 `package.json` 变更都会让 install 直接失败。

### 6.2 日常开发流程

```bash
# 启动虚拟显示栈（幂等，已在跑则跳过）
bash scripts/gui-up.sh

# 启动开发模式（服务器端）
WITSEEK_DEMO_SEND="看看工作区里有什么" bash scripts/dev.sh --daemon

# 本地看画面（另开终端）
./scripts/wtunnel.sh --daemon
# → 浏览器打开 http://127.0.0.1:6080/witseek.html

# 截图核对（不依赖浏览器）
./scripts/wssh.sh 'bash scripts/shot.sh .runtime/shots/latest.png 1440'
./scripts/wpull.sh .runtime/shots/latest.png
```

### 6.3 生产构建与 Windows 打包

```bash
# 仅编译 TS 到 apps/desktop/out/（main/preload/renderer）
bash scripts/build.sh

# 产出 Windows NSIS 安装包（P5，免 Wine；约 4–6 分钟）
bash scripts/pack_windows.sh
# → artifacts/Witseek-Setup-<version>.exe（约 112 MiB）
#   artifacts/win-unpacked/（改好图标的未打包目录）、artifacts/witseek.nsi
```

Windows 打包是两段式（详见 `docs/P5-验收记录.md` §二）：electron-builder 只出 `dir`
（`signAndEditExecutable:false` 跳过依赖 Wine 的 rcedit）→ afterPack 用 resedit 改 PE 图标/版本
→ `make_nsis.py` 生成零第三方插件 `.nsi` → conda-forge 的 **Linux 原生 makensis** 编译。
**不要**把 electron-builder target 改回 `nsis`：它会 `spawn wine` 跑 32 位 makensis.exe，本机无 Wine。

---

## 7. 依赖管理

### 7.1 已安装的依赖

**运行时（dependencies）**：
- `react` / `react-dom` ^19.3.0
- `@witseek/*` workspace 包（内核，已内联到主进程 bundle 中）
- `node-pty` ^1.1.0（P4，集成终端；含原生模块，安装后需 `rebuild-native` 针对 Electron 重编译）
- `@xterm/xterm` ^6.0.0、`@xterm/addon-fit` ^0.11.0（P4，终端渲染）

**开发时（devDependencies）**：
- `electron` ^44.4.1
- `electron-vite` ^5.0.0
- `vite` ^8.3.0
- `typescript` ^7.0.2
- `vitest` ^5.0.1
- `@electron/rebuild` ^4.2.0（P4，把 node-pty 重编译为 Electron ABI）
- `electron-builder` ^26.15.3（P5，出 win-unpacked；NSIS 编译不用它、改用 Linux makensis）
- `resedit` ^3.1.0（P5，纯 JS 改写 PE 图标/版本，替代依赖 Wine 的 rcedit；纯 ESM，钩子内动态 import）
- `@types/node` ^26.6.1（**必须逐包声明**，pnpm 严格隔离）
- `@types/react` / `@types/react-dom` ^19.3.0

**零第三方运行时依赖**：glob / grep 均为自实现，减少环境风险（node-pty 是 P4 唯一新增的带原生代码的运行时依赖，缺失时终端回退到系统 `script`，应用不崩）。

**node-pty 跨平台二进制（P5 关键）**：node-pty@1.1.0 npm 包自带全平台 **N-API** prebuilds
（`prebuilds/win32-x64/{pty,conpty,conpty_console_list}.node` + `winpty-agent.exe`/`winpty.dll`/
`conpty/`），目录名无 ABI 后缀即跨 ABI 通用；Windows 包经 `asarUnpack` 带上这一套，无需在 Windows 现场编译。

### 7.2 添加新依赖

**不要**用 `pnpm add`。改脚手架：

1. 找到负责写目标 `package.json` 的脚手架脚本
2. 在 `devDependencies` 或 `dependencies` 段添加 `"pkg-name": "^x.y.z"`
3. 推上服务器、重跑脚手架、`pnpm install --no-frozen-lockfile`

### 7.3 缓存位置（全部在服务器项目内）

| 缓存 | 路径 |
|------|------|
| pnpm store | `.cache/pnpm-store` |
| Electron 二进制 | `.cache/electron` |
| electron-builder | `.cache/electron-builder` |
| XDG runtime | `.runtime/xdg` |

---

## 8. 常用命令速查

| 命令 | 作用 |
|------|------|
| `pnpm -r typecheck` | 全量类型检查（5 个包） |
| `CI=1 pnpm test --run` | 运行全部单测（当前 19 文件 / 193 例） |
| `pnpm --filter @witseek/desktop rebuild-native` | 针对 Electron 重编译 node-pty（P4） |
| `pnpm demo:kernel` | 离线演示：MockProvider 驱动 Agent 循环 |
| `bash scripts/dev.sh` | 前台开发模式 |
| `bash scripts/dev.sh --daemon` | 后台开发模式 |
| `bash scripts/dev.sh --stop` | 停止后台开发模式 |
| `bash scripts/build.sh` | 生产构建（编译到 apps/desktop/out） |
| `bash scripts/pack_windows.sh` | P5：免 Wine 产出 Windows NSIS exe（artifacts/） |
| `node scripts/verify_asar.mjs artifacts/win-unpacked/resources/app.asar` | P5：校验打进 app.asar 的文件树 |
| `bash scripts/gui-up.sh` | 启动虚拟显示栈 |
| `bash scripts/gui-down.sh` | 停止虚拟显示栈 |
| `bash scripts/shot.sh out.png 1280` | 截图 |
| `bash scripts/relay-audit.sh` | 本地中转自检 |

---

## 9. 测试体系

### 9.1 单测结构

```
packages/harness-core/test/     # 内核单测（P2 80 例 + P4 新增 diff-hunks 11 / checkpoint 7 / settings 6）
packages/tools/test/            # 工具单测
packages/provider-deepseek/test/ # SSE/客户端单测
tests/unit/                     # 主进程单测（P3 82 例 + P4 host-p4 7 例）
  ├── agent-host.test.ts        #   AgentHost 事件流、审批、会话
  ├── host-p4.test.ts           #   P4：模式持久化、自动检查点、回滚、hunk 部分接受
  ├── transcript.test.ts        #   事件归约器
  ├── util.test.ts              #   visibleTree、defaultCollapsed、relativeTime
  └── workspace.test.ts         #   文件树（回归守卫，P3 新增）
```

当前全量 **19 个测试文件 / 193 例全绿**（P2 80 → P3 162 → P4 193）。

### 9.2 测试哲学

- **内核层测试不依赖 Electron**：`AgentHost` 刻意不 import electron，只认 `HostSink` 回调。一旦有人在 `host.ts` 里写 `import { app } from 'electron'`，这些测试立刻崩——相当于给"内核与外壳解耦"加了一道自动守卫。
- **MockProvider 是关键**：它让内核在没有 API Key、没有 UI 的情况下被完整验证。
- **回归守卫**：`workspace.test.ts` 锁死文件树深度截断这类问题。

---

## 10. 已知问题与注意事项

### 10.1 已踩过的坑（不要再踩）

| 坑 | 表现 | 根因 | 修法 |
|---|---|---|---|
| `pkill -f` 自伤 | SSH 命令输出为空，会话被杀 | 模式串出现在执行它的 shell 命令行里 | 一律写 `[e]lectron-vite` |
| 白屏（标题正常） | 窗口在、内容空白 | electron-vite 只 HMR 渲染进程，主进程/preload 改了不重建 | **改完主进程/preload 必须重启 dev 进程** |
| `CI=1` 冻结锁文件 | `ERR_PNPM_OUTDATED_LOCKFILE` | 环境里 `CI=1` | 加 `--no-frozen-lockfile` |
| `@types/node` 不可达 | `TS2688` | pnpm 严格隔离 | 逐包声明 |
| React 19 无全局 JSX | `TS2503` | `@types/react` 19 起不再提供 `global.JSX` | `import type { JSX } from 'react'` |
| CSS 导入缺类型 | `TS2882` | 副作用导入无声明 | tsconfig `types` 加 `"vite/client"` |
| `writeFile` 不建中间目录 | ENOENT | `node:fs` 行为 | 写多级路径前 `mkdir -p` |
| 脚手架所有权冲突 | typecheck 脚本消失 | 两个脚本写同一个文件 | 一个文件只有一个脚本负责 |
| ESM 主进程重复声明 `require`（P4） | dev 启动即崩 `Identifier 'require' has already been declared`，typecheck 不报 | electron-vite 的 ESM 主产物自带 `require` 垫片，`terminal.ts` 再 `const require = createRequire(...)` 冲突 | 改名 `nodeRequire`；凡是主进程要用 createRequire 都避开 `require` 标识符 |
| 终端折叠画布溢出（P4） | 折叠成一行后 xterm 黑底仍从栏下方漏出 | `.terminal` 折叠高 31px 但没裁掉 body | 容器加 `overflow:hidden` |
| 漏跑 tests 脚手架（P4） | `tsc: command not found`、vitest 无输出 | `scaffold_p1.sh` 的根 `package.json` 是无 devDeps 精简版，devDeps/test 脚本由 `scaffold_p2_tests.sh` 补；只跑 p1/p2/p3/p4 会被覆盖 | 重建严格按 §6.1 顺序，p2_tests、p3_tests 不可漏，随后 install |
| electron-builder NSIS 要 Wine（P5） | `spawn wine ENOENT` | 其 `nsis-3.0.4.1/makensis.exe` 是 32 位 PE，需 wine32（i386，无 sudo 装不了）；rcedit 同样依赖 Wine | win `signAndEditExecutable:false` + resedit afterPack 改 PE；NSIS 改用 conda-forge **Linux 原生 makensis** 编译自写零插件 `.nsi`（见 P5 验收 §二） |
| resedit 3.x API 变化（P5） | `icon.isIcon is not a function`、`exe.setResource is not a function` | 3.x 图标要传 `IconFile.from(ico).icons.map(i=>i.data)`；写回用 `res.outputResource(exe)` 而非 `exe.setResource`；版本用 `vi.outputToResourceEntries(res.entries)`；resedit 是纯 ESM，`.cjs` 钩子内 `await import('resedit')` | afterPack.cjs 已按 3.1.0 签名写好，勿照抄旧版教程 |
| NSIS 版本/语言指令格式（P5） | `invalid VIFileVersion format`、`Invalid command: "/LANG=2052"` | `VIFileVersion` 必须四段（0.1.0→0.1.0.0）；`/LANG=n` 要跟在 `VIAddVersionKey` 之后 | make_nsis.py 已自动补零段、按正确顺序生成 |
| wpull 回收目录目标（P5） | `wpull artifacts/x.exe -To artifacts/` 把文件存成名为 `artifacts` 的文件，或 scp 报 No such file | scp 不会自动建本地父目录，尾分隔符目录形式被当文件名 | `-To` 给完整文件路径，且先确保本地 `artifacts/` 目录存在 |

### 10.2 诊断手法

1. **判别"跑的是不是最新构建"要看产物，不要看界面**：
   - 主进程 2.39 kB / preload 0.25 kB = P1 旧产物
   - 主进程 60.93 kB / preload 2.44 kB = P3 正确产物

2. **在无头虚拟显示上点按钮不要目测坐标**：截图会被缩放，目测误差可达上百像素。正确做法是读 `xwd -root` 原始像素（或用 PIL 读未缩放截图），按颜色程序化定位控件，再取几何中心交给点击工具。
    - 首选 P3 解包的 `.tools/xdotool/prefix/usr/bin/xdotool`（需带完整路径与 `LD_LIBRARY_PATH=.tools/xdotool/prefix/usr/lib/x86_64-linux-gnu`）。
    - 备用纯 Python 通路：conda env 内 `pip install python-xlib`，用 `scripts/xdrive.py click x y / type TEXT / key NAME`（P4 验证通过）。注意 openbox 首次点击可能只聚焦不触发；**折叠/展开类 toggle 不能点两次**；xterm 需点在文本行上才聚焦。python-xlib 0.33 的 `fake_input` 只吃位置参数，移动指针用 `Xlib.protocol.request.WarpPointer`（字段 `dst_x/dst_y`）。

### 10.3 未完成事项

| 阶段 | 内容 | 状态 |
|------|------|------|
| **P4** | 审批策略三档可切换并持久化、diff 逐块接受/拒绝、集成终端、检查点与回滚 | ✅ 已完成（见 `docs/P4-验收记录.md`，193 测试全绿 + GUI 实测） |
| **P5-Windows 安装包** | 免 Wine 产出 NSIS exe（图标/版本/快捷方式/卸载器） | ✅ 已完成（见 `docs/P5-验收记录.md`，112 MiB exe，PE 资源/asar/193 测试已校验） |
| **P5-Windows 实机验证** | 在真实 Windows 上安装、启动、看图标、ConPTY 终端、卸载 | ⏳ 未做（无 Windows 环境，当前仅 Linux 侧静态/PE 层验证） |
| **P5-Linux 包** | Linux AppImage/deb（不涉及 Wine，风险低） | 待开发 |
| **P5-签名** | exe 代码签名（当前未签名，首跑有 SmartScreen 提示） | 待证书 |
| **P6** | e2e 测试 + 截图基线回归 | 待开发 |
| API Key | 正式版写入 OS 密钥链，不落明文 | 待确认 |

---

## 11. 关键文件索引

| 文件 | 作用 | 修改频率 |
|------|------|----------|
| `docs/DESIGN.md` | 总设计文档、进度、缺陷清单 | 每阶段更新 |
| `docs/P2-验收记录.md` | P2 验收数据 | 归档 |
| `docs/P3-验收记录.md` | P3 验收数据 | 归档 |
| `docs/P4-验收记录.md` | P4 闭环能力验收（193 测试、node-pty rebuild、GUI 截图） | 归档 |
| `docs/P5-验收记录.md` | P5 Windows 免 Wine 安装包验收（两段式路线、PE/asar 校验、踩坑、实机验证缺口） | 归档 |
| `scripts/scaffold_p*.sh` | 声明式脚手架（唯一事实来源） | 每阶段新增/修改 |
| `apps/desktop/afterPack.cjs` | P5 resedit 改 PE 图标/版本（scaffold_p5 生成） | 低 |
| `scripts/pack_windows.sh` / `make_nsis.py` | P5 Windows 打包总入口 / NSIS 脚本生成器 | 低 |
| `apps/desktop/src/main/host.ts` | AgentHost（核心，P4 含 hunk 审批/检查点） | 中 |
| `apps/desktop/src/main/terminal.ts` | 终端管理（node-pty/script 回退，cwd 锁定，P4） | 低 |
| `apps/desktop/src/main/ipc.ts` | IPC 路由 | 中 |
| `apps/desktop/src/main/provider.ts` | 模型提供方 | 低 |
| `apps/desktop/src/main/workspace.ts` | 文件树 | 低 |
| `apps/desktop/src/renderer/src/components/TerminalPane.tsx` | 集成终端面板（P4） | 低 |
| `apps/desktop/src/renderer/src/transcript.ts` | 事件归约器（P4 含 checkpoint/hunk 块） | 中 |
| `apps/desktop/src/renderer/src/state/AgentContext.tsx` | 状态管理 | 中 |
| `packages/harness-core/src/checkpoint.ts` | 工作区快照与回滚（P4） | 中 |
| `packages/harness-core/src/settings.ts` | 设置持久化（P4） | 低 |
| `packages/harness-core/src/diff.ts` | 行级 diff + diffHunks/rebuildText（P4） | 中 |
| `packages/harness-core/src/agent.ts` | Agent 循环（P4 含 ApprovalResolution） | 低 |
| `packages/harness-core/src/permission.ts` | 审批引擎 | 中（P4） |
| `packages/harness-core/src/context.ts` | 上下文管理 | 低 |
| `packages/harness-core/src/session.ts` | 会话持久化 | 低 |
| `packages/tools/src/fs.ts` | 文件工具 | 低 |
| `packages/provider-deepseek/src/client.ts` | DeepSeek 客户端 | 低 |

---

## 12. 联系与上下文

- **服务器**：`dengxin@10.157.197.70`，Ubuntu 24.04.3，40 核 / 503 GB / RTX 4090
- **conda 环境**：`xwt_seek`
- **Node**：`~/.nvm/versions/node/v22.22.2/bin`
- **项目根**：`/media/hnu/hnu2021/dengxin/xuanwentao/Witseek`
- **本地中转**：`D:\Witseek`（仅中转，不装依赖）

---

*本文档与 `docs/DESIGN.md`、`docs/P2-验收记录.md`、`docs/P3-验收记录.md`、`docs/P4-验收记录.md`、`docs/P5-验收记录.md` 互为补充。设计决策见 DESIGN.md，验收数据见验收记录，操作细节见本文档。*
