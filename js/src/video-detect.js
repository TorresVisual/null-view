// Runs in an isolated WKContentWorld, in every frame (decisions.md "JS bridge").
// Reports the frame's <video> elements to native; native (Core/Video.swift) picks the primary.
// Plain script, no bundling: Swift loads this file as-is and the Playwright test loads the same file.
// Not covered (ponytail): videos inside shadow roots. Add a recursive walk if a site needs it.
(() => {
  if (window.__nvVideoDetect) return;
  window.__nvVideoDetect = true;

  const frame = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const EVENTS = ['play', 'playing', 'pause', 'ended', 'loadedmetadata', 'durationchange', 'emptied', 'resize'];
  const watched = new WeakSet();
  let timer = 0, due = 0, last = '', everHadVideos = false;

  const post = (m) => window.webkit?.messageHandlers?.nvVideo?.postMessage(JSON.stringify(m)); // native takes a JSON string
  const num = (x) => (Number.isFinite(x) && x >= 0 ? x : null);

  function describe(v, i) {
    const r = v.getBoundingClientRect();
    const vw = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const vh = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    return {
      i,
      w: Math.round(r.width), h: Math.round(r.height), vis: Math.round(vw * vh),
      playing: !v.paused && !v.ended && v.readyState > 2,
      ended: v.ended, muted: v.muted, loop: v.loop,
      dur: Number.isFinite(v.duration) ? v.duration : null,
      pos: num(v.currentTime) ?? 0,
      live: v.duration === Infinity,
      drm: !!v.mediaKeys,
      src: !!(v.currentSrc || v.src || v.srcObject),
    };
  }

  function report() {
    timer = 0; due = 0;
    const vids = [...document.querySelectorAll('video')];
    vids.forEach((v) => {
      if (watched.has(v)) return;
      watched.add(v);
      EVENTS.forEach((e) => v.addEventListener(e, () => schedule(100), true));
      v.addEventListener('timeupdate', () => schedule(1000), true);
    });
    if (!vids.length && !everHadVideos) return;
    everHadVideos = true;
    const videos = vids.slice(0, 50).map(describe);
    const msg = { type: 'videos', frame, videos };
    const json = JSON.stringify(msg);
    if (json === last) return;
    last = json;
    post(msg);
  }

  // Keep the earliest deadline: a timeupdate must not delay a pause report.
  function schedule(ms) {
    const at = Date.now() + ms;
    if (timer && due <= at) return;
    clearTimeout(timer);
    due = at;
    timer = setTimeout(report, ms);
  }

  new MutationObserver(() => schedule(250)).observe(document, { childList: true, subtree: true });
  addEventListener('pagehide', () => post({ type: 'gone', frame }));
  addEventListener('pageshow', () => { last = ''; schedule(0); }); // back/forward cache restore
  addEventListener('resize', () => schedule(250));
  addEventListener('scroll', () => schedule(500), { passive: true });
  schedule(0);
})();
