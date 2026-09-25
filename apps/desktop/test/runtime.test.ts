import { EventEmitter } from 'node:events'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { spawnMock } = vi.hoisted(() => ({ spawnMock: vi.fn() }))
vi.mock('node:child_process', () => ({ spawn: spawnMock }))

import { DshRuntime } from '../src/main/runtime'

class FakeChild extends EventEmitter {
  stdout = new EventEmitter()
  stderr = new EventEmitter()
  pid: number | null = null
  kill = vi.fn()
}

describe('DshRuntime', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    spawnMock.mockReset()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('ignores a late exit from the previous process after restart', () => {
    const children: FakeChild[] = []
    spawnMock.mockImplementation(() => {
      const child = new FakeChild()
      children.push(child)
      return child
    })

    const runtime = new DshRuntime(
      {
        nodeExecutable: 'node',
        dshBin: 'dsh',
        witseekPatchPath: 'witseek.patch.yml',
        agentPresetRoot: 'agent-presets'
      } as never,
      { dshHome: 'dsh-home', workspace: 'workspace' } as never,
      'cache'
    )

    runtime.start()
    runtime.restart()
    vi.advanceTimersByTime(700)

    expect(children).toHaveLength(2)
    children[0].emit('exit', 0, null)
    expect(runtime.state.status).toBe('starting')

    // The old exit must not clear the new process startup timer.
    vi.advanceTimersByTime(90_000)
    expect(runtime.state.status).toBe('error')
    runtime.kill()
  })
})
