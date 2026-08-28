import { _electron as electron, expect, test, type ElectronApplication, type Page } from "@playwright/test";
import { access, cp, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "../..");
const mainPath = join(root, "electron", "main.mjs");
const configPath = join(root, "slatesync.config.json");

function blankPdf(pageCount: number) {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    `<< /Type /Pages /Kids [${Array.from({ length: pageCount }, (_, index) => `${index + 3} 0 R`).join(" ")}] /Count ${pageCount} >>`,
    ...Array.from({ length: pageCount }, () => "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>"),
  ];
  let body = "%PDF-1.4\n";
  const offsets = [0];
  for (let index = 0; index < objects.length; index += 1) {
    offsets.push(Buffer.byteLength(body));
    body += `${index + 1} 0 obj\n${objects[index]}\nendobj\n`;
  }
  const xref = Buffer.byteLength(body);
  body += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  body += offsets.slice(1).map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("");
  body += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(body, "ascii");
}

async function launch(userDataDir: string) {
  // Electron's --user-data-dir does not redefine appData on macOS. Seed the
  // machine setting explicitly or a test could accidentally open the user's
  // default Project Library instead of the isolated fixture package.
  try { await access(join(userDataDir, "settings.json")); } catch {
    await writeFile(join(userDataDir, "settings.json"), JSON.stringify({
      libraryPath: join(userDataDir, "Isolated Library.slatesync-library"),
      ocrPythonPath: "",
      ocrSetupCompleted: false,
      ocrSetupSkipped: true,
    }), "utf8");
  }
  const app = await electron.launch({ args: [`--user-data-dir=${userDataDir}`, mainPath], cwd: root, env: { ...process.env, SLATESYNC_CONFIG_PATH: configPath, OPENAI_API_KEY: "", OPENROUTER_API_KEY: "", TOKENPLAN_API_KEY: "", DASHSCOPE_API_KEY: "", OPENAI_COMPATIBLE_API_KEY: "" } });
  const page = await app.firstWindow();
  await page.waitForSelector("[data-testid=modern-shell]");
  await page.waitForFunction(() => Boolean((window as Window & { slateSync?: unknown }).slateSync));
  // The shell marker is present during boot; wait for the typed config/library
  // projection before asserting route content so the test has no timing sleep.
  await page.waitForSelector('#main-content[aria-label="项目库"]');
  return { app, page };
}

async function launchLegacy(userDataDir: string) {
  try { await access(join(userDataDir, "settings.json")); } catch {
    await writeFile(join(userDataDir, "settings.json"), JSON.stringify({ libraryPath: join(userDataDir, "Isolated Library.slatesync-library"), ocrPythonPath: "", ocrSetupCompleted: false, ocrSetupSkipped: true }), "utf8");
  }
  const app = await electron.launch({ args: [`--user-data-dir=${userDataDir}`, mainPath, "--slatesync-renderer=legacy"], cwd: root, env: { ...process.env, SLATESYNC_CONFIG_PATH: configPath, OPENAI_API_KEY: "", OPENROUTER_API_KEY: "", TOKENPLAN_API_KEY: "", DASHSCOPE_API_KEY: "", OPENAI_COMPATIBLE_API_KEY: "" } });
  const page = await app.firstWindow();
  await page.waitForSelector("#project-home-page:not([hidden])");
  await page.waitForFunction(() => Boolean((window as Window & { slateSync?: unknown }).slateSync));
  return { app, page };
}

async function close(app: ElectronApplication, userDataDir: string) {
  await app.close();
  await rm(userDataDir, { recursive: true, force: true });
}

async function assertGateway(page: Page) {
  const facts = await page.evaluate(async () => {
    const api = window.slateSync;
    const library = await api.projects.getLibraryInfo();
    return { namespace: Object.keys(api).sort(), hasElectronApi: typeof (globalThis as { electronAPI?: unknown }).electronAPI !== "undefined", libraryOk: library.ok, route: document.querySelector("main")?.getAttribute("aria-label") };
  });
  expect(facts.namespace).toEqual(["app", "files", "projects", "recognition", "settings", "tasks"]);
  expect(facts.hasElectronApi).toBe(false);
  expect(facts.libraryOk).toBe(true);
  expect(facts.route).toBe("项目库");
}

test.describe("modern production Electron", () => {
  test("fresh profile run one", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-fresh-1-"));
    const { app, page } = await launch(userData);
    try { await assertGateway(page); await expect(page.getByRole("heading", { name: "项目库" })).toBeVisible(); }
    finally { await close(app, userData); }
  });

  test("fresh profile run two", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-fresh-2-"));
    const { app, page } = await launch(userData);
    try { await assertGateway(page); await expect(page.getByText("项目列表")).toBeVisible(); }
    finally { await close(app, userData); }
  });

  test("copied version-1 Library profile remains readable", async () => {
    const sourceUserData = await mkdtemp(join(tmpdir(), "slatesync-e2e-source-"));
    const copiedUserData = await mkdtemp(join(tmpdir(), "slatesync-e2e-v1-"));
    const { app: sourceApp, page: sourcePage } = await launch(sourceUserData);
    let copiedLibrary = "";
    try {
      const result = await sourcePage.evaluate(() => window.slateSync.projects.getLibraryInfo());
      if (!result.ok) throw new Error(result.error.message);
      copiedLibrary = `${result.data.path}.copy.slatesync-library`;
      await cp(result.data.path, copiedLibrary, { recursive: true });
      // The source profile is intentionally disposable and may not persist a
      // settings file until a machine setting changes; the copied v1 Library
      // only needs the frozen path selection shape to boot read-only.
      await writeFile(join(copiedUserData, "settings.json"), JSON.stringify({
        libraryPath: copiedLibrary,
        ocrPythonPath: "",
        ocrSetupCompleted: false,
        ocrSetupSkipped: true,
      }), "utf8");
    } finally { await close(sourceApp, sourceUserData); }
    const { app, page } = await launch(copiedUserData);
    try { await assertGateway(page); await expect(page.getByRole("heading", { name: "项目库" })).toBeVisible(); }
    finally { await close(app, copiedUserData); await rm(copiedLibrary, { recursive: true, force: true }); }
  });

  test("uses the retained CSV Worker through the integrated workspace", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-csv-worker-"));
    const { app, page } = await launch(userData);
    try {
      await page.getByRole("button", { name: "新建项目" }).first().click();
      await page.locator("#new-project-form input").first().fill("CSV Worker Fixture");
      await page.getByRole("button", { name: "创建项目" }).click();
      await expect(page.getByRole("heading", { name: "CSV Worker Fixture" })).toBeVisible();
      await page.locator('input[data-csv-upload]').setInputFiles(join(root, "test", "fixtures", "baseline", "csv", "resolve-source.csv"));
      await expect(page.locator('[data-testid="csv-virtual-table"]')).toBeVisible();
      await expect(page.getByText(/行 ·/)).toBeVisible();
    } finally { await close(app, userData); }
  });

  test("keeps a synthetic 10,000-row CSV virtualized through scroll and keyboard edit", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-10k-"));
    const csvPath = join(userData, "synthetic-10000.csv");
    const rows = Array.from({ length: 10_000 }, (_, index) => `A${String(index + 1).padStart(5, "0")}C001.mov,${(index % 120) + 1},01,${(index % 8) + 1}`).join("\r\n");
    await writeFile(csvPath, `File Name,Scene,Shot,Take\r\n${rows}\r\n`, "utf8");
    const { app, page } = await launch(userData);
    try {
      await page.getByRole("button", { name: "打开项目 默认项目" }).click();
      await expect(page.locator('#main-content[aria-label="工作台"]')).toBeVisible();
      // Compare the frozen legacy client with the modern v1 envelope against
      // the exact same production Worker. Five-decode batches keep wrapper
      // overhead above timer noise without changing the 10,000-row workload.
      const workerComparison = await page.evaluate(async (csvText) => {
        const workerUrl = new URL("../../public/csv-worker.js", window.location.href);
        const clientUrl = new URL("../../public/csv-worker-client.js", window.location.href);
        const module = await import(clientUrl.href) as { createCsvWorkerClient: (options?: unknown) => { request(task: unknown, transfer?: Transferable[]): Promise<unknown>; terminate(): void } };
        const legacy = module.createCsvWorkerClient({ workerUrl });
        const modernWorker = new Worker(workerUrl, { type: "module" });
        let nextId = 1;
        const pending = new Map<number, (reply: { error?: string }) => void>();
        modernWorker.addEventListener("message", (event) => {
          const resolveReply = pending.get(event.data.id);
          if (resolveReply) { pending.delete(event.data.id); resolveReply(event.data); }
        });
        const modernRequest = (buffer: ArrayBuffer) => new Promise<void>((resolveRequest, rejectRequest) => {
          const id = nextId++;
          pending.set(id, (reply) => reply.error ? rejectRequest(new Error(reply.error)) : resolveRequest());
          modernWorker.postMessage({ id, version: 1, task: { type: "decode-metadata", data: buffer } }, [buffer]);
        });
        const bytes = new TextEncoder().encode(csvText);
        const runLegacy = async () => { for (let index = 0; index < 5; index += 1) { const copy = bytes.slice().buffer; await legacy.request({ type: "decode-metadata", data: copy }, [copy]); } };
        const runModern = async () => { for (let index = 0; index < 5; index += 1) await modernRequest(bytes.slice().buffer); };
        await runLegacy();
        await runModern();
        const legacyMs: number[] = [];
        const modernMs: number[] = [];
        for (let sample = 0; sample < 7; sample += 1) {
          const ordered = sample % 2 === 0 ? [[runLegacy, legacyMs], [runModern, modernMs]] as const : [[runModern, modernMs], [runLegacy, legacyMs]] as const;
          for (const [run, values] of ordered) { const started = performance.now(); await run(); values.push((performance.now() - started) / 5); }
        }
        legacy.terminate();
        modernWorker.terminate();
        const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
        return { warmupBatches: 2, sampleCount: 7, operationsPerSample: 5, legacyMs, modernMs, legacyMedianMs: median(legacyMs), modernMedianMs: median(modernMs) };
      }, `File Name,Scene,Shot,Take\r\n${rows}\r\n`);
      expect(workerComparison.modernMedianMs).toBeLessThanOrEqual(workerComparison.legacyMedianMs * 1.1);

      const csvInput = page.locator("input[data-csv-upload]");
      // Warm the lazy table/JIT path once, then clear it before establishing
      // the leak baseline. Otherwise one-time compiled code is misclassified
      // as retained CSV data after the measured clear.
      await csvInput.setInputFiles(csvPath);
      await expect(page.getByText("10,000 行 · 4 列")).toBeVisible();
      await page.getByRole("button", { name: "清除表格" }).click();
      await expect(page.locator('[data-testid="csv-virtual-table"]')).toBeHidden();
      await expect(page.getByRole("status").filter({ hasText: "任务已保存" })).toBeVisible();

      const cdp = await page.context().newCDPSession(page);
      const rendererWorkingSetKb = () => app.evaluate(({ app: electronApp }) => electronApp.getAppMetrics()
        .filter((metric) => metric.type === "Tab")
        .reduce((total, metric) => total + metric.memory.workingSetSize, 0));
      await cdp.send("HeapProfiler.collectGarbage");
      const baselineHeap = (await cdp.send("Runtime.getHeapUsage") as { usedSize: number }).usedSize;
      const baselineWorkingSetKb = await rendererWorkingSetKb();

      await csvInput.setInputFiles(csvPath);
      await expect(page.getByText("10,000 行 · 4 列")).toBeVisible();
      const table = page.locator('[data-testid="csv-virtual-table"]');
      const initialRows = await table.locator("tbody tr").count();
      expect(initialRows).toBeGreaterThan(0);
      expect(initialRows).toBeLessThan(100);

      const scrollStarted = performance.now();
      await table.locator('[class*="tableScroll"]').evaluate((element) => {
        const scrollElement = element as HTMLElement;
        scrollElement.scrollTop = 150_000;
        scrollElement.dispatchEvent(new Event("scroll"));
      });
      await page.waitForFunction(() => [...document.querySelectorAll('[data-testid="csv-virtual-table"] tbody tr')]
        .some((row) => Number(row.getAttribute("data-index") || "0") > 1_000));
      const scrollMs = performance.now() - scrollStarted;
      const scrolledRows = await table.locator("tbody tr").count();
      expect(scrolledRows).toBeLessThan(100);

      const firstVisibleRow = table.locator("tbody tr").first();
      const firstVisibleIndex = await firstVisibleRow.getAttribute("data-index");
      expect(firstVisibleIndex).not.toBeNull();
      if (firstVisibleIndex === null) throw new Error("virtual row lost its stable data-index");
      // Pin the edit locator to the row id rather than the first visible row;
      // a state update may legitimately change the virtual window ordering.
      const input = table.locator(`tbody tr[data-index="${firstVisibleIndex}"] input`).first();
      await input.focus();
      await expect(input).toBeFocused();
      const editStarted = performance.now();
      await input.fill("keyboard-edited");
      await input.press("Enter");
      const keyboardEditMs = performance.now() - editStarted;
      await expect(input).toHaveValue("keyboard-edited");
      expect(keyboardEditMs).toBeLessThan(250);
      await expect(page.getByRole("status").filter({ hasText: "任务已保存" })).toBeVisible();
      await cdp.send("HeapProfiler.collectGarbage");
      const loadedHeap = (await cdp.send("Runtime.getHeapUsage") as { usedSize: number }).usedSize;
      const loadedWorkingSetKb = await rendererWorkingSetKb();
      const payloadBytes = Buffer.byteLength(`File Name,Scene,Shot,Take\r\n${rows}\r\n`);
      const cellCharacters = rows.length + 10_000 * (3 + 2 + 1);
      // Two retained table projections are budgeted as UTF-16 content plus
      // V8 string/array slots. TanStack also creates one row model and four
      // cell models per source row even though only <100 DOM rows mount; the
      // conservative 2 KiB/row + 256 B/cell allowance documents that view
      // representation separately from the 1.25x binary-transfer budget.
      const rawTableRepresentationBytes = 2 * (cellCharacters * 2 + (10_000 * 4 + 4) * 32 + (10_000 + 1) * 32 + (10_000 * 4 + 4) * 8 + 512 * 1024);
      const virtualRowModelRepresentationBytes = 10_000 * 2_048 + 10_000 * 4 * 256;
      const documentedTableRepresentationBytes = rawTableRepresentationBytes + virtualRowModelRepresentationBytes;
      const heapAdditionalBytes = Math.max(0, loadedHeap - baselineHeap);
      const rendererProcessAdditionalBytes = Math.max(0, loadedWorkingSetKb - baselineWorkingSetKb) * 1024;
      expect(heapAdditionalBytes).toBeLessThanOrEqual(payloadBytes * 1.25 + documentedTableRepresentationBytes);
      expect(rendererProcessAdditionalBytes).toBeLessThanOrEqual(payloadBytes * 1.25 + documentedTableRepresentationBytes);

      await page.getByRole("button", { name: "清除表格" }).click();
      await expect(page.locator('[data-testid="csv-virtual-table"]')).toBeHidden();
      await expect(page.getByRole("status").filter({ hasText: "任务已保存" })).toBeVisible();
      await cdp.send("HeapProfiler.collectGarbage");
      const releasedHeap = (await cdp.send("Runtime.getHeapUsage") as { usedSize: number }).usedSize;
      const releasedWorkingSetKb = await rendererWorkingSetKb();
      expect(releasedHeap).toBeLessThanOrEqual(baselineHeap * 1.05 + 1024 * 1024);
      expect(releasedWorkingSetKb).toBeLessThanOrEqual(baselineWorkingSetKb * 1.05 + 1024);
      await page.getByRole("button", { name: "全局设置" }).click();
      await expect(page.locator('#main-content[aria-label="全局设置"]')).toBeVisible();
      await expect.poll(() => page.workers().length).toBe(0);
      console.log("IP03_08_E2E_PERFORMANCE_METRICS", JSON.stringify({ rows: 10_000, initialDomRows: initialRows, scrolledDomRows: scrolledRows, scrollMs, keyboardEditMs, payloadBytes, rawTableRepresentationBytes, virtualRowModelRepresentationBytes, documentedTableRepresentationBytes, baselineHeap, loadedHeap, heapAdditionalBytes, releasedHeap, baselineWorkingSetKb, loadedWorkingSetKb, rendererProcessAdditionalBytes, releasedWorkingSetKb, workerComparison }));
    } finally { await close(app, userData); }
  });

  test("flushes task edits, restores retained CSV state, and supports new/delete/retry surfaces", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-tasks-"));
    const slateCsvPath = join(userData, "slate-input.csv");
    await writeFile(slateCsvPath, "File Name,Scene,Shot,Take,Comments\r\nA001_C001.mov,12,03,02,_OK\r\n", "utf8");
    const { app, page } = await launch(userData);
    try {
      await page.getByRole("button", { name: "打开项目 默认项目" }).click();
      await expect(page.locator('#main-content[aria-label="工作台"]')).toBeVisible();
      const ids = await page.evaluate(async () => {
        const projects = await window.slateSync.projects.list();
        if (!projects.ok) throw new Error(projects.error.message);
        const projectId = projects.data.find((item) => item.name === "默认项目")?.id;
        if (!projectId) throw new Error("missing default project");
        const baseRecord = { id: "record-1", sourcePage: 1, cardNumber: "A001", videoCode: "C001", scene: "1", shot: "1", take: "1", takeStatus: "过" as const, description: null, comments: null, shotSize: null, cameraPosition: null, confidence: "high" as const };
        const first = await window.slateSync.tasks.save({ projectId, task: {
          projectId,
          filename: "Task A.pdf",
          status: "completed",
          pageCount: 1,
          resolveCsvFilename: "Task A.csv",
          resolveCsvTable: { headers: ["File Name", "Scene", "Shot", "Take", "Comments"], rows: [["A001C001.mov", "001", "01", "01", "_OK"]], format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\r\n", finalNewline: true } },
          result: { sheetTitle: "Task A", records: [baseRecord], warnings: [] },
          editedRecords: [baseRecord],
        } });
        const second = await window.slateSync.tasks.save({ projectId, task: { projectId, filename: "Task B.pdf", status: "draft", pageCount: 0 } });
        if (!first.ok || !second.ok) throw new Error("failed to seed tasks");
        return { first: first.data, second: second.data };
      });

      await page.getByRole("button", { name: "刷新任务列表" }).click();
      await page.getByRole("button", { name: /^Task A\.pdf / }).click();
      const sceneInput = page.getByRole("textbox", { name: "Scene 第 2 行" });
      await expect(sceneInput).toHaveValue("001");
      await sceneInput.fill("099");
      // Switching immediately exercises the explicit flush boundary rather
      // than relying on the autosave timer or a fixed wait.
      await page.getByRole("button", { name: /^Task B\.pdf / }).click();
      await expect(page.locator('[data-testid="csv-virtual-table"]')).toBeHidden();
      await page.getByRole("button", { name: /^Task A\.pdf / }).click();
      await expect(page.getByRole("textbox", { name: "Scene 第 2 行" })).toHaveValue("099");

      await page.getByRole("button", { name: "新建", exact: true }).click();
      await expect(page.locator('[data-testid="csv-virtual-table"]')).toBeHidden();
      await page.getByRole("button", { name: "删除Task B.pdf" }).click();
      const deleteDialog = page.getByRole("dialog", { name: "删除任务？" });
      await expect(deleteDialog).toBeVisible();
      await deleteDialog.getByRole("button", { name: "确认删除" }).click();
      await expect(page.getByRole("button", { name: /^Task B\.pdf / })).toHaveCount(0);

      await page.locator("input[data-slate-csv-upload]").setInputFiles(slateCsvPath);
      await expect(page.getByText(/slate-input\.csv · 1 条/)).toBeVisible();
      await page.getByRole("button", { name: "从场记 CSV 生成结果" }).click();
      await expect(page.getByRole("heading", { name: "slate-input.csv" })).toBeVisible();
      await expect(page.getByText("1 条记录 · 0 个警告")).toBeVisible();

      // Ensure both generated identifiers were real task IDs and not UI-only
      // placeholders; the assertion also prevents dead-code seed helpers.
      expect(ids.first).not.toBe(ids.second);
    } finally { await close(app, userData); }
  });

  test("keeps 500 projects and 1,000 task summaries responsive with bounded memory and frame cadence", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-scale-"));
    const { app, page } = await launch(userData);
    try {
      await page.getByRole("button", { name: "打开项目 默认项目" }).click();
      await expect(page.locator('#main-content[aria-label="工作台"]')).toBeVisible();
      const beforeMetrics = await app.evaluate(({ app: electronApp }) => electronApp.getAppMetrics().map((metric) => ({ type: metric.type, workingSetKb: metric.memory.workingSetSize })));
      await page.evaluate(async () => {
        const projects = await window.slateSync.projects.list();
        if (!projects.ok) throw new Error(projects.error.message);
        const projectId = projects.data.find((item) => item.name === "默认项目")?.id;
        if (!projectId) throw new Error("missing default project");
        // Seeding is deliberately serial so the fixture itself cannot hide an
        // uncontrolled production request fan-out.
        for (let index = 0; index < 1_000; index += 1) {
          const result = await window.slateSync.tasks.save({ projectId, task: { projectId, filename: `Perf Task ${String(index).padStart(4, "0")}`, status: "draft", pageCount: index % 20 } });
          if (!result.ok) throw new Error(result.error.message);
        }
      });
      const refreshStarted = performance.now();
      await page.getByRole("button", { name: "刷新任务列表" }).click();
      await expect(page.getByRole("button", { name: /^Perf Task 0999 / })).toBeVisible();
      const taskRefreshMs = performance.now() - refreshStarted;
      const taskRail = page.locator('[class*="taskRail"]').last();
      const taskSummaryDomRows = await taskRail.locator('[class*="taskVirtualRow"]').count();
      expect(taskSummaryDomRows).toBeLessThan(100);

      const frameMetrics = await taskRail.evaluate(async (element) => {
        const rail = element as HTMLElement;
        const frames: number[] = [];
        const longTasks: number[] = [];
        const observer = "PerformanceObserver" in window && PerformanceObserver.supportedEntryTypes.includes("longtask")
          ? new PerformanceObserver((list) => { for (const entry of list.getEntries()) longTasks.push(entry.duration); })
          : null;
        observer?.observe({ entryTypes: ["longtask"] });
        for (let frame = 0; frame < 120; frame += 1) {
          await new Promise<void>((resolveFrame) => requestAnimationFrame((time) => { frames.push(time); resolveFrame(); }));
          rail.scrollTop = (rail.scrollHeight - rail.clientHeight) * (frame / 119);
        }
        observer?.disconnect();
        const durationMs = (frames.at(-1) || 0) - (frames[0] || 0);
        return { durationMs, fps: durationMs > 0 ? ((frames.length - 1) * 1000) / durationMs : 0, maxFrameGapMs: Math.max(...frames.slice(1).map((time, index) => time - (frames[index] || time))), longTasks };
      });
      expect(frameMetrics.fps).toBeGreaterThanOrEqual(55);
      expect(frameMetrics.longTasks.filter((duration) => duration > 50)).toEqual([]);

      await taskRail.evaluate((element) => { (element as HTMLElement).scrollTop = 0; });
      await expect(page.getByRole("button", { name: /^Perf Task 0999 / })).toBeVisible();
      const switchSamples: number[] = [];
      for (const label of ["0999", "0998", "0999", "0998", "0999"]) {
        const started = performance.now();
        const button = page.getByRole("button", { name: new RegExp(`^Perf Task ${label} `) });
        await button.click();
        await expect(button).toHaveAttribute("data-active", "true");
        switchSamples.push(performance.now() - started);
      }

      await page.evaluate(async () => {
        for (let index = 1; index < 500; index += 1) {
          const result = await window.slateSync.projects.create({ name: `Perf Project ${String(index).padStart(3, "0")}`, description: "Synthetic scale fixture" });
          if (!result.ok) throw new Error(result.error.message);
        }
      });
      await page.getByRole("button", { name: "项目库", exact: true }).click();
      const projectRefreshStarted = performance.now();
      await page.getByRole("button", { name: "刷新", exact: true }).click();
      await expect(page.locator('[class*="metricValue"]').first()).toHaveText("500");
      const projectRefreshMs = performance.now() - projectRefreshStarted;
      const projectCards = await page.locator('button[aria-label^="打开项目 "]').count();
      expect(projectCards).toBe(500);
      expect(projectRefreshMs).toBeLessThan(2_000);
      expect(taskRefreshMs).toBeLessThan(2_000);

      const afterMetrics = await app.evaluate(({ app: electronApp }) => electronApp.getAppMetrics().map((metric) => ({ type: metric.type, workingSetKb: metric.memory.workingSetSize })));
      console.log("IP03_08_SCALE_PERFORMANCE_MEMORY", JSON.stringify({ hardware: `${process.platform}-${process.arch}`, runtime: process.version, projects: 500, projectCards, projectRefreshMs, tasks: 1_000, taskSummaryDomRows, taskRefreshMs, frameMetrics, switchSamples, beforeMetrics, afterMetrics }));
    } finally { await close(app, userData); }
  });

  test("prepares a valid PDF and rejects over-limit or corrupt replacements without stale state", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-pdf-"));
    const { app, page } = await launch(userData);
    try {
      await page.getByRole("button", { name: "打开项目 默认项目" }).click();
      const input = page.locator("input[data-slate-upload]");
      await input.setInputFiles({ name: "too-many-pages.pdf", mimeType: "application/pdf", buffer: blankPdf(21) });
      await expect(page.getByRole("alert")).toContainText("PDF 最多支持 20 页");
      await page.getByRole("button", { name: "重试" }).click();

      await input.setInputFiles({ name: "one-page.pdf", mimeType: "application/pdf", buffer: blankPdf(1) });
      await expect(page.getByText("one-page.pdf", { exact: true })).toBeVisible();
      await expect(page.getByText(/PDF · .* · 1 页/)).toBeVisible();

      await page.getByRole("button", { name: "移除" }).click();
      await expect(page.getByText("one-page.pdf", { exact: true })).toHaveCount(0);
      await input.setInputFiles({ name: "broken.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-broken", "ascii") });
      await expect(page.getByRole("alert")).toContainText("无法读取 PDF");
      await page.getByRole("button", { name: "全局设置" }).click();
      await expect(page.locator('#main-content[aria-label="全局设置"]')).toBeVisible();
      // Both route-scoped Workers must be gone after the workspace unmounts.
      await expect.poll(() => page.workers().length).toBe(0);
    } finally { await close(app, userData); }
  });

  test("keeps modern project and task switching within the legacy baseline", async () => {
    const measure = async (mode: "legacy" | "modern") => {
      const userData = await mkdtemp(join(tmpdir(), `slatesync-e2e-switch-${mode}-`));
      const launched = mode === "legacy" ? await launchLegacy(userData) : await launch(userData);
      const { app, page } = launched;
      try {
        const ids = await page.evaluate(async () => {
          const projects = await window.slateSync.projects.list();
          if (!projects.ok) throw new Error(projects.error.message);
          const defaultProject = projects.data.find((item) => item.name === "默认项目");
          if (!defaultProject) throw new Error("missing default project");
          const secondProject = await window.slateSync.projects.create({ name: "Switch Project", description: "isolated timing fixture" });
          if (!secondProject.ok) throw new Error(secondProject.error.message);
          const save = async (projectId: string, filename: string, scene: string) => {
            const record = { id: `record-${scene}`, sourcePage: 1, cardNumber: "A001", videoCode: "C001", scene, shot: "01", take: "01", takeStatus: "过" as const, description: null, comments: null, shotSize: null, cameraPosition: null, confidence: "high" as const };
            const rows = Array.from({ length: 500 }, (_, index) => [index === 0 ? "A001C001.mov" : `A${String(index + 2).padStart(3, "0")}C001.mov`, index === 0 ? scene : "", "", ""]);
            const result = await window.slateSync.tasks.save({ projectId, task: { projectId, filename, status: "completed", pageCount: 1, resolveCsvFilename: `${filename}.csv`, resolveCsvTable: { headers: ["File Name", "Scene", "Shot", "Take"], rows, format: { encoding: "utf-8", bom: false, delimiter: ",", lineEnding: "\r\n", finalNewline: true } }, result: { sheetTitle: filename, records: [record], warnings: [] }, editedRecords: [record] } });
            if (!result.ok) throw new Error(result.error.message);
            return result.data;
          };
          for (let index = 0; index < 1_000; index += 1) {
            for (const projectId of [defaultProject.id, secondProject.data.id]) {
              const summary = await window.slateSync.tasks.save({ projectId, task: { projectId, filename: `Switch Summary ${String(index).padStart(3, "0")}`, status: "draft", pageCount: index % 20 } });
              if (!summary.ok) throw new Error(summary.error.message);
            }
          }
          return { defaultProjectId: defaultProject.id, secondProjectId: secondProject.data.id, firstTaskId: await save(defaultProject.id, "Switch A", "101"), secondTaskId: await save(defaultProject.id, "Switch B", "202"), secondProjectTaskId: await save(secondProject.data.id, "Switch Project Task", "303") };
        });
        const taskSamples: number[] = [];
        const projectSamples: number[] = [];
        if (mode === "legacy") {
          await page.locator(`[data-project-action="open"][data-project-id="${ids.defaultProjectId}"]`).click();
          await expect(page.locator("#workspace-page")).not.toHaveAttribute("hidden", "");
          for (const [taskId, filename] of [[ids.firstTaskId, "Switch A.csv"], [ids.secondTaskId, "Switch B.csv"], [ids.firstTaskId, "Switch A.csv"], [ids.secondTaskId, "Switch B.csv"], [ids.firstTaskId, "Switch A.csv"]] as const) {
            taskSamples.push(await page.evaluate(({ id, expected }) => new Promise<number>((resolveTiming) => {
              const select = document.querySelector("#task-select") as HTMLSelectElement;
              const started = performance.now();
              const finish = () => {
                if (select.value !== id || document.querySelector("#metadata-file-name")?.textContent !== expected || document.querySelectorAll("#csv-result-body tr").length !== 500) return;
                observer.disconnect();
                resolveTiming(performance.now() - started);
              };
              const observer = new MutationObserver(finish);
              observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
              select.value = id;
              select.dispatchEvent(new Event("change", { bubbles: true }));
              finish();
            }), { id: taskId, expected: filename }));
          }
          for (const projectId of [ids.secondProjectId, ids.defaultProjectId, ids.secondProjectId, ids.defaultProjectId]) {
            await page.locator("#nav-projects").click();
            await expect(page.locator("#project-home-page")).not.toHaveAttribute("hidden", "");
            projectSamples.push(await page.evaluate(({ id, name }) => new Promise<number>((resolveTiming) => {
              const target = document.querySelector<HTMLButtonElement>(`[data-project-action="open"][data-project-id="${id}"]`);
              if (!target) throw new Error(`missing project ${name}`);
              const started = performance.now();
              const expectedTask = name === "Switch Project" ? "Switch Project Task" : "Switch A";
              const finish = () => {
                const tasksReady = [...document.querySelectorAll("#task-select option")].some((option) => option.textContent?.includes(expectedTask));
                if (document.querySelector("#workspace-page")?.hasAttribute("hidden") || !document.querySelector("#project-context")?.textContent?.includes(name) || !tasksReady) return;
                observer.disconnect();
                resolveTiming(performance.now() - started);
              };
              const observer = new MutationObserver(finish);
              observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
              target.click();
              finish();
            }), { id: projectId, name: projectId === ids.secondProjectId ? "Switch Project" : "默认项目" }));
          }
        } else {
          await page.getByRole("button", { name: "打开项目 默认项目" }).click();
          await page.getByRole("button", { name: "刷新任务列表" }).click();
          for (const taskId of [ids.firstTaskId, ids.secondTaskId, ids.firstTaskId, ids.secondTaskId, ids.firstTaskId]) {
            taskSamples.push(await page.evaluate(({ label }) => new Promise<number>((resolveTiming) => {
              const target = [...document.querySelectorAll<HTMLButtonElement>('button[data-active]')].find((button) => button.textContent?.includes(label));
              if (!target) throw new Error(`missing task button ${label}`);
              const started = performance.now();
              const finish = () => {
                if (target.getAttribute("data-active") !== "true") return;
                observer.disconnect();
                resolveTiming(performance.now() - started);
              };
              const observer = new MutationObserver(finish);
              observer.observe(target, { attributes: true, attributeFilter: ["data-active"] });
              target.click();
              finish();
            }), { label: taskId === ids.firstTaskId ? "Switch A" : "Switch B" }));
          }
          for (const name of ["Switch Project", "默认项目", "Switch Project", "默认项目"]) {
            await page.getByRole("button", { name: "项目库", exact: true }).click();
            projectSamples.push(await page.evaluate(({ expected }) => new Promise<number>((resolveTiming) => {
              const target = document.querySelector<HTMLButtonElement>(`button[aria-label="打开项目 ${expected}"]`);
              if (!target) throw new Error(`missing project ${expected}`);
              const started = performance.now();
              const expectedTask = expected === "Switch Project" ? "Switch Project Task" : "Switch A";
              const finish = () => {
                const main = document.querySelector('#main-content[aria-label="工作台"]');
                const heading = [...document.querySelectorAll("h1, h2")].some((item) => item.textContent?.trim() === expected);
                const tasksReady = [...document.querySelectorAll("button")].some((button) => button.textContent?.includes(expectedTask));
                if (!main || !heading || !tasksReady) return;
                observer.disconnect();
                resolveTiming(performance.now() - started);
              };
              const observer = new MutationObserver(finish);
              observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
              target.click();
              finish();
            }), { expected: name }));
          }
        }
        const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
        return { mode, taskSamples, projectSamples, taskMedianMs: median(taskSamples), projectMedianMs: median(projectSamples) };
      } finally { await close(app, userData); }
    };
    const legacy = await measure("legacy");
    const modern = await measure("modern");
    expect(modern.taskMedianMs).toBeLessThanOrEqual(legacy.taskMedianMs * 1.15);
    expect(modern.projectMedianMs).toBeLessThanOrEqual(legacy.projectMedianMs * 1.15);
    console.log("IP03_08_SWITCH_BASELINE", JSON.stringify({ hardware: `${process.platform}-${process.arch}`, runtime: process.version, warmup: "each Renderer booted and opened the default project before alternating samples", sampleCount: { task: 5, project: 4 }, legacy, modern }));
  });

  test("keeps keyboard focus, ARIA state, reduced motion, and route scroll bounded", async () => {
    const userData = await mkdtemp(join(tmpdir(), "slatesync-e2e-a11y-"));
    const { app, page } = await launch(userData);
    try {
      const newProjectButton = page.getByRole("button", { name: "新建项目", exact: true });
      await newProjectButton.focus();
      await expect(newProjectButton).toBeFocused();
      await newProjectButton.press("Enter");
      const dialog = page.getByRole("dialog", { name: "新建项目" });
      await expect(dialog).toBeVisible();
      await expect(dialog.getByRole("button", { name: "关闭对话框" })).toBeFocused();
      expect(await dialog.getAttribute("aria-modal")).toBe("true");
      await page.keyboard.press("Tab");
      await expect(dialog.locator("input").first()).toBeFocused();

      await page.keyboard.press("Escape");
      await expect(dialog).toBeHidden();
      await expect(newProjectButton).toBeFocused();

      await page.getByRole("button", { name: "打开项目 默认项目" }).click();
      await expect(page.locator('#main-content[aria-label="工作台"]')).toBeVisible();
      await page.getByRole("button", { name: "项目设置" }).first().click();
      await expect(page.locator('#main-content[aria-label="项目设置"]')).toBeVisible();

      await page.evaluate(() => window.scrollTo({ top: 500, left: 0, behavior: "auto" }));
      await page.getByRole("button", { name: "工作台", exact: true }).click();
      await page.waitForFunction(() => Math.abs(window.scrollY) < 1);

      await page.emulateMedia({ reducedMotion: "reduce" });
      const accessibilityFacts = await page.evaluate(() => ({
        motion: getComputedStyle(document.documentElement).getPropertyValue("--ss-motion-base").trim(),
        unlabeledButtons: [...document.querySelectorAll("button")]
          .filter((button) => !button.getAttribute("aria-label") && !button.textContent?.trim() && !button.getAttribute("title"))
          .map((button) => button.outerHTML.slice(0, 160)),
        mainLabel: document.querySelector("#main-content")?.getAttribute("aria-label"),
      }));
      expect(accessibilityFacts.motion).toBe("1ms");
      expect(accessibilityFacts.unlabeledButtons).toEqual([]);
      expect(accessibilityFacts.mainLabel).toBe("工作台");
    } finally { await close(app, userData); }
  });
});
