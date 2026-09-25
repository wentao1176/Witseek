import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const desktopDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

describe('Windows updater package resources', () => {
  it('ships the app-update.yml that electron-updater reads before download', () => {
    const desktopPackage = JSON.parse(readFileSync(path.join(desktopDir, 'package.json'), 'utf8'))
    const resources = desktopPackage.build.extraResources as Array<{ from: string; to: string }>
    const updateResource = resources.find(item => item.from === 'resources/app-update.yml')
    const updateConfig = readFileSync(path.join(desktopDir, 'resources', 'app-update.yml'), 'utf8')

    expect(updateResource).toEqual({ from: 'resources/app-update.yml', to: 'app-update.yml' })
    expect(updateConfig).toMatch(/^provider: github$/m)
    expect(updateConfig).toMatch(/^owner: wentao1176$/m)
    expect(updateConfig).toMatch(/^repo: Witseek$/m)
    expect(updateConfig).toMatch(/^updaterCacheDirName: Witseek-updater$/m)
  })
})
