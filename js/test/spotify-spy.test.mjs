// SPIKE (#17): runs the real src/spotify-spy.js in Playwright WebKit. Spotify's API hosts are
// answered by route stubs; the page reads what the hook recorded through window.__nvSpy.drain().
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { webkit } from 'playwright';

const SCRIPT = new URL('../src/spotify-spy.js', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const ALBUM = 'spotify:album:' + 'a'.repeat(22), ALBUM2 = 'spotify:album:' + 'b'.repeat(22), TRACK = 'spotify:track:' + 't'.repeat(22);
let browser, context, page;

before(async () => {
  browser = await webkit.launch();
  context = await browser.newContext();
  await context.route('http://nv.test/**', (r) => r.fulfill({ contentType: 'text/html', body: '<html></html>' }));
  const cors = { 'access-control-allow-origin': '*' };
  await context.route('https://api-partner.spotify.com/**', (r) => r.fulfill({
    contentType: 'application/json', headers: cors,
    body: JSON.stringify({ data: { artistUnion: { discography: { totalCount: 14, items: [ALBUM, ALBUM2, ALBUM] }, pad: 'x'.repeat(2000) } } }),
  }));
  await context.route('https://api-partner.spotify.com/outline', (r) => r.fulfill({
    contentType: 'application/json', headers: cors,
    body: JSON.stringify({ data: { artistUnion: { discography: { items: [{ uri: ALBUM, name: 'Folge 1', date: { year: 1979 } }] } } } }),
  }));
  await context.route('https://spclient.wg.spotify.com/**', (r) => r.fulfill({
    contentType: 'application/json', headers: cors, body: JSON.stringify({ tracks: [TRACK] }),
  }));
  await context.route('https://gew4-spclient.spotify.com/**', (r) => r.fulfill({ contentType: 'application/json', headers: cors, body: '{"ok":true}' }));
  await context.route('https://other.test/**', (r) => r.fulfill({ contentType: 'application/json', headers: cors, body: '{"a":1}' }));
  await context.route('https://api.spotify.com/text', (r) => r.fulfill({ contentType: 'text/plain', headers: cors, body: 'nope' }));
  await context.addInitScript({ path: SCRIPT });
});
after(() => browser?.close());
beforeEach(async () => { page = await context.newPage(); await page.goto('http://nv.test/page'); });

const drain = async () => {
  await new Promise((r) => setTimeout(r, 200));   // records are written after the body clone resolves
  return (await page.evaluate(() => window.__nvSpy.drain())).map((s) => JSON.parse(s));
};

test('fetch to a Spotify API host is recorded with status, key path, id counts and a short head; the page still reads the body', async () => {
  const body = await page.evaluate(async () => (await fetch('https://api-partner.spotify.com/pathfinder/v2/query?operationName=queryArtistDiscographyAll')).json());
  assert.equal(body.data.artistUnion.discography.totalCount, 14);   // clone, not consumed
  const [r, ...rest] = await drain();
  assert.equal(rest.length, 0);
  assert.equal(r.status, 200);
  assert.match(r.url, /api-partner\.spotify\.com\/pathfinder\/v2\/query\?operationName=queryArtistDiscographyAll/);
  assert.equal(r.path, 'data.artistUnion');
  assert.deepEqual(r.keys, ['discography', 'pad']);
  assert.equal(r.albums, 2);                                        // distinct album URIs
  assert.equal(r.tracks, 0);
  assert.equal(r.total, 14);
  assert.ok(r.head.length <= 500 && r.head.startsWith('{"data"'));
  assert.deepEqual(await drain(), []);                              // drain clears
});

test('a sample outline shows where title, cover and year live next to the first album URI', async () => {
  await page.evaluate(() => fetch('https://api-partner.spotify.com/outline'));
  const [r] = await drain();
  assert.equal(r.samplePath, 'data.artistUnion.discography.items[0]');
  assert.deepEqual(r.sample, ['uri: ' + ALBUM, 'name: Folge 1', 'date.year: 1979']);
});

test('POST bodies are recorded, and POSTs to one URL with different bodies are kept apart', async () => {
  await page.evaluate(async () => {
    for (const op of ['queryArtistDiscographyAll', 'getAlbum']) {
      await fetch('https://api-partner.spotify.com/pathfinder/v2/query', { method: 'POST', body: JSON.stringify({ operationName: op, variables: { offset: 0 } }) });
    }
  });
  const rs = await drain();
  assert.equal(rs.length, 2);
  assert.match(rs[0].req, /queryArtistDiscographyAll/);
  assert.match(rs[1].req, /getAlbum/);
});

test('XHR is recorded too', async () => {
  await page.evaluate(() => new Promise((res) => {
    const x = new XMLHttpRequest(); x.open('GET', 'https://spclient.wg.spotify.com/metadata/4/x'); x.onloadend = res; x.send();
  }));
  const [r] = await drain();
  assert.equal(r.status, 200);
  assert.equal(r.tracks, 1);
});

test('other hosts and non-JSON responses are ignored', async () => {
  await page.evaluate(async () => { await fetch('https://other.test/x'); await fetch('https://api.spotify.com/text'); });
  assert.deepEqual(await drain(), []);
});

test('telemetry and library/curation polling are skipped so they do not use up the cap', async () => {
  await page.evaluate(async () => {
    await fetch('https://gew4-spclient.spotify.com/gabo-receiver-service/v3/events', { method: 'POST', body: '{}' });
    await fetch('https://gew4-spclient.spotify.com/melody/v1/msg/batch', { method: 'POST', body: '{}' });
    await fetch('https://api-partner.spotify.com/pathfinder/v2/query', { method: 'POST', body: '{"operationName":"areEntitiesInLibrary"}' });
    await fetch('https://api-partner.spotify.com/pathfinder/v2/query', { method: 'POST', body: '{"operationName":"getAlbum"}' });
  });
  const rs = await drain();
  assert.equal(rs.length, 1);
  assert.match(rs[0].req, /getAlbum/);
});

test('the same URL is recorded once and the total is capped', async () => {
  await page.evaluate(async () => {
    for (let i = 0; i < 3; i++) await fetch('https://api-partner.spotify.com/same');
    for (let i = 0; i < 60; i++) await fetch('https://api-partner.spotify.com/u' + i);
  });
  assert.equal((await drain()).length, 30);
});
