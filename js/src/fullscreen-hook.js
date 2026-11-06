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
      const ev = new CustomEvent('nv-fullscreen', { bubbles: true, cancelable: true });
      this.dispatchEvent(ev);
      return ev.defaultPrevented ? Promise.resolve() : orig.apply(this, args);
    };
  };
  ['requestFullscreen', 'webkitRequestFullscreen'].forEach((n) => wrap(Element.prototype, n));
  ['webkitEnterFullscreen', 'webkitEnterFullScreen'].forEach((n) => wrap(HTMLVideoElement.prototype, n));

  // Background playback: YouTube and others pause on `visibilitychange` when the app is backgrounded or the
  // screen locks (log 2026-11-06: paused in the same second as "app background"). Present the page as always
  // visible and swallow those events before any page listener sees them.
  // ponytail: all sites, all the time. Narrow it to pages with a playing video if a site misbehaves.
  for (const [k, v] of [['hidden', false], ['webkitHidden', false], ['visibilityState', 'visible'], ['webkitVisibilityState', 'visible']]) {
    Object.defineProperty(Document.prototype, k, { get: () => v, configurable: true });
  }
  const stop = (e) => e.stopImmediatePropagation();
  for (const t of ['visibilitychange', 'webkitvisibilitychange']) {
    addEventListener(t, stop, true);
    document.addEventListener(t, stop, true);
  }
})();
