import { defineConfig } from "vite";

export default defineConfig({
  // Preload is the only Electron-facing bundle. Do not let Vite copy the
  // legacy public tree into out/preload; that tree remains the Renderer-owned
  // production input and must be packaged exactly once.
  publicDir: false,
  build: {
    outDir: "out/preload",
    emptyOutDir: true,
    sourcemap: true,
    lib: {
      entry: "src/preload/index.ts",
      formats: ["cjs"],
      fileName: () => "index.cjs",
    },
    rollupOptions: {
      external: ["electron"],
      output: {
        entryFileNames: "index.cjs",
        exports: "named",
      },
    },
  },
});
