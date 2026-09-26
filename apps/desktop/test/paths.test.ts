import { describe, expect, it, vi } from 'vitest'

const appMock = vi.hoisted(() => ({
  isPackaged: false,
  getPath: vi.fn(() => '/home/test/.dsh/witseek/electron')
}))
vi.mock('electron', () => ({ app: appMock }))

import { dataLayout } from '../src/main/paths'

describe('dataLayout', () => {
  it('treats an empty WITSEEK_WORKSPACE as unset', () => {
    vi.stubEnv('WITSEEK_WORKSPACE', '')

    expect(dataLayout({ defaultWorkspace: '/home/test/.dsh/witseek/workspace' }).workspace)
      .toBe('/home/test/.dsh/witseek/workspace')
  })
})
