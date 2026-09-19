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
