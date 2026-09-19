#!/usr/bin/env bash
# scaffold_p2_tests.sh —— 生成 P2 测试与根配置
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

echo "== 根 package.json =="

w package.json <<'EOF'
{
  "name": "witseek",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "DeepSeek harness desktop application",
  "scripts": {
    "dev": "pnpm --filter @witseek/desktop dev",
    "build": "pnpm --filter @witseek/desktop build",
    "typecheck": "pnpm -r --if-present typecheck",
    "test": "vitest run",
    "test:watch": "vitest",
    "demo:kernel": "tsx scripts/demo-kernel.mts"
  },
  "devDependencies": {
    "@witseek/harness-core": "workspace:*",
    "@witseek/provider-deepseek": "workspace:*",
    "@witseek/tools": "workspace:*",
    "tsx": "^4.23.13",
    "typescript": "^7.0.2",
    "vitest": "^5.0.1"
  }
}
EOF

echo "== packages/provider-deepseek 测试 =="

w packages/provider-deepseek/test/sse.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import { parseSse } from '../src/sse.js'

function streamOf(chunks: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder()
  return new ReadableStream({
    start(controller) {
      for (const c of chunks) controller.enqueue(enc.encode(c))
      controller.close()
    }
  })
}

async function collect(s: ReadableStream<Uint8Array>): Promise<string[]> {
  const out: string[] = []
  for await (const d of parseSse(s)) out.push(d)
  return out
}

describe('parseSse', () => {
  it('解析基本事件', async () => {
    const got = await collect(streamOf(['data: {"a":1}\n\n', 'data: {"b":2}\n\n']))
    expect(got).toEqual(['{"a":1}', '{"b":2}'])
  })

  it('处理 CRLF 换行', async () => {
    const got = await collect(streamOf(['data: {"a":1}\r\n\r\n']))
    expect(got).toEqual(['{"a":1}'])
  })

  it('分片切在分隔符中间也不丢事件', async () => {
    // 这是最容易出错的场景：一个 chunk 以 \r 结尾，下一个以 \n 开头
    const got = await collect(streamOf(['data: {"a":1}\r', '\n\r', '\ndata: {"b":2}\n\n']))
    expect(got).toEqual(['{"a":1}', '{"b":2}'])
  })

  it('多行 data 合并', async () => {
    const got = await collect(streamOf(['data: line1\ndata: line2\n\n']))
    expect(got).toEqual(['line1\nline2'])
  })

  it('忽略非 data 字段', async () => {
    const got = await collect(streamOf(['event: ping\nid: 3\ndata: x\n\n']))
    expect(got).toEqual(['x'])
  })

  it('末尾没有空行也能收到', async () => {
    const got = await collect(streamOf(['data: tail']))
    expect(got).toEqual(['tail'])
  })

  it('识别 [DONE]', async () => {
    const got = await collect(streamOf(['data: [DONE]\n\n']))
    expect(got).toEqual(['[DONE]'])
  })
})
EOF

w packages/provider-deepseek/test/client.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import type { ChatMessage, StreamEvent } from '@witseek/protocol'
import { DeepSeekClient } from '../src/client.js'

function sseStream(lines: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder()
  return new ReadableStream({
    start(c) {
      for (const l of lines) c.enqueue(enc.encode(`data: ${l}\n\n`))
      c.close()
    }
  })
}

function fakeFetch(lines: string[], capture?: { body?: unknown }): typeof fetch {
  return (async (_url: string | URL | Request, init?: RequestInit) => {
    if (capture && init?.body) capture.body = JSON.parse(init.body as string)
    return new Response(sseStream(lines), { status: 200 })
  }) as unknown as typeof fetch
}

async function collect(gen: AsyncIterable<StreamEvent>): Promise<StreamEvent[]> {
  const out: StreamEvent[] = []
  for await (const e of gen) out.push(e)
  return out
}

describe('DeepSeekClient', () => {
  it('分离 reasoning 与 content', async () => {
    const client = new DeepSeekClient({
      apiKey: 'k',
      fetchImpl: fakeFetch([
        '{"choices":[{"delta":{"reasoning_content":"想一想"}}]}',
        '{"choices":[{"delta":{"content":"答案"}}]}',
        '{"choices":[{"delta":{},"finish_reason":"stop"}]}'
      ])
    })

    const events = await collect(
      client.stream({ model: 'deepseek-reasoner', messages: [{ role: 'user', content: 'hi' }] })
    )

    const reasoning = events.filter((e) => e.type === 'reasoning-delta').map((e) => (e as { text: string }).text)
    const content = events.filter((e) => e.type === 'content-delta').map((e) => (e as { text: string }).text)
    expect(reasoning.join('')).toBe('想一想')
    expect(content.join('')).toBe('答案')
  })

  it('按 index 拼装分片的 tool_calls', async () => {
    const client = new DeepSeekClient({
      apiKey: 'k',
      fetchImpl: fakeFetch([
        // id/name 只在首片出现，arguments 跨多片累加
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}',
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"a.txt\\"}"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}'
      ])
    })

    const events = await collect(
      client.stream({ model: 'deepseek-chat', messages: [{ role: 'user', content: 'x' }] })
    )
    const call = events.find((e) => e.type === 'tool-call')
    expect(call).toBeDefined()
    expect((call as { call: { id: string; name: string; arguments: string } }).call).toEqual({
      id: 'c1',
      name: 'read_file',
      arguments: '{"path":"a.txt"}'
    })
  })

  it('不回传 reasoning_content', async () => {
    const capture: { body?: unknown } = {}
    const client = new DeepSeekClient({ apiKey: 'k', fetchImpl: fakeFetch([], capture) })

    const history: ChatMessage[] = [
      { role: 'assistant', content: '上一轮回答', reasoning: '上一轮的思维链' }
    ]
    await collect(client.stream({ model: 'deepseek-reasoner', messages: history }))

    const body = capture.body as { messages: Array<Record<string, unknown>> }
    expect(body.messages[0].content).toBe('上一轮回答')
    expect(body.messages[0].reasoning_content).toBeUndefined()
  })

  it('API 报错时抛出带状态码的错误', async () => {
    const client = new DeepSeekClient({
      apiKey: 'k',
      fetchImpl: (async () =>
        new Response('{"error":"bad key"}', { status: 401, statusText: 'Unauthorized' })) as unknown as typeof fetch
    })
    await expect(
      collect(client.stream({ model: 'deepseek-chat', messages: [{ role: 'user', content: 'x' }] }))
    ).rejects.toThrow(/401/)
  })

  it('构造时缺少 apiKey 直接报错', () => {
    expect(() => new DeepSeekClient({ apiKey: '' })).toThrow(/apiKey/)
  })
})
EOF

echo "== packages/tools 测试 =="

w packages/tools/test/glob.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import { globToRegExp, matchGlob } from '../src/glob.js'

describe('globToRegExp', () => {
  it('* 不跨目录', () => {
    expect(matchGlob('*.ts', 'a.ts')).toBe(true)
    expect(matchGlob('*.ts', 'src/a.ts')).toBe(false)
  })

  it('** 跨任意层目录', () => {
    expect(matchGlob('**/*.ts', 'a.ts')).toBe(true)
    expect(matchGlob('**/*.ts', 'a/b/c.ts')).toBe(true)
    expect(matchGlob('src/**/*.ts', 'src/a/b.ts')).toBe(true)
    expect(matchGlob('src/**/*.ts', 'lib/a.ts')).toBe(false)
  })

  it('? 匹配单个字符', () => {
    expect(matchGlob('a?.ts', 'ab.ts')).toBe(true)
    expect(matchGlob('a?.ts', 'abc.ts')).toBe(false)
  })

  it('{a,b} 分支', () => {
    expect(matchGlob('*.{ts,js}', 'a.ts')).toBe(true)
    expect(matchGlob('*.{ts,js}', 'a.js')).toBe(true)
    expect(matchGlob('*.{ts,js}', 'a.py')).toBe(false)
  })

  it('正则元字符被当作字面量', () => {
    expect(matchGlob('a+b.ts', 'a+b.ts')).toBe(true)
    expect(matchGlob('a+b.ts', 'aab.ts')).toBe(false)
  })

  it('锚定首尾，不做子串匹配', () => {
    const re = globToRegExp('a.ts')
    expect(re.test('a.ts')).toBe(true)
    expect(re.test('xa.ts')).toBe(false)
    expect(re.test('a.tsx')).toBe(false)
  })
})
EOF

w packages/tools/test/fs.test.ts <<'EOF'
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext } from '@witseek/protocol'
import { applyEdit, editFileTool, listDirTool, readFileTool, writeFileTool } from '../src/fs.js'
import { resolveInWorkspace } from '../src/paths.js'

let root: string
let ctx: ToolContext

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-fs-'))
  ctx = { workspaceRoot: root }
})

afterEach(() => {
  // 临时目录由系统回收
})

describe('resolveInWorkspace', () => {
  it('识别工作区内的相对路径', () => {
    expect(resolveInWorkspace('/w', 'a/b.txt').outside).toBe(false)
  })

  it('识别越界路径', () => {
    expect(resolveInWorkspace('/w', '../outside.txt').outside).toBe(true)
    expect(resolveInWorkspace('/w', '/etc/passwd').outside).toBe(true)
  })

  it('不会被 a/../.. 之类的绕法骗过', () => {
    expect(resolveInWorkspace('/w/sub', '../../x').outside).toBe(true)
  })
})

describe('read_file', () => {
  it('返回带行号的内容', async () => {
    await writeFile(join(root, 'a.txt'), 'l1\nl2\nl3', 'utf8')
    const r = await readFileTool.execute({ path: 'a.txt' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('1\tl1')
    expect(r.output).toContain('3\tl3')
  })

  it('支持 offset / limit', async () => {
    await writeFile(join(root, 'a.txt'), 'l1\nl2\nl3\nl4', 'utf8')
    const r = await readFileTool.execute({ path: 'a.txt', offset: 2, limit: 2 }, ctx)
    expect(r.output).toContain('2\tl2')
    expect(r.output).toContain('3\tl3')
    expect(r.output).not.toContain('l4')
  })

  it('文件不存在时报错而不是抛出', async () => {
    await expect(readFileTool.execute({ path: 'nope.txt' }, ctx)).rejects.toThrow()
  })

  it('缺少 path 参数时报错', async () => {
    await expect(readFileTool.execute({}, ctx)).rejects.toThrow(/path/)
  })
})

describe('write_file', () => {
  it('自动创建父目录', async () => {
    const r = await writeFileTool.execute({ path: 'deep/nested/x.txt', content: 'hi' }, ctx)
    expect(r.ok).toBe(true)
    expect(await readFile(join(root, 'deep/nested/x.txt'), 'utf8')).toBe('hi')
  })
})

describe('edit_file', () => {
  it('唯一匹配时替换成功', async () => {
    await writeFile(join(root, 'a.txt'), 'foo\nbar\nbaz', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'bar', newText: 'BAR' }, ctx)
    expect(r.ok).toBe(true)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('foo\nBAR\nbaz')
  })

  it('多处匹配且未指定 replaceAll 时拒绝', async () => {
    await writeFile(join(root, 'a.txt'), 'x\nx\nx', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'x', newText: 'y' }, ctx)
    expect(r.ok).toBe(false)
    expect(r.output).toMatch(/3 次/)
    // 确认没有写坏文件
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('x\nx\nx')
  })

  it('replaceAll 时全部替换', async () => {
    await writeFile(join(root, 'a.txt'), 'x\nx\nx', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'x', newText: 'y', replaceAll: true }, ctx)
    expect(r.ok).toBe(true)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('y\ny\ny')
  })

  it('找不到原文时返回失败而非抛错', async () => {
    await writeFile(join(root, 'a.txt'), 'abc', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'zzz', newText: 'q' }, ctx)
    expect(r.ok).toBe(false)
  })
})

describe('list_dir', () => {
  it('目录在前，且跳过 node_modules', async () => {
    // 夹具必须自己建父目录：node:fs 的 writeFile 不会补建中间路径，
    // 早先漏了 mkdir，报的是 ENOENT 而不是断言失败，很容易误判成实现有问题。
    await mkdir(join(root, 'zdir'), { recursive: true })
    await writeFile(join(root, 'b.txt'), '', 'utf8')
    await writeFile(join(root, 'a.txt'), '', 'utf8')
    await mkdir(join(root, 'node_modules'), { recursive: true })
    await writeFile(join(root, 'node_modules/x.txt'), '', 'utf8')
    const r = await listDirTool.execute({ path: '.', depth: 1 }, ctx)
    expect(r.output).not.toContain('node_modules')
    // zdir 字典序排在 a.txt / b.txt 之后，却必须显示在它们前面，这才叫"目录在前"
    expect(r.output.indexOf('zdir')).toBeLessThan(r.output.indexOf('a.txt'))
  })
})

describe('applyEdit', () => {
  // 这是 edit_file 的纯函数内核。UI 的 diff 预览直接调它，
  // 所以必须保证"预览所依据的替换"和"真正写入的替换"完全一致。
  it('唯一匹配时替换并给出结果文本', () => {
    const r = applyEdit('a\nb\nc', 'b', 'B')
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.text).toBe('a\nB\nc')
    expect(r.applied).toBe(1)
  })

  it('多处匹配且未开 replaceAll 时拒绝，并报出出现次数', () => {
    const r = applyEdit('x\nx\nx', 'x', 'y')
    expect(r.ok).toBe(false)
    if (r.ok) return
    expect(r.error).toContain('3')
  })

  it('replaceAll 时全部替换', () => {
    const r = applyEdit('x\nx\nx', 'x', 'y', true)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.text).toBe('y\ny\ny')
    expect(r.applied).toBe(3)
  })

  it('找不到原文时失败而不是原样返回', () => {
    const r = applyEdit('abc', 'zzz', 'y')
    expect(r.ok).toBe(false)
  })

  it('oldText 为空视为非法输入', () => {
    // 空串会被 split 成"每个字符之间"，能匹配出 len+1 处，
    // 若不拦下来会得到一个看似成功但毫无意义的替换
    const r = applyEdit('abc', '', 'y')
    expect(r.ok).toBe(false)
  })

  it('与 edit_file 工具的执行结果一致', async () => {
    const original = 'line1\nline2\nline3\n'
    await writeFile(join(root, 'sample.txt'), original, 'utf8')
    const pure = applyEdit(original, 'line2', 'LINE-TWO')
    expect(pure.ok).toBe(true)
    if (!pure.ok) return

    await editFileTool.execute({ path: 'sample.txt', oldText: 'line2', newText: 'LINE-TWO' }, ctx)
    expect(await readFile(join(root, 'sample.txt'), 'utf8')).toBe(pure.text)
  })
})
EOF

w packages/tools/test/search.test.ts <<'EOF'
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext } from '@witseek/protocol'
import { globTool, grepTool } from '../src/search.js'

let root: string
let ctx: ToolContext

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-search-'))
  await writeFile(join(root, 'a.ts'), 'const x = 1\nexport default x\n', 'utf8')
  // sub/ 必须显式创建：writeFile 不会补建中间路径。
  // 少了这一行，7 个用例会一起报 ENOENT，看起来像实现挂了，其实只是夹具缺目录。
  await mkdir(join(root, 'sub'), { recursive: true })
  await writeFile(join(root, 'sub/b.ts'), 'const y = 2\n', 'utf8')
  await writeFile(join(root, 'c.md'), '# title\nconst inMarkdown = 3\n', 'utf8')
  // ctx 必须赋值。漏了这一行，只有"提前返回"的用例（缺 pattern、非法正则）
  // 能侥幸通过，其余全在 ctx.workspaceRoot 上抛 TypeError —— 很容易被误读成实现 bug。
  ctx = { workspaceRoot: root }
})

describe('glob 工具', () => {
  it('按扩展名查找', async () => {
    const r = await globTool.execute({ pattern: '**/*.ts' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('a.ts')
    expect(r.output).toContain('sub/b.ts')
    expect(r.output).not.toContain('c.md')
  })

  it('无匹配时返回提示而非空串', async () => {
    const r = await globTool.execute({ pattern: '**/*.zzz' }, ctx)
    expect(r.output).toBe('(无匹配)')
  })

  it('缺少 pattern 时返回失败', async () => {
    const r = await globTool.execute({}, ctx)
    expect(r.ok).toBe(false)
  })
})

describe('grep 工具', () => {
  it('返回文件与行号', async () => {
    const r = await grepTool.execute({ pattern: 'const', glob: '**/*.ts' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('a.ts:1:')
    expect(r.output).toContain('sub/b.ts:1:')
    expect(r.output).not.toContain('c.md')
  })

  it('glob 限定生效', async () => {
    const r = await grepTool.execute({ pattern: 'const', glob: '**/*.md' }, ctx)
    expect(r.output).toContain('c.md:2:')
  })

  it('非法正则返回失败而不是抛错', async () => {
    const r = await grepTool.execute({ pattern: '([' }, ctx)
    expect(r.ok).toBe(false)
    expect(r.output).toMatch(/正则/)
  })

  it('忽略大小写', async () => {
    const noCase = await grepTool.execute({ pattern: 'CONST', glob: '**/*.ts' }, ctx)
    expect(noCase.output).toBe('(无匹配)')
    const withCase = await grepTool.execute({ pattern: 'CONST', glob: '**/*.ts', ignoreCase: true }, ctx)
    expect(withCase.output).toContain('a.ts:1:')
  })
})
EOF

w packages/tools/test/shell.test.ts <<'EOF'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext } from '@witseek/protocol'
import { runCommandTool } from '../src/shell.js'

let ctx: ToolContext

beforeEach(async () => {
  ctx = { workspaceRoot: await mkdtemp(join(tmpdir(), 'witseek-sh-')) }
})

describe('run_command', () => {
  it('成功命令返回退出码 0', async () => {
    const r = await runCommandTool.execute({ command: 'echo hello' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('hello')
    expect(r.meta?.exitCode).toBe(0)
  })

  it('失败命令 ok=false 但仍有输出', async () => {
    const r = await runCommandTool.execute({ command: 'exit 3' }, ctx)
    expect(r.ok).toBe(false)
    expect(r.meta?.exitCode).toBe(3)
  })

  it('stderr 被捕获', async () => {
    const r = await runCommandTool.execute({ command: 'echo oops 1>&2' }, ctx)
    expect(r.output).toContain('stderr')
    expect(r.output).toContain('oops')
  })

  it('超时被杀掉', async () => {
    const r = await runCommandTool.execute({ command: 'sleep 5', timeoutMs: 800 }, ctx)
    expect(r.ok).toBe(false)
    expect(r.meta?.timedOut).toBe(true)
  }, 10_000)

  it('缺少 command 返回失败', async () => {
    const r = await runCommandTool.execute({}, ctx)
    expect(r.ok).toBe(false)
  })
})
EOF

echo "== packages/harness-core 测试 =="

w packages/harness-core/test/permission.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import type { ToolDefinition } from '@witseek/protocol'
import { PermissionEngine, describeApproval } from '../src/permission.js'

const ro: ToolDefinition = {
  name: 'read_file',
  description: '',
  parameters: { type: 'object' },
  readOnly: true,
  execute: async () => ({ ok: true, output: '' })
}

const rw: ToolDefinition = {
  name: 'write_file',
  description: '',
  parameters: { type: 'object' },
  readOnly: false,
  execute: async () => ({ ok: true, output: '' })
}

const sh: ToolDefinition = { ...rw, name: 'run_command' }

describe('PermissionEngine', () => {
  it('只读工具在任何模式下都放行', () => {
    for (const mode of ['read-only', 'confirm', 'auto'] as const) {
      expect(new PermissionEngine(mode).verdict(ro, false)).toBe('allow')
    }
  })

  it('read-only 模式下写操作是拒绝而不是询问', () => {
    expect(new PermissionEngine('read-only').verdict(rw, false)).toBe('deny')
  })

  it('confirm 模式下写操作需要询问', () => {
    expect(new PermissionEngine('confirm').verdict(rw, false)).toBe('ask')
  })

  it('auto 模式下工作区内放行', () => {
    expect(new PermissionEngine('auto').verdict(rw, false)).toBe('allow')
  })

  it('auto 模式下越界仍然要询问', () => {
    // 工作区隔离是安全底线，auto 不能越过它
    expect(new PermissionEngine('auto').verdict(rw, true)).toBe('ask')
  })

  it('记住后免询问', () => {
    const e = new PermissionEngine('confirm')
    e.remember('write_file')
    expect(e.verdict(rw, false)).toBe('allow')
    e.forgetAll()
    expect(e.verdict(rw, false)).toBe('ask')
  })
})

describe('describeApproval', () => {
  it('为写文件生成摘要', () => {
    expect(describeApproval(rw, { path: 'a.txt' }, false).summary).toBe('写入文件 a.txt')
  })

  it('为命令生成摘要并截断长命令', () => {
    const long = 'x'.repeat(300)
    const s = describeApproval(sh, { command: long }, false).summary
    expect(s).toContain('执行命令')
    expect(s.length).toBeLessThan(200)
  })

  it('越界时加上警告', () => {
    expect(describeApproval(rw, { path: '/etc/x' }, true).summary).toContain('超出工作区')
  })
})
EOF

w packages/harness-core/test/context.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import type { ChatMessage } from '@witseek/protocol'
import { ContextManager, conversationTokens, estimateTokens } from '../src/context.js'

describe('estimateTokens', () => {
  it('中文按字计', () => {
    expect(estimateTokens('你好世界')).toBe(4)
  })

  it('英文按 4 字符计', () => {
    expect(estimateTokens('abcdefgh')).toBe(2)
  })

  it('空串为 0', () => {
    expect(estimateTokens('')).toBe(0)
  })
})

describe('ContextManager', () => {
  it('未超预算时原样返回', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'hi' }
    ]
    const r = new ContextManager({ maxTokens: 10_000 }).fit(msgs)
    expect(r.trimmed).toBe(false)
    expect(r.messages).toHaveLength(2)
  })

  it('先裁剪工具结果而不是直接丢消息', () => {
    // 夹具要让 tool 结果落在保护窗口之外。keepRecent=3 保护末尾 3 条，
    // 所以 tool 之后必须再垫够消息 —— 否则它在保护区内，本就不该被裁，
    // 断言 stubbed > 0 就成了不可能满足的要求。
    const big = 'x'.repeat(4000)
    const msgs: ChatMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'task' },
      { role: 'assistant', content: '', toolCalls: [{ id: 'c1', name: 'read_file', arguments: '{}' }] },
      { role: 'tool', content: big, toolCallId: 'c1' },
      { role: 'assistant', content: 'done' },
      { role: 'user', content: 'more1' },
      { role: 'user', content: 'more2' },
      { role: 'user', content: 'more3' }
    ]
    const r = new ContextManager({ maxTokens: 500, keepRecent: 3 }).fit(msgs)
    expect(r.trimmed).toBe(true)
    expect(r.stubbedToolResults).toBe(1)
    // 只降质不减量：光把工具结果换成占位符就该够用，一条消息都不该丢
    expect(r.droppedMessages).toBe(0)
    expect(r.messages).toHaveLength(msgs.length)
    // 结构必须留着：role 与 toolCallId 不能被一起抹掉，否则后续 tool_calls 配对会断
    expect(r.messages[3].role).toBe('tool')
    expect(r.messages[3].toolCallId).toBe('c1')
    expect(r.messages[3].content).not.toBe(big)
    expect(r.finalTokens).toBeLessThan(conversationTokens(msgs))
  })

  it('保留 system 消息', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 'IMPORTANT' },
      ...Array.from({ length: 40 }, (_, i): ChatMessage => ({ role: 'user', content: `m${i} ${'y'.repeat(200)}` }))
    ]
    const r = new ContextManager({ maxTokens: 300, keepRecent: 4 }).fit(msgs)
    expect(r.messages[0].content).toBe('IMPORTANT')
    expect(r.droppedMessages).toBeGreaterThan(0)
  })

  it('裁剪后不再超预算', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 's' },
      ...Array.from({ length: 60 }, (_, i): ChatMessage => ({ role: 'user', content: `${i} ${'z'.repeat(300)}` }))
    ]
    const r = new ContextManager({ maxTokens: 400, keepRecent: 5 }).fit(msgs)
    expect(r.finalTokens).toBeLessThanOrEqual(400)
  })

  it('思维链在裁剪时被丢弃', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 's' },
      { role: 'assistant', content: 'a', reasoning: 'r'.repeat(3000) },
      { role: 'user', content: 'u' },
      { role: 'user', content: 'u2' },
      { role: 'user', content: 'u3' },
      { role: 'user', content: 'u4' }
    ]
    const r = new ContextManager({ maxTokens: 200, keepRecent: 2 }).fit(msgs)
    expect(r.messages[1].reasoning).toBeUndefined()
  })
})
EOF

w packages/harness-core/test/session.test.ts <<'EOF'
import { mkdtemp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta } from '@witseek/protocol'
import { SessionStore, latestMeta } from '../src/session.js'

let store: SessionStore
let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'witseek-sess-'))
  store = new SessionStore(dir)
})

const meta = (id: string, updatedAt: string): SessionMeta => ({
  id,
  title: `t-${id}`,
  workspace: '/w',
  model: 'deepseek-chat',
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt
})

describe('SessionStore', () => {
  it('创建后可读回', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    const records = await store.read('s1')
    expect(records).toHaveLength(1)
    expect(records[0].kind).toBe('meta')
  })

  it('追加消息', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.append('s1', { kind: 'message', message: { role: 'user', content: 'hi' } })
    await store.append('s1', { kind: 'message', message: { role: 'assistant', content: 'yo' } })
    expect(await store.read('s1')).toHaveLength(3)
  })

  it('是追加写而非覆盖', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.append('s1', { kind: 'message', message: { role: 'user', content: 'hi' } })
    const raw = await readFile(join(dir, 's1.jsonl'), 'utf8')
    expect(raw.split('\n').filter(Boolean)).toHaveLength(2)
  })

  it('损坏的半行不影响整体读取', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.append('s1', { kind: 'message', message: { role: 'user', content: 'hi' } })
    const p = join(dir, 's1.jsonl')
    const { appendFile } = await import('node:fs/promises')
    await appendFile(p, '{"kind":"mess', 'utf8') // 模拟写入中断
    expect(await store.read('s1')).toHaveLength(2)
  })

  it('list 按更新时间倒序', async () => {
    await store.create(meta('old', '2026-01-01T00:00:00.000Z'))
    await store.create(meta('new', '2026-06-01T00:00:00.000Z'))
    const list = await store.list()
    expect(list[0].id).toBe('new')
  })

  it('拒绝非法会话 id（防路径穿越）', async () => {
    await expect(store.read('../../etc/passwd')).rejects.toThrow(/非法/)
  })

  it('读不存在的会话返回空数组', async () => {
    expect(await store.read('nope')).toEqual([])
  })

  it('touch 后以最后一条 meta 为准', async () => {
    // JSONL 是追加写的，更新元信息靠再追加一条 meta。
    // 若读取时取的是第一条，界面就会一直显示建会话时的旧标题与旧时间。
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.touch({ ...meta('s1', '2026-09-18T12:00:00.000Z'), title: '改过的标题' })

    const records = await store.read('s1')
    expect(latestMeta(records)?.title).toBe('改过的标题')
    expect(latestMeta(records)?.updatedAt).toBe('2026-09-18T12:00:00.000Z')
  })

  it('touch 过的会话在列表里排到前面', async () => {
    await store.create(meta('old', '2026-01-01T00:00:00.000Z'))
    await store.create(meta('new', '2026-02-01T00:00:00.000Z'))
    // old 本来是旧的，touch 之后应该排到最前
    await store.touch(meta('old', '2026-12-31T00:00:00.000Z'))

    const list = await store.list()
    expect(list.map((m) => m.id)).toEqual(['old', 'new'])
  })

  it('touch 不存在的会话会抛错而不是静默新建', async () => {
    await expect(store.touch(meta('ghost', '2026-01-01T00:00:00.000Z'))).rejects.toThrow()
  })

  it('latestMeta 对空记录返回 undefined', () => {
    expect(latestMeta([])).toBeUndefined()
  })
})
EOF

w packages/harness-core/test/agent.test.ts <<'EOF'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MockProvider, textTurn, toolTurn } from '@witseek/provider-deepseek'
import { createDefaultTools } from '@witseek/tools'
import type { AgentEvent } from '@witseek/protocol'
import { runAgent } from '../src/agent.js'
import { PermissionEngine } from '../src/permission.js'
import { ToolRegistry } from '../src/registry.js'

let root: string

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-agent-'))
})

function baseOpts(provider: MockProvider, over: Partial<Parameters<typeof runAgent>[0]> = {}) {
  const events: AgentEvent[] = []
  return {
    events,
    opts: {
      provider,
      model: 'mock-model',
      registry: new ToolRegistry(createDefaultTools()),
      workspaceRoot: root,
      permission: new PermissionEngine('auto'),
      onEvent: (e: AgentEvent) => events.push(e),
      ...over
    }
  }
}

describe('runAgent', () => {
  it('跑通 读文件 → 改文件 → 结论 的闭环', async () => {
    await writeFile(join(root, 'a.txt'), 'foo\nbar\n', 'utf8')

    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'read_file', args: { path: 'a.txt' } }])
      if (turn === 1) {
        return toolTurn([{ name: 'edit_file', args: { path: 'a.txt', oldText: 'bar', newText: 'BAR' } }])
      }
      return textTurn('已把 bar 改成 BAR。')
    })

    const { opts, events } = baseOpts(provider)
    const result = await runAgent(opts, '把 bar 改成 BAR')

    expect(result.stopReason).toBe('completed')
    expect(result.steps).toBe(3)
    expect(result.finalText).toBe('已把 bar 改成 BAR。')
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('foo\nBAR\n')

    const toolNames = events.filter((e) => e.type === 'tool-start').map((e) => (e as { call: { name: string } }).call.name)
    expect(toolNames).toEqual(['read_file', 'edit_file'])
  })

  it('工具结果被回灌进消息，模型能看到', async () => {
    await writeFile(join(root, 'a.txt'), 'UNIQUE_CONTENT', 'utf8')

    let sawToolResult = false
    const provider = new MockProvider((req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'read_file', args: { path: 'a.txt' } }])
      sawToolResult = req.messages.some((m) => m.role === 'tool' && m.content.includes('UNIQUE_CONTENT'))
      return textTurn('ok')
    })

    await runAgent(baseOpts(provider).opts, '读一下')
    expect(sawToolResult).toBe(true)
  })

  it('未知工具不中断循环', async () => {
    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'no_such_tool', args: {} }])
      return textTurn('我换个方式。')
    })
    const { opts, events } = baseOpts(provider)
    const result = await runAgent(opts, 'x')

    expect(result.stopReason).toBe('completed')
    const end = events.find((e) => e.type === 'tool-end')
    expect((end as { result: { ok: boolean; output: string } }).result.output).toMatch(/未知工具/)
  })

  it('参数不是合法 JSON 时把错误回给模型', async () => {
    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) {
        return [{ type: 'tool-call', call: { id: 'c1', name: 'read_file', arguments: '{bad json' } }, { type: 'done', finishReason: 'tool_calls' }]
      }
      return textTurn('收到，我修正参数。')
    })
    const { opts, events } = baseOpts(provider)
    const result = await runAgent(opts, 'x')

    expect(result.stopReason).toBe('completed')
    const end = events.find((e) => e.type === 'tool-end')
    expect((end as { result: { output: string } }).result.output).toMatch(/JSON/)
  })

  it('权限拒绝时不执行工具', async () => {
    await writeFile(join(root, 'a.txt'), 'orig', 'utf8')

    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) {
        return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'HACKED' } }])
      }
      return textTurn('好的，我不改了。')
    })

    const { opts, events } = baseOpts(provider, {
      permission: new PermissionEngine('confirm'),
      approver: async () => 'deny'
    })
    const result = await runAgent(opts, 'x')

    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('orig')
    const approval = events.find((e) => e.type === 'approval')
    expect((approval as { decision: string }).decision).toBe('deny')
    expect(result.stopReason).toBe('completed')
  })

  it('approve-always 之后同工具免询问', async () => {
    await writeFile(join(root, 'a.txt'), 'orig', 'utf8')
    const approver = vi.fn(async () => 'approve-always' as const)

    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'one' } }])
      if (turn === 1) return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'two' } }])
      return textTurn('done')
    })

    const { opts } = baseOpts(provider, { permission: new PermissionEngine('confirm'), approver })
    await runAgent(opts, 'x')

    expect(approver).toHaveBeenCalledTimes(1)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('two')
  })

  it('read-only 模式下写操作被直接拒绝', async () => {
    await writeFile(join(root, 'a.txt'), 'orig', 'utf8')
    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'X' } }])
      return textTurn('被拒绝了。')
    })
    const { opts, events } = baseOpts(provider, { permission: new PermissionEngine('read-only') })
    await runAgent(opts, 'x')

    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('orig')
    // read-only 是拒绝而非询问，不应产生审批事件
    expect(events.some((e) => e.type === 'approval')).toBe(false)
  })

  it('达到步数上限会停下', async () => {
    const provider = new MockProvider(() => toolTurn([{ name: 'list_dir', args: {} }]))
    const { opts } = baseOpts(provider, { maxSteps: 3 })
    const result = await runAgent(opts, 'x')
    expect(result.steps).toBe(3)
    expect(result.stopReason).toBe('max-steps')
  })

  it('provider 抛错时返回 error 而不是崩溃', async () => {
    const provider = new MockProvider(() => {
      throw new Error('网络断了')
    })
    const { opts } = baseOpts(provider)
    const result = await runAgent(opts, 'x')
    expect(result.stopReason).toBe('error')
    expect(result.error).toContain('网络断了')
  })

  it('已取消的信号不会开始新一轮', async () => {
    const provider = new MockProvider(() => textTurn('不该被调用'))
    const ac = new AbortController()
    ac.abort()
    const { opts } = baseOpts(provider, { signal: ac.signal })
    const result = await runAgent(opts, 'x')
    expect(result.stopReason).toBe('aborted')
    expect(provider.turn).toBe(0)
  })

  it('reasoning 事件与 content 事件分开', async () => {
    const provider = new MockProvider(() => textTurn('答案', '思考过程'))
    const { opts, events } = baseOpts(provider)
    await runAgent(opts, 'x')

    const kinds = events.filter((e) => e.type === 'reasoning' || e.type === 'content').map((e) => e.type)
    expect(kinds).toEqual(['reasoning', 'content'])
  })

  it('system prompt 里带上工作区路径与工具清单', async () => {
    let sys = ''
    const provider = new MockProvider((req) => {
      sys = req.messages[0].content
      return textTurn('ok')
    })
    await runAgent(baseOpts(provider).opts, 'x')
    expect(sys).toContain(root)
    expect(sys).toContain('read_file')
  })

  it('history 会被带入上下文', async () => {
    let count = 0
    const provider = new MockProvider((req) => {
      count = req.messages.length
      return textTurn('ok')
    })
    const { opts } = baseOpts(provider, {
      history: [
        { role: 'user', content: '上一轮问题' },
        { role: 'assistant', content: '上一轮回答' }
      ]
    })
    await runAgent(opts, '这一轮')
    expect(count).toBe(4) // system + 2 历史 + 当前
  })
})
EOF

echo "== packages/harness-core diff 测试 =="

w packages/harness-core/test/diff.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import { diffLines, diffPreview, splitLines } from '../src/diff.js'

describe('splitLines', () => {
  it('空串得到零行', () => {
    expect(splitLines('')).toEqual([])
  })

  it('末尾换行不算多出一行空行', () => {
    // 这是最容易出错的地方：若把末尾 \n 当成分隔，每个正常文件都会多一条假差异
    expect(splitLines('a\nb\n')).toEqual(['a', 'b'])
    expect(splitLines('a\nb')).toEqual(['a', 'b'])
  })
})

describe('diffLines', () => {
  it('完全相同则全是 plain', () => {
    const { lines } = diffLines('a\nb', 'a\nb')
    expect(lines.every((l) => l.kind === 'plain')).toBe(true)
    expect(lines).toHaveLength(2)
  })

  it('单行替换标成 del + add', () => {
    const { lines } = diffLines('a\nb\nc', 'a\nB\nc')
    expect(lines.map((l) => l.kind)).toEqual(['plain', 'del', 'add', 'plain'])
  })

  it('插入一行不会把后续行全标成变更', () => {
    // 这正是选 LCS 而非按行号硬比的原因
    const { lines } = diffLines('a\nb\nc', 'a\nx\nb\nc')
    const kinds = lines.map((l) => l.kind)
    expect(kinds).toEqual(['plain', 'add', 'plain', 'plain'])
    expect(lines.filter((l) => l.kind === 'plain')).toHaveLength(3)
  })

  it('删除一行同理', () => {
    const { lines } = diffLines('a\nx\nb\nc', 'a\nb\nc')
    expect(lines.map((l) => l.kind)).toEqual(['plain', 'del', 'plain', 'plain'])
  })

  it('行号在两侧各自连续', () => {
    const { lines } = diffLines('a\nb\nc', 'a\nB\nc')
    const del = lines.find((l) => l.kind === 'del')
    const add = lines.find((l) => l.kind === 'add')
    expect(del?.oldNo).toBe(2)
    expect(del?.newNo).toBeUndefined()
    expect(add?.newNo).toBe(2)
    expect(add?.oldNo).toBeUndefined()
  })

  it('从空文件新增内容', () => {
    const { lines } = diffLines('', 'a\nb')
    expect(lines.map((l) => l.kind)).toEqual(['add', 'add'])
  })

  it('清空文件内容', () => {
    const { lines } = diffLines('a\nb', '')
    expect(lines.map((l) => l.kind)).toEqual(['del', 'del'])
  })

  it('超大输入退化为整体替换而不是卡死', () => {
    const big = Array.from({ length: 3000 }, (_, i) => `line ${i}`).join('\n')
    const other = Array.from({ length: 3000 }, (_, i) => `other ${i}`).join('\n')
    const { lines, truncated } = diffLines(big, other)
    expect(truncated).toBe(true)
    expect(lines).toHaveLength(6000)
  })
})

describe('diffPreview', () => {
  it('统计增删行数', () => {
    const p = diffPreview('a.ts', 'a\nb\nc', 'a\nB\nc\nd')
    expect(p.path).toBe('a.ts')
    expect(p.added).toBe(2)
    expect(p.removed).toBe(1)
    expect(p.truncated).toBe(false)
  })

  it('无变化时增删都是 0', () => {
    const p = diffPreview('a.ts', 'same', 'same')
    expect(p.added).toBe(0)
    expect(p.removed).toBe(0)
  })
})
EOF

echo
echo "==> P2 测试已生成"
find packages -path "*/test/*" -name "*.ts" | sort
