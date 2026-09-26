/**
 * Witseek 桌面壳入口。
 *
 * 职责（壳只做"容器"，不实现任何 agent 能力）：
 *  1. 拉起内置的官方 dsh 运行时（独立上游 Node + `dsh web`）；
 *  2. 解析 dsh 打印的带 token 本地 URL，在主视图（WebContentsView）加载官方 Web UI；
 *  3. 提供启动/错误本地页、单实例、菜单、生命周期清理、外链外跳；
 *  4. 右侧可折叠的工作区文件预览栏（previewView，详见 views.ts / preview-fs.ts）；
 *  5. 经 GitHub Releases 的自动更新（electron-updater，仅打包后生效）。
 *
 * 模型 / 插件 / 工具 / 会话等全部能力来自 dsh（一切皆插件）；
 * API Key 在官方界面 设置 → 模型 中填写并即时生效，持久化在数据目录。
 */
import { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, shell } from 'electron'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildMenu } from './menu'
import { checkLayout, runtimeLayout, type DataLayout } from './paths'
import { registerPreviewIpc } from './preview-fs'
import { DshRuntime, type RuntimeState } from './runtime'
import { checkForUpdatesManual, setupUpdater } from './updater'
import { createViews, type ViewBundle } from './views'
import {
  describeMigrationIssue,
  finalizeLegacyUserData,
  prepareDesktopStorage,
  type DesktopStorage
} from './storage'

// main 以 ESM(.mjs) 输出，没有 __dirname 全局，用 import.meta.url 推导模块目录
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url))

let win: BrowserWindow | null = null
let runtime: DshRuntime | null = null
let views: ViewBundle | null = null
let data: DataLayout | null = null
let storage: DesktopStorage | null = null
let appLoaded = false
let legacyDataFinalized = false

const singleInstance = app.requestSingleInstanceLock()
if (!singleInstance) {
  app.quit()
} else {
  storage = prepareDesktopStorage()

  app.on('second-instance', () => {
    if (!win) return
    if (win.isMinimized()) win.restore()
    win.focus()
  })

  app.whenReady().then(bootstrap)

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit()
  })

  app.on('before-quit', () => {
    runtime?.kill()
  })
}

function bootstrap(): void {
  const layout = runtimeLayout()
  const prepared = storage ?? prepareDesktopStorage()
  storage = prepared
  data = prepared.data

  runtime = new DshRuntime(layout, data, prepared.cacheDir)

  // 启动/错误页使用的生命周期 IPC 需在创建窗口（加载启动页）之前注册，
  // 否则页面首帧调用 invoke 会出现 “No handler registered”。
  ipcMain.handle('shell:get-state', () => ({
    ...(runtime?.state ?? { status: 'error', url: null, port: null, message: '' }),
    message: startupMessage(prepared) || runtime?.state.message || '',
    migrationIssues: prepared.migrationIssues.map(issue => ({
      ...issue,
      message: describeMigrationIssue(issue)
    })),
    initializationError: prepared.initializationError
  }))
  ipcMain.handle('shell:retry', () => {
    app.relaunch()
    app.exit(0)
    return true
  })
  ipcMain.handle('shell:open-data', () => shell.openPath(data!.dshHome))
  ipcMain.handle('shell:open-workspace', () => shell.openPath(data!.workspace))
  ipcMain.handle('shell:open-legacy-data', () =>
    shell.openPath(path.join(prepared.legacyUserData, 'dsh-home'))
  )
  ipcMain.handle('shell:open-legacy-workspace', () =>
    shell.openPath(path.join(prepared.legacyUserData, 'workspace'))
  )

  win = createWindow(data.shellDir)
  views = createViews(win, {
    rendererEntry: data.rendererEntry,
    rendererIsUrl: data.rendererIsUrl,
    previewPreload: data.previewPreload,
    mainPreload: path.join(MODULE_DIR, '..', 'preload', 'desktopBridge.cjs')
  })

  wireMainView()
  registerPreviewIpc(
    win,
    data,
    views.mainView.webContents,
    root => views?.previewView.webContents.send('preview:workspace', root),
    [prepared.cacheDir]
  )
  ipcMain.handle('preview:resize', (_event, width: number) => {
    views?.setSidebarWidth(width)
    return views?.sidebarWidth ?? 0
  })

  Menu.setApplicationMenu(
    buildMenu({
      restart: () => restartRuntime(),
      openData: () => void shell.openPath(data!.dshHome),
      openWorkspace: () => void shell.openPath(data!.workspace),
      toggleSidebar: () => views?.toggleSidebar() ?? false,
      checkUpdates: () => void checkForUpdatesManual(() => win)
    })
  )

  if (!prepared.migrationIssues.length && !prepared.initializationError) {
    setupUpdater(() => win, prepared.cacheDir)
  }

  runtime.on('state', (state: RuntimeState) => {
    win?.webContents.send('shell:state', state)
    if (state.status === 'ready' && state.url) {
      if (!legacyDataFinalized) {
        legacyDataFinalized = true
        const preservedPath = finalizeLegacyUserData(prepared)
        if (preservedPath) {
          setTimeout(() => {
            void dialog.showMessageBox({
              type: 'warning',
              title: '旧数据仍保留在原位置',
              message: 'Witseek 已正常启动，但旧桌面数据未能移动。',
              detail: `为保护数据，原目录保持不变：\n${preservedPath}`
            })
          }, 500)
        }
      }
      loadApp(state.url)
    }
  })
  runtime.on('log', (text: string) => {
    win?.webContents.send('shell:log', text)
  })
  runtime.on('fatal', () => showError())
  runtime.on('stopped', () => showError())

  const startupError = startupMessage(prepared)
  const layoutError = startupError || checkLayout(layout)
  if (layoutError) {
    runtime.state = { status: 'error', url: null, port: null, message: layoutError }
    showError()
  } else {
    runtime.start()
  }
}

function startupMessage(prepared: DesktopStorage): string {
  const issues = prepared.migrationIssues.map(describeMigrationIssue)
  const messages = [
    prepared.initializationError,
    issues.length
      ? `检测到旧数据迁移冲突。原数据已保留，请打开相关目录处理后重试：\n${issues.join('\n')}`
      : null
  ].filter((message): message is string => Boolean(message))
  return messages.join('\n')
}

function restartRuntime(): void {
  if (!runtime || !win || !data) return
  appLoaded = false
  views?.mainView.setVisible(false)
  win.loadFile(path.join(data.shellDir, 'loading.html')).catch(() => {})
  runtime.restart()
}

function loadApp(url: string): void {
  if (appLoaded || !win || !views) return
  appLoaded = true
  views.mainView.webContents.loadURL(url).catch(() => showError())
}

function showError(): void {
  if (!win || !data) return
  appLoaded = false
  views?.mainView.setVisible(false)
  win.loadFile(path.join(data.shellDir, 'error.html')).catch(() => {})
}

/** 在承载官方 dsh 的主视图上挂载安全/标题/显隐逻辑 */
function wireMainView(): void {
  if (!win || !views) return
  const contents = views.mainView.webContents

  // dsh 主文档加载完成后再显示主视图，此前露出底层启动页，避免白屏
  contents.on('did-finish-load', () => {
    if (runtime?.state.status === 'ready') views?.mainView.setVisible(true)
  })

  contents.on(
    'did-fail-load',
    (_event, errorCode, _description, validatedURL, isMainFrame) => {
      if (
        isMainFrame &&
        validatedURL.startsWith('http://127.0.0.1') &&
        errorCode !== -3 &&
        runtime?.state.status !== 'ready'
      ) {
        showError()
      }
    }
  )

  // dsh 页面里的外部链接用系统浏览器打开，本地页面不离开 127.0.0.1
  contents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url) && !/^http:\/\/127\.0\.0\.1(:\d+)?\//.test(url)) {
      void shell.openExternal(url)
      return { action: 'deny' }
    }
    return { action: 'allow' }
  })
  contents.on('will-navigate', (event, url) => {
    if (/^https?:\/\//i.test(url) && !/^http:\/\/127\.0\.0\.1:\d+\//.test(url)) {
      event.preventDefault()
      void shell.openExternal(url)
    }
  })

  contents.on('page-title-updated', (event, title) => {
    event.preventDefault()
    win?.setTitle(title ? `${title} · Witseek` : 'Witseek')
  })
}

function createWindow(shellDir: string): BrowserWindow {
  const icon = nativeImage.createFromPath(path.join(shellDir, 'icon.png'))
  const browserWindow = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 960,
    minHeight: 620,
    title: 'Witseek',
    icon,
    backgroundColor: '#0b0d10',
    show: false,
    webPreferences: {
      preload: path.join(MODULE_DIR, '..', 'preload', 'index.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false
    }
  })

  browserWindow.once('ready-to-show', () => browserWindow.show())
  browserWindow.loadFile(path.join(shellDir, 'loading.html')).catch(() => {})
  browserWindow.on('closed', () => {
    win = null
  })
  return browserWindow
}
