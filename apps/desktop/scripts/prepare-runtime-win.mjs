#!/usr/bin/env node
/**
 * prepare-runtime-win.mjs
 *
 * 把 runtime/stage-win32/dsh（pnpm hoisted + supportedArchitectures=win32-x64
 * 安装出的官方 dsh 生产树）裁剪后放到 apps/desktop/.runtime-build/win/dsh，
 * 并下载一份 Windows 版上游 Node（node.exe）到 .runtime-build/win/node.exe。
 *
 * electron-builder 再通过 extraResources 把两者原样带进安装包的 resources/runtime。
 * 全程在 Linux 构建机上完成，不需要 Wine：所有原生模块（node-pty / koffi /
 * sharp / node-addon-require-builtin / ripgrep）都以官方预编译产物随包分发。
 *
 * 用法：node scripts/prepare-runtime-win.mjs [--node-version v24.x.x]
 */
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const APP_ROOT = path.resolve(here, '..')
const REPO_ROOT = path.resolve(APP_ROOT, '..', '..')
const SRC = path.join(REPO_ROOT, 'runtime', 'stage-win32', 'dsh')
const OUT = path.join(APP_ROOT, '.runtime-build', 'win')
const DSH_OUT = path.join(OUT, 'dsh')
const CACHE = path.join(REPO_ROOT, '.cache', 'node-win')

function run(file, args, opts = {}) {
  return execFileSync(file, args, { stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8', ...opts })
}

function fail(msg) {
  console.error(`[prepare-runtime] ${msg}`)
  process.exit(1)
}

/** 选择要保留的文件 / 目录（相对 dsh 根的 POSIX 路径） */
function wanted(relPosix) {
  if (/(^|\/)\.bin(\/|$)/.test(relPosix)) return false
  if (/\.(pdb|map|d\.ts|tsbuildinfo)$/.test(relPosix)) return false
  // node-pty 在单个包里携带全平台 prebuilds，只保留 win32-x64
  if (/(^|\/)prebuilds\/(linux-x64|linux-arm64|darwin-x64|darwin-arm64|win32-arm64)(\/|$)/.test(relPosix)) {
    return false
  }
  // conpty 的 arm64 OpenConsole
  if (/(^|\/)win10-arm64(\/|$)/.test(relPosix)) return false
  return true
}

function resolveNodeVersion(argVersion) {
  if (argVersion) return argVersion
  const mirrors = [
    'https://npmmirror.com/mirrors/node/index.json',
    'https://nodejs.org/dist/index.json'
  ]
  for (const url of mirrors) {
    try {
      const idx = JSON.parse(run('curl', ['-fsSL', '--max-time', '30', url]))
      const hit = idx.find(
        r => r.version.startsWith('v24.') && !/-/.test(r.version) && r.lts
      ) || idx.find(r => r.version.startsWith('v24.') && !/-/.test(r.version))
      if (hit) {
        console.log(`[prepare-runtime] 选用 Windows Node ${hit.version}（${url}）`)
        return hit.version
      }
    } catch (_) {
      /* try next mirror */
    }
  }
  fail('无法解析最新的 Node v24 版本，请用 --node-version 显式指定')
}

function provisionNode(version) {
  mkdirSync(CACHE, { recursive: true })
  const zip = path.join(CACHE, `node-${version}-win-x64.zip`)
  const exeName = 'node.exe'
  const finalExe = path.join(OUT, exeName)
  if (existsSync(finalExe)) {
    console.log(`[prepare-runtime] node.exe 已存在，跳过下载`)
    return
  }
  if (!existsSync(zip)) {
    const urls = [
      `https://npmmirror.com/mirrors/node/${version}/node-${version}-win-x64.zip`,
      `https://nodejs.org/dist/${version}/node-${version}-win-x64.zip`
    ]
    let ok = false
    for (const url of urls) {
      try {
        console.log(`[prepare-runtime] 下载 ${url}`)
        run('curl', ['-fL', '--retry', '3', '--retry-all-errors', '-o', zip, url], { stdio: 'inherit' })
        ok = true
        break
      } catch (_) {
        /* try next mirror */
      }
    }
    if (!ok) fail(`Node Windows 压缩包下载失败：node-${version}-win-x64.zip`)
  }
  const tmp = path.join(CACHE, `extract-${version}`)
  rmSync(tmp, { recursive: true, force: true })
  mkdirSync(tmp, { recursive: true })
  // -j 打平目录，只解出顶层 node.exe
  run('unzip', ['-o', '-j', zip, `node-${version}-win-x64/${exeName}`, '-d', tmp], { stdio: 'inherit' })
  mkdirSync(OUT, { recursive: true })
  cpSync(path.join(tmp, exeName), finalExe)
  rmSync(tmp, { recursive: true, force: true })
  console.log(`[prepare-runtime] node.exe 就位 (${version})`)
}

function copyDshTree() {
  const srcBin = path.join(SRC, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
  if (!existsSync(srcBin)) {
    fail(`源运行时不存在：${srcBin}\n请先在 runtime/stage-win32/dsh 安装 win32-x64 生产树（scripts/stage_win_runtime.sh）`)
  }
  rmSync(DSH_OUT, { recursive: true, force: true })
  mkdirSync(DSH_OUT, { recursive: true })
  cpSync(path.join(SRC, 'package.json'), path.join(DSH_OUT, 'package.json'))
  const srcNm = path.join(SRC, 'node_modules')
  const dstNm = path.join(DSH_OUT, 'node_modules')
  console.log('[prepare-runtime] 裁剪复制 dsh 生产树（hoisted node_modules）…')
  cpSync(srcNm, dstNm, {
    recursive: true,
    force: true,
    filter(absSrc) {
      const rel = path.relative(SRC, absSrc).split(path.sep).join('/')
      return wanted(rel)
    }
  })
}

function mustExist(rel, label) {
  const p = path.join(DSH_OUT, rel)
  if (!existsSync(p)) fail(`缺少关键运行时文件（${label}）：${rel}`)
  console.log(`  ✓ ${label}`)
}

function verify() {
  mustExist(path.join('node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'), 'dsh CLI 入口')
  mustExist(path.join('node_modules', 'node-pty', 'prebuilds', 'win32-x64', 'conpty.node'), 'node-pty conpty')
  mustExist(path.join('node_modules', '@vscode', 'ripgrep-win32-x64', 'bin', 'rg.exe'), 'ripgrep')
  const nodeExe = path.join(OUT, 'node.exe')
  if (!existsSync(nodeExe)) fail('缺少 node.exe')
  console.log('  ✓ node.exe')

  // 这些包的具体文件名可能随版本变化，用 glob 风格校验
  const { globSync } = await_import_glob()
  const expectGlobs = [
    ['node_modules/@koromix/koffi-win32-x64/**/koffi.node', 'koffi FFI'],
    ['node_modules/node-addon-require-builtin-win32-x64-msvc/**/*.node', 'require-builtin addon'],
    ['node_modules/@img/sharp-win32-x64/**/*.node', 'sharp native']
  ]
  for (const [g, label] of expectGlobs) {
    const hits = globSync(g, { cwd: DSH_OUT })
    if (hits.length === 0) fail(`缺少关键原生模块（${label}）：${g}`)
    console.log(`  ✓ ${label}: ${hits[0]}`)
  }
  // 不应残留其它平台 prebuild（直接检查已知目录）
  for (const plat of ['linux-x64', 'linux-arm64', 'darwin-x64', 'darwin-arm64', 'win32-arm64']) {
    const leakedDir = path.join(DSH_OUT, 'node_modules', 'node-pty', 'prebuilds', plat)
    if (existsSync(leakedDir)) fail(`仍残留非 win32-x64 prebuild 目录：${plat}`)
  }
  console.log('  ✓ 无其它平台 node-pty prebuild 残留')
}

// 极简 glob（避免再引依赖）：用 find 收集后内存匹配
function await_import_glob() {
  return {
    globSync(pattern, opts) {
      const cwd = opts.cwd
      const out = []
      const seen = new Set()
      function walk(dir) {
        let entries = []
        try { entries = readdirSyncSafe(dir) } catch { return }
        for (const name of entries) {
          const full = path.join(dir, name)
          let st
          try { st = statSyncSafe(full) } catch { continue }
          const rel = path.relative(cwd, full).split(path.sep).join('/')
          if (st.isDirectory()) walk(full)
          else if (miniMatch(rel, pattern) && !seen.has(rel)) { seen.add(rel); out.push(rel) }
        }
      }
      walk(cwd)
      return out
    }
  }
}
import { readdirSync as readdirSyncSafe, statSync as statSyncSafe } from 'node:fs'
function miniMatch(rel, pattern) {
  // 仅支持本脚本用到的 ** / * / 固定段
  const re = pattern
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*\*/g, '<<DS>>')
    .replace(/\*/g, '[^/]*')
    .replace(/<<DS>>/g, '.*')
    .replace(/\//g, '\\/')
  return new RegExp('^' + re + '$').test(rel)
}

function writeManifest(nodeVersion) {
  const dshPkg = JSON.parse(
    readFileSync(path.join(DSH_OUT, 'node_modules', '@deepseek-ai', 'dsh', 'package.json'), 'utf8')
  )
  let sizeMb = ''
  try {
    const kb = Number(run('du', ['-sk', DSH_OUT]).split(/\s+/)[0])
    sizeMb = `${Math.round(kb / 1024)} MB`
  } catch { sizeMb = 'unknown' }
  const manifest = {
    schemaVersion: 1,
    platform: 'win32',
    arch: 'x64',
    node: nodeVersion,
    dsh: dshPkg.version,
    dshTreeSize: sizeMb,
    generatedAt: new Date().toISOString()
  }
  writeFileSync(path.join(OUT, 'runtime-manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
  console.log(`[prepare-runtime] manifest: dsh ${dshPkg.version} / node ${nodeVersion} / ${sizeMb}`)
}

const eqArg = process.argv.find(a => a.startsWith('--node-version='))
const flagIdx = process.argv.indexOf('--node-version')
const argVersion =
  eqArg?.split('=')[1] || (flagIdx !== -1 ? process.argv[flagIdx + 1] : undefined)
const nodeVersion = resolveNodeVersion(argVersion)
mkdirSync(OUT, { recursive: true })
provisionNode(nodeVersion)
copyDshTree()
await Promise.resolve(verify())
writeManifest(nodeVersion)
console.log('[prepare-runtime] 完成：' + OUT)
