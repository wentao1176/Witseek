/**
 * 运行时与数据目录解析。
 *
 * 打包后：Electron 的 resources/ 下有三份独立内容：
 *   - runtime/node.exe + runtime/dsh/   内置的官方 dsh 生产运行时（不走 asar）
 *   - shell/loading.html、error.html、icon.png  壳自身的启动/错误静态资源
 *   - app.asar 内的 out/renderer/preview.html    右侧文件预览栏（壳自带渲染层）
 * 开发时：运行时取自仓库根 runtime/stage-<os>/dsh，Node 用 PATH 中的 node，
 *   预览栏走 electron-vite 的 renderer dev server（process.env.ELECTRON_RENDERER_URL）。
 */
import { app } from 'electron'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export interface RuntimeLayout {
  packaged: boolean
  nodeExecutable: string
  dshDir: string
  /** dsh CLI 入口（lib/bin.js）的绝对路径 */
  dshBin: string
  /** Witseek 的只读 dsh 组合补丁。 */
  witseekPatchPath: string
  /** 随应用交付的 Witseek Coding preset 根目录。 */
  agentPresetRoot: string
}

export interface DataLayout {
  /** dsh 的 Harness home（配置 / 凭据 / 插件 / profile 都在这里持久化） */
  dshHome: string
  /** dsh 进程的工作目录，即默认文件系统位置 / 默认工作区，也是文件预览栏的根 */
  workspace: string
  /** 壳静态资源目录（loading/error/icon） */
  shellDir: string
  /** 文件预览栏 preload（out/preload/preview.cjs） */
  previewPreload: string
  /** 文件预览栏页面：dev 为 dev server URL，打包后为本地文件路径 */
  rendererEntry: string
  /** rendererEntry 是否为远程 dev server（决定 loadURL 还是 loadFile） */
  rendererIsUrl: boolean
}

const isWin = process.platform === 'win32'

/** apps/desktop/out/main/index.mjs 向上四级到仓库根 */
function repoRoot(): string {
  const here = path.dirname(fileURLToPath(import.meta.url))
  return path.resolve(here, '..', '..', '..', '..')
}

/** out/main/index.mjs 的同级产物根 out/ */
function outDir(): string {
  const here = path.dirname(fileURLToPath(import.meta.url))
  return path.resolve(here, '..')
}

export function runtimeLayout(): RuntimeLayout {
  if (app.isPackaged) {
    const root = path.join(process.resourcesPath, 'runtime')
    const dshDir = path.join(root, 'dsh')
    return {
      packaged: true,
      nodeExecutable: path.join(root, isWin ? 'node.exe' : 'node'),
      dshDir,
      dshBin: path.join(dshDir, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
      witseekPatchPath: path.join(root, 'witseek.patch.yml'),
      agentPresetRoot: path.join(root, 'agent-presets')
    }
  }
  const root = repoRoot()
  const resources = path.join(root, 'apps', 'desktop', 'resources')
  const stage =
    isWin ? 'stage-win32' : process.platform === 'darwin' ? 'stage-darwin' : 'stage-linux'
  const dshDir = process.env.WITSEEK_DSH_DIR || path.join(root, 'runtime', stage, 'dsh')
  return {
    packaged: false,
    nodeExecutable: process.env.WITSEEK_NODE || (isWin ? 'node.exe' : 'node'),
    dshDir,
    dshBin: path.join(dshDir, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
    witseekPatchPath: path.join(resources, 'witseek.patch.yml'),
    agentPresetRoot: path.join(resources, 'agent-presets')
  }
}

export interface DataLayoutOverrides {
  /** Witseek-owned dsh home. */
  dshHome?: string
  /** Default workspace before the WITSEEK_WORKSPACE override is applied. */
  defaultWorkspace?: string
  /** Explicit validated workspace, taking precedence over WITSEEK_WORKSPACE. */
  workspace?: string
}

export function dataLayout(overrides: DataLayoutOverrides = {}): DataLayout {
  const userData = app.getPath('userData')
  const shellDir = app.isPackaged
    ? path.join(process.resourcesPath, 'shell')
    : path.join(repoRoot(), 'apps', 'desktop', 'resources')

  const devServerUrl = process.env.ELECTRON_RENDERER_URL
  const rendererIsUrl = Boolean(devServerUrl)
  const rendererEntry = devServerUrl
    ? `${devServerUrl}/preview.html`
    : path.join(outDir(), 'renderer', 'preview.html')

  return {
    dshHome: overrides.dshHome ?? path.join(userData, 'dsh-home'),
    // Windows 默认工作区位于 Witseek dsh home；其他平台保持原位置。
    // 可用 WITSEEK_WORKSPACE 覆盖（开发/高级用法），
    // 它同时是 dsh 进程 cwd 与右侧文件预览栏的根目录。
    workspace:
      overrides.workspace ||
      process.env.WITSEEK_WORKSPACE ||
      overrides.defaultWorkspace ||
      path.join(userData, 'workspace'),
    shellDir,
    previewPreload: path.join(outDir(), 'preload', 'preview.cjs'),
    rendererEntry,
    rendererIsUrl
  }
}

/** 返回错误信息表示运行时缺失；null 表示就绪 */
export function checkLayout(layout: RuntimeLayout): string | null {
  if (layout.packaged && !existsSync(layout.nodeExecutable)) {
    return `内置 Node 运行时缺失：${layout.nodeExecutable}`
  }
  if (!existsSync(layout.dshBin)) {
    return `找不到 dsh 启动文件：${layout.dshBin}。请先准备运行时（prepare:runtime）。`
  }
  if (!existsSync(layout.witseekPatchPath)) {
    return `找不到 Witseek dsh 补丁：${layout.witseekPatchPath}`
  }
  if (!existsSync(path.join(layout.agentPresetRoot, 'witseek-coding', 'agent.cordis.yml'))) {
    return `找不到 Witseek Coding preset：${layout.agentPresetRoot}`
  }
  return null
}
