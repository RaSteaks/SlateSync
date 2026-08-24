import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const configuredRendererPort = Number.parseInt(process.env.SLATESYNC_RENDERER_PORT || "5173", 10);
const rendererDevPort = Number.isInteger(configuredRendererPort) && configuredRendererPort > 0 && configuredRendererPort < 65_536
  ? configuredRendererPort
  : 5173;
const isRendererDev = process.env.SLATESYNC_RENDERER_DEV === "true";

export default defineConfig({
  root: "src/renderer",
  // File-based production shells need relative assets; the dev server needs
  // root-relative HMR modules so Electron can resolve Vite's client correctly.
  base: isRendererDev ? "/" : "./",
  server: {
    host: "localhost",
    port: rendererDevPort,
    strictPort: true,
  },
  plugins: [
    react(),
    {
      name: "electron-file-protocol-html",
      transformIndexHtml(html, context) {
        // Chromium's file:// module loader rejects Vite's crossorigin
        // attribute in the sandboxed Electron window; relative same-origin
        // assets do not need it and remain CSP-protected.
        let nextHtml = html.replace(/\s+crossorigin(?:="[^"]*")?/g, "");
        if (!context.server) return nextHtml;

        // Vite's HMR websocket and injected development styles are local-only
        // exceptions; the packaged file renderer keeps the stricter CSP above.
        const hmrPort = context.server.config.server.port || 5173;
        // React Refresh bootstraps through an inline module in Vite's dev HTML;
        // allow that local-only script while keeping the packaged CSP strict.
        nextHtml = nextHtml.replace("script-src 'self'", "script-src 'self' 'unsafe-eval' 'unsafe-inline'");
        nextHtml = nextHtml.replace("style-src 'self'", "style-src 'self' 'unsafe-inline'");
        nextHtml = nextHtml.replace("connect-src 'none'", `connect-src 'self' ws://localhost:${hmrPort} ws://127.0.0.1:${hmrPort} ws://[::1]:${hmrPort}`);
        return nextHtml;
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
