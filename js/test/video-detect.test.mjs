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
  await context.addInitScript({ path: SCRIPT.replace('video-detect', 'fullscreen-hook') });
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

test('diagnostic: the source is reported as host + path only (no query), blob as "blob"', async () => {
  await load(`<video id=a width=640 height=360></video><video id=b width=640 height=360 src="blob:x"></video>`);
  await fake('#a', { currentSrc: 'https://cdn.example.com/ad/clip.mp4?token=secret', networkState: 2, readyState: 0 }, 'loadstart');
  await settle();
  const v = lastVideos();
  assert.deepEqual([v[0].s, v[0].ns, v[0].rs, v[0].err], ['cdn.example.com/ad/clip.mp4', 2, 0, 0]);
  assert.equal(v[1].s, 'blob');
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
  const count = () => msgs.filter((m) => m.type === 'videos').length;
  const n = count();
  await page.evaluate(() => document.querySelector('#a').dispatchEvent(new Event('timeupdate')));
  await settle(1300);
  assert.equal(count(), n);          // nothing changed, so no video report
  await fake('#a', { paused: true, currentTime: 2 }, 'pause');
  await settle(400);
  assert.equal(lastVideos()[0].playing, false);
  assert.equal(lastVideos()[0].pos, 2);
});

test('videos in iframes are reported by their own frame', async () => {
  await load(`<iframe id=f width=400 height=300 srcdoc="<video id=in width=300 height=200 src=blob:z></video>"></iframe>`);
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

const style = (sel, prop) => page.evaluate(([s, p]) => getComputedStyle(document.querySelector(s))[p], [sel, prop]);

test('enter pins the video over the viewport, hides the rest, exit restores', async () => {
  await load(`<div id=wrap style="transform:translateX(5px);position:relative"><p id=other>other</p>
              <video id=a width=320 height=180 src="blob:x"></video></div>`);
  await settle(400);
  assert.equal(await page.evaluate(() => __nvCmd(0, 'enter')), true);
  assert.equal(await style('#a', 'position'), 'fixed');
  assert.equal(await style('#a', 'width'), '800px');
  assert.equal(await style('#wrap', 'transform'), 'none');       // transformed ancestor would trap position:fixed
  assert.equal(await style('#other', 'visibility'), 'hidden');
  await page.evaluate(() => __nvCmd(0, 'exit'));
  assert.equal(await style('#a', 'position'), 'static');
  assert.equal(await style('#other', 'visibility'), 'visible');
  assert.equal(await page.evaluate(() => __nvCmd(5, 'enter')), false);   // no such video
});

test('a video in an iframe pins its iframe in the parent too', async () => {
  await load(`<p id=other>other</p><iframe id=f width=400 height=300 srcdoc="<video id=in width=300 height=200 src=blob:z></video>"></iframe>`);
  await settle(600);
  await page.frames()[1].evaluate(() => __nvCmd(0, 'enter'));
  await settle(200);
  assert.equal(await style('#f', 'position'), 'fixed');
  assert.equal(await style('#other', 'visibility'), 'hidden');
  await page.frames()[1].evaluate(() => __nvCmd(0, 'exit'));
  await settle(200);
  assert.equal(await style('#f', 'position'), 'static');
});

test('an iframe inside a shadow root is pinned and the page around it hidden, header included', async () => {
  await load(`<header id=hdr style="position:fixed;top:0;left:0;right:0;height:50px">logo</header><p id=other>other</p>
    <div id=host></div><script>host.attachShadow({ mode: 'open' }).innerHTML =
      '<nav id=nav>menu</nav><div id=wrap style="transform:translateX(3px)"><iframe id=f width=400 height=300 srcdoc="<video id=in width=300 height=200 src=blob:z></video>"></iframe></div>'</script>`);
  await settle(600);
  const sh = (sel, prop) => page.evaluate(([s, p]) => getComputedStyle(host.shadowRoot.querySelector(s))[p], [sel, prop]);
  await page.frames()[1].evaluate(() => __nvCmd(0, 'enter'));
  await settle(200);
  assert.equal(await sh('#f', 'position'), 'fixed');
  assert.equal(await sh('#wrap', 'transform'), 'none');
  assert.equal(await sh('#nav', 'visibility'), 'hidden');
  assert.equal(await style('#hdr', 'visibility'), 'hidden');
  assert.equal(await style('#other', 'visibility'), 'hidden');
  await page.frames()[1].evaluate(() => __nvCmd(0, 'exit'));
  await settle(200);
  assert.equal(await sh('#f', 'position'), 'static');
  assert.equal(await sh('#nav', 'visibility'), 'visible');
  assert.equal(await style('#hdr', 'visibility'), 'visible');
});

test('a video inside a shadow root (web-component player, added later) is found, driven, pinned and fullscreen-swallowed', async () => {
  await load('<p id=other>other</p><div id=host></div>');
  await settle(300);
  assert.equal(msgs.filter((m) => m.type === 'videos').length, 0);
  // Like Joyn's <turbo-video>: the player attaches its shadow root and builds the <video> after load.
  await page.evaluate(() => { host.attachShadow({ mode: 'open' }).innerHTML = '<div id=wrap style="transform:translateX(3px)"><video id=sv width=640 height=360 src="blob:x"></video></div>'; });
  await settle(2000);   // no light-DOM change: found by the periodic rescan
  assert.equal(lastVideos()?.length, 1);
  assert.equal(lastVideos()[0].w, 640);
  // A video added to the shadow root later is seen too (the root is observed once found).
  await page.evaluate(() => { const v = document.createElement('video'); v.id = 'sv2'; v.width = 320; v.height = 180; v.src = 'blob:y'; host.shadowRoot.append(v); });
  await settle(700);
  assert.equal(lastVideos().length, 2);
  await page.evaluate(() => { window.calls = []; const v = host.shadowRoot.querySelector('#sv'); v.play = () => (calls.push('play'), Promise.resolve()); });
  assert.equal(await page.evaluate(() => __nvCmd(0, 'play')), true);
  assert.deepEqual(await page.evaluate(() => calls), ['play']);
  assert.equal(await page.evaluate(() => __nvCmd(0, 'enter')), true);
  const sh = (sel, prop) => page.evaluate(([s, p]) => getComputedStyle(host.shadowRoot.querySelector(s))[p], [sel, prop]);
  assert.equal(await sh('#sv', 'position'), 'fixed');
  assert.equal(await sh('#wrap', 'transform'), 'none');
  assert.equal(await style('#other', 'visibility'), 'hidden');
  await page.evaluate(() => __nvCmd(0, 'exit'));
  assert.equal(await sh('#sv', 'position'), 'static');
  // The page's fullscreen request from inside the shadow root reaches us.
  msgs.length = 0;
  await page.evaluate(() => { host.shadowRoot.querySelector('#sv').requestFullscreen?.() ?? host.shadowRoot.querySelector('#sv').webkitRequestFullscreen?.(); });
  await settle(200);
  const fsMsgs = msgs.filter((m) => m.type === 'fullscreen');
  assert.equal(fsMsgs.length, 1);
  assert.equal(fsMsgs[0].i, 0);
});

test('commands drive the element; position updates come fast in video mode', async () => {
  await load('<video id=a width=640 height=360 src="blob:x"></video>');
  await settle(300);
  await page.evaluate(() => { const v = document.querySelector('#a'); window.calls = [];
    v.pause = () => calls.push('pause'); v.play = () => (calls.push('play'), Promise.resolve()); });
  await page.evaluate(() => { __nvCmd(0, 'play'); __nvCmd(0, 'pause'); __nvCmd(0, 'rate', 2); });
  assert.deepEqual(await page.evaluate(() => calls), ['play', 'pause']);
  assert.equal(await page.evaluate(() => document.querySelector('#a').playbackRate), 2);
  assert.equal(await page.evaluate(() => __nvCmd(0, 'bogus')), false);   // unknown commands do nothing
  await page.evaluate(() => __nvCmd(0, 'enter'));
  await fake('#a', { paused: false, readyState: 4, duration: 60, currentTime: 1 }, 'playing');
  await settle(400);
  await fake('#a', { currentTime: 2 }, 'timeupdate');
  await settle(450);                      // < 1000 ms: only fast mode reports this
  assert.equal(lastVideos()[0].pos, 2);
});

test('the page asking for fullscreen is swallowed for a drivable video, passed through otherwise', async () => {
  await load('<video id=a width=640 height=360 src="blob:x"></video><video id=b width=640 height=360></video>');
  await settle(300);
  const ask = (sel) => page.evaluate((s) => {
    const el = document.querySelector(s);
    window.passed = 0;
    el.webkitEnterFullscreen = undefined;                       // not under test
    const f = Element.prototype.requestFullscreen ?? Element.prototype.webkitRequestFullscreen;
    return f ? (f.call(el), true) : false;
  }, sel);
  assert.ok(await ask("#a"), "no fullscreen API in this WebKit build");
  await settle(200);
  const fs = msgs.filter((m) => m.type === 'fullscreen');
  assert.equal(fs.length, 1);
  assert.equal(fs[0].i, 0);
  await ask('#b');                                              // no source: left to the page
  await settle(200);
  assert.equal(msgs.filter((m) => m.type === 'fullscreen').length, 1);
});

test('the page never sees itself hidden, so sites do not pause on background', async () => {
  await load('<p>hi</p>');
  const r = await page.evaluate(() => {
    let heard = 0;
    document.addEventListener('visibilitychange', () => heard++);
    addEventListener('visibilitychange', () => heard++);
    document.dispatchEvent(new Event('visibilitychange'));
    return [heard, document.hidden, document.visibilityState];
  });
  assert.deepEqual(r, [0, false, 'visible']);
});

test('diagnostic: fetch/XHR outcomes are forwarded as net lines, tracker hosts are skipped', async () => {
  await load('<video id=a width=640 height=360 src="blob:x"></video>');
  await settle(300);
  await page.evaluate(async () => {
    await fetch('/v1/ad-pod/abc').catch(() => {});                       // ad-looking
    await fetch('/plain/page').catch(() => {});                          // ordinary: logged too now
    await fetch('http://clarity.invalid/x').catch(() => {});             // tracker host: skipped
    await fetch('http://nv-down.invalid/x').catch(() => {});             // fails
    await new Promise((r) => { const x = new XMLHttpRequest(); x.open('GET', '/ima3/thing'); x.onloadend = r; x.send(); });
  });
  await settle(2200);
  const lines = msgs.filter((m) => m.type === 'net').flatMap((m) => m.lines);
  assert.ok(lines.some((l) => l.includes('GET nv.test/v1/ad-pod/abc 200')), JSON.stringify(lines));
  assert.ok(lines.some((l) => l.includes('nv-down.invalid') && l.includes('ERR')), JSON.stringify(lines));
  assert.ok(lines.some((l) => l.includes('nv.test/ima3/thing')), JSON.stringify(lines));
  assert.ok(lines.some((l) => l.includes('nv.test/plain/page 200')), JSON.stringify(lines));
  assert.ok(!lines.some((l) => l.includes('clarity')), JSON.stringify(lines));
});

test('diagnostic: sent even without a video, and failed script loads are included', async () => {
  await load('<p>no video here</p>');
  await settle(300);
  await page.evaluate(async () => {
    await fetch('/v1/ad-pod/abc').catch(() => {});
    await new Promise((r) => { const s = document.createElement('script'); s.src = 'http://nv-down.invalid/p.js'; s.onerror = r; document.head.append(s); });
  });
  await settle(2200);
  assert.equal(msgs.filter((m) => m.type === 'videos').length, 0);
  const lines = msgs.filter((m) => m.type === 'net').flatMap((m) => m.lines);
  assert.ok(lines.some((l) => l.includes('nv.test/v1/ad-pod/abc')), JSON.stringify(lines));
  assert.ok(lines.some((l) => l.includes('script nv-down.invalid/p.js ERR')), JSON.stringify(lines));
});
