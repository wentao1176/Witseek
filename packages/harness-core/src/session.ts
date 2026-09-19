import { appendFile, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { SessionMeta, SessionRecord } from '@witseek/protocol'

/**
 * 会话存储：JSONL 追加写。
 *
 * 选 JSONL 而不是数据库，是因为它的写入是纯追加、天然可回放 ——
 * 调试 agent 时能直接看到每一步发生了什么，这对 harness 类产品比查询能力更重要。
 */
/**
 * 取会话当前的元信息。
 *
 * 以**最后一条** meta 为准，而不是第一条 ——
 * JSONL 是纯追加的，更新标题或时间靠再追加一条 meta，
 * 不回头改写历史行。若用 `find` 取第一条，界面就会一直显示建会话时的旧信息。
 */
export function latestMeta(records: SessionRecord[]): SessionMeta | undefined {
  for (let i = records.length - 1; i >= 0; i--) {
    const r = records[i]
    if (r.kind === 'meta') return r.meta
  }
  return undefined
}

export class SessionStore {
  readonly #dir: string

  constructor(dir: string) {
    this.#dir = dir
  }

  get dir(): string {
    return this.#dir
  }

  #file(id: string): string {
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error(`非法会话 id: ${id}`)
    return join(this.#dir, `${id}.jsonl`)
  }

  async init(): Promise<void> {
    await mkdir(this.#dir, { recursive: true })
  }

  async create(meta: SessionMeta): Promise<void> {
    await this.init()
    await writeFile(this.#file(meta.id), `${JSON.stringify({ kind: 'meta', meta })}\n`, 'utf8')
  }

  /** 追加一条 meta 来更新标题/时间。调用前该会话必须已 create 过。 */
  async touch(meta: SessionMeta): Promise<void> {
    await this.init()
    const file = this.#file(meta.id)
    // appendFile 在文件不存在时会**静默新建** —— 那样一个拼错的 id
    // 会凭空造出一个没有消息的空会话，混在列表里很难排查。这里显式要求它已存在。
    try {
      await stat(file)
    } catch {
      throw new Error(`会话不存在: ${meta.id}`)
    }
    await appendFile(file, `${JSON.stringify({ kind: 'meta', meta })}\n`, 'utf8')
  }

  async append(id: string, record: SessionRecord): Promise<void> {
    await this.init()
    await appendFile(this.#file(id), `${JSON.stringify(record)}\n`, 'utf8')
  }

  async read(id: string): Promise<SessionRecord[]> {
    // 必须先解析路径再进 try。把 this.#file(id) 写在 try 里面，
    // 非法 id 抛出的错误会被下面的 catch 当成"文件不存在"吞掉，
    // 路径穿越校验就形同虚设了 —— 这是被测试逮到的一个真实缺陷。
    const file = this.#file(id)
    let text: string
    try {
      text = await readFile(file, 'utf8')
    } catch {
      return []
    }
    const out: SessionRecord[] = []
    for (const line of text.split('\n')) {
      const t = line.trim()
      if (!t) continue
      try {
        out.push(JSON.parse(t) as SessionRecord)
      } catch {
        // 半行（写入中断）跳过，不让一行坏数据毁掉整个会话
      }
    }
    return out
  }

  async list(): Promise<SessionMeta[]> {
    await this.init()
    const files = await readdir(this.#dir)
    const metas: SessionMeta[] = []
    for (const f of files) {
      if (!f.endsWith('.jsonl')) continue
      const meta = latestMeta(await this.read(f.slice(0, -6)))
      if (meta) metas.push(meta)
    }
    metas.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    return metas
  }
}
