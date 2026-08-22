// postinstall: copy the pdf.js build artifacts into public/vendor/pdfjs/.
//
// The Electron renderer loads pdf.js from there, so this keeps the vendored
// copy in sync with the installed pdfjs-dist version.
import { copyFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(fileURLToPath(import.meta.url));
const PROJECT_DIR = join(ROOT, "..");
const PDFJS_BUILD = join(PROJECT_DIR, "node_modules", "pdfjs-dist", "build");
const TARGET = join(PROJECT_DIR, "public", "vendor", "pdfjs");

await mkdir(TARGET, { recursive: true });

for (const file of ["pdf.mjs", "pdf.worker.mjs"]) {
  await copyFile(join(PDFJS_BUILD, file), join(TARGET, file));
}

console.log("pdf.js 资源已复制到 public/vendor/pdfjs/");
