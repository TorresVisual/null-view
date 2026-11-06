// Runs the real src/video-detect.js in Playwright's WebKit. `window.webkit.messageHandlers.nvVideo`
// is stubbed to collect what the script would send to Swift. Videos have no real media (codecs
// differ per build), so tests set the element properties the script reads.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { webkit } from 'playwright';

const SCRIPT = new URL('../src/video-detect.js', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
let browser, context, page, msgs, html = '';

// Real navigation, not page.setContent: document.open() would erase the script's window listeners.
const load = async (body) => { html = body; await page.goto('http://nv.test/page'); };

before(async () => {
  browser = await webkit.launch();
  context = await browser.newContext({ viewport: { width: 800, height: 600 } });
  await context.route('http://nv.test/**', (r) => r.fulfill({ contentType: 'text/html', body: html }));
  await context.exposeFunction('__nvPost', (m) => msgs.push(JSON.parse(m)));
  await context.addInitScript(() => {
    window.webkit = { messageHandlers: { nvVideo: { postMessage: (m) => window.__nvPost(m) } } };
  });
  await context.addInitScript({ path: SCRIPT });
});
after(() => browser?.close());
beforeEach(async () => { msgs = []; page = await context.newPage(); });

const settle = (ms = 700) => new Promise((r) => setTimeout(r, ms));
const lastVideos = (frame) => msgs.filter((m) => m.type === 'videos' && (!frame || m.frame === frame)).at(-1)?.videos;

// Fake what a loaded video reports, then fire the event the browser would.
const fake = (sel, props, event) => page.evaluate(([sel, props, event]) => {
  const v = document.querySelector(sel);
  for (const [k, val] of Object.entries(props)) Object.defineProperty(v, k, { value: val, configurable: true });
  if (event) v.dispatchEvent(new Event(event));
}, [sel, props, event]);

test('reports every video with size, state and position', async () => {
  await load(`<video id=a width=640 height=360 src="blob:x"></video>
                         <video id=b width=1 height=1></video>`);
  await fake('#a', { paused: false, ended: false, readyState: 4, duration: 120.5, currentTime: 12.25 }, 'playing');
  await settle();
  const v = lastVideos();
  assert.equal(v.length, 2);
  assert.deepEqual([v[0].i, v[0].w, v[0].h, v[0].playing, v[0].dur, v[0].pos, v[0].live, v[0].drm],
                   [0, 640, 360, true, 120.5, 12.25, false, false]);
  assert.equal(v[0].vis, 640 * 360);
  assert.equal(v[1].w, 1);
  assert.equal(v[1].dur, null);          // NaN duration is sent as null
  assert.equal(v[1].src, false);
});

test('detects a video added later, and live streams and DRM', async () => {
  await load('<p>hi</p>');
  await settle(400);
  assert.equal(msgs.filter((m) => m.type === 'videos').length, 0);   // no videos yet: stay quiet
  await page.evaluate(() => document.body.insertAdjacentHTML('beforeend', '<video id=c width=320 height=240 src="blob:y"></video>'));
  await fake('#c', { duration: Infinity, mediaKeys: {} }, 'durationchange');
  await settle();
  const v = lastVideos();
  assert.equal(v.length, 1);
  assert.deepEqual([v[0].live, v[0].dur, v[0].drm, v[0].src], [true, null, true, true]);
});

test('state changes are reported quickly, an unchanged state is not repeated', async () => {
  await load('<video id=a width=640 height=360 src="blob:x"></video>');
  await fake('#a', { paused: false, readyState: 4, duration: 60, currentTime: 1 }, 'playing');
  await settle(400);
  assert.equal(lastVideos()[0].playing, true);
  const n = msgs.length;
  await page.evaluate(() => document.querySelector('#a').dispatchEvent(new Event('timeupdate')));
  await settle(1300);
  assert.equal(msgs.length, n);          // nothing changed, so no message
  await fake('#a', { paused: true, currentTime: 2 }, 'pause');
  await settle(400);
  assert.equal(lastVideos()[0].playing, false);
  assert.equal(lastVideos()[0].pos, 2);
});

test('videos in iframes are reported by their own frame', async () => {
  await load(`<iframe id=f width=400 height=300 srcdoc="<video id=in width=300 height=200 src='blob:z'></video>"></iframe>`);
  await settle(900);
  const frames = [...new Set(msgs.filter((m) => m.type === 'videos').map((m) => m.frame))];
  assert.equal(frames.length, 1);        // the top frame has no video; only the iframe reports
  assert.equal(lastVideos(frames[0])[0].w, 300);
});

test('a frame says goodbye when its page goes away', async () => {
  await load('<video width=640 height=360 src="blob:x"></video>');
  await settle(500);
  const frame = msgs[0].frame;
  await page.goto('about:blank');
  await settle(300);
  assert.ok(msgs.some((m) => m.type === 'gone' && m.frame === frame));
});

test('offscreen video has no visible area', async () => {
  await load('<div style="height:2000px"></div><video id=a width=640 height=360 src="blob:x"></video>');
  await settle(500);
  assert.equal(lastVideos()[0].vis, 0);
  assert.equal(lastVideos()[0].w, 640);
  await page.evaluate(() => document.querySelector('#a').scrollIntoView());
  await settle(800);
  assert.ok(lastVideos()[0].vis > 0);
});
