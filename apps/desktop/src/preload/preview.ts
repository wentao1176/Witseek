/**
 * 文件预览栏 preload：在 sandbox + contextIsolation 下，仅向预览页暴露
 * 白名单的工作区浏览/预览能力。所有文件访问都在主进程 preview-fs.ts 中受限处理。
 * 输出为 CJS（preview.cjs）。IIFE 包裹以隔离作用域。
 */
;(() => {
  const { contextBridge, ipcRenderer } = require('electron')

  interface RootInfo {
    root: string
    rel: string
    sep: string
    platform: string
    name: string
  }

  const api = {
    root: () => ipcRenderer.invoke('preview:root'),
    list: (rel: string) => ipcRenderer.invoke('preview:list', rel),
    read: (rel: string) => ipcRenderer.invoke('preview:read', rel),
    gitStatus: () => ipcRenderer.invoke('preview:git-status'),
    gitDiff: (rel: string) => ipcRenderer.invoke('preview:git-diff', rel),
    pick: () => ipcRenderer.invoke('preview:pick'),
    reveal: (rel: string) => ipcRenderer.invoke('preview:reveal', rel),
    open: (rel: string) => ipcRenderer.invoke('preview:open', rel),
    openAbs: (abs: string) => ipcRenderer.invoke('preview:open-abs', abs),
    revealAbs: (abs: string) => ipcRenderer.invoke('preview:reveal-abs', abs),
    openRoot: () => ipcRenderer.invoke('preview:open-root'),
    resize: (width: number) => ipcRenderer.invoke('preview:resize', width),
    onVisibility: (cb: (open: boolean) => void) => {
      const handler = (_event: unknown, open: boolean) => cb(open)
      ipcRenderer.on('preview:visibility', handler)
      return () => ipcRenderer.removeListener('preview:visibility', handler)
    },
    onWorkspace: (cb: (root: RootInfo) => void) => {
      const handler = (_event: unknown, root: RootInfo) => cb(root)
      ipcRenderer.on('preview:workspace', handler)
      return () => ipcRenderer.removeListener('preview:workspace', handler)
    }
  }

  contextBridge.exposeInMainWorld('witseekPreview', api)
})()
