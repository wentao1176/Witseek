/**
 * 双 WebContentsView 布局：
 *   mainView    —— 官方 dsh Web UI（启动前隐藏，露出底层启动页）
 *   previewView —— 壳自带的右侧文件预览栏，可折叠、可拖拽调宽
 *
 * BrowserWindow 自身的 webContents 承载启动/错误本地页（最底层）；两个 child view
 * 叠加在其上。侧栏关闭时宽度为 0（保留视图状态，再次打开不丢文件树展开/已开文件）。
 */
import { BrowserWindow, WebContentsView } from 'electron'

export interface ViewBundle {
  mainView: WebContentsView
  previewView: WebContentsView
  sidebarOpen: boolean
  sidebarWidth: number
  layout: () => void
  setSidebarOpen: (open: boolean) => void
  toggleSidebar: () => boolean
  setSidebarWidth: (width: number) => void
}

const DEFAULT_SIDEBAR_WIDTH = 440
const MIN_SIDEBAR_WIDTH = 320

export function createViews(
  win: BrowserWindow,
  opts: {
    rendererEntry: string
    rendererIsUrl: boolean
    previewPreload: string
    mainPreload: string
  }
): ViewBundle {
  const mainView = new WebContentsView({
    webPreferences: {
      preload: opts.mainPreload,
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: false
    }
  })
  mainView.setBackgroundColor('#0b0d10')
  mainView.setVisible(false)

  const previewView = new WebContentsView({
    webPreferences: {
      preload: opts.previewPreload,
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: false
    }
  })
  previewView.setBackgroundColor('#0b0d10')

  win.contentView.addChildView(mainView)
  win.contentView.addChildView(previewView)

  if (opts.rendererIsUrl) {
    void previewView.webContents.loadURL(opts.rendererEntry)
  } else {
    void previewView.webContents.loadFile(opts.rendererEntry)
  }

  // 预览栏不允许任意导航/弹窗，始终停留在本地预览页
  previewView.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  previewView.webContents.on('will-navigate', event => event.preventDefault())

  const state = {
    sidebarOpen: false,
    sidebarWidth: DEFAULT_SIDEBAR_WIDTH
  }

  const layout = (): void => {
    const [width, height] = win.getContentSize()
    const sideWidth = state.sidebarOpen ? state.sidebarWidth : 0
    mainView.setBounds({ x: 0, y: 0, width: width - sideWidth, height })
    previewView.setBounds({
      x: width - sideWidth,
      y: 0,
      width: sideWidth,
      height
    })
  }

  const setSidebarOpen = (open: boolean): void => {
    if (state.sidebarOpen === open) return
    state.sidebarOpen = open
    layout()
    previewView.webContents.send('preview:visibility', open)
  }

  const toggleSidebar = (): boolean => {
    setSidebarOpen(!state.sidebarOpen)
    return state.sidebarOpen
  }

  const setSidebarWidth = (width: number): void => {
    const [winWidth] = win.getContentSize()
    const max = Math.max(MIN_SIDEBAR_WIDTH, Math.round(winWidth * 0.7))
    state.sidebarWidth = Math.min(max, Math.max(MIN_SIDEBAR_WIDTH, Math.round(width)))
    layout()
  }

  win.on('resize', layout)

  // 初始布局（侧栏收起，主视图占满）
  layout()

  return {
    mainView,
    previewView,
    get sidebarOpen() {
      return state.sidebarOpen
    },
    get sidebarWidth() {
      return state.sidebarWidth
    },
    layout,
    setSidebarOpen,
    toggleSidebar,
    setSidebarWidth
  }
}
