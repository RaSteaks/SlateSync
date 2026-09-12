// Real Chromium + renderer, synthetic gateway. No Electron process or user library.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { mkdir, writeFile } = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('playwright');
const { fixture } = require('./ui-interaction-fixture.cjs');
const { layoutChecks } = require('./layout-browser-checks.cjs');
const root = path.resolve(__dirname, '../..');
const output = process.env.SLATESYNC_UI_OUTPUT || '/tmp/slatesync-interaction-browser';
const port = Number(process.env.SLATESYNC_UI_PORT || 5287);
const base = `http://127.0.0.1:${port}`;
const results = [];
const failures = [];
let serverLog = '';

async function main() {
  await mkdir(output, { recursive: true });
  const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--config', 'vite.renderer.config.ts', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  server.stdout.on('data', data => { serverLog += data; });
  server.stderr.on('data', data => { serverLog += data; });
  let browser;
  try {
    for (let attempt = 0; ; attempt++) {
      try { if ((await fetch(base)).ok) break; } catch {}
      if (attempt >= 60) throw new Error(`Vite did not start: ${serverLog}`);
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    browser = await chromium.launch({ headless: true, channel: 'chrome' });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark', reducedMotion: 'reduce' });
    page.setDefaultTimeout(12000);
    page.on('pageerror', error => failures.push(error.message));
    await fixture(page);
    const reset = async () => { await page.goto(base); await page.getByRole('button', { name: '打开项目 审查样例项目', exact: true }).waitFor(); };
    const openProject = async () => { await page.getByRole('button', { name: '打开项目 审查样例项目', exact: true }).click(); await page.getByRole('heading', { name: '载入场记单', exact: true }).waitFor(); };
    const nav = name => page.getByRole('button', { name, exact: true }).click();
    const test = async (name, callback) => {
      if (process.argv[2] && process.argv[2] !== name) return;
      await reset();
      try { await callback(); } catch (error) {
        results.push({ name, status: 'failed', error: error.message });
        await writeFile(path.join(output, `${name}-failure.txt`), await page.locator('body').innerText());
        await writeFile(path.join(output, `${name}-state.json`), JSON.stringify(await page.evaluate(async () => ({ export: (await import('/state/export-store.ts')).useExportStore.getState(), recognition: (await import('/state/recognition-store.ts')).useRecognitionStore.getState() })), null, 2));
        await page.screenshot({ path: path.join(output, `${name}-failure.png`) });
        throw error;
      }
      results.push({ name, status: 'passed' });
      console.log(`PASS ${name}`);
    };

    await test('resolve-builtin-template', async () => {
      await openProject();
      await page.evaluate(async () => {
        // Synthetic recognized row and save gateway; no user media or library.
        const { useRecognitionStore } = await import('/state/recognition-store.ts');
        useRecognitionStore.setState({ records: [{ id: 'template-record', targetId: 'manual:template', cardNumber: 'A001', videoCode: 'C001', scene: '12A', shot: 'B', take: '003', comments: '对白完整', description: '街口外景' }] });
        window.slateSync.files = { save: ({data}) => { window.__review.savedCsv = new TextDecoder('utf-8').decode(data); return Promise.resolve({ok: true, data: {saved: true, filePath: '/tmp/synthetic.csv'}}); } };
      });
      await nav('项目设置');
      const template = page.getByRole('combobox', { name: '导出模板', exact: true });
      await template.selectOption('resolve-21.1-csv-v1');
      await page.getByRole('checkbox', { name: '内容描述', exact: true }).check();
      for (const name of ['素材文件名', '素材起始时码', '素材结束时码', '卷名', '源文件目录']) assert.equal(await page.getByRole('checkbox', {name, exact: true}).isDisabled(), true);
      await template.focus(); await page.keyboard.press('Space'); await page.keyboard.press('Escape');
      await page.screenshot({path: path.join(output, 'resolve-template-settings.png'), fullPage: true});
      await page.setViewportSize({width: 960, height: 700});
      await page.emulateMedia({colorScheme: 'light', reducedMotion: 'reduce'});
      await page.screenshot({path: path.join(output, 'resolve-template-settings-narrow.png'), fullPage: true});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await nav('保存项目设置');
      await page.waitForFunction(() => window.__review.projects[0].settings.export?.templateId === 'resolve-21.1-csv-v1');
      await nav('返回工作台');
      await page.getByRole('heading', {name: '回填预览', exact: true}).scrollIntoViewIfNeeded();
      const fileName = page.getByRole('textbox', {name: 'File Name 第 2 行', exact: true});
      await fileName.waitFor();
      await nav('导出 Resolve CSV');
      await page.getByText(/Resolve 导出有 1 行缺少素材文件名/).first().waitFor();
      const edits = {'File Name': 'A001C001.mov', 'Start TC': '01:00:00:00', 'End TC': '01:00:09:24', 'Reel Name': 'A001', 'Clip Directory': '/Volumes/素材/A001'};
      for (const [header, value] of Object.entries(edits)) {
        const cell = page.getByRole('textbox', {name: `${header} 第 2 行`, exact: true});
        await cell.fill(value); await cell.press('Tab');
      }
      await page.waitForFunction(async () => (await import('/state/export-store.ts')).useExportStore.getState().previewTable?.exportWarnings?.length === 0);
      await nav('导出 Resolve CSV');
      await page.waitForFunction(() => Boolean(window.__review.savedCsv));
      const csv = await page.evaluate(() => window.__review.savedCsv);
      assert.equal(await page.getByText(/Resolve 导出有 1 行缺少素材文件名/).count(), 0);
      assert.match(csv, /^File Name,Start TC,End TC,Reel Name,Clip Directory,Scene,Shot,Take,Comments,Description/);
      assert.match(csv, /A001C001.mov,01:00:00:00,01:00:09:24,A001,\/Volumes\/素材\/A001,12A,B,003,对白完整,街口外景/);
      await page.screenshot({path: path.join(output, 'resolve-template-preview.png'), fullPage: true});
      await nav('项目设置');
      assert.equal(await template.inputValue(), 'resolve-21.1-csv-v1');
      assert.equal(await page.getByRole('checkbox', {name: '内容描述', exact: true}).isChecked(), true);
      await page.getByRole('button', {name: '上移素材起始时码', exact: true}).click();
      await nav('保存项目设置');
      await page.waitForFunction(() => window.__review.projects[0].settings.export.columns[0].key === 'startTimecode');
      await nav('返回工作台');
      await page.getByRole('heading', {name: '回填预览', exact: true}).scrollIntoViewIfNeeded();
      await page.waitForFunction(async () => (await import('/state/export-store.ts')).useExportStore.getState().previewTable?.headers[0] === 'Start TC');
      await page.evaluate(() => { window.__review.savedCsv = null; });
      await nav('导出 Resolve CSV');
      await page.waitForFunction(() => Boolean(window.__review.savedCsv));
      const restoredCsv = await page.evaluate(() => window.__review.savedCsv);
      assert.match(restoredCsv, /^Start TC,File Name,End TC/);
      assert.match(restoredCsv, /01:00:00:00,A001C001.mov,01:00:09:24/);

    });

    await test('project-import-template', async () => {
      await openProject(); await nav('项目设置');
      const template = page.getByRole('combobox', { name: '导出模板', exact: true });
      assert.equal(await template.inputValue(), 'resolve-21.1-csv-v1');
      const input = page.getByLabel('导入 CSV 模板文件', { exact: true });
      await input.setInputFiles({ name: '后期样表.csv', mimeType: 'text/csv', buffer: Buffer.from('Comments;File Name;客户备注;Scene\n样本不得复用;sample.mov;PRIVATE SAMPLE;999\n') });
      await page.getByRole('status').filter({hasText: '已导入 后期样表.csv'}).waitFor();
      assert.equal(await template.inputValue(), 'imported-csv-v1');
      await input.setInputFiles({ name: '错误.csv', mimeType: 'text/csv', buffer: Buffer.from('Scene,scene') });
      await page.getByText('模板包含重复列标题：scene').waitFor();
      assert.equal(await template.inputValue(), 'imported-csv-v1');
      await nav('保存项目设置');
      await page.waitForFunction(() => window.__review.projects[0].settings.export?.templateId === 'imported-csv-v1');
      assert.equal(await page.evaluate(() => JSON.stringify(window.__review.projects[0].settings).includes('PRIVATE SAMPLE')), false);
      await page.screenshot({path: path.join(output, 'import-template-settings.png'), fullPage: true});
      await nav('返回工作台');
      await page.evaluate(async () => {
        // A fresh task has no session override and must inherit the saved schema.
        const { useExportStore } = await import('/state/export-store.ts');
        useExportStore.getState().clear();
        const { useRecognitionStore } = await import('/state/recognition-store.ts');
        useRecognitionStore.setState({ records: [{id: 'new-task-row', targetId:'manual:new-task', scene:'12A', shot:'B', take:'003', comments:'真实备注'}] });
        window.slateSync.files = { save: ({data}) => { window.__review.savedCsv = new TextDecoder().decode(data); return Promise.resolve({ok:true,data:{saved:true,filePath:'/tmp/synthetic.csv'}}); } };
      });
      await page.getByRole('heading', { name:'回填预览', exact:true }).scrollIntoViewIfNeeded();
      const customCell = page.getByRole('textbox', { name: '客户备注 第 2 行', exact:true });
      await customCell.fill('人工填写'); await customCell.press('Tab');
      await nav('导出 Resolve CSV');
      await page.waitForFunction(() => Boolean(window.__review.savedCsv));
      assert.equal(await page.evaluate(() => window.__review.savedCsv), 'Comments;File Name;客户备注;Scene\n真实备注;;人工填写;12A\n');
      await nav('项目设置');
      assert.equal(await template.inputValue(), 'imported-csv-v1');
      await page.setViewportSize({width: 960, height: 700});
      await page.emulateMedia({colorScheme:'light'});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.screenshot({path: path.join(output, 'import-template-settings-narrow.png'), fullPage:true});
    });

    await test('project-create-retry', async () => {
      await page.evaluate(() => { window.__review.createMode = 'failure'; });
      await nav('新建项目');
      const dialog = page.getByRole('dialog');
      await dialog.getByLabel('项目名称', { exact: true }).fill('失败后保留');
      await dialog.getByRole('button', { name: '创建项目', exact: true }).click();
      await dialog.getByRole('alert').waitFor();
      assert.equal(await dialog.getByLabel('项目名称', { exact: true }).inputValue(), '失败后保留');
      await page.evaluate(() => { window.__review.createMode = 'success'; });
      await dialog.getByRole('button', { name: '创建项目', exact: true }).click();
      await page.getByRole('heading', { name: '载入场记单', exact: true }).waitFor();
    });

    await test('project-draft-guard', async () => {
      await openProject(); await nav('项目设置');
      const name = page.locator('#project-settings-name');
      await name.fill('新的项目名称');
      await page.evaluate(async () => { const { useProjectStore } = await import('/state/project-store.ts'); useProjectStore.getState().setConfig(structuredClone(window.__review.config)); });
      assert.equal(await name.inputValue(), '新的项目名称');
      await nav('日志');
      await page.getByRole('dialog').getByRole('button', { name: '取消', exact: true }).click();
      assert.equal(await name.inputValue(), '新的项目名称');
      await page.evaluate(() => {
        window.__review.update = window.slateSync.projects.update;
        window.slateSync.projects.update = data => new Promise(resolve => { window.__review.finishUpdate = () => resolve({ ok: false, error: { code: 'TEST', message: '模拟保存失败' } }); });
      });
      await nav('日志');
      await page.getByRole('dialog').getByRole('button', { name: '保存并离开', exact: true }).click();
      assert.equal(await page.getByRole('dialog').getByRole('button', { name: '取消', exact: true }).isDisabled(), true);
      await page.evaluate(() => window.__review.finishUpdate());
      await page.getByRole('dialog').getByRole('alert').waitFor();
      assert.equal(await name.inputValue(), '新的项目名称');
      await page.evaluate(() => { window.slateSync.projects.update = window.__review.update; });
      await page.getByRole('dialog').getByRole('button', { name: '保存并离开', exact: true }).click();
      await page.waitForFunction(async () => (await import('/state/ui-store.ts')).useUiStore.getState().route === 'logs');
      assert.equal(await page.evaluate(() => window.__review.projects[0].name), '新的项目名称');
      await nav('项目设置'); await name.fill('不应保存'); await nav('项目库');
      await page.getByRole('dialog').getByRole('button', { name: '放弃修改并离开', exact: true }).click();
      await page.getByRole('heading', { name: '项目库', exact: true }).waitFor();
      assert.equal(await page.evaluate(() => window.__review.projects[0].name), '新的项目名称');
    });

    await test('global-save-lock', async () => {
      await nav('全局设置');
      const endpoint = page.locator('#settings-general input').last();
      await endpoint.fill('https://first.example/v1');
      await page.evaluate(() => {
        window.slateSync.settings.saveGlobalSettings = patch => new Promise(resolve => {
          window.__review.finishSave = () => { Object.assign(window.__review.globalSettings.values, patch.values); resolve({ ok: true, data: structuredClone(window.__review.globalSettings) }); };
        });
      });
      await page.getByTestId('global-settings-save').click();
      assert.equal(await endpoint.isDisabled(), true);
      assert.equal(await page.getByRole('group', { name: '首选 OCR 引擎' }).getByRole('button').first().isDisabled(), true);
      assert.equal(await page.getByRole('group', { name: '主题', exact: true }).getByRole('button').first().isEnabled(), true);
      await page.evaluate(() => window.__review.finishSave());
      await page.waitForFunction(async () => (await import('/state/global-settings-store.ts')).useGlobalSettingsStore.getState().mutationOwner === null);
      assert.equal(await endpoint.inputValue(), 'https://first.example/v1');
      assert.equal(await endpoint.isEnabled(), true);
    });

    await test('provider-response-order', async () => {
      await openProject(); await nav('项目设置');
      await page.evaluate(() => {
        window.__review.responses = [];
        window.slateSync.recognition.getModels = ({ providerId }) => new Promise(resolve => {
          window.__review.responses.push({ providerId, done: () => resolve({ ok: true, data: { models: window.__review.models.filter(m => m.providers.includes(providerId)) } }) });
        });
      });
      const provider = page.locator('#project-settings-form').getByRole('combobox', { name: 'Provider', exact: true });
      await provider.selectOption('openrouter'); await provider.selectOption('openai');
      await page.waitForFunction(() => window.__review.responses.length === 2);
      await page.evaluate(() => { window.__review.responses[1].done(); window.__review.responses[0].done(); });
      const trigger = page.locator('#project-settings-form button[aria-haspopup="dialog"]');
      await trigger.click();
      const tree = page.getByRole('treegrid');
      await tree.waitFor();
      assert.match(await tree.textContent(), /Alpha/);
      assert.doesNotMatch(await tree.textContent(), /Beta/);
      await page.keyboard.press('Escape');
    });

    await test('manual-model-text-and-error', async () => {
      await nav('全局设置');
      await page.evaluate(() => {
        window.slateSync.settings.createCustomProvider = data => { window.__review.providerRequest = data; return Promise.resolve({ ok: false, error: { code: 'TEST', message: '模拟接口保存失败' } }); };
      });
      await page.locator('#settings-custom-providers').getByRole('button', { name: '新增', exact: true }).click();
      const dialog = page.getByRole('dialog');
      await dialog.getByRole('textbox', { name: /^接口名称/ }).fill('测试接口');
      await dialog.getByRole('textbox', { name: /^Base URL/ }).fill('https://example.test/v1');
      const manual = dialog.locator('textarea');
      await manual.fill('vendor/first'); await manual.press('End'); await manual.press('Enter'); await manual.pressSequentially('vendor/second');
      assert.equal(await manual.inputValue(), 'vendor/first\nvendor/second');
      await dialog.getByRole('button', { name: '保存接口', exact: true }).click();
      await dialog.getByRole('alert').waitFor();
      assert.deepEqual(await page.evaluate(() => window.__review.providerRequest.manualModelIds), ['vendor/first', 'vendor/second']);
      assert.equal(await manual.inputValue(), 'vendor/first\nvendor/second');
      assert.equal(await manual.isEnabled(), true);
      await dialog.getByRole('button', { name: '取消', exact: true }).click();
      await dialog.getByRole('button', { name: '继续编辑', exact: true }).click();
      assert.equal(await dialog.locator('textarea').inputValue(), 'vendor/first\nvendor/second');
    });

    await test('picker-keyboard', async () => {
      await page.evaluate(async url => { (await import(url)).mount(); }, '/@fs' + root + '/test-support/refactor/picker-browser-harness.tsx');
      const outer = page.getByRole('dialog', { name: '键盘测试', exact: true });
      const trigger = outer.locator('button[aria-haspopup="dialog"]');
      await trigger.focus(); await trigger.press('ArrowDown');
      await page.getByRole('treegrid').waitFor();
      const focused = () => page.evaluate(() => document.activeElement?.textContent?.trim());
      assert.equal(await focused(), 'Alpha');
      await page.keyboard.press('ArrowDown'); assert.equal(await focused(), 'Beta');
      await page.keyboard.press('Home'); assert.equal(await focused(), 'Alpha');
      for (const key of ['End', 'ArrowRight', 'ArrowDown']) await page.keyboard.press(key);
      assert.equal(await focused(), 'Gamma');
      await page.keyboard.press('d'); assert.equal(await focused(), 'Delta');
      assert.match(await trigger.textContent(), /Alpha/, 'browsing must not commit');
      await page.keyboard.press('Enter');
      assert.match(await trigger.textContent(), /Delta/);
      assert.equal(await page.getByRole('treegrid').count(), 0);
      await trigger.press('Space'); await page.getByRole('treegrid').waitFor();
      assert.equal(await focused(), 'Delta');
      await page.keyboard.press('ArrowLeft'); assert.equal(await focused(), '更多模型');
      await page.keyboard.press('ArrowLeft');
      assert.equal(await page.getByRole('row', { name: '更多模型', exact: true }).getAttribute('aria-expanded'), 'false');
      await page.keyboard.press('ArrowRight'); await page.keyboard.press('ArrowDown');
      await page.keyboard.press('Space');
      assert.match(await trigger.textContent(), /Gamma/);
      await trigger.press('ArrowDown'); await page.getByRole('treegrid').waitFor();
      // Reconfirming the current leaf must close as well.
      await page.keyboard.press('Enter');
      assert.equal(await page.getByRole('treegrid').count(), 0);
      await trigger.press('ArrowDown'); await page.getByRole('treegrid').waitFor();
      await page.keyboard.press('Escape');
      assert.equal(await outer.count(), 1);
      assert.equal(await trigger.evaluate(el => el === document.activeElement), true);
      await trigger.press('ArrowDown'); await page.getByRole('treegrid').waitFor();
      await page.keyboard.press('Tab');
      assert.equal(await outer.getByLabel('后续输入', { exact: true }).evaluate(el => el === document.activeElement), true);
      await trigger.click(); await page.getByRole('treegrid').waitFor();
      await page.addScriptTag({ path: require.resolve('axe-core') });
      const violations = await page.evaluate(async () => (await axe.run(document.querySelector('[aria-label="选择模型"]'), { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'] } })).violations);
      assert.deepEqual(violations.map(v => v.id), []);
      await page.screenshot({ path: path.join(output, 'picker-keyboard.png') });
      await page.keyboard.press('Escape');
      await page.setViewportSize({ width: 960, height: 700 });
      await trigger.click(); await page.getByRole('treegrid').waitFor();
      const popup = await page.getByRole('dialog', { name: '选择模型', exact: true }).boundingBox();
      assert.ok(popup && popup.x >= 0 && popup.y >= 0 && popup.x + popup.width <= 960 && popup.y + popup.height <= 700);
      await page.screenshot({ path: path.join(output, 'picker-keyboard-960.png') });
      await page.setViewportSize({ width: 1440, height: 900 });
    });

    await test('repeat-section-navigation', async () => {
      await nav('全局设置');
      const runtime = page.getByRole('group', { name: '全局设置分区导航' }).getByRole('button', { name: '运行参数', exact: true });
      const pageHeading = page.locator('#global-settings-heading');
      await runtime.click();
      await page.evaluate(() => window.scrollTo(0, 0));
      await runtime.click();
      assert.equal(await page.locator('#settings-runtime h2').evaluate(el => el === document.activeElement), true);
      assert.ok(await page.evaluate(() => window.scrollY) > 300);
      // The parent item and its shortcut share the page-top focus contract,
      // including repeated activation while Global Settings is already open.
      await nav('全局设置');
      assert.equal(await pageHeading.evaluate(el => el === document.activeElement), true);
      await runtime.click();
      await page.keyboard.press('Meta+,');
      assert.equal(await pageHeading.evaluate(el => el === document.activeElement), true);
      assert.equal(await page.evaluate(async () => (await import('/state/ui-store.ts')).useUiStore.getState().settingsSection), null);
    });

    await test('file-preparation-lock', async () => {
      await openProject();
      await page.evaluate(async () => {
        const service = (await import('/services/preparation-service.ts')).getPreparationService();
        window.__review.prepareCalls = 0;
        service.prepare = () => { window.__review.prepareCalls++; return new Promise((resolve, reject) => {
          window.__review.failPrepare = () => reject(new Error('模拟素材准备失败'));
          window.__review.finishPrepare = () => resolve({ pageCount: 1, imageDataGroups: [['data:image/png;base64,iVBORw0KGgo=']] });
        }); };
      });
      const input = page.locator('input[type="file"]').first();
      const file = { name: 'fixture.png', mimeType: 'image/png', buffer: Buffer.from('isolated fixture') };
      await input.setInputFiles(file);
      assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isDisabled(), true);
      assert.equal(await input.isDisabled(), true);
      // Other routes remain inspectable during preparation, but package
      // transfer must expose the same lease as a disabled, explained action.
      await nav('项目设置');
      assert.equal(await page.getByRole('button', { name: '导入项目', exact: true }).isDisabled(), true);
      assert.equal(await page.getByRole('button', { name: '导出项目', exact: true }).isDisabled(), true);
      assert.match(await page.locator('body').textContent(), /当前任务处理完成后，才能导入或导出项目/);
      await nav('工作台');
      await nav('项目库');
      assert.equal(await page.getByRole('heading', { name: '载入场记单', exact: true }).count(), 1);
      await page.evaluate(() => window.__review.failPrepare());
      await page.getByRole('alert').filter({ hasText: '模拟素材准备失败' }).waitFor();
      assert.equal(await input.isEnabled(), true);
      await input.setInputFiles(file);
      await page.evaluate(() => window.__review.finishPrepare());
      await page.waitForFunction(async () => (await import('/state/task-store.ts')).useTaskStore.getState().operation === null);
      assert.equal(await page.evaluate(() => window.__review.prepareCalls), 2);
      assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isEnabled(), true);
    });

    await test('recognition-lifetime-lock', async () => {
      await openProject();
      await page.evaluate(async () => {
        const { useSlateStore } = await import('/state/slate-store.ts');
        const { useTaskStore } = await import('/state/task-store.ts');
        const originalSave = window.slateSync.tasks.save;
        window.__review.runCalls = 0; window.__review.cancelCalls = 0;
        window.slateSync.tasks.save = request => window.__review.allowSave ? originalSave(request) : new Promise(resolve => {
          window.__review.finishAutosave = async () => { window.__review.allowSave = true; resolve(await originalSave(request)); };
        });
        window.slateSync.recognition.run = request => { window.__review.runCalls++; return new Promise(resolve => { window.__review.finishRun = () => resolve({ ok: false, error: { code: 'RECOGNITION_CANCELED', message: '识别已停止' } }); }); };
        window.slateSync.recognition.cancel = () => { window.__review.cancelCalls++; return new Promise(resolve => { window.__review.finishCancel = () => resolve({ ok: true, data: { canceled: true } }); }); };
        const c = document.createElement('canvas'); c.width = 8; c.height = 8; c.getContext('2d').fillRect(0, 0, 8, 8);
        useSlateStore.getState().setInput({ filename: 'review.png', fileType: 'image/png', fileSize: 128, pageCount: 1, imageDataGroups: [[c.toDataURL()]] });
        useTaskStore.getState().setItems([{ id: 'older', filename: '历史任务', status: 'draft', recordCount: 0 }], window.__review.projects[0].id);
      });
      // Exercise the real dirty/autosave path after supplying synthetic pixels.
      await page.getByRole('textbox', { name: /识别提示/ }).fill('浏览器识别测试');
      await page.waitForFunction(async () => ['dirty', 'saving'].includes((await import('/state/task-store.ts')).useTaskStore.getState().saveState));
      await nav('开始识别');
      await page.waitForFunction(() => Boolean(window.__review.finishAutosave));
      assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isDisabled(), true);
      assert.equal(await page.getByRole('button', { name: '删除历史任务', exact: true }).isDisabled(), true);
      assert.equal(await page.evaluate(() => window.__review.runCalls), 0);
      await nav('项目库');
      assert.equal(await page.getByRole('heading', { name: '载入场记单', exact: true }).count(), 1);
      await page.evaluate(() => { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true, cancelable: true })); window.__review.finishAutosave(); });
      await page.waitForFunction(() => window.__review.runCalls === 1);
      await nav('日志'); await nav('工作台');
      assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isDisabled(), true);
      await nav('停止');
      await page.evaluate(() => window.__review.finishRun());
      await page.waitForFunction(async () => (await import('/state/recognition-store.ts')).useRecognitionStore.getState().phase === 'stopping');
      assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isDisabled(), true);
      assert.equal(await page.evaluate(() => window.__review.cancelCalls), 1);
      await page.evaluate(() => window.__review.finishCancel());
      await page.waitForFunction(async () => (await import('/state/task-store.ts')).useTaskStore.getState().operation === null);
      assert.equal(await page.getByRole('button', { name: '新建', exact: true }).isEnabled(), true);
      await nav('新建');
      await page.waitForFunction(async () => !(await import('/state/slate-store.ts')).useSlateStore.getState().filename);
      await page.waitForFunction(async () => (await import('/state/task-store.ts')).useTaskStore.getState().operation === null);
      // Discarding project settings still flushes the independent workspace
      // draft before entering the library and releasing its input state.
      await page.evaluate(async () => {
        const save = window.slateSync.tasks.save;
        window.slateSync.tasks.save = request => new Promise(resolve => { window.__review.finishLeaveSave = () => resolve(save(request)); });
        (await import('/state/slate-store.ts')).useSlateStore.getState().setInput({ filename: 'leave.png', fileType: 'image/png', fileSize: 128, pageCount: 1, imageDataGroups: [['data:image/png;base64,iVBORw0KGgo=']] });
      });
      await page.getByRole('textbox', { name: /识别提示/ }).fill('离开前最后修改');
      await nav('项目设置');
      await page.locator('#project-settings-name').fill('放弃项目名称修改');
      await nav('项目库');
      await page.getByRole('dialog').getByRole('button', { name: '放弃修改并离开', exact: true }).click();
      await page.waitForFunction(() => Boolean(window.__review.finishLeaveSave));
      assert.equal(await page.evaluate(async () => (await import('/state/ui-store.ts')).useUiStore.getState().route), 'project-settings');
      await page.evaluate(() => window.__review.finishLeaveSave());
      await page.getByRole('heading', { name: '项目库', exact: true }).waitFor();
      assert.equal(await page.evaluate(async () => (await import('/state/slate-store.ts')).useSlateStore.getState().filename), null);
      assert.equal(await page.evaluate(() => [...window.__review.tasks.values()].some(task => task.customPrompt === '离开前最后修改')), true);
    });
    // Share the isolated browser/gateway with geometry, focus and contrast
    // regressions so layout work also runs all nine interaction flows above.
    await layoutChecks({ page, test, nav, output });
    assert.deepEqual(failures, [], 'browser page errors');
  } finally {
    if (browser) await browser.close();
    server.kill('SIGTERM');
    await writeFile(path.join(output, 'results.json'), JSON.stringify({ results, pageErrors: failures }, null, 2));
    await writeFile(path.join(output, 'vite.log'), serverLog);
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
