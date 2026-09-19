/**
 * SSE 行解析器。
 *
 * 不按 "\n\n" 切分整块，而是逐行消费 —— 因为一个 chunk 可能正好切在
 * "\r\n\r\n" 中间，按块切会漏事件。逐行处理对分片边界天然免疫。
 */
export async function* parseSse(
  stream: ReadableStream<Uint8Array>
): AsyncGenerator<string, void, undefined> {
  const decoder = new TextDecoder()
  const reader = stream.getReader()
  let buf = ''
  let dataLines: string[] = []

  const flush = (): string | null => {
    if (dataLines.length === 0) return null
    const payload = dataLines.join('\n')
    dataLines = []
    return payload
  }

  /** 消费一行，返回需要 yield 的 payload（无则 null）。 */
  const feed = (line: string): string | null => {
    if (line.endsWith('\r')) line = line.slice(0, -1)
    if (line === '') return flush()
    if (line.startsWith('data:')) {
      dataLines.push(line.slice(5).replace(/^ /, ''))
    }
    // 其余字段（event: / id: / retry:）当前用不到，忽略
    return null
  }

  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buf += decoder.decode(value, { stream: true })

      let nl: number
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl)
        buf = buf.slice(nl + 1)
        const payload = feed(line)
        if (payload !== null) yield payload
      }
    }
    // 流结束时缓冲区里可能还压着最后一行：SSE 不要求以换行收尾，
    // 而真实服务端最后一条 data: 之后往往直接断流。漏掉它就会丢事件。
    if (buf !== '') {
      const payload = feed(buf)
      buf = ''
      if (payload !== null) yield payload
    }
    const payload = flush()
    if (payload !== null) yield payload
  } finally {
    reader.releaseLock()
  }
}
