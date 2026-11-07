// Page-world script. Swift injects the per-page config as window.__nvConfig
// (from WebExtension.lookup) in a script that runs just before this one.
// Scriptlets must run in the page world to patch page APIs, so this is NOT
// in the isolated content world (see docs/decisions.md deviation note).
import { ContentScript } from '@adguard/safari-extension';

// The library runs scriptlets by putting their code in a <script> element's textContent. YouTube sends
// `require-trusted-types-for 'script'`, which rejects a plain string there ("This assignment requires a
// TrustedScript"), so no scriptlet ever ran on YouTube. We are already in the page world, so make the
// assignment compliant for the duration of the call. Without Trusted Types nothing changes.
function withTrustedScripts(fn) {
  let policy;
  try { policy = window.trustedTypes?.createPolicy('nv-adblock', { createScript: (s) => s }); } catch { /* policy name refused */ }
  if (!policy) return fn();
  const proto = HTMLScriptElement.prototype;
  const own = Object.getOwnPropertyDescriptor(proto, 'textContent'); // WebKit may define its own
  Object.defineProperty(proto, 'textContent', {
    configurable: true,
    get: (own ?? Object.getOwnPropertyDescriptor(Node.prototype, 'textContent')).get,
    set(v) { this.text = typeof v === 'string' ? policy.createScript(v) : v; },
  });
  try { return fn(); } finally { if (own) Object.defineProperty(proto, 'textContent', own); else delete proto.textContent; }
}

if (window.__nvConfig) withTrustedScripts(() => new ContentScript().applyConfiguration(window.__nvConfig, false));
