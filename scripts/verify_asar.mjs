// verify_asar.mjs —— 零依赖解析 app.asar 头部文件树并核对关键条目（P5 打包校验）
// 用法：node scripts/verify_asar.mjs <path-to-app.asar>
import fs from 'node:fs'

const asarPath = process.argv[2]
if (!asarPath) {
  console.error('用法: node verify_asar.mjs <app.asar>')
  process.exit(2)
}
const fd = fs.openSync(asarPath, 'r')
const probe = Buffer.alloc(2 * 1024 * 1024)
fs.readSync(fd, probe, 0, probe.length, 0)
const marker = Buffer.from('{"files"')
const s = probe.indexOf(marker)
if (s < 0) {
  console.error('未找到 asar files 头')
  process.exit(1)
}
const jsonLen = probe.readUInt32LE(s - 4)
const header = JSON.parse(probe.toString('utf8', s, s + jsonLen))

const files = []
function walk(node, prefix) {
  if (!node.files) {
    files.push(prefix)
    return
  }
  for (const [name, child] of Object.entries(node.files)) {
    walk(child, prefix ? `${prefix}/${name}` : name)
  }
}
walk(header, '')

const want = [
  ['main 产物', /^out\/main\/index\.mjs$/],
  ['preload 产物', /^out\/preload\/index\.mjs$/],
  ['renderer.html', /^out\/renderer\/index\.html$/],
  ['renderer.js', /^out\/renderer\/assets\/index-.*\.js$/],
  ['harness-core', /@witseek\+harness-core|@witseek\/harness-core/],
  ['protocol', /@witseek\+protocol|@witseek\/protocol/],
  ['provider-deepseek', /provider-deepseek/],
  ['tools', /@witseek\+tools|@witseek\/tools/],
  ['xterm', /@xterm\+xterm|@xterm\/xterm/],
  ['node-pty package', /node-pty\/package\.json/],
  ['node-pty win32 prebuild 条目', /node-pty\/prebuilds\/win32-x64/]
]
let ok = true
for (const [name, re] of want) {
  const hit = files.some((f) => re.test(f))
  if (!hit) ok = false
  console.log(`${hit ? 'OK   ' : 'MISS '} ${name}`)
}
const bad = files.filter(
  (f) =>
    /node-pty\/(build|bin|deps)\//.test(f) ||
    /prebuilds\/(darwin|win32-arm64|linux)/.test(f)
)
console.log('杂散平台原生文件:', bad.length ? bad.slice(0, 10).join(' | ') : '无')
console.log('asar 内文件总数:', files.length, ' out/ 文件:', files.filter((f) => f.startsWith('out/')).length)
process.exit(ok && bad.length === 0 ? 0 : 1)
