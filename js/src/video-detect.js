// Runs in an isolated WKContentWorld, in every frame (decisions.md "JS bridge").
// Reports the frame's <video> elements to native; native (Core/Video.swift) picks the primary.
// Plain script, no bundling: Swift loads this file as-is and the Playwright test loads the same file.
// Videos inside open shadow roots are found too (Joyn's <turbo-video>). Closed shadow roots cannot be searched (ponytail).
(() => {
  if (window.__nvVideoDetect) return;
  window.__nvVideoDetect = true;

  const frame = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const EVENTS = ['play', 'playing', 'pause', 'ended', 'loadedmetadata', 'durationchange', 'emptied', 'resize', 'ratechange', 'webkitpresentationmodechanged', 'error', 'loadstart', 'stalled', 'abort'];
  const watched = new WeakSet();
  let lastNet = '', timer = 0, due = 0, last = '', everHadVideos = false, fast = false; // fast: video mode wants 4 position updates/s

  const post = (m) => window.webkit?.messageHandlers?.nvVideo?.postMessage(JSON.stringify(m)); // native takes a JSON string
  // Every <video> under root, including those inside open shadow roots, in a stable order (light DOM first).
  // Report and commands share this, so an index means the same video in both. Each shadow root found is
  // watched for changes (a MutationObserver on the document does not see into shadow trees).
  const mo = new MutationObserver(() => schedule(250));
  const observed = new WeakSet();
  function deepVideos(root) {
    const out = root.localName === 'video' ? [root] : [...root.querySelectorAll('video')];
    for (const e of [root, ...root.querySelectorAll('*')]) {
      const sr = e.shadowRoot;
      if (!sr) continue;
      if (!observed.has(sr)) { observed.add(sr); mo.observe(sr, { childList: true, subtree: true }); }
      out.push(...deepVideos(sr));
    }
    return out;
  }
  const num = (x) => (Number.isFinite(x) && x >= 0 ? x : null);
  // Diagnostic: where the video loads from (host + path only; the query may carry tokens).
  const srcLabel = (v) => { try { const u = new URL(v.currentSrc || v.src); return u.protocol === 'blob:' ? 'blob' : (u.host + u.pathname).slice(0, 80); } catch (e) { return ''; } };

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
      rate: v.playbackRate, s: srcLabel(v), ns: v.networkState, rs: v.readyState, err: v.error ? v.error.code : 0,
      pip: v.webkitPresentationMode === 'picture-in-picture',
      pj: Date.now() - Number(document.documentElement.getAttribute('data-nv-pj') || 0) < 1500, // page called pause() just now
    };
  }

  function report() {
    timer = 0; due = 0;
    const vids = deepVideos(document);
    vids.forEach((v) => {
      if (watched.has(v)) return;
      watched.add(v);
      EVENTS.forEach((e) => v.addEventListener(e, () => schedule(100), true));
      v.addEventListener('timeupdate', () => schedule(fast ? 250 : 1000), true);
    });
    // Network diagnostic written by fullscreen-hook.js (page world). Sent from every frame, video or not: a
    // player stall can be an ad iframe's doing. Lines from a sub-frame carry its host. Native caps the volume.
    const net = document.documentElement.getAttribute('data-nv-net');
    if (net && net !== lastNet) {
      lastNet = net;
      const tag = parent === window ? '' : '[' + location.host + '] ';
      try { const lines = JSON.parse(net); if (Array.isArray(lines)) post({ type: 'net', frame, lines: lines.map((l) => tag + String(l)) }); } catch (e) { /* forged or cut */ }
    }
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

  mo.observe(document, { childList: true, subtree: true });
  // Attaching a shadow root is not a DOM mutation anyone can observe, so a player that builds its shadow tree
  // after it was inserted would be missed. Rescan now and then; an unchanged report is not re-sent.
  // ponytail: a full tree walk every 1.5 s. Hook attachShadow in the page world if that ever shows up in a profile.
  setInterval(() => schedule(0), 1500);
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
    const v = deepVideos(document)[i];
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
    const t = e.composedPath()[0]; // e.target is retargeted to the shadow host
    const v = t.localName === 'video' ? t : deepVideos(t)[0];
    const i = v ? deepVideos(document).indexOf(v) : -1;
    if (i < 0 || !(v.currentSrc || v.src || v.srcObject)) return;
    e.preventDefault();
    post({ type: 'fullscreen', frame, i });
  }, true);
})();
