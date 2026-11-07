import { webkit } from 'playwright';
const b = await webkit.launch();
const c = await b.newContext({ viewport: { width: 390, height: 844 }, locale: 'de-AT' });
const p = await c.newPage();
const accept = async () => { await p.getByText(/akzeptieren/i).first().click({ timeout: 6000 }).catch(() => {}); };
const links = async () => p.evaluate(() => [...new Set([...document.querySelectorAll('a[href]')].map(a => a.href))]);
let found = null;
for (const idx of ['https://www.joyn.at/filme', 'https://www.joyn.at/serien']) {
  await p.goto(idx, { waitUntil: 'domcontentloaded', timeout: 30000 }); await p.waitForTimeout(3000); await accept(); await p.waitForTimeout(2500);
  const l = (await links()).filter(h => /joyn\.at\/(filme|serien)\/[^/?]+$/.test(h)).slice(0, 12);
  for (const s of l) {
    await p.goto(s, { waitUntil: 'domcontentloaded', timeout: 30000 }); await p.waitForTimeout(3500);
    const pl = (await links()).filter(h => /joyn\.at\/play\/(?!live-tv)/.test(h));
    if (pl.length) { found = pl[0]; break; }
  }
  if (found) break;
}
console.log('play url:', found);
if (found) {
  const seen = []; const t0 = Date.now();
  p.on('request', (r) => seen.push(`${((Date.now() - t0) / 1000).toFixed(1)}s ${r.method()} ${r.url().slice(0, 170)}`));
  p.on('requestfailed', (r) => seen.push(`${((Date.now() - t0) / 1000).toFixed(1)}s FAILED ${r.url().slice(0, 120)}`));
  await p.goto(found, { waitUntil: 'domcontentloaded', timeout: 30000 }); await p.waitForTimeout(3000); await accept();
  await p.waitForTimeout(45000);
  const keep = seen.filter(u => !/_next[/]static|datadog|event-collector|netid|adex|sensic|npaw|adjust|userreport|datazoom|p7s1.io|graphql|usercentrics|clarity|tiktok|facebook|hotjar|launchdarkly|googletagmanager|google-analytics|usersnap|fonts\.|\.css|\.woff|\.png|\.jpg|\.svg|img\.joyn/.test(u));
  console.log(keep.join('\n'));
}
await b.close();
