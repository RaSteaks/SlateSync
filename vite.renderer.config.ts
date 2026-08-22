import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "src/renderer",
  base: "./",
  plugins: [
    react(),
    {
      name: "electron-file-protocol-html",
      transformIndexHtml(html) {
        // Chromium's file:// module loader rejects Vite's crossorigin
        // attribute in the sandboxed Electron window; relative same-origin
        // assets do not need it and remain CSP-protected.
        return html.replace(/\s+crossorigin(?:="[^"]*")?/g, "");
      },
    },
  ],
  build: {
    outDir: "../../out/renderer",
    emptyOutDir: true,
    sourcemap: true,
    rollupOptions: {
      input: "src/renderer/index.html",
    },
  },
});
