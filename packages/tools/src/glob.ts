/**
 * 极简 glob 匹配器。
 *
 * 自己实现而不引入 fast-glob，是为了让内核保持零第三方运行时依赖 ——
 * 在这种受限环境里，每多一个依赖就多一个失败点。
 *
 * 支持: **  *  ?  {a,b}  以及转义字符
 */
const SPECIAL = /[.+^$()|[\]\\]/g

function escapeLiteral(s: string): string {
  return s.replace(SPECIAL, '\\$&')
}

function segmentToRegex(seg: string): string {
  let out = ''
  for (let i = 0; i < seg.length; i++) {
    const c = seg[i]
    if (c === '*') {
      out += '[^/]*'
    } else if (c === '?') {
      out += '[^/]'
    } else if (c === '{') {
      const end = seg.indexOf('}', i)
      if (end === -1) {
        out += '\\{'
      } else {
        const alts = seg.slice(i + 1, end).split(',').map(escapeLiteral)
        out += `(?:${alts.join('|')})`
        i = end
      }
    } else {
      out += escapeLiteral(c)
    }
  }
  return out
}

export function globToRegExp(pattern: string): RegExp {
  const segs = pattern.split('/').filter((s) => s !== '' && s !== '.')
  let re = '^'
  for (let i = 0; i < segs.length; i++) {
    const seg = segs[i]
    if (seg === '**') {
      // 匹配零个或多个完整路径段（含其后的斜杠）
      re += '(?:[^/]+/)*'
    } else {
      re += segmentToRegex(seg)
      if (i < segs.length - 1) re += '/'
    }
  }
  re += '$'
  return new RegExp(re)
}

export function matchGlob(pattern: string, path: string): boolean {
  return globToRegExp(pattern).test(path.split('\\').join('/'))
}
