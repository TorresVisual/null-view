// Runs in an isolated WKContentWorld, in every frame (decisions.md "JS bridge").
// Reports the frame's <video> elements to native; native (Core/Video.swift) picks the primary.
// Plain script, no bundling: Swift loads this file as-is and the Playwright test loads the same file.
// Not covered (ponytail): videos inside shadow roots. Add a recursive walk if a site needs it.
(() => {
  if (window.__nvVideoDetect) return;
  window.__nvVideoDetect = true;

  const frame = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const EVENTS = ['play', 'playing', 'pause', 'ended', 'loadedmetadata', 'durationchange', 'emptied', 'resize', 'ratechange', 'webkitpresentationmodechanged'];
  const watched = new WeakSet();
  let timer = 0, due = 0, last = '', everHadVideos = false, fast = false; // fast: video mode wants 4 position updates/s

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
      rate: v.playbackRate,
      pip: v.webkitPresentationMode === 'picture-in-picture',
      pj: Date.now() - Number(document.documentElement.getAttribute('data-nv-pj') || 0) < 1500, // page called pause() just now
    };
  }

  function report() {
    timer = 0; due = 0;
    const vids = [...document.querySelectorAll('video')];
    vids.forEach((v) => {
      if (watched.has(v)) return;
      watched.add(v);
      EVENTS.forEach((e) => v.addEventListener(e, () => schedule(100), true));
      v.addEventListener('timeupdate', () => schedule(fast ? 250 : 1000), true);
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

  // ---- Video mode (Phase 4) ----
  // Own fullscreen: the video (or the <iframe> holding it) is pinned over the whole viewport, everything
  // else is hidden. Attributes mark the pinned element and its ancestors; a constructable stylesheet is
  // used because, unlike a <style> element, a page CSP cannot block it.
  // Shadow roots on the way up get the same rules (an outer stylesheet does not reach into them), and
  // the hide rule matches every element there. Closed shadow roots cannot be searched (ponytail).
  const BASE = `
    [data-nv-chain]{transform:none!important;filter:none!important;perspective:none!important;contain:none!important;
      backdrop-filter:none!important;will-change:auto!important;overflow:visible!important;z-index:auto!important}
    [data-nv-target]{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;
      max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;border:0!important;
      z-index:2147483647!important;background:#000!important;object-fit:contain!important;transform:none!important}`;
  const HIDE = '*:not([data-nv-chain]):not([data-nv-target]){visibility:hidden!important}';
  const HIDE_DOC = `html[data-nv-on] body ${HIDE}
    html[data-nv-on],html[data-nv-on] body{overflow:hidden!important;background:#000!important}`;
  const sheets = new Map(); // document or shadow root -> our stylesheet
  const marked = new Set(); // elements carrying our attributes (querySelectorAll cannot see into shadow roots)

  function adopt(root, css) {
    if (sheets.has(root)) return;
    const s = new CSSStyleSheet();
    s.replaceSync(BASE + css);
    root.adoptedStyleSheets = [...root.adoptedStyleSheets, s];
    sheets.set(root, s);
  }

  function mark(el, attr) { el.setAttribute(attr, ''); marked.add(el); }

  function expand(el) {
    mark(el, 'data-nv-target');
    for (let p = el; ;) {
      const par = p.parentElement;
      if (par === document.body) break;
      if (par) { mark(par, 'data-nv-chain'); p = par; continue; }
      const root = p.getRootNode();
      if (!root.host) break;
      adopt(root, HIDE);
      mark(root.host, 'data-nv-chain');
      p = root.host;
    }
    document.documentElement.setAttribute('data-nv-on', '');
    adopt(document, HIDE_DOC);
  }

  function collapse() {
    marked.forEach((e) => { e.removeAttribute('data-nv-chain'); e.removeAttribute('data-nv-target'); });
    marked.clear();
    document.documentElement.removeAttribute('data-nv-on');
    sheets.forEach((s, root) => { root.adoptedStyleSheets = root.adoptedStyleSheets.filter((x) => x !== s); });
    sheets.clear();
  }

  const framesIn = (root) => [...root.querySelectorAll('*')].flatMap((e) =>
    [...(e.matches('iframe,frame') ? [e] : []), ...(e.shadowRoot ? framesIn(e.shadowRoot) : [])]);

  const up = (nv) => { if (parent !== window) parent.postMessage({ nv }, '*'); };

  // A child frame asks its parent to pin the <iframe> that holds it; each level forwards upward.
  addEventListener('message', (e) => {
    const nv = e.data?.nv;
    if (nv !== 'expand' && nv !== 'collapse') return;
    const f = framesIn(document).find((x) => x.contentWindow === e.source);
    if (!f) return;
    if (nv === 'expand') expand(f); else collapse();
    up(nv);
  });

  // Native commands, run with evaluateJavaScript in this content world. Returns false if the video is gone.
  window.__nvCmd = (i, cmd, arg) => {
    const v = document.querySelectorAll('video')[i];
    if (!v) return false;
    switch (cmd) {
      case 'enter': fast = true; expand(v); up('expand'); break;
      case 'exit': fast = false; collapse(); up('collapse'); break;
      case 'play': v.play().catch(() => {}); break;
      case 'pause': v.pause(); break;
      case 'seek': v.currentTime = arg; break;
      case 'rate': v.playbackRate = arg; break;
      case 'pip': v.webkitSetPresentationMode?.(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); break;
      default: return false;
    }
    schedule(0);
    return true;
  };

  // The page-world hook (fullscreen-hook.js) fires this when the page asks for fullscreen. Swallow the
  // request only for a video we can drive; otherwise leave it alone so the page behaves as a plain browser.
  document.addEventListener('nv-fullscreen', (e) => {
    const t = e.target;
    const v = t.tagName === 'VIDEO' ? t : t.querySelector?.('video');
    const i = v ? [...document.querySelectorAll('video')].indexOf(v) : -1;
    if (i < 0 || !(v.currentSrc || v.src || v.srcObject)) return;
    e.preventDefault();
    post({ type: 'fullscreen', frame, i });
  }, true);
})();
