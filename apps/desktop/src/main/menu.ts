import { app, Menu, dialog, shell, type MenuItemConstructorOptions } from 'electron'

export interface MenuHandlers {
  restart: () => void
  openData: () => void
  openWorkspace: () => void
  toggleSidebar: () => boolean
  checkUpdates: () => void
}

export function buildMenu(handlers: MenuHandlers): Menu {
  const isMac = process.platform === 'darwin'
  const template: MenuItemConstructorOptions[] = []

  if (isMac) {
    template.push({
      label: app.name,
      submenu: [
        { role: 'about', label: '关于' },
        { type: 'separator' },
        { role: 'services', label: '服务' },
        { type: 'separator' },
        { role: 'hide', label: '隐藏' },
        { role: 'hideOthers', label: '隐藏其它' },
        { role: 'unhide', label: '显示全部' },
        { type: 'separator' },
        { role: 'quit', label: `退出 ${app.name}` }
      ]
    })
  }

  template.push({
    label: '应用',
    submenu: [
      {
        label: '重新启动后端',
        accelerator: 'CmdOrCtrl+Alt+R',
        click: () => handlers.restart()
      },
      { type: 'separator' },
      {
        label: '打开数据目录（配置 / API Key / 插件）',
        click: () => handlers.openData()
      },
      { label: '打开工作区文件夹', click: () => handlers.openWorkspace() },
      { type: 'separator' },
      ...(isMac ? [] : [{ role: 'quit' as const, label: '退出' }])
    ]
  })

  template.push({
    label: '编辑',
    submenu: [
      { role: 'undo', label: '撤销' },
      { role: 'redo', label: '重做' },
      { type: 'separator' },
      { role: 'cut', label: '剪切' },
      { role: 'copy', label: '复制' },
      { role: 'paste', label: '粘贴' },
      { role: 'selectAll', label: '全选' }
    ]
  })

  template.push({
    label: '视图',
    submenu: [
      {
        label: '文件预览边栏',
        type: 'checkbox',
        checked: false,
        accelerator: 'CmdOrCtrl+B',
        click: item => {
          item.checked = handlers.toggleSidebar()
        }
      },
      { type: 'separator' },
      { role: 'reload', label: '重新加载界面' },
      { role: 'forceReload', label: '强制重新加载' },
      { role: 'toggleDevTools', label: '开发者工具' },
      { type: 'separator' },
      { role: 'resetZoom', label: '重置缩放' },
      { role: 'zoomIn', label: '放大' },
      { role: 'zoomOut', label: '缩小' },
      { type: 'separator' },
      { role: 'togglefullscreen', label: '全屏' }
    ]
  })

  template.push({
    label: '窗口',
    submenu: [
      { role: 'minimize', label: '最小化' },
      { role: 'zoom', label: '缩放' },
      { role: 'close', label: '关闭' }
    ]
  })

  template.push({
    label: '帮助',
    submenu: [
      { label: '检查更新…', click: () => handlers.checkUpdates() },
      { type: 'separator' },
      {
        label: '关于 Witseek',
        click: () => {
          dialog.showMessageBox({
            type: 'info',
            title: '关于 Witseek',
            message: 'Witseek',
            detail:
              `版本：${app.getVersion()}\n` +
              'Witseek 是 DeepSeek Harness（dsh，MIT 许可）的桌面封装。\n' +
              '模型 API Key 请在界面的 设置 → 模型 中配置。\n' +
              'https://github.com/deepseek-ai/deepseek-harness'
          })
        }
      },
      {
        label: 'DeepSeek Harness 项目主页',
        click: () => shell.openExternal('https://github.com/deepseek-ai/deepseek-harness')
      }
    ]
  })

  return Menu.buildFromTemplate(template)
}
