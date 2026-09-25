/**
 * GitHub Releases 自动更新（electron-updater，NSIS 全量包）。
 *
 * 我们在无 Wine 环境下用自定义 makensis 产出安装包，因此由构建脚本额外生成
 * electron-updater 需要的 latest.yml（含安装包 sha512/size/path），随安装包一并
 * 上传到 GitHub Release。缺少 blockMap 时 electron-updater 自动退化为全量下载更新。
 *
 * 仅在打包后启用（dev 下没有更新源）；启动后延迟静默检查，下载完成再弹窗引导重启；
 * 菜单“检查更新…”提供手动检查并明确提示“已是最新 / 正在下载 / 失败”。
 */
import {
  app,
  dialog,
  type BrowserWindow,
  type MessageBoxOptions
} from 'electron'
import { NsisUpdater } from 'electron-updater'
import path from 'node:path'

const GITHUB_FEED = {
  provider: 'github' as const,
  owner: 'wentao1176',
  repo: 'Witseek'
}

let configured = false
let updater: NsisUpdater | null = null

type WinGetter = () => BrowserWindow | null

/** 有父窗口就作为 sheet/模态弹出，否则退化为无窗口消息框 */
function box(getWin: WinGetter, options: MessageBoxOptions) {
  const win = getWin()
  return win ? dialog.showMessageBox(win, options) : dialog.showMessageBox(options)
}

function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map(n => parseInt(n, 10) || 0)
  const pb = b.split('.').map(n => parseInt(n, 10) || 0)
  const len = Math.max(pa.length, pb.length)
  for (let i = 0; i < len; i++) {
    const da = pa[i] ?? 0
    const db = pb[i] ?? 0
    if (da !== db) return da - db
  }
  return 0
}

export function setupUpdater(getWin: WinGetter, cacheDir: string): void {
  if (!app.isPackaged || configured) return
  configured = true

  updater = new NsisUpdater(GITHUB_FEED, {
    get version() { return app.getVersion() },
    get name() { return app.getName() },
    get isPackaged() { return app.isPackaged },
    get appUpdateConfigPath() {
      return app.isPackaged
        ? path.join(process.resourcesPath, 'app-update.yml')
        : path.join(app.getAppPath(), 'dev-app-update.yml')
    },
    get userDataPath() { return app.getPath('userData') },
    get baseCachePath() { return cacheDir },
    whenReady: () => app.whenReady(),
    relaunch: () => app.relaunch(),
    quit: () => app.quit(),
    onQuit: handler => app.once('quit', (_event, exitCode) => handler(exitCode))
  })
  updater.autoDownload = true
  updater.autoInstallOnAppQuit = true
  updater.allowDowngrade = false

  updater.on('update-downloaded', info => {
    void box(getWin, {
      type: 'info',
      title: '更新已就绪',
      message: `新版本 ${info.version} 已下载完成`,
      detail: '重启 Witseek 后将完成安装。',
      buttons: ['立即重启并安装', '稍后'],
      defaultId: 0,
      cancelId: 1
    }).then(res => {
      if (res.response === 0) updater?.quitAndInstall()
    })
  })

  updater.on('error', err => {
    console.error('[updater] 更新检查失败：', err?.message ?? err)
  })

  setTimeout(() => {
    updater?.checkForUpdates().catch(err => {
      console.error('[updater] 启动检查失败：', err?.message ?? err)
    })
  }, 6000)
}

export async function checkForUpdatesManual(getWin: WinGetter): Promise<void> {
  if (!app.isPackaged) {
    await box(getWin, {
      type: 'info',
      title: '检查更新',
      message: '开发环境不检查更新',
      detail: '自动更新仅在安装后的正式版本中生效。',
      buttons: ['知道了']
    })
    return
  }

  if (!updater) {
    await box(getWin, {
      type: 'warning',
      title: '检查更新',
      message: '更新器尚未就绪',
      detail: '请先解决启动页面显示的数据目录问题，再重试。',
      buttons: ['知道了']
    })
    return
  }

  try {
    const result = await updater.checkForUpdates()
    const latest = result?.updateInfo?.version
    if (!latest) {
      await box(getWin, {
        type: 'warning',
        title: '检查更新',
        message: '暂未获取到更新信息',
        buttons: ['知道了']
      })
      return
    }
    if (compareVersions(latest, app.getVersion()) > 0) {
      await box(getWin, {
        type: 'info',
        title: '检查更新',
        message: `发现新版本 ${latest}`,
        detail: '正在后台下载，完成后会提示你重启安装。',
        buttons: ['好的']
      })
    } else {
      await box(getWin, {
        type: 'info',
        title: '检查更新',
        message: '已是最新版本',
        detail: `当前版本 ${app.getVersion()}。`,
        buttons: ['好的']
      })
    }
  } catch (err) {
    await box(getWin, {
      type: 'error',
      title: '检查更新失败',
      message: '无法连接到更新服务器',
      detail: err instanceof Error ? err.message : String(err),
      buttons: ['知道了']
    })
  }
}
