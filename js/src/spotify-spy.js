// SPIKE (#17): runs in the PAGE world of the dedicated Spotify WebView only (main frame, document start).
// Wraps fetch and XMLHttpRequest and keeps a short record of each JSON response from a Spotify host, so the
// spike can see which private API response carries the album list and an album's chapters. No message
// handler (decisions.md "JS bridge"): Swift polls window.__nvSpy.drain(), which returns one JSON string
// per record and clears them. Remove or replace this file once the response shapes are known.
// ponytail: fetch/XHR on the main thread only; not workers. Cap 30 records per document, one per method+URL+request body.
(() => {
  const HOST = /(^|\.)spotify\.com$/, MAX = 30, HEAD = 500;
  const recs = [], seen = new Set();

  // Follow single-key objects ({data:{artistUnion:{...}}}) so `keys` describes the useful level, not just "data".
  const shape = (j) => {
    const path = [];
    let o = j;
    while (o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).length === 1 && path.length < 6) {
      const k = Object.keys(o)[0]; path.push(k); o = o[k];
    }
    return { path: path.join('.'), keys: o && typeof o === 'object' ? Object.keys(o).slice(0, 30) : [] };
  };

  // The first object that holds a spotify:album:/track: URI as `uri`, as leaf lines ("a.b[0].c: value"), so the log
  // shows where title, cover and year sit next to the id. Cap 40 lines, values cut to 60 chars.
  const sampleOf = (j) => {
    const URI = /^spotify:(album|track):/;
    const find = (o, path) => {
      if (!o || typeof o !== 'object') return null;
      if (!Array.isArray(o) && typeof o.uri === 'string' && URI.test(o.uri)) return { o, path };
      for (const [k, v] of Object.entries(o)) {
        const hit = find(v, Array.isArray(o) ? path + '[' + k + ']' : (path ? path + '.' : '') + k);
        if (hit) return hit;
      }
      return null;
    };
    const hit = find(j, '');
    if (!hit) return { samplePath: '', sample: [] };
    const lines = [];
    const walk = (o, p) => {
      if (lines.length >= 40) return;
      if (o && typeof o === 'object') for (const [k, v] of Object.entries(o)) walk(v, Array.isArray(o) ? p + '[' + k + ']' : (p ? p + '.' : '') + k);
      else lines.push(p + ': ' + String(o).slice(0, 60));
    };
    walk(hit.o, '');
    return { samplePath: hit.path, sample: lines };
  };

  const record = (method, url, status, ct, text, req) => {
    let u;
    try { u = new URL(url, location.href); } catch (e) { return; }
    if (!HOST.test(u.hostname) || !/json/i.test(ct || '')) return;
    const shown = u.host + u.pathname + u.search, key = method + shown + req;
    if (recs.length >= MAX || seen.has(key)) return;
    seen.add(key);
    const uris = new Set(text.match(/spotify:(?:album|track):[A-Za-z0-9]{22}/g) || []);
    const count = (kind) => [...uris].filter((s) => s.startsWith('spotify:' + kind + ':')).length;
    let sh = { path: '', keys: [], samplePath: '', sample: [] };
    try { const j = JSON.parse(text); sh = { ...shape(j), ...sampleOf(j) }; } catch (e) { /* not parseable: head still logged */ }
    const total = /"totalCount":\s*(\d+)/.exec(text);
    recs.push(JSON.stringify({
      method, status, url: shown.slice(0, 400), req, len: text.length, path: sh.path, keys: sh.keys,
      samplePath: sh.samplePath, sample: sh.sample, albums: count('album'), tracks: count('track'), total: total ? +total[1] : null, head: text.slice(0, HEAD),
    }));
  };

  const origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      const p = origFetch.apply(this, arguments);
      const url = String(input?.url ?? input), method = init?.method || input?.method || 'GET';
      const req = typeof init?.body === 'string' ? init.body.slice(0, 300) : '';  // GraphQL: the operation name lives here
      p.then((r) => {
        const ct = r.headers.get('content-type') || '';
        if (/json/i.test(ct)) r.clone().text().then((t) => record(method, url, r.status, ct, t, req), () => {});
      }, () => {});
      return p;
    };
  }

  const xOpen = XMLHttpRequest.prototype.open, xSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) { this.nvSpy = [String(method), String(url)]; return xOpen.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (body) {
    const [method, url] = this.nvSpy || ['?', '?'], req = typeof body === 'string' ? body.slice(0, 300) : '';
    this.addEventListener('loadend', () => {
      try { record(method, url, this.status, this.getResponseHeader('content-type'), this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText, req); } catch (e) { /* binary response type */ }
    });
    return xSend.apply(this, arguments);
  };

  window.__nvSpy = { drain: () => recs.splice(0) };
})();
