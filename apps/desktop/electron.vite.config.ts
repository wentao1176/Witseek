import { resolve } from 'node:path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'

// Witseek 桌面壳：
//  - main：主进程（ESM .mjs），负责拉起 dsh、双视图布局、右侧文件预览栏、自动更新；
//  - preload：两个 CJS 桥接（index 给启动/错误页，preview 给文件预览栏）；
//  - renderer：壳自带的右侧文件预览栏（preview.html + preview.ts，vite 打包，
//    marked / highlight.js 在构建时 bundle，运行时离线可用）。
// 主会话区依旧直接加载内置 dsh 运行时提供的官方 Web UI。
export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()],
    build: {
      outDir: 'out/main',
      rollupOptions: {
        input: resolve(__dirname, 'src/main/index.ts'),
        external: ['electron'],
        output: {
          format: 'es',
          entryFileNames: '[name].mjs'
        }
      }
    }
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    build: {
      outDir: 'out/preload',
      rollupOptions: {
        input: {
          index: resolve(__dirname, 'src/preload/index.ts'),
          preview: resolve(__dirname, 'src/preload/preview.ts')
        },
        external: ['electron'],
        output: {
          format: 'cjs',
          entryFileNames: '[name].cjs'
        }
      }
    }
  },
  renderer: {
    build: {
      outDir: 'out/renderer',
      rollupOptions: {
        input: {
          preview: resolve(__dirname, 'src/renderer/preview.html')
        }
      }
    }
  }
})
