// Runs the real src/spotify-data.js in Playwright WebKit. Spotify's API hosts are answered by route stubs;
// the page reads what the hook recorded through window.__nvSpotify.drain().
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { webkit } from 'playwright';

const SCRIPT = new URL('../src/spotify-data.js', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const URL_ = 'https://api-partner.spotify.com/pathfinder/v2/query';
let browser, context, page;

before(async () => {
  browser = await webkit.launch();
  context = await browser.newContext();
  await context.route('http://nv.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html></html>' }));
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' };
  // Echo the requested operation back, so each test can see which body it got.
  await context.route('https://api-partner.spotify.com/**', (r) => {
    if (r.request().method() === 'OPTIONS') return r.fulfill({ status: 204, headers: cors });
    const op = /operationName["=:]+\s*"?(\w+)/.exec(r.request().postData() || r.request().url())?.[1] ?? '?';
    return r.fulfill({ contentType: 'application/json', headers: cors, body: JSON.stringify({ data: { op, pad: 'x'.repeat(3000) } }) });
  });
  await context.route('https://other.test/**', (r) => r.fulfill({ contentType: 'application/json', headers: cors, body: '{"a":1}' }));
  await context.route('https://api.spotify.com/text', (r) => r.fulfill({ contentType: 'text/plain', headers: cors, body: 'nope' }));
  await context.addInitScript({ path: SCRIPT });
});
after(() => browser?.close());
beforeEach(async () => { page = await context.newPage(); await page.goto('http://nv.test/page'); });

const drain = async () => {
  await new Promise((r) => setTimeout(r, 200));   // records are written after the body clone resolves
  return page.evaluate(() => window.__nvSpotify.drain());
};
const post = (op) => page.evaluate(async ([u, op]) => (await fetch(u, { method: 'POST', body: JSON.stringify({ operationName: op, variables: { offset: 0 } }) })).json(), [URL_, op]);

test('the three operations are recorded with their full body; the page still reads the body', async () => {
  const body = await post('getAlbum');
  assert.equal(body.data.op, 'getAlbum');                // clone, not consumed
  await post('queryArtistDiscographyAll');
  await post('queryArtistDiscographyOverview');
  const rs = await drain();
  assert.deepEqual(rs.map((r) => r.op), ['getAlbum', 'queryArtistDiscographyAll', 'queryArtistDiscographyOverview']);
  assert.ok(rs[0].text.length > 3000);                    // not cut to a head
  assert.equal(JSON.parse(rs[0].text).data.op, 'getAlbum');
  assert.deepEqual(await drain(), []);                    // drain clears
});

test('other operations, other hosts and non-JSON responses are ignored', async () => {
  await post('areEntitiesInLibrary');
  await page.evaluate(async () => { await fetch('https://other.test/x'); await fetch('https://api.spotify.com/text'); });
  assert.deepEqual(await drain(), []);
});

test('the operation name in the URL (GET) is recognised too', async () => {
  await page.evaluate(async (u) => { await fetch(u + '?operationName=getAlbum&variables=%7B%7D'); }, URL_);
  assert.deepEqual((await drain()).map((r) => r.op), ['getAlbum']);
});

test('XHR is recorded too', async () => {
  await page.evaluate((u) => new Promise((res) => {
    const x = new XMLHttpRequest(); x.open('POST', u); x.onloadend = res; x.send(JSON.stringify({ operationName: 'getAlbum' }));
  }), URL_);
  assert.deepEqual((await drain()).map((r) => r.op), ['getAlbum']);
});

test('the same response is recorded twice when requested twice, and the backlog is capped', async () => {
  await page.evaluate(async ([u]) => {
    for (let i = 0; i < 130; i++) await fetch(u, { method: 'POST', body: JSON.stringify({ operationName: 'getAlbum', i }) });
  }, [URL_]);
  assert.equal((await drain()).length, 100);
});

test('scrollStep moves half a viewport at a time, wraps after the end, ignores the sidebar, and reports where it is', async () => {
  await page.setContent(`<nav id="side" style="height:100px;overflow:auto"><div style="height:9000px"></div></nav>
    <main id="m" style="height:200px;overflow:auto"><div style="height:1000px"></div></main>`);
  const step = () => page.evaluate(() => [window.__nvSpotify.scrollStep(), document.getElementById('m').scrollTop, document.getElementById('side').scrollTop]);
  assert.deepEqual(await step(), ['step top=100 of 1000 client=200 el=main#m', 100, 0]);
  for (let i = 0; i < 7; i++) await step();             // 100 * 8 = 800 = the end
  assert.equal((await step())[0].split(' ')[0], 'wrapped');
  assert.equal(await page.evaluate(() => document.getElementById('m').scrollTop), 0);   // back at the top
});

test('scrollStep moves every scrollable element in main, not just the tallest', async () => {
  await page.setContent(`<main style="height:200px;overflow:auto"><div id="in" style="height:150px;overflow:auto"><div style="height:600px"></div></div><div style="height:1000px"></div></main>`);
  await page.evaluate(() => window.__nvSpotify.scrollStep());
  assert.deepEqual(await page.evaluate(() => [document.querySelector('main').scrollTop, document.getElementById('in').scrollTop]), [100, 75]);
});

test('scrollStep finds a scroller that is an ancestor of main, and leaves a non-scrolling main alone', async () => {
  await page.setContent(`<div id="outer" style="height:300px;overflow:auto"><main style="height:100px"><div style="height:2000px"></div></main></div>`);
  const r = await page.evaluate(() => [window.__nvSpotify.scrollStep(), document.getElementById('outer').scrollTop]);
  assert.equal(r[0], 'step top=150 of 2000 client=300 el=div#outer');
  assert.equal(r[1], 150);
});

test('scrollTo puts the scroller at a fraction of its range, for any scroller around main', async () => {
  await page.setContent(`<div id="outer" style="height:300px;overflow:hidden"><main><div style="height:1300px"></div></main></div>`);
  const r = await page.evaluate(() => [window.__nvSpotify.scrollTo(0.5), document.getElementById('outer').scrollTop]);
  assert.equal(r[1], 500);                                  // 0.5 * (1300 - 300)
  assert.match(r[0], /^top=500 of 1300 client=300 el=div#outer$/);
  assert.equal(await page.evaluate(() => window.__nvSpotify.scrollTo(2)), 'top=1000 of 1300 client=300 el=div#outer');   // clamped to the end
  await page.setContent('<p>nothing scrolls</p>');
  assert.equal(await page.evaluate(() => window.__nvSpotify.scrollTo(0.5)), 'none');
});

test('playChapter clicks the row found by its track link, falls back to the row index, and says when it is not rendered', async () => {
  await page.setContent(`<main>
    <div data-testid="tracklist-row" aria-rowindex="2"><a href="/track/AAA">Teil 1</a><button aria-label="Play Teil 1" onclick="window.hit='A'"></button></div>
    <div data-testid="tracklist-row" aria-rowindex="3"><span>Teil 2</span><button data-testid="play-button" onclick="window.hit='B'"></button></div>
    <div data-testid="tracklist-row" aria-rowindex="4"><span>Teil 3</span></div></main>`);
  const play = (uri, n) => page.evaluate(([u, n]) => [window.__nvSpotify.playChapter(u, n), window.hit], [uri, n]);
  assert.deepEqual(await play('spotify:track:AAA', 1), ['row button', 'A']);
  assert.deepEqual(await play('spotify:track:ZZZ', 2), ['row button', 'B']);
  await page.evaluate(() => document.querySelector('[aria-rowindex="4"]').addEventListener('dblclick', () => { window.hit = 'C'; }));
  assert.deepEqual(await play('spotify:track:YYY', 3), ['row dblclick', 'C']);
  assert.deepEqual(await play('spotify:track:XXX', 40), ['not rendered', 'C']);
});

test('playAlbum clicks the action-bar play button', async () => {
  await page.setContent(`<main><div data-testid="action-bar-row"><button data-testid="play-button" onclick="window.hit='album'"></button></div></main>`);
  assert.equal(await page.evaluate(() => window.__nvSpotify.playAlbum()), 'play button clicked');
  assert.equal(await page.evaluate(() => window.hit), 'album');
  await page.setContent('<main></main>');
  assert.equal(await page.evaluate(() => window.__nvSpotify.playAlbum()), 'play button NOT found');
});

// Issue #20: stop when the album ends. The page reports the current track as the media-session title.
const mockPlayer = (title, label = 'Pause') => page.evaluate(([t, l]) => {
  Object.defineProperty(navigator, 'mediaSession', { value: { metadata: { title: t }, playbackState: 'playing' }, configurable: true });
  document.body.innerHTML = `<button data-testid="control-button-playpause" aria-label="${l}" onclick="window.clicks=(window.clicks||0)+1"></button>`;
}, [title, label]);
const nowPlaying = (title) => page.evaluate((t) => { navigator.mediaSession.metadata.title = t; return window.__nvSpotify.checkAlbum(); }, title);
const clicks = () => page.evaluate(() => window.clicks || 0);
const log = () => page.evaluate(() => window.__nvSpotify.takeLog());

test('watchAlbum pauses and logs when the playing track leaves the album, once', async () => {
  await mockPlayer('Teil 1');
  await page.evaluate(() => window.__nvSpotify.watchAlbum('Folge 1', ['Teil 1', 'Teil 2']));
  await nowPlaying('Teil 1'); await nowPlaying('Teil 2');
  assert.equal(await clicks(), 0);                          // inside the album: leave it alone
  await nowPlaying('Some Recommendation');
  assert.equal(await clicks(), 1);
  assert.deepEqual(await log(), ['stop: left album Folge 1 (now "Some Recommendation", button)']);
  assert.deepEqual(await log(), []);                        // taken once
  await nowPlaying('Another One');
  assert.equal(await clicks(), 1);                          // one-shot: the owner may press play again
});

test('watchAlbum does not stop on what was playing before the album started, and ignores an empty title', async () => {
  await mockPlayer('Old Song');
  await page.evaluate(() => window.__nvSpotify.watchAlbum('Folge 1', ['Teil 1']));
  await nowPlaying('Old Song'); await nowPlaying('');
  assert.equal(await clicks(), 0);                          // never saw an album chapter yet
  await nowPlaying('Teil 1'); await nowPlaying('');
  assert.equal(await clicks(), 0);
});

test('watchAlbum stays armed while paused (no click, no log) and stops once playing again', async () => {
  await mockPlayer('Teil 1', 'Play');
  await page.evaluate(() => { navigator.mediaSession.playbackState = 'paused'; window.__nvSpotify.watchAlbum('Folge 1', ['Teil 1']); });
  await nowPlaying('Teil 1'); await nowPlaying('Other');
  assert.equal(await clicks(), 0);
  assert.deepEqual(await log(), []);
  await page.evaluate(() => document.querySelector('button').setAttribute('aria-label', 'Pause'));
  await nowPlaying('Other');
  assert.equal(await clicks(), 1);
  assert.match((await log())[0], /^stop: left album Folge 1 \(now "Other", button\)$/);
});
