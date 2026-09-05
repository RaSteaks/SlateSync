// Layout acceptance uses the same real renderer and in-memory gateway as the
// interaction suite. Measurements come from Chromium, never from CSS snapshots.
const assert = require('node:assert/strict');
const { writeFile } = require('node:fs/promises');
const path = require('node:path');
const { expect } = require('@playwright/test');

async function layoutChecks({ page, test, nav, output }) {
  const evidence = { geometry: [], sidebar: [], contrast: [] };
  const settle = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const appearance = async (density, collapsed, theme = 'dark') => {
    await page.evaluate(async ({ density, collapsed, theme }) => {
      const { useUiStore } = await import('/state/ui-store.ts');
      useUiStore.getState().setDensity(density);
      useUiStore.getState().setTheme(theme);
      if (useUiStore.getState().sidebarCollapsed !== collapsed) useUiStore.getState().toggleSidebar();
    }, { density, collapsed, theme });
    await settle();
  };
  const geometry = () => page.locator('#settings-general').evaluate(section => {
    const rect = el => {
      const { x, y, width, height, right, bottom } = el.getBoundingClientRect();
      return { x, y, width, height, right, bottom };
    };
    const grid = section.querySelector('[data-testid="settings-overview-grid"]');
    const cards = [...grid.children].map(rect);
    const style = getComputedStyle(section);
    const contentWidth = section.getBoundingClientRect().width - ['paddingLeft', 'paddingRight', 'borderLeftWidth', 'borderRightWidth'].reduce((n, key) => n + parseFloat(style[key]), 0);
    return {
      contentWidth, cards, columns: getComputedStyle(grid).gridTemplateColumns.split(' ').length,
      fields: [...grid.firstElementChild.querySelectorAll('select,input')].map(rect),
      controls: [...grid.firstElementChild.querySelectorAll('select,input,button')].map(rect),
      key: rect(section.querySelector('input')),
      visibility: rect(section.querySelector('button[aria-label$="API Key"]')),
      overflow: document.documentElement.scrollWidth - innerWidth,
    };
  });
  const checkGeometry = (g, desktop = true) => {
    assert.equal(g.columns, g.contentWidth >= 960 ? 2 : 1, 'columns must follow the section content width');
    if (desktop) assert.ok(g.key.width >= 240, `API Key width ${g.key.width}`);
    assert.ok(g.visibility.width >= 66, 'visibility action must not shrink');
    assert.ok(g.overflow <= 1, `page overflow ${g.overflow}`);
    for (const control of g.controls) {
      assert.ok(control.width > 0 && control.x >= g.cards[0].x && control.right <= g.cards[0].right, 'credential controls must stay inside their card');
    }
    for (let i = 1; i < g.fields.length; i++) assert.ok(g.fields[i].y >= g.fields[i - 1].bottom, 'credential fields must occupy separate rows');
    if (g.columns === 1) assert.ok(g.cards[1].y >= g.cards[0].bottom, 'Appearance follows Credentials');
    else {
      assert.ok(Math.abs(g.cards[0].y - g.cards[1].y) <= 1, 'wide cards share the same row');
      assert.ok(Math.abs(g.cards[0].width - g.cards[1].width) <= 1, 'wide cards have equal width');
    }
  };

  try {
    await test('settings-responsive-layout', async () => {
      await appearance('comfortable', false);
      await nav('全局设置');
      const key = page.locator('#settings-general input').first();
      const endpoint = page.locator('#settings-general input').nth(1);
      const provider = page.locator('#settings-general select').first();
      // OpenRouter adds the fourth field. A long, synthetic endpoint and key
      // exercise native input scrolling without ever reading real credentials.
      await provider.selectOption('openrouter');
      await key.fill('synthetic-layout-key-'.repeat(12));
      await endpoint.fill(`https://layout.example/${'long-endpoint/'.repeat(24)}`);
      await page.evaluate(async () => {
        const { useProjectStore } = await import('/state/project-store.ts');
        const config = structuredClone(useProjectStore.getState().config);
        config.providers.find(item => item.id === 'openrouter').requiredEnv = ['SYNTHETIC_LONG_CONFIGURATION_NAME_'.repeat(8)];
        useProjectStore.getState().setConfig(config);
        window.__layoutInput = document.querySelector('#settings-general input');
      });
      for (const [width, height] of [[960, 600], [1280, 800], [1440, 900], [1920, 1080]]) {
        for (const density of ['comfortable', 'compact']) {
          for (const collapsed of [false, true]) {
            await key.focus();
            await key.evaluate(el => el.setSelectionRange(5, 17));
            await page.setViewportSize({ width, height });
            await appearance(density, collapsed);
            const g = await geometry();
            checkGeometry(g);
            assert.equal(g.fields.length, 4);
            assert.deepEqual(await key.evaluate(el => [el === window.__layoutInput, el === document.activeElement, el.selectionStart, el.selectionEnd]), [true, true, 5, 17]);
            assert.equal(await key.inputValue(), 'synthetic-layout-key-'.repeat(12));
            assert.equal(await endpoint.inputValue(), `https://layout.example/${'long-endpoint/'.repeat(24)}`);
            evidence.geometry.push({ width, height, density, collapsed, ...g });
            await page.evaluate(() => window.scrollTo(0, 0));
            await page.screenshot({ path: path.join(output, `settings-${width}-${density}-${collapsed ? 'collapsed' : 'expanded'}.png`) });
          }
        }
      }
      // Resize the actual query container around its boundary, independent of
      // the window. The card inputs must retain identity across both layouts.
      await appearance('comfortable', false);
      for (const width of [959, 960]) {
        await page.locator('#settings-general').evaluate((el, width) => {
          const s = getComputedStyle(el);
          const edges = ['paddingLeft', 'paddingRight', 'borderLeftWidth', 'borderRightWidth'].reduce((n, key) => n + parseFloat(s[key]), 0);
          el.style.width = `${width + edges}px`;
        }, width);
        await settle();
        const g = await geometry();
        assert.equal(g.contentWidth, width);
        checkGeometry(g);
        evidence.geometry.push({ boundary: width, ...g });
      }
      await page.locator('#settings-general').evaluate(el => el.style.removeProperty('width'));
      // A real Chromium IME composition survives a resize and density/sidebar
      // reflow. CDP supplies synthetic composition text, not OS input events.
      const cdp = await page.context().newCDPSession(page);
      await endpoint.focus();
      await endpoint.evaluate(el => { window.__layoutEndpoint = el; el.setSelectionRange(el.value.length, el.value.length); });
      await cdp.send('Input.imeSetComposition', { text: '中文输入', selectionStart: 4, selectionEnd: 4 });
      await page.setViewportSize({ width: 960, height: 600 });
      await appearance('compact', true);
      assert.deepEqual(await endpoint.evaluate(el => [el === window.__layoutEndpoint, el === document.activeElement, el.value.endsWith('中文输入')]), [true, true, true]);
      await cdp.send('Input.insertText', { text: '中文输入' });
      assert.ok((await endpoint.inputValue()).endsWith('中文输入'));
      await cdp.detach();
      await endpoint.fill('https://layout.example/v1');
      // Save failure retains the complete form; retry succeeds and the same
      // geometry remains usable with long error and success feedback present.
      await page.evaluate(() => {
        window.slateSync.settings.saveProviderKey = () => Promise.resolve({ ok: false, error: { code: 'TEST', message: '模拟保存失败，请检查接口配置后重试。'.repeat(12) } });
      });
      await nav('保存密钥');
      await page.getByRole('alert').filter({ hasText: '模拟保存失败' }).waitFor();
      assert.equal(await key.inputValue(), 'synthetic-layout-key-'.repeat(12));
      checkGeometry(await geometry());
      await page.evaluate(() => { window.slateSync.settings.saveProviderKey = () => Promise.resolve({ ok: true, data: { configured: true } }); });
      await nav('保存密钥');
      await expect(key).toHaveValue('');
      await page.getByText('密钥已保存', { exact: true }).waitFor();
      checkGeometry(await geometry());
      await page.screenshot({ path: path.join(output, 'settings-save-feedback-960.png') });
    });

    await test('settings-sidebar-collapse', async () => {
      await page.setViewportSize({ width: 1440, height: 900 });
      await appearance('comfortable', false);
      await nav('全局设置');
      const list = page.locator('[aria-label="全局设置分区导航"]');
      const parent = page.locator('button[title="全局设置"]');
      const help = page.locator('button[title="说明"]');
      const runtime = list.getByRole('button', { name: '运行参数', exact: true });
      await runtime.click();
      await page.locator('#settings-runtime input').first().fill('81');
      await runtime.focus();
      const request = () => page.evaluate(async () => (await import('/state/ui-store.ts')).useUiStore.getState().settingsSectionRequest);
      const initialRequest = await request();
      await appearance('comfortable', true);
      await expect(parent).toBeFocused();
      await expect(list).toBeHidden();
      const g = await list.evaluate(el => ({ height: el.getBoundingClientRect().height, display: getComputedStyle(el).display }));
      assert.deepEqual(g, { height: 0, display: 'none' });
      const parentRect = await parent.boundingBox();
      const helpRect = await help.boundingBox();
      const gap = helpRect.y - parentRect.y - parentRect.height;
      assert.ok(gap >= 0 && gap <= 8, `hidden subnav left ${gap}px of blank space`);
      assert.ok(!(await page.locator('nav[aria-label="主导航"]').ariaSnapshot()).includes('运行参数'));
      await page.keyboard.press('Tab');
      await expect(help).toBeFocused();
      assert.deepEqual(await request(), initialRequest);
      evidence.sidebar.push({ mode: 'collapsed', ...g, gap, keyboardSkipsChildren: true });
      await page.screenshot({ path: path.join(output, 'settings-sidebar-collapsed.png') });
      await appearance('comfortable', false);
      await expect(runtime).toHaveAttribute('data-active', 'true');
      await expect(runtime).toHaveAttribute('data-dirty', 'true');
      // Explicit collapse must preserve a field's focus; clicking the actual
      // collapse trigger keeps focus on that trigger instead of the parent.
      const field = page.locator('#settings-runtime input').first();
      await field.focus();
      await appearance('comfortable', true);
      await expect(field).toBeFocused();
      await nav('展开侧栏');
      await expect(page.getByRole('button', { name: '收起侧栏', exact: true })).toBeFocused();
      await nav('收起侧栏');
      await expect(page.getByRole('button', { name: '展开侧栏', exact: true })).toBeFocused();
      await appearance('comfortable', false);
      // Cover the existing icon rail and top-bar boundaries. Each focused
      // child being hidden must return to the parent without resetting route.
      for (const width of [921, 920, 641, 640, 320, 921]) {
        if (width <= 920 && await list.isVisible()) await runtime.focus();
        await page.setViewportSize({ width, height: 700 });
        await settle();
        if (width <= 920) {
          await expect(list).toBeHidden();
          await expect(parent).toBeFocused();
          await parent.press('Tab');
          await expect(help).toBeFocused();
          await parent.focus();
        } else await expect(list).toBeVisible();
        assert.deepEqual(await request(), initialRequest);
        evidence.sidebar.push({ width, hidden: !await list.isVisible(), height: await list.evaluate(el => el.getBoundingClientRect().height) });
      }
      await runtime.click();
      await page.evaluate(() => window.scrollTo(0, 0));
      await runtime.click();
      await expect(page.locator('#settings-runtime h2')).toBeFocused();
      assert.ok(await page.evaluate(() => window.scrollY) > 300);
      // Returning to a narrow rail while focus is in the page must not steal it.
      await page.setViewportSize({ width: 920, height: 700 });
      await expect(page.locator('#settings-runtime h2')).toBeFocused();
      await page.setViewportSize({ width: 921, height: 700 });
      await runtime.focus();
      await runtime.evaluate(el => el.blur());
      await page.setViewportSize({ width: 920, height: 700 });
      await settle();
      assert.equal(await page.evaluate(() => document.activeElement === document.body), true, 'an earlier deliberate blur must not be rescued');
    });

    await test('segmented-contrast', async () => {
      await page.setViewportSize({ width: 1440, height: 900 });
      await appearance('comfortable', false);
      await nav('全局设置');
      await page.addScriptTag({ path: require.resolve('axe-core') });
      const groups = page.locator('[role="group"]:has(> button[aria-pressed])');
      const paint = button => button.evaluate(el => {
        const css = getComputedStyle(el);
        const rgb = color => color.match(/[\d.]+/g).slice(0, 3).map(Number);
        let ancestor = el;
        while (ancestor && ['transparent', 'rgba(0, 0, 0, 0)'].includes(getComputedStyle(ancestor).backgroundColor)) ancestor = ancestor.parentElement;
        const background = getComputedStyle(ancestor).backgroundColor;
        const luminance = values => values.map(n => { n /= 255; return n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4; }).reduce((sum, n, i) => sum + n * [.2126, .7152, .0722][i], 0);
        const l1 = luminance(rgb(css.color)), l2 = luminance(rgb(background));
        return { foreground: css.color, background, ratio: (Math.max(l1, l2) + .05) / (Math.min(l1, l2) + .05), opacity: css.opacity, outlineStyle: css.outlineStyle, outlineWidth: css.outlineWidth, selected: el.getAttribute('aria-pressed') };
      });
      for (const [theme, scheme] of [['dark', 'dark'], ['light', 'light'], ['system', 'dark'], ['system', 'light']]) {
        await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
        for (const density of ['comfortable', 'compact']) {
          await appearance(density, false, theme);
          await expect(page.locator('html')).toHaveAttribute('data-theme', scheme);
          const count = await groups.count();
          assert.ok(count >= 3, 'include appearance and OCR consumers of the shared control');
          for (let i = 0; i < count; i++) {
            const group = groups.nth(i);
            for (const button of await group.getByRole('button').all()) {
              if (await button.isDisabled()) continue;
              await page.mouse.move(0, 0);
              const normal = await paint(button);
              await button.hover();
              const hover = await paint(button);
              await button.focus();
              await button.press('Tab'); await page.keyboard.press('Shift+Tab');
              await expect(button).toBeFocused();
              const focus = await paint(button);
              for (const state of [normal, hover, focus]) assert.ok(state.ratio >= 4.5, `${theme}/${density}: ${await button.textContent()} contrast ${state.ratio}`);
              assert.notEqual(focus.outlineStyle, 'none');
              assert.ok(parseFloat(focus.outlineWidth) >= 2);
              assert.equal(focus.selected, normal.selected, 'browsing does not change the value');
              evidence.contrast.push({ theme, scheme, density, group: await group.getAttribute('aria-label'), label: await button.textContent(), normal, hover, focus });
            }
          }
          const violations = await page.evaluate(async () => (await axe.run([...document.querySelectorAll('[role="group"]:has(> button[aria-pressed])')], { runOnly: { type: 'rule', values: ['color-contrast'] } })).violations);
          assert.deepEqual(violations.map(item => item.id), []);
          await page.evaluate(() => window.scrollTo(0, 0));
          await page.screenshot({ path: path.join(output, `segmented-${theme}-${scheme}-${density}.png`) });
        }
      }
      // Disabled OCR segments retain their disabled paint on hover and cannot
      // dispatch a selection, while the independent appearance controls work.
      await page.evaluate(async () => (await import('/state/global-settings-store.ts')).useGlobalSettingsStore.getState().beginMutation('global'));
      const disabled = page.getByRole('group', { name: '首选 OCR 引擎' }).getByRole('button').first();
      await expect(disabled).toBeDisabled();
      const before = await paint(disabled);
      await disabled.hover();
      assert.deepEqual(await paint(disabled), before);
      await disabled.click({ force: true });
      assert.equal(await disabled.getAttribute('aria-pressed'), before.selected);
      assert.ok(parseFloat(before.opacity) < 1);
      await expect(page.getByRole('group', { name: '主题', exact: true }).getByRole('button').first()).toBeEnabled();
      await page.evaluate(async () => (await import('/state/global-settings-store.ts')).useGlobalSettingsStore.getState().endMutation('global'));
    });
  } finally {
    await writeFile(path.join(output, 'layout-evidence.json'), JSON.stringify(evidence, null, 2));
  }
}

module.exports = { layoutChecks };
