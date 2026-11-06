// Page-world script. Swift injects the per-page config as window.__nvConfig
// (from WebExtension.lookup) in a script that runs just before this one.
// Scriptlets must run in the page world to patch page APIs, so this is NOT
// in the isolated content world (see docs/decisions.md deviation note).
import { ContentScript } from '@adguard/safari-extension';

if (window.__nvConfig) new ContentScript().applyConfiguration(window.__nvConfig, false);
