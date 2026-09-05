#!/usr/bin/env node

// Captures only user-reachable modern Renderer states in an isolated profile.
// The script intentionally drives the same Project Library, settings, and
// validation controls as an operator; no production-only visual hook exists.
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { _electron as electron } from "@playwright/test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
// Raw captures are local test output. A reviewer can still override the path,
// while the default stays under the repository's ignored test-results tree.
const outputRoot = resolve(process.env.SLATESYNC_VISUAL_OUTPUT || join(root, "test-results", "refactor", "IP-03-08", "visual-run-1"));
const mainPath = join(root, "electron", "main.mjs");
const configPath = join(root, "slatesync.config.json");

async function stable(page) {
  await page.evaluate(async () => {
    await document.fonts.ready;
    await new Promise((resolvePromise) => requestAnimationFrame(() => requestAnimationFrame(resolvePromise)));
  });
}

async function resetTransientFocus(page) {
  await page.evaluate(() => {
    const active = document.activeElement;
    if (active instanceof HTMLElement) active.blur();
    const body = document.body;
    const hadTabIndex = body.hasAttribute("tabindex");
    if (!hadTabIndex) body.setAttribute("tabindex", "-1");
    body.focus({ preventScroll: true });
    if (!hadTabIndex) body.removeAttribute("tabindex");
  });
  await page.waitForFunction(() => document.activeElement === document.body || document.activeElement === document.documentElement);
}

async function resetViewportScroll(page) {
  await page.evaluate(() => {
    window.scrollTo(0, 0);
    document.scrollingElement?.scrollTo({ top: 0, left: 0, behavior: "auto" });
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
  });
  await page.waitForFunction(() => {
    const owner = document.scrollingElement;
    return window.scrollY === 0 && (owner ? owner.scrollTop === 0 : true);
  });
}

async function capture(page, name, width, height) {
  await page.setViewportSize({ width, height });
  // Resizing can preserve the previously focused control's scroll position;
  // reset after the resize so every baseline captures the page origin.
  await resetViewportScroll(page);
  // Stable screenshots describe the settled page, not the OS cursor's
  // transient hover/focus state. Keyboard focus is verified separately by
  // the E2E/a11y evidence so this does not hide an accessibility defect.
  await page.mouse.move(2, 2);
  await resetTransientFocus(page);
  await stable(page);
  if (name === "09-workspace-dark-reduced-motion") {
    const finalGeometry = await page.evaluate(() => {
      const aside = document.querySelector("aside");
      const brand = aside?.firstElementChild;
      return {
        windowY: window.scrollY,
        asideY: aside?.getBoundingClientRect().top ?? null,
        brandY: brand?.getBoundingClientRect().top ?? null,
        brandText: brand?.textContent?.trim() ?? null,
      };
    });
    process.stdout.write(`VISUAL_CAPTURE_GEOMETRY ${JSON.stringify(finalGeometry)}\n`);
  }
  const path = join(outputRoot, `${name}-${width}x${height}.png`);
  await page.screenshot({ path, animations: "disabled" });
  return path;
}

async function captureElement(page, name, width, height, locator) {
  await page.setViewportSize({ width, height });
  await locator.scrollIntoViewIfNeeded();
  await page.mouse.move(2, 2);
  await resetTransientFocus(page);
  await stable(page);
  const path = join(outputRoot, `${name}-${width}x${height}.png`);
  await locator.screenshot({ path, animations: "disabled" });
  return path;
}

async function waitRoute(page, label) {
  await page.waitForSelector(`#main-content[aria-label="${label}"]`);
  await page.waitForFunction(() => {
    const owner = document.scrollingElement;
    return window.scrollY === 0 && (owner ? owner.scrollTop === 0 : true);
  });
  await stable(page);
}

const userData = await mkdtemp(join(tmpdir(), "slatesync-visual-"));
// Keep the displayed portable-library path deterministic across the two
// captures while still allocating it under the OS temp directory. The
// profile remains random for process isolation; only the disposable package
// name is stable so a user-visible path does not invalidate PNG hashes.
const isolatedLibrary = join(tmpdir(), "slatesync-visual-baseline.slatesync-library");
const tinySlatePath = join(userData, "visual-slate.png");
// Reuse the executable legacy baseline as disposable image bytes; the
// loopback provider returns deterministic slate data and never interprets it.
await writeFile(tinySlatePath, await readFile(join(root, ".codex", "refactor", "baseline", "visual", "workspace-empty.png")));

let providerGateOpen = false;
const providerWaiters = [];
let markProviderRequest;
const providerRequest = new Promise((resolvePromise) => { markProviderRequest = resolvePromise; });
const providerServer = createServer(async (request, response) => {
  if (request.url?.endsWith("/models")) {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ data: [{ id: "visual-model", object: "model" }] }));
    return;
  }
  if (request.method !== "POST" || !request.url?.endsWith("/responses")) {
    response.writeHead(404).end();
    return;
  }
  for await (const _chunk of request) { /* Consume the real request body before exposing progress. */ }
  markProviderRequest();
  if (!providerGateOpen) await new Promise((resolvePromise) => providerWaiters.push(resolvePromise));
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({
    output_text: JSON.stringify({
      sheetTitle: "Visual Functional Slate",
      records: [{ cardNumber: "A001", videoCode: "C001", scene: "12", shot: "03", take: "02", takeStatus: "过", description: "演员进入画面", comments: null, shotSize: "中景", cameraPosition: "A 机", confidence: "high" }],
      warnings: [],
    }),
    usage: { input_tokens: 30, output_tokens: 20 },
  }));
});
providerServer.listen(0, "127.0.0.1");
await once(providerServer, "listening");
const providerAddress = providerServer.address();
if (!providerAddress || typeof providerAddress === "string") throw new Error("visual provider server did not bind");
const providerBaseUrl = `http://127.0.0.1:${providerAddress.port}/v1`;
await mkdir(outputRoot, { recursive: true });
await rm(isolatedLibrary, { recursive: true, force: true });
await writeFile(join(userData, "settings.json"), JSON.stringify({
  libraryPath: isolatedLibrary,
  ocrPythonPath: "",
  ocrSetupCompleted: false,
  ocrSetupSkipped: true,
}), "utf8");
let app;
try {
  app = await electron.launch({
    // Chromium's default macOS color-management profile can change between
    // fresh 960px captures. Pin the disposable visual runner to sRGB so the
    // stability check measures app pixels rather than ICC metadata/transform.
    args: ["--force-color-profile=srgb", `--user-data-dir=${userData}`, mainPath],
    cwd: root,
    env: {
      ...process.env,
      SLATESYNC_CONFIG_PATH: configPath,
      OPENAI_API_KEY: "",
      OPENROUTER_API_KEY: "",
      TOKENPLAN_API_KEY: "",
      DASHSCOPE_API_KEY: "",
      OPENAI_COMPATIBLE_API_KEY: "visual-capture-only",
      OPENAI_COMPATIBLE_BASE_URL: providerBaseUrl,
      OPENAI_COMPATIBLE_MODEL: "visual-model",
      OPENAI_COMPATIBLE_API_MODE: "responses",
      OPENAI_COMPATIBLE_JSON_MODE: "json_schema",
    },
  });
  const page = await app.firstWindow();
  await page.waitForSelector('#main-content[aria-label="项目库"]');
  const paths = [];

  paths.push(await capture(page, "01-project-library-empty-dark", 1440, 900));
  await page.getByRole("button", { name: "新建项目" }).first().click();
  await page.getByRole("dialog", { name: "新建项目" }).waitFor();
  await stable(page);
  paths.push(await captureElement(page, "02-new-project-dialog-dark", 1440, 900, page.getByRole("dialog", { name: "新建项目" })));
  await page.getByRole("button", { name: "取消" }).click();
  // Choose the same explicit preference exposed by Global Settings so the
  // sidebar's three-state shortcut does not make the baseline OS-dependent.
  await page.getByRole("button", { name: "全局设置" }).click();
  await waitRoute(page, "全局设置");
  await page.getByRole("combobox", { name: "主题" }).selectOption("light");
  await page.getByRole("button", { name: "项目库" }).click();
  await waitRoute(page, "项目库");
  await page.waitForFunction(() => document.documentElement.dataset.theme === "light");
  paths.push(await capture(page, "03-project-library-light", 1440, 900));
  await page.getByRole("button", { name: "紧凑密度" }).click();
  await page.waitForFunction(() => document.documentElement.dataset.density === "compact");
  paths.push(await capture(page, "04-project-library-compact-light", 960, 600));

  // Use the migration-owned default project for the workspace/settings states.
  // Its fixed v1 ID keeps the user-visible toolbar deterministic without
  // changing production's random ID generation for newly created projects.
  await page.getByRole("button", { name: "打开项目 默认项目" }).click();
  await waitRoute(page, "工作台");
  paths.push(await capture(page, "05-workspace-empty-compact-light", 960, 600));

  await page.getByRole("button", { name: "全局设置" }).click();
  await waitRoute(page, "全局设置");
  await page.getByRole("combobox", { name: "Provider" }).waitFor();
  await page.locator('input[placeholder="粘贴 API Key"]').waitFor();
  paths.push(await capture(page, "06-global-settings-light", 960, 600));

  await page.getByRole("button", { name: "项目设置" }).click();
  await waitRoute(page, "项目设置");
  paths.push(await capture(page, "07-project-settings-light", 960, 600));
  await page.locator("#project-settings-form input").first().fill("");
  await page.locator("#project-settings-form button[type=submit]").click();
  const projectNameError = page.getByRole("alert").filter({ hasText: "请输入项目名称。" });
  await projectNameError.waitFor();
  // Keep the captured error state user-visible at the field that owns it.
  await projectNameError.scrollIntoViewIfNeeded();
  await stable(page);
  paths.push(await capture(page, "08-project-settings-error-light", 960, 600));

  await page.locator('button[title="工作台"]').click();
  await waitRoute(page, "工作台");
  const scrollGeometry = await page.evaluate(() => {
    const aside = document.querySelector("aside");
    const brand = document.querySelector("aside > div");
    return {
      windowY: window.scrollY,
      documentY: document.documentElement.scrollTop,
      bodyY: document.body.scrollTop,
      asideY: aside?.getBoundingClientRect().top ?? null,
      asideScrollTop: aside?.scrollTop ?? null,
      brandY: brand?.getBoundingClientRect().top ?? null,
      brandHeight: brand?.getBoundingClientRect().height ?? null,
    };
  });
  process.stdout.write(`VISUAL_SCROLL_GEOMETRY ${JSON.stringify(scrollGeometry)}\n`);
  await page.getByRole("button", { name: "全局设置" }).click();
  await waitRoute(page, "全局设置");
  await page.getByRole("combobox", { name: "主题" }).selectOption("dark");
  await page.getByRole("button", { name: "工作台" }).click();
  await waitRoute(page, "工作台");
  await page.waitForFunction(() => document.documentElement.dataset.theme === "dark");
  await page.emulateMedia({ reducedMotion: "reduce" });
  paths.push(await capture(page, "09-workspace-dark-reduced-motion", 1440, 900));

  await page.getByRole("button", { name: "项目库" }).click();
  await waitRoute(page, "项目库");
  await page.getByRole("button", { name: "新建项目" }).first().click();
  await page.locator("#new-project-form input").first().fill("Visual Baseline Project");
  await page.getByRole("button", { name: "创建项目" }).click();
  await waitRoute(page, "工作台");
  await page.getByRole("button", { name: "项目库" }).click();
  await waitRoute(page, "项目库");
  await page.locator('[class*="projectCard"]').filter({ hasText: "Visual Baseline Project" }).getByRole("button", { name: "归档" }).click();
  await page.getByRole("button", { name: "恢复" }).waitFor();
  const archiveToast = page.locator('[role="status"]').filter({ hasText: "项目已归档" });
  await archiveToast.waitFor();
  await archiveToast.getByRole("button", { name: "关闭通知" }).click();
  await archiveToast.waitFor({ state: "detached" });
  // The Library intentionally retains current-project context. Select the
  // stable default project before this full-page capture so a freshly created
  // random project ID does not masquerade as visual drift between runs.
  await page.getByRole("button", { name: "打开项目 默认项目" }).click();
  await waitRoute(page, "工作台");
  await page.getByRole("button", { name: "项目库" }).click();
  await waitRoute(page, "项目库");
  paths.push(await capture(page, "10-project-library-archived-dark", 1440, 900));

  await page.getByRole("button", { name: "打开项目 默认项目" }).click();
  await waitRoute(page, "工作台");
  // Functional modern states use the unchanged recognition contract against
  // a gated loopback provider. The response is released by the capture flow,
  // so evidence contains no fixed wait, real credential, or production hook.
  await page.locator("input[data-slate-upload]").setInputFiles(tinySlatePath);
  await page.getByAltText("visual-slate.png 第 1 页预览").first().waitFor();
  paths.push(await captureElement(page, "11-workspace-ready-dark", 1440, 900, page.locator('[class*="workspaceMain"]')));
  await page.getByRole("combobox", { name: "Provider" }).selectOption("openai-compatible");
  await page.getByRole("combobox", { name: "模型" }).selectOption("openai-compatible/custom");
  await page.getByRole("combobox", { name: "识别模式" }).selectOption("standard");
  await page.getByRole("button", { name: "开始识别" }).click();
  const progressBanner = page.locator('[class*="recognitionBanner"]').first();
  await progressBanner.waitFor();
  await providerRequest;
  paths.push(await captureElement(page, "12-recognition-progress-dark", 1440, 900, progressBanner));
  providerGateOpen = true;
  for (const release of providerWaiters.splice(0)) release();
  await page.waitForFunction(() => Boolean(document.querySelector("#recognition-results-title") || document.querySelector('[role="alert"]')));
  const recognitionAlert = page.locator('[role="alert"]').last();
  if (await recognitionAlert.count()) throw new Error(`visual recognition failed: ${await recognitionAlert.innerText()}`);
  const resultPanel = page.locator('[aria-labelledby="recognition-results-title"]');
  paths.push(await captureElement(page, "13-result-detail-dark", 1440, 900, resultPanel));
  await page.locator("input[data-csv-upload]").setInputFiles(join(root, "test", "fixtures", "baseline", "csv", "resolve-source.csv"));
  const csvPreview = page.locator('[data-testid="csv-virtual-table"]');
  await csvPreview.waitFor();
  paths.push(await captureElement(page, "14-csv-preview-dark", 1440, 900, csvPreview));

  const files = [];
  for (const path of paths) {
    const bytes = await readFile(path);
    files.push({ name: path.slice(outputRoot.length + 1), bytes: bytes.byteLength, sha256: createHash("sha256").update(bytes).digest("hex") });
  }
  await writeFile(join(outputRoot, "manifest.json"), `${JSON.stringify({ generatedAt: new Date().toISOString(), viewportStates: files }, null, 2)}\n`, "utf8");
  process.stdout.write(`VISUAL_BASELINE_CAPTURE_OK ${files.length} ${outputRoot}\n`);
} finally {
  await app?.close();
  providerServer.close();
  await once(providerServer, "close").catch(() => undefined);
  await rm(userData, { recursive: true, force: true });
  await rm(isolatedLibrary, { recursive: true, force: true });
}
