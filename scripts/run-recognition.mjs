// CLI harness for running a single recognition job outside the UI.
//
// Loads .env + workflow config, runs recognizeSlate against a prepared input
// JSON (see /tmp/slatesync-pages/recognition-input.json), persists the task and
// diagnostic session, and prints the results. Useful for debugging recognition
// without the browser or Electron.
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

// Load .env
const envPath = join(ROOT, ".env");
try {
  const contents = await readFile(envPath, "utf8");
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const sep = line.indexOf("=");
    if (sep < 1) continue;
    const key = line.slice(0, sep).trim();
    let value = line.slice(sep + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
} catch {}

// CLI args: node scripts/run-recognition.mjs <input.json> [provider] [model]
const inputPath = process.argv[2] || "/tmp/slatesync-pages/recognition-input.json";
const providerId = process.argv[3] || "tokenplan";
const modelId = process.argv[4] || "qwen3.8-max";

const { recognizeSlate, configureModelHttpAgent } = await import(
  join(ROOT, "lib", "ai-client.mjs")
);
const { loadWorkflowConfig } = await import(join(ROOT, "lib", "config.mjs"));
const { createSessionCapture, createDiagnosticsStore } = await import(
  join(ROOT, "lib", "diagnostics.mjs")
);
const { createTaskStore } = await import(join(ROOT, "lib", "task-store.mjs"));

configureModelHttpAgent(process.env);

const workflowConfig = await loadWorkflowConfig(
  join(ROOT, "slatesync.config.json"),
);
const diagnostics = createDiagnosticsStore(join(ROOT, "data"));
const taskStore = createTaskStore(join(ROOT, "data"));

const input = JSON.parse(await readFile(inputPath, "utf8"));

console.log(
  `Starting recognition: ${input.pageCount} pages, provider=${providerId}, model=${modelId}`,
);

const capture = createSessionCapture();

try {
  const result = await recognizeSlate(
    {
      providerId,
      modelId,
      imageDataGroups: input.imageDataGroups,
      pageCount: input.pageCount,
      filename: input.filename,
      accuracyMode: "high",
      customPrompt: input.customPrompt || undefined,
      fieldFormats: workflowConfig.resolve.fieldFormats,
      comments: workflowConfig.resolve.comments,
    },
    {
      env: process.env,
      ocrAutoEnable: true,
      capture,
      onProgress: (event) => {
        console.log(`[${event.percent}%] ${event.phase}: ${event.message}`);
      },
    },
  );

  const sessionId = await diagnostics.saveSession(capture.session);
  const taskId = await taskStore.saveTask({
    status: "completed",
    filename: input.filename,
    pageCount: result.pageCount,
    provider: result.provider,
    model: result.model,
    accuracyMode: result.accuracyMode,
    result: result.result,
    usage: result.usage,
    durationMs: result.durationMs,
    ocrSummary: result.ocr,
    diagnosticSessionId: sessionId,
  });

  console.log(`\n=== Recognition Complete ===`);
  console.log(`Duration: ${(result.durationMs / 1000).toFixed(1)}s`);
  console.log(`Records: ${result.result.records.length}`);
  console.log(`Sheet title: ${result.result.sheetTitle}`);
  console.log(`Diagnostic session: ${sessionId}`);
  console.log(`Task: ${taskId}`);
  console.log(`Usage: ${JSON.stringify(result.usage)}`);
  console.log(`OCR: ${JSON.stringify(result.ocr)}`);
  console.log(`Warnings: ${result.result.warnings.length}`);

  const outputPath = inputPath.replace(".json", "-result.json");
  await writeFile(
    outputPath,
    JSON.stringify({ taskId, diagnosticSessionId: sessionId, ...result }, null, 2),
  );
  console.log(`\nFull result saved to ${outputPath}`);

  console.log(`\n=== Records ===`);
  for (const record of result.result.records) {
    console.log(
      `  ${record.cardNumber} ${record.videoCode} | Scene:${record.scene} Shot:${record.shot} Take:${record.take} | ${record.takeStatus || "-"} | ${record.confidence}`,
    );
  }
} catch (error) {
  capture.setError(error);
  const sessionId = await diagnostics.saveSession(capture.session);
  console.error(`\nRecognition failed (session ${sessionId}): ${error.message}`);
  process.exit(1);
}
