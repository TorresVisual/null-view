# Phase 0 results

Device: iPhone, iOS 26.6.2, sideloaded via AltStore. App built by the `build-ios` workflow.

## Run 1 (2026-11-06)

| Gate | Result | Notes |
|---|---|---|
| 1 Blocking | **Pass** | EasyList: 78,057 source rules, 59,689 Safari rules (cap 150,000), 38 errors. EasyPrivacy: 56,456 source rules, 56,478 Safari rules, 42 errors. Nothing discarded. Download about 0.1 s, conversion about 0.2 s per list, `WKContentRuleList` compile 2 to 4 s. All 4 probed ad URLs blocked; control request loaded. |
| 2 Scriptlets | **Pass** | The `set-constant` scriptlet ran in the page world (`window.nvScriptletTest === true`). The advanced engine built from 501 advanced rules in under 0.1 s. |
| 2 Cosmetic CSS | **Inconclusive** | The probe looked for an `h1` and found none (`no h1`), so nothing was measured. Run 2 probes `body` and logs the page title. |
| 3 PiP | **Inconclusive (fixture broken)** | `video error 4`: the sample URL (Google's `gtv-videos-bucket`) now returns HTTP 403, so no media loaded and `webkitSupportsPresentationMode` was `false`. Run 2 uses Apple's HLS sample and MDN's MP4. |
| 4 Background audio | Not run | Needs a working video. |
| 5 URL scheme | Not run | |

Takeaway: the risky part (real lists compile within the rule cap, scriptlets inject through a user script) works. The remaining gates are about video and the URL scheme.
