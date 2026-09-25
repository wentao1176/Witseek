/**
 * 内置 dsh 运行时的子进程管理。
 *
 * 以独立的上游 Node 启动 `dsh web --patch <file> --no-open --port 0`：
 *  - dsh 的启动器参数必须放在首个 Web 参数之前，否则会被转发给 Web 应用；
 *  - --port 0 让操作系统分配空闲端口，避免与其它实例冲突；
 *  - dsh 启动后会在 stdout 打印带随机 token 的访问地址
 *    （形如 `dsh web: http://127.0.0.1:3080/?token=...`），解析它交给窗口加载；
 *  - 不开监听端口之外的东西，仅绑定 127.0.0.1，token 即本地访问凭据。
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { EventEmitter } from 'node:events'
import type { DataLayout, RuntimeLayout } from './paths'

const URL_RE = /(https?:\/\/127\.0\.0\.1:(\d+)\/?\?token=[A-Za-z0-9_-]+)/
const START_TIMEOUT_MS = 90_000

export type RuntimeStatus = 'starting' | 'ready' | 'error' | 'stopped'

export interface RuntimeState {
  status: RuntimeStatus
  url: string | null
  port: number | null
  message: string
}

export class DshRuntime extends EventEmitter {
  state: RuntimeState = { status: 'stopped', url: null, port: null, message: '' }
  private child: ChildProcess | null = null
  private buffer = ''
  private ready = false
  private timer: NodeJS.Timeout | null = null
  private restartTimer: NodeJS.Timeout | null = null
  private generation = 0

  constructor(
    private readonly layout: RuntimeLayout,
    private readonly data: DataLayout,
    private readonly cacheDir: string
  ) {
    super()
  }

  private setState(patch: Partial<RuntimeState>): void {
    this.state = { ...this.state, ...patch }
    this.emit('state', { ...this.state })
  }

  start(): void {
    if (this.child) return
    if (this.restartTimer) {
      clearTimeout(this.restartTimer)
      this.restartTimer = null
    }
    mkdirSync(this.data.dshHome, { recursive: true })
    mkdirSync(this.data.workspace, { recursive: true })

    const generation = ++this.generation
    this.ready = false
    this.buffer = ''
    const args = [
      this.layout.dshBin,
      'web',
      '--patch',
      this.layout.witseekPatchPath,
      '--no-open',
      '--host',
      '127.0.0.1',
      '--port',
      '0'
    ]
    const env = {
      ...process.env,
      DSH_HOME: this.data.dshHome,
      WITSEEK_AGENT_PRESET_ROOT: this.layout.agentPresetRoot,
      TEMP: this.cacheDir,
      TMP: this.cacheDir
    }

    this.setState({ status: 'starting', url: null, port: null, message: '正在启动 DeepSeek Harness 运行时…' })
    const child = spawn(this.layout.nodeExecutable, args, {
      cwd: this.data.workspace,
      env,
      windowsHide: true,
      // Unix 下让 dsh 成为新进程组组长，便于整组终止；Windows 用 taskkill /T
      detached: process.platform !== 'win32'
    })
    this.child = child
    const isCurrent = (): boolean => this.child === child && this.generation === generation

    const onData = (chunk: Buffer): void => {
      if (!isCurrent()) return
      const text = chunk.toString()
      this.buffer += text
      if (this.buffer.length > 200_000) this.buffer = this.buffer.slice(-200_000)
      this.emit('log', text)
      if (!this.ready) {
        const m = this.buffer.match(URL_RE)
        if (m) {
          this.ready = true
          if (this.timer) {
            clearTimeout(this.timer)
            this.timer = null
          }
          this.setState({
            status: 'ready',
            url: m[1],
            port: Number(m[2]),
            message: '就绪'
          })
        }
      }
    }
    child.stdout?.on('data', onData)
    child.stderr?.on('data', onData)

    child.on('error', err => {
      if (!isCurrent()) return
      this.child = null
      this.generation += 1
      if (this.timer) {
        clearTimeout(this.timer)
        this.timer = null
      }
      this.setState({ status: 'error', message: `无法启动运行时：${err.message}` })
      this.emit('fatal', err.message)
    })

    child.on('exit', (code, signal) => {
      if (!isCurrent()) return
      this.child = null
      if (this.timer) {
        clearTimeout(this.timer)
        this.timer = null
      }
      const message = `dsh 运行时已退出（code=${code ?? ''} signal=${signal ?? ''}）`
      if (!this.ready) {
        this.setState({ status: 'error', message })
        this.emit('fatal', `${message}\n${this.buffer.slice(-1500)}`)
      } else {
        this.setState({ status: 'stopped', url: null, port: null, message })
        this.emit('stopped', message)
      }
    })

    this.timer = setTimeout(() => {
      this.timer = null
      if (!isCurrent()) return
      if (!this.ready) {
        const message = '启动超时：等待 dsh 服务地址超时。'
        this.setState({ status: 'error', message })
        this.emit('fatal', `${message}\n${this.buffer.slice(-1500)}`)
        this.kill()
      }
    }, START_TIMEOUT_MS)
  }

  kill(): void {
    const child = this.child
    this.child = null
    this.generation += 1
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    if (this.restartTimer) {
      clearTimeout(this.restartTimer)
      this.restartTimer = null
    }
    if (!child || !child.pid) {
      return
    }
    try {
      if (process.platform === 'win32') {
        spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true })
      } else {
        try {
          process.kill(-child.pid, 'SIGTERM')
        } catch {
          child.kill('SIGTERM')
        }
      }
    } catch {
      /* ignore */
    }
  }

  restart(): void {
    this.kill()
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null
      this.start()
    }, 700)
  }

  recentLog(): string {
    return this.buffer.slice(-4000)
  }
}
