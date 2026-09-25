/** Narrow bridge used only by the trusted dsh WebContentsView. */
;(() => {
  const { contextBridge, ipcRenderer } = require('electron')

  contextBridge.exposeInMainWorld('witseekDesktop', {
    setWorkspace: (workspace: string | null) =>
      ipcRenderer.invoke('desktop:set-workspace', workspace)
  })
})()
