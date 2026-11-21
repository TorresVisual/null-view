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

test('scrollStep moves one step at a time, wraps after the end, and ignores the sidebar', async () => {
  await page.setContent(`<nav id="side" style="height:100px;overflow:auto"><div style="height:9000px"></div></nav>
    <main id="m" style="height:200px;overflow:auto"><div style="height:1000px"></div></main>`);
  const step = () => page.evaluate(() => [window.__nvSpotify.scrollStep(), document.getElementById('m').scrollTop, document.getElementById('side').scrollTop]);
  assert.deepEqual(await step(), ['step', 160, 0]);
  assert.equal((await step())[0], 'step');
  for (let i = 0; i < 3; i++) await step();   // 160 * 5 = 800 = the end
  assert.deepEqual(await step(), ['wrapped', 0, 0]);   // after reaching the end, the next call is back at the top
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
