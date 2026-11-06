// "Hide an element" picker. Evaluated on demand (not a user script) in the main frame of the isolated
// "nullview.picker" content world, so the page cannot see the `nvPicker` message handler.
// Tap what to hide, "Larger" widens it to the parent, "Hide" posts {type:'rule', host, selector} and
// hides it now. Swift turns that into a `host##selector` custom rule (ElementRule.line validates it).
// ponytail: main frame only; no iframes. Class names with digits are skipped (build-hash classes change).
(() => {
  if (window.__nvPicker) return true;
  window.__nvPicker = true;

  // The same charset ElementRule.line accepts: no digits in names, no escapes, no quotes.
  const NAME = /^[A-Za-z_][A-Za-z_-]*$/;
  const TAG = /^[A-Za-z][A-Za-z0-9-]*$/;

  const unique = (sel, el) => {
    try { const f = document.querySelectorAll(sel); return f.length === 1 && f[0] === el; } catch { return false; }
  };

  const part = (n) => {
    if (n.id && NAME.test(n.id) && document.querySelectorAll('#' + n.id).length === 1) return '#' + n.id;
    if (!TAG.test(n.localName)) return null;
    let s = n.localName + [...n.classList].filter((c) => NAME.test(c)).slice(0, 2).map((c) => '.' + c).join('');
    const p = n.parentElement;
    if (p && p.querySelectorAll(':scope > ' + s).length > 1) {
      const same = [...p.children].filter((c) => c.localName === n.localName);
      s += ':nth-of-type(' + (same.indexOf(n) + 1) + ')';
    }
    return s;
  };

  // Shortest chain of `parent > child` parts, walking up from the element until it is unique.
  const selectorFor = (el) => {
    const parts = [];
    for (let n = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
      const p = part(n);
      if (!p) return null;
      parts.unshift(p);
      const sel = parts.join(' > ');
      if (unique(sel, el)) return sel;
    }
    const full = 'body > ' + parts.join(' > ');
    return unique(full, el) ? full : null;
  };

  const host = document.createElement('div');
  host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `<style>
    .box{position:fixed;border:2px solid #0a84ff;background:rgba(10,132,255,.25);pointer-events:none;display:none}
    .bar{position:fixed;left:8px;right:8px;bottom:max(8px,env(safe-area-inset-bottom));background:#1c1c1e;color:#fff;
      font:14px -apple-system,sans-serif;border-radius:12px;padding:10px;pointer-events:auto;display:flex;gap:8px;flex-wrap:wrap}
    .sel{flex:1 1 100%;font:12px ui-monospace,monospace;opacity:.8;word-break:break-all;max-height:3.6em;overflow:hidden}
    button{flex:1;min-height:44px;font:600 15px -apple-system,sans-serif;border:0;border-radius:8px;background:#3a3a3c;color:#fff}
    button:disabled{opacity:.4}
    .go{background:#0a84ff}
  </style><div class=box></div>
  <div class=bar><div class=sel>Tap what you want to hide</div>
    <button class=up disabled>Larger</button><button class=go disabled>Hide</button><button class=no>Cancel</button></div>`;
  const $ = (c) => root.querySelector('.' + c);
  const box = $('box'), label = $('sel'), up = $('up'), go = $('go');

  let current = null, selector = null;

  const draw = () => {
    if (!current) return;
    const r = current.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
  };

  const choose = (el) => {
    current = el;
    selector = selectorFor(el);
    label.textContent = selector || "Can't build a rule for this one. Try Larger.";
    go.disabled = !selector;
    const p = el.parentElement;
    up.disabled = !p || p === document.body || p === document.documentElement;
    draw();
  };

  const onTap = (e) => {
    if (e.composedPath().includes(host)) return; // our own bar
    e.preventDefault();
    e.stopImmediatePropagation();
    const t = e.target;
    if (t !== document.body && t !== document.documentElement) choose(t);
  };

  const stop = () => {
    window.removeEventListener('click', onTap, true);
    window.removeEventListener('scroll', draw, true);
    window.removeEventListener('resize', draw);
    host.remove();
    delete window.__nvPicker;
  };

  up.addEventListener('click', () => { if (current && !up.disabled) choose(current.parentElement); });
  $('no').addEventListener('click', stop);
  go.addEventListener('click', () => {
    if (!selector) return;
    const style = document.createElement('style');
    style.textContent = selector + '{display:none!important}';
    (document.head || document.documentElement).append(style);
    window.webkit.messageHandlers.nvPicker.postMessage(JSON.stringify({ type: 'rule', host: location.hostname, selector }));
    stop();
  });

  window.addEventListener('click', onTap, true);
  window.addEventListener('scroll', draw, true);
  window.addEventListener('resize', draw);
  document.documentElement.append(host);
  return true; // evaluateJavaScript reports an undefined result as a failure
})();
