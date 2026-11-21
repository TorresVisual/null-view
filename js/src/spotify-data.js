// Runs in the PAGE world of the dedicated Spotify WebView only (main frame, document start). Issue #18.
// Passive: wraps fetch and XMLHttpRequest and keeps the full body of the web player's own responses for the
// three operations the native screens need. It sends no request of its own and knows no token or hash.
// No message handler (decisions.md "JS bridge"): Swift polls window.__nvSpotify.drain(), which returns the
// records ({op, text}) and clears them. Spotify's markup and operation names are private and can change:
// the commands at the bottom report what they did, so a miss shows up in the in-app log.
// ponytail: main thread only, not workers. Backlog capped at 100 records (oldest dropped) in case Swift stops polling.
(() => {
  const HOST = /(^|\.)spotify\.com$/, MAX = 100;
  const OPS = /operationName["=:\s]+"?(queryArtistDiscographyAll|queryArtistDiscographyOverview|getAlbum)\b/;
  const recs = [];

  const record = (url, req, ct, text) => {
    if (!/json/i.test(ct || '')) return;
    let u;
    try { u = new URL(url, location.href); } catch (e) { return; }
    if (!HOST.test(u.hostname)) return;
    const m = OPS.exec(req + ' ' + u.search);   // POST: the operation lives in the body; GET: in the query string
    if (!m) return;
    recs.push({ op: m[1], text });
    if (recs.length > MAX) recs.shift();
  };

  const origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      const p = origFetch.apply(this, arguments);
      const url = String(input?.url ?? input);
      const req = typeof init?.body === 'string' ? init.body.slice(0, 500) : '';
      p.then((r) => {
        const ct = r.headers.get('content-type') || '';
        if (/json/i.test(ct)) r.clone().text().then((t) => record(url, req, ct, t), () => {});
      }, () => {});
      return p;
    };
  }

  const xOpen = XMLHttpRequest.prototype.open, xSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) { this.nvUrl = String(url); return xOpen.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (body) {
    const req = typeof body === 'string' ? body.slice(0, 500) : '';
    this.addEventListener('loadend', () => {
      try { record(this.nvUrl || '', req, this.getResponseHeader('content-type'), this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText); } catch (e) { /* binary response type */ }
    });
    return xSend.apply(this, arguments);
  };

  // The page lists are virtualized and page in as they are scrolled, so the fetcher scrolls in steps (a jump
  // skipped offsets 140 to 180 in the spike). Every scrollable element in main moves, because which one the
  // page watches is Spotify's business; the tallest one decides when the end is reached.
  const scrollers = () => {
    const root = document.querySelector('main') || document.body;
    const all = [root, ...root.querySelectorAll('*')].filter((e) => e.scrollHeight > e.clientHeight + 50 && /auto|scroll/.test(getComputedStyle(e).overflowY));
    const doc = document.scrollingElement;
    if (doc && doc.scrollHeight > doc.clientHeight + 50) all.push(doc);
    return all;
  };
  const describe = (e) => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (e.classList[0] ? '.' + e.classList[0] : '');

  const rowFor = (uri, number) => {
    const id = uri.split(':').pop();
    const rows = [...document.querySelectorAll('[data-testid="tracklist-row"]')];
    return rows.find((r) => r.querySelector(`a[href*="/track/${id}"]`)) || rows.find((r) => r.getAttribute('aria-rowindex') === String(number + 1));
  };

  window.__nvSpotify = {
    drain: () => recs.splice(0),
    /** Half a viewport down every scrollable element; wraps to the top after the end. Returns 'step', 'wrapped' or
     *  'none' plus where the tallest scroller is, so the in-app log shows what happened when the list stalls. */
    scrollStep() {
      const els = scrollers();
      if (!els.length) return 'none';
      const main = els.reduce((a, e) => (e.scrollHeight > a.scrollHeight ? e : a));
      const end = main.scrollTop + main.clientHeight >= main.scrollHeight - 2;
      for (const e of els) e.scrollTop = end ? 0 : e.scrollTop + e.clientHeight * 0.5;
      return `${end ? 'wrapped' : 'step'} top=${Math.round(main.scrollTop)} of ${main.scrollHeight} client=${main.clientHeight} el=${describe(main)}`;
    },
    /** Plays that chapter's row. Returns which way it was clicked, or why not ('not rendered': scroll and retry). */
    playChapter(uri, number) {
      const row = rowFor(uri, number);
      if (!row) return 'not rendered';
      row.scrollIntoView({ block: 'center' });
      const b = row.querySelector('button[data-testid="play-button"], button[aria-label^="Play"]');
      if (b) { b.click(); return 'row button'; }
      row.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true }));
      return 'row dblclick';
    },
    /** The album's own play button: resumes where Spotify left off. */
    playAlbum() {
      const b = document.querySelector('[data-testid="action-bar-row"] [data-testid="play-button"]') || document.querySelector('main [data-testid="play-button"]');
      if (!b) return 'play button NOT found';
      b.click();
      return 'play button clicked';
    },
  };
})();
