// Runs in the PAGE world, every frame, at document start. It only turns "the page asks for fullscreen"
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
})();
