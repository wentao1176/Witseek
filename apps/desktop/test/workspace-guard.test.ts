import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import { describe, expect, it, vi } from 'vitest'

interface WorkspaceApi {
  create(input: { path: string }): Promise<{ path: string }>
}

function loadClientPlugin(workspaces: WorkspaceApi, validateWorkspace: (path: string) => Promise<void>): void {
  const source = readFileSync(
    new URL('../resources/dsh-client-witseek-desktop/client.js', import.meta.url),
    'utf8'
  )
  let plugin: { apply(ctx: unknown): void } | undefined
  const context = vm.createContext({
    window: {
      __ModuleLoader__: {
        load: ({ factory }: { factory: (require: (name: string) => unknown) => { apply(ctx: unknown): void } }) => {
          plugin = factory(() => ({ useEffect: vi.fn() }))
        }
      }
    },
    witseekDesktop: { validateWorkspace }
  })
  vm.runInContext(source, context)
  if (!plugin) throw new Error('Witseek dsh client plugin did not load')

  const slots = {
    inject: vi.fn((_name: string, register: () => void) => register()),
    register: vi.fn()
  }
  plugin.apply({
    get: (name: string) => name === 'workspaces' ? workspaces : undefined,
    slots,
    effect: (effect: () => void) => effect()
  })
}

describe('Witseek dsh workspace guard', () => {
  it('validates a workspace before dsh registers it', async () => {
    const calls: string[] = []
    const validateWorkspace = vi.fn(async (candidate: string) => {
      calls.push(`validate:${candidate}`)
      if (candidate === '/install') throw new Error('workspace overlaps install directory')
    })
    const createWorkspace = vi.fn(async ({ path }: { path: string }) => {
      calls.push(`create:${path}`)
      return { path }
    })
    const workspaces: WorkspaceApi = { create: createWorkspace }

    loadClientPlugin(workspaces, validateWorkspace)

    await expect(workspaces.create({ path: '/install' })).rejects.toThrow(/overlaps install/)
    expect(createWorkspace).not.toHaveBeenCalled()
    await expect(workspaces.create({ path: '/project' })).resolves.toEqual({ path: '/project' })
    expect(calls).toEqual(['validate:/install', 'validate:/project', 'create:/project'])
  })
})
