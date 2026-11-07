// The blocker bundle must run scriptlets on pages that send `require-trusted-types-for 'script'`
// (YouTube does). Run `npm run build` first: the test loads dist/adblock-content.js.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { webkit } from 'playwright';

const BUNDLE = new URL('../dist/adblock-content.js', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const CFG = { css: [], extendedCss: [], js: [], engineTimestamp: 1,
  scriptlets: [{ name: 'set-constant', args: ['__nvProbe', 'true'] }] };
let browser, context;

before(async () => {
  browser = await webkit.launch();
  context = await browser.newContext();
  // WKUserScript runs at document start with a <head> to append to; the page calls this from its <head> to match.
  await context.addInitScript(`window.__nvRun = function () { window.__nvConfig = ${JSON.stringify(CFG)};\n${fs.readFileSync(BUNDLE, 'utf8')}\n};`);
  await context.route('http://nv.test/**', (r) => r.fulfill({
    contentType: 'text/html',
    headers: new URL(r.request().url()).pathname === '/tt' ? { 'content-security-policy': "require-trusted-types-for 'script'" } : {},
    body: '<html><head><script>window.__nvRun()</script></head><body></body></html>',
  }));
});
after(() => browser?.close());

for (const [name, path] of [['plain page', '/plain'], ['page requiring Trusted Types', '/tt']]) {
  test(`scriptlets run on a ${name}`, async () => {
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => { window.__tcBefore = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'textContent'); });
    await page.goto('http://nv.test' + path);
    assert.equal(await page.evaluate(() => window.__nvProbe), true);
    assert.deepEqual(errors, []);
    // The shim must not outlive the call: the page's own script elements are untouched afterwards.
    assert.equal(await page.evaluate(() => Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'textContent')?.set === window.__tcBefore?.set), true);
  });
}
