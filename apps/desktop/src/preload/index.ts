/**
 * 壳 preload：只给本地 loading/error 页暴露最小的生命周期控制 API。
 * 加载官方 dsh 页面（http://127.0.0.1）时该对象虽也存在，但 dsh 不会使用，无副作用。
 * sandbox 下仅使用 electron 白名单 API，输出为 CJS。用 IIFE 包裹以避免与
 * preview.cjs 在类型检查阶段共享全局作用域而重复声明。
 */
;(() => {
  const { contextBridge, ipcRenderer } = require('electron')

  const api = {
    getState: () => ipcRenderer.invoke('shell:get-state'),
    retry: () => ipcRenderer.invoke('shell:retry'),
    openDataFolder: () => ipcRenderer.invoke('shell:open-data'),
    openWorkspace: () => ipcRenderer.invoke('shell:open-workspace'),
    onState: (cb: (state: unknown) => void) => {
      const handler = (_event: unknown, state: unknown) => cb(state)
      ipcRenderer.on('shell:state', handler)
      return () => ipcRenderer.removeListener('shell:state', handler)
    },
    onLog: (cb: (text: string) => void) => {
      const handler = (_event: unknown, text: string) => cb(text)
      ipcRenderer.on('shell:log', handler)
      return () => ipcRenderer.removeListener('shell:log', handler)
    }
  }

  contextBridge.exposeInMainWorld('witseekShell', api)
})()
