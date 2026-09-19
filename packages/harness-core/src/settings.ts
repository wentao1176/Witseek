import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { AppSettings, PermissionMode } from '@witseek/protocol'

export const DEFAULT_PERMISSION_MODE: PermissionMode = 'confirm'

const VALID_MODES: readonly PermissionMode[] = ['read-only', 'confirm', 'auto']

function isValidMode(m: unknown): m is PermissionMode {
  return typeof m === 'string' && (VALID_MODES as readonly string[]).includes(m)
}

/**
 * 应用设置的 JSON 持久化（目前只有审批模式）。
 *
 * - 放在 userData 而不是工作区：设置是"这个用户/这台机器"的偏好，
 *   不应污染用户的项目目录，也不应被 git 跟踪。
 * - 写入走临时文件 + rename 的原子替换，避免写到一半崩溃留下半份 JSON。
 * - 文件不存在或损坏时回落到默认值，绝不因为设置问题让应用起不来。
 */
export class SettingsStore {
  readonly #file: string
  #cache: AppSettings | null = null

  constructor(file: string) {
    this.#file = file
  }

  get file(): string {
    return this.#file
  }

  async load(): Promise<AppSettings> {
    if (this.#cache) return this.#cache
    let settings: AppSettings = { permissionMode: DEFAULT_PERMISSION_MODE, updatedAt: '' }
    try {
      const raw = await readFile(this.#file, 'utf8')
      const parsed = JSON.parse(raw) as Partial<AppSettings>
      if (isValidMode(parsed.permissionMode)) {
        settings = { permissionMode: parsed.permissionMode, updatedAt: parsed.updatedAt ?? '' }
      }
    } catch {
      // 首次启动（文件不存在）或文件损坏：静默回落默认
    }
    this.#cache = settings
    return settings
  }

  async save(patch: Partial<AppSettings>): Promise<AppSettings> {
    const cur = await this.load()
    const next: AppSettings = { ...cur, ...patch, updatedAt: new Date().toISOString() }
    const dir = dirname(this.#file)
    await mkdir(dir, { recursive: true })
    const tmp = join(dir, `.settings-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}.tmp`)
    await writeFile(tmp, `${JSON.stringify(next, null, 2)}\n`, 'utf8')
    await rename(tmp, this.#file)
    this.#cache = next
    return next
  }
}
