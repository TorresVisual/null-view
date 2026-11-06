// Runs the real src/element-picker.js in Playwright's WebKit. `webkit.messageHandlers.nvPicker` is a
// stub that collects what the script would send to Swift. The script is added after load, like the
// app evaluates it on demand.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { webkit } from 'playwright';

const SCRIPT = new URL('../src/element-picker.js', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
let browser, context, page, msgs, html = '';

before(async () => {
  browser = await webkit.launch();
  context = await browser.newContext({ viewport: { width: 800, height: 600 } });
  await context.route('http://nv.test/**', (r) => r.fulfill({ contentType: 'text/html', body: r.request().url().endsWith('/other') ? 'other' : html }));
  await context.exposeFunction('__nvPost', (m) => msgs.push(JSON.parse(m)));
  await context.addInitScript(() => { window.webkit = { messageHandlers: { nvPicker: { postMessage: (m) => window.__nvPost(m) } } }; });
});
after(() => browser?.close());
beforeEach(async () => { msgs = []; page = await context.newPage(); });

const open = async (body) => {
  html = `<body>${body}</body>`;
  await page.goto('http://nv.test/page');
  await page.addScriptTag({ path: SCRIPT });
};
const pick = (sel) => page.click(sel);
const hide = () => page.locator('button.go').click();
// The selector must pass Swift's ElementRule charset.
const CHARSET =/^[A-Za-z#.][A-Za-z0-9_\-#.>:() ]*$/;
const rule = () => msgs.find((m) => m.type === 'rule');
// How many elements the posted selector matches, and whether the first one is `sel`'s element.
const matches = (selector) => page.evaluate((s) => [...document.querySelectorAll(s)].length, selector);

test('a unique id is the whole selector, and the element disappears', async () => {
  await open('<div id=ad-box>ad</div><p>text</p>');
  await pick('#ad-box');
  await hide();
  assert.equal(rule().selector, '#ad-box');
  assert.equal(rule().host, 'nv.test');
  assert.equal(await page.locator('#ad-box').isHidden(), true);
  assert.equal(await page.locator('p').isVisible(), true);
});

test('identical siblings are told apart by position and the selector matches only the target', async () => {
  await open('<ul><li class=item>a</li><li class=item>b</li><li class=item>c</li></ul>');
  await pick('li:nth-child(2)');
  await hide();
  const { selector } = rule();
  assert.match(selector, CHARSET);
  assert.equal(await matches(selector), 1);
  assert.equal(await page.evaluate((s) => document.querySelector(s).textContent, selector), 'b');
});

test('classes with digits (build hashes) are ignored', async () => {
  await open('<div><span class="css-1x2y3z promo">x</span></div><div><span>y</span></div>');
  await pick('.promo');
  await hide();
  const { selector } = rule();
  assert.ok(!/\d{2}/.test(selector.replace(/nth-of-type\(\d+\)/, '')), selector);
  assert.equal(await matches(selector), 1);
});

test('Larger selects the parent', async () => {
  await open('<section id=wrap><div id=inner><b id=leaf>x</b></div></section>');
  await pick('#leaf');
  await page.locator('button.up').click();
  await hide();
  assert.equal(rule().selector, '#inner');
});

test('Larger stops at body', async () => {
  await open('<div id=top><b id=leaf>x</b></div>');
  await pick('#leaf');
  await page.locator('button.up').click();
  assert.equal(await page.locator('button.up').isDisabled(), true);
});

test('Cancel posts nothing, removes the overlay and gives the page its taps back', async () => {
  await open('<a id=l href="/other">link</a>');
  await pick('#l'); // selecting does not follow the link
  assert.equal(page.url(), 'http://nv.test/page');
  await page.locator('button.no').click();
  assert.equal(msgs.length, 0);
  assert.equal(await page.locator('button.no').count(), 0);
  await page.click('#l');
  await page.waitForURL('**/other');
});

test('starting twice does not stack a second overlay', async () => {
  await open('<p>x</p>');
  await page.addScriptTag({ path: SCRIPT });
  assert.equal(await page.evaluate(() => document.querySelectorAll('html > div').length), 1);
});

test('body and html cannot be picked', async () => {
  await open('<p>x</p>');
  await page.mouse.click(790, 590);
  assert.equal(await page.locator('button.go').isDisabled(), true);
});
