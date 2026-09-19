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
