# Phase 0 runbook

The spike app is a single screen, not the real app. It exists to answer the five gate questions in `decisions.md`.

## Build and install

1. Push, then run the `build-ios` workflow by hand (Actions tab, "Run workflow"). Do this once, not speculatively.
2. Download the `NullView-ipa` artifact, unzip it, and sideload `NullView.ipa` with AltStore.
3. If the build fails, read the log before re-running (macOS minutes cost 10x).

## Gate checks (on the phone)

| Gate | How | Pass |
|---|---|---|
| 1 Blocking | Tap "1 Compile lists", wait for "advanced engine built". Then tap "1+2 Block/cosmetic test". | The log shows EasyList and EasyPrivacy compiled, and all four ad URLs say `blocked` while `control` says `ok`. Also note conversion time, `discarded` and `errors`. |
| 2 Cosmetic and scriptlets | Same test run. | `cosmetic_body_bg` is `rgb(255, 0, 0)` and `scriptlet_nvScriptletTest` is `true`. |
| 3 PiP | Tap "3+4 Video page", press play, then the PiP button. | The video floats in PiP and the page's own buttons still control it. |
| 4 Background audio | Play, then lock the screen or switch apps. | Audio keeps playing. |
| 5 URL scheme | Make a Shortcut with action "Open URLs" set to `nullview://open?url=https://example.com`. Run it. | The app opens, the log shows `5: received ...`, and example.com loads. |

Record the results (numbers included) in `docs/phase0-results.md`. If any gate fails, stop and re-decide with the owner.

## Deviation from decisions.md (needs the owner's sign-off)

decisions.md says all injected scripts run in an isolated `WKContentWorld`. Scriptlets can't: they patch page APIs (`Object.defineProperty`, `fetch`, `window.*`) and so must run in the **page world**. The spike injects the AdGuard cosmetic/scriptlet bundle with `in: .page`.

The proposed rule is that video-detection and bridge scripts stay in an isolated world with a message handler, and only the blocker bundle runs in the page world with no message handler.

## Known limits of the spike

- Cosmetic and scriptlet rules are looked up for the main frame only. Iframes need their own lookup (`topUrl`).
- The `SafariConverterLib` code is GPLv3, so this repo should be GPLv3 too if the code ships. That is fine for personal use.
- The Swift code has never been compiled (no toolchain on this PC). Expect to fix compile errors on the first CI run.
