/**
 * Witseek-owned Windows data paths and one-time migration from the old Electron
 * profile. Moves are same-volume directory renames only: this intentionally
 * avoids copying dsh credentials, symlinks, or project files.
 */
import { app } from 'electron'
import {
  existsSync,
  mkdirSync,
  renameSync,
  rmSync,
  rmdirSync
} from 'node:fs'
import path from 'node:path'
import { dataLayout, type DataLayout } from './paths'

export type DataMigrationReason =
  | 'destination-exists'
  | 'different-volume'
  | 'move-failed'

export interface DataMigrationIssue {
  source: string
  destination: string
  reason: DataMigrationReason
}

export interface DesktopStorage {
  data: DataLayout
  cacheDir: string
  legacyUserData: string
  legacyUpdaterCacheDir: string
  migrationIssues: DataMigrationIssue[]
  initializationError: string | null
}

function sameVolume(source: string, destination: string): boolean {
  const sourceRoot = path.parse(path.resolve(source)).root.toLocaleLowerCase()
  const destinationRoot = path.parse(path.resolve(destination)).root.toLocaleLowerCase()
  return sourceRoot === destinationRoot
}

function migrationReasonText(issue: DataMigrationIssue): string {
  switch (issue.reason) {
    case 'destination-exists':
      return '目标目录已存在'
    case 'different-volume':
      return '源目录和目标目录不在同一磁盘'
    case 'move-failed':
      return '目录移动失败'
  }
}

function inspectMove(source: string, destination: string): DataMigrationIssue | null {
  if (!existsSync(source)) return null
  if (existsSync(destination)) {
    return { source, destination, reason: 'destination-exists' }
  }
  if (!sameVolume(source, destination)) {
    return { source, destination, reason: 'different-volume' }
  }
  return null
}

function cachePath(home: string): string {
  if (app.isPackaged) {
    const installDir = path.dirname(process.execPath)
    const installName = path.basename(installDir)
    return path.resolve(installDir, '..', `${installName}-cache`)
  }
  return path.join(home, '.dsh', 'witseek', 'cache')
}

/** Run after the single-instance lock and before Electron's ready event. */
export function prepareDesktopStorage(): DesktopStorage {
  const isWindows = process.platform === 'win32'
  const legacyUserData = isWindows
    ? path.join(app.getPath('appData'), '@witseek', 'desktop')
    : app.getPath('userData')
  const home = app.getPath('home')
  const legacyUpdaterCacheDir = isWindows
    ? path.join(
        process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'),
        'dsh-desktop-updater'
      )
    : ''
  const dshHome = isWindows ? path.join(home, '.dsh', 'witseek') : undefined
  const defaultWorkspace = dshHome ? path.join(dshHome, 'workspace') : undefined
  const cacheDir = isWindows ? cachePath(home) : path.join(app.getPath('userData'), 'updater-cache')
  const migrationIssues: DataMigrationIssue[] = []
  let initializationError: string | null = null

  if (!isWindows || !dshHome || !defaultWorkspace) {
    const data = dataLayout()
    return {
      data,
      cacheDir,
      legacyUserData,
      legacyUpdaterCacheDir,
      migrationIssues,
      initializationError
    }
  }

  const legacyDshHome = path.join(legacyUserData, 'dsh-home')
  const legacyWorkspace = path.join(legacyUserData, 'workspace')
  const useCustomWorkspace = Boolean(process.env.WITSEEK_WORKSPACE)

  // Preflight both moves before changing either tree. A collision or volume
  // mismatch therefore leaves the old profile and workspace untouched.
  const dshMoveIssue = inspectMove(legacyDshHome, dshHome)
  if (dshMoveIssue) migrationIssues.push(dshMoveIssue)
  const workspaceMoveIssue = useCustomWorkspace
    ? null
    : inspectMove(legacyWorkspace, defaultWorkspace)
  if (workspaceMoveIssue) migrationIssues.push(workspaceMoveIssue)
  if (
    !useCustomWorkspace &&
    existsSync(legacyDshHome) &&
    existsSync(legacyWorkspace) &&
    existsSync(path.join(legacyDshHome, 'workspace')) &&
    !workspaceMoveIssue
  ) {
    migrationIssues.push({
      source: legacyWorkspace,
      destination: path.join(dshHome, 'workspace'),
      reason: 'destination-exists'
    })
  }

  if (migrationIssues.length === 0) {
    let movedDshHome = false
    let createdDshHome = false
    let activeMove = { source: legacyDshHome, destination: dshHome }
    try {
      if (existsSync(legacyDshHome)) {
        mkdirSync(path.dirname(dshHome), { recursive: true })
        renameSync(legacyDshHome, dshHome)
        movedDshHome = true
      } else if (!existsSync(dshHome)) {
        // The workspace destination is nested under this directory. All
        // migration conflicts were checked before creating it.
        mkdirSync(dshHome, { recursive: true })
        createdDshHome = true
      }

      if (!useCustomWorkspace && existsSync(legacyWorkspace)) {
        activeMove = { source: legacyWorkspace, destination: defaultWorkspace }
        mkdirSync(path.dirname(defaultWorkspace), { recursive: true })
        renameSync(legacyWorkspace, defaultWorkspace)
      }
    } catch (error) {
      // If one rename succeeded before a later operation failed, try to put
      // that tree back. Never copy or recursively remove user data.
      if (movedDshHome && existsSync(dshHome) && !existsSync(legacyDshHome)) {
        try {
          renameSync(dshHome, legacyDshHome)
        } catch {
          migrationIssues.push({ source: dshHome, destination: legacyDshHome, reason: 'move-failed' })
        }
      } else if (createdDshHome && existsSync(dshHome)) {
        try {
          rmdirSync(dshHome)
        } catch {
          // It is not empty or cannot be removed; preserving it is safer.
        }
      }
      migrationIssues.push({ ...activeMove, reason: 'move-failed' })
      initializationError = `迁移旧数据时发生错误：${error instanceof Error ? error.message : String(error)}`
    }
  }

  const hasMigrationIssues = migrationIssues.length > 0
  const shellUserData = path.join(dshHome, 'electron')
  try {
    mkdirSync(cacheDir, { recursive: true })
    app.setPath('sessionData', cacheDir)
    if (!hasMigrationIssues) {
      mkdirSync(dshHome, { recursive: true })
      mkdirSync(process.env.WITSEEK_WORKSPACE || defaultWorkspace, { recursive: true })
      mkdirSync(shellUserData, { recursive: true })
      app.setPath('userData', shellUserData)
    }
  } catch (error) {
    initializationError = `无法准备 Witseek 数据或缓存目录：${error instanceof Error ? error.message : String(error)}`
  }

  return {
    data: dataLayout({ dshHome, defaultWorkspace }),
    cacheDir,
    legacyUserData,
    legacyUpdaterCacheDir,
    migrationIssues,
    initializationError
  }
}

/**
 * Called only once dsh is healthy. Move residual old Electron files into a
 * timestamped backup and remove only the exact stale updater download cache.
 */
export function finalizeLegacyUserData(storage: DesktopStorage): string | null {
  if (process.platform !== 'win32') return null

  let preservedPath: string | null = null
  if (existsSync(storage.legacyUserData)) {
    const backupRoot = storage.data.dshHome
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-')
    let backup = path.join(backupRoot, `legacy-desktop-backup-${timestamp}`)
    for (let suffix = 1; existsSync(backup); suffix += 1) {
      backup = path.join(backupRoot, `legacy-desktop-backup-${timestamp}-${suffix}`)
    }

    if (!sameVolume(storage.legacyUserData, backup)) {
      preservedPath = storage.legacyUserData
    } else {
      try {
        renameSync(storage.legacyUserData, backup)
        const legacyParent = path.dirname(storage.legacyUserData)
        try {
          rmdirSync(legacyParent)
        } catch {
          // Keep a non-empty @witseek folder owned by any remaining files.
        }
      } catch {
        preservedPath = storage.legacyUserData
      }
    }
  }

  if (storage.legacyUpdaterCacheDir && existsSync(storage.legacyUpdaterCacheDir)) {
    try {
      rmSync(storage.legacyUpdaterCacheDir, { recursive: true, force: true })
    } catch {
      // Cache cleanup is best effort; it must not interrupt a healthy launch.
    }
  }

  return preservedPath
}

export function describeMigrationIssue(issue: DataMigrationIssue): string {
  return `${migrationReasonText(issue)}：${issue.source} → ${issue.destination}`
}
