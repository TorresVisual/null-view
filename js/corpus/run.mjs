// Live-site smoke test: loads each corpus site in Playwright WebKit with the real video-detect.js and
// reports what it found. Needs network, so it is NOT part of `npm test`. Run: npm run corpus
// Desktop WebKit is not iOS (no blocker, other codecs, bot walls): a miss here is a lead, the phone decides.
import { webkit } from 'playwright';

const SCRIPT = new URL('../src/video-detect.js', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
// kind: what the page is for. videos: 'none' = no candidate, 'some' = at least one, 'multiple' = two or more, 'any' = just load.
const SITES = [
  { kind: 'static', url: 'https://example.com/', videos: 'none' },
  { kind: 'news', url: 'https://www.npr.org/sections/news/', videos: 'none' },
  { kind: 'video, multiple', url: 'https://www.w3schools.com/html/html5_video.asp', videos: 'multiple' },
  { kind: 'embedded video', url: 'https://www.w3schools.com/html/tryit.asp?filename=tryhtml5_video', videos: 'some' },
  { kind: 'ad-heavy', url: 'https://www.dailymail.co.uk/home/index.html', videos: 'some' },
  { kind: 'SPA', url: 'https://www.youtube.com/', videos: 'any' },
  { kind: 'JS required', url: 'https://react.dev/', videos: 'none' },
];

const browser = await webkit.launch();
const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
let msgs = [];
await context.exposeFunction('__nvPost', (m) => msgs.push(JSON.parse(m)));
await context.addInitScript(() => {
  window.webkit = { messageHandlers: { nvVideo: { postMessage: (m) => window.__nvPost(m) } } };
});
await context.addInitScript({ path: SCRIPT });

let bad = 0;
for (const s of SITES) {
  msgs = [];
  const page = await context.newPage();
  let status = '', title = '';
  try {
    const r = await page.goto(s.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    status = String(r?.status());
    await page.waitForTimeout(4000);
    title = (await page.title()).slice(0, 40);
  } catch (e) { status = 'ERR ' + e.message.split('\n')[0].slice(0, 50); }
  // Latest report per frame, then count videos that are real candidates (not tiny/decorative).
  const last = new Map();
  for (const m of msgs) if (m.type === 'videos') last.set(m.frame, m.videos);
  const all = [...last.values()].flat();
  const found = all.filter((v) => v.w * v.h >= 100 * 100 && v.src !== false);
  const ok = !status.startsWith('ERR') && status < 400 &&
    (s.videos === 'any' || ({ none: found.length === 0, some: found.length > 0, multiple: found.length > 1 }[s.videos]));
  if (!ok) bad++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${s.kind.padEnd(15)} ${status.padEnd(4)} frames=${last.size} videos=${all.length} candidates=${found.length} drm=${all.filter((v) => v.drm).length} "${title}" ${s.url}`);
  await page.close();
}
await browser.close();
process.exit(bad ? 1 : 0);
