// Runs in the PAGE world, every frame, at document start. Two jobs. (1) Background playback: see the end.
// (2) It only turns "the page asks for fullscreen"
// into a cancelable DOM event that video-detect.js (isolated world) listens for. No message handler here:
// the page gets no path to native code (decisions.md "JS bridge"). If nobody cancels the event, the
// original method runs, so unsupported videos keep the page's own fullscreen.
// ponytail: patched methods are detectable by the page (toString), nobody is hiding from sites here.
(() => {
  const wrap = (proto, name) => {
    const orig = proto?.[name];
    if (typeof orig !== 'function') return;
    proto[name] = function (...args) {
      const ev = new CustomEvent('nv-fullscreen', { bubbles: true, composed: true, cancelable: true }); // composed: leaves shadow roots
      this.dispatchEvent(ev);
      return ev.defaultPrevented ? Promise.resolve() : orig.apply(this, args);
    };
  };
  ['requestFullscreen', 'webkitRequestFullscreen'].forEach((n) => wrap(Element.prototype, n));
  ['webkitEnterFullscreen', 'webkitEnterFullScreen'].forEach((n) => wrap(HTMLVideoElement.prototype, n));

  // Diagnostic: stamp the document whenever the PAGE calls pause(), so the isolated script can tell
  // "the page paused it" from "iOS paused it". Our own pause command runs in the isolated world and
  // does not pass through this patch.
  const pause = HTMLMediaElement.prototype.pause;
  HTMLMediaElement.prototype.pause = function (...args) {
    document.documentElement.setAttribute('data-nv-pj', String(Date.now()));
    return pause.apply(this, args);
  };

  // Background playback: YouTube and others pause on `visibilitychange` when the app is backgrounded or the
  // screen locks (log 2026-11-06: paused in the same second as "app background"). Present the page as always
  // visible and swallow those events before any page listener sees them.
  // ponytail: all sites, all the time. Narrow it to pages with a playing video if a site misbehaves.
  for (const [k, v] of [['hidden', false], ['webkitHidden', false], ['visibilityState', 'visible'], ['webkitVisibilityState', 'visible']]) {
    Object.defineProperty(Document.prototype, k, { get: () => v, configurable: true });
  }
  // Diagnostic (Joyn stalls ~40 s on some plays): remember fetch/XHR calls that failed, are still pending after
  // 5 s, took over 3 s, or look like ads, in a DOM attribute. The isolated script forwards them to the log.
  // The page can forge the attribute, so native only logs the lines (length-checked), nothing else.
  // ponytail: fetch and XHR only, not workers, iframes' parents or <script>/<img> loads.
  const NET = [];
  const AD = /ad-pod|[/.]ads?[/.?]|vast|ima3|gampad|sqrt-|zomap|adition|71i[.]de|ioam|doubleclick|googlesyndication|hybrid-prd/i;
  let netTimer = 0;
  const netLog = (method, url, result, start) => {
    const ms = Math.round(performance.now() - start);
    let where = url;
    try { const u = new URL(url, location.href); where = u.host + u.pathname; } catch (e) { /* keep raw */ }
    if (!(result === 'ERR' || String(result).startsWith('pending') || ms > 3000 || AD.test(where))) return;
    NET.push('+' + (start / 1000).toFixed(1) + 's ' + method + ' ' + where.slice(0, 90) + ' ' + result + ' ' + ms + 'ms');
    if (NET.length > 40) NET.shift();
    clearTimeout(netTimer);
    netTimer = setTimeout(() => document.documentElement.setAttribute('data-nv-net', JSON.stringify(NET)), 300);
  };
  const origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function (input, init) {
      const url = String(input?.url ?? input), method = init?.method || input?.method || 'GET', start = performance.now();
      const slow = setTimeout(() => netLog(method, url, 'pending>5s', start), 5000);
      const p = origFetch.apply(this, arguments);
      p.then((r) => { clearTimeout(slow); netLog(method, url, r.status, start); }, () => { clearTimeout(slow); netLog(method, url, 'ERR', start); });
      return p;
    };
  }
  const xOpen = XMLHttpRequest.prototype.open, xSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) { this.nvCall = [String(method), String(url)]; return xOpen.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    const [method, url] = this.nvCall || ['?', '?'], start = performance.now();
    const slow = setTimeout(() => netLog(method, url, 'pending>5s', start), 5000);
    this.addEventListener('loadend', () => { clearTimeout(slow); netLog(method, url, this.status || 'ERR', start); });
    return xSend.apply(this, arguments);
  };

  const stop = (e) => e.stopImmediatePropagation();
  for (const t of ['visibilitychange', 'webkitvisibilitychange']) {
    addEventListener(t, stop, true);
    document.addEventListener(t, stop, true);
  }
})();
