import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['packages/**/test/**/*.test.ts', 'apps/desktop/test/**/*.test.ts'],
    environment: 'node',
    reporters: ['default']
  }
})
