import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The native desktop owner serves these static production assets and owns RPC.
// Keep this entry independent from the OpenWrt preview's SSH and fixture plugins.
export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  plugins: [react()],
  base: './',
  publicDir: false,
  define: {
    'process.env.NODE_ENV': JSON.stringify('production'),
  },
  build: {
    target: 'safari16',
    outDir: 'dist-desktop',
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      input: fileURLToPath(new URL('./desktop.html', import.meta.url)),
    },
  },
});
