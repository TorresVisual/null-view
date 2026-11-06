# Incompatible sites

Where video mode cannot engage and the app behaves as a plain browser (decisions.md: fail open). Add a row whenever a phone test or `npm run corpus` finds one. "Blocking" problems (a site breaks because of a list) are fixed with the allowlist (shield button) and noted here too.

| Site / kind | Problem | Status | Found |
|---|---|---|---|
| DRM streaming (Netflix, Disney+, Prime Video, etc.) | Encrypted media: the detector flags `drm`, the video-mode button is disabled | Out of scope (decisions.md) | design |
| Bare media file URLs (`https://host/file.mp4`) | iOS opens its generic viewer, there is no page or `<video>` for us | Not supported | Phase 4 |
| YouTube | Pauses itself on screen lock | Worked around (lock-screen play handler resumes) | Phase 4 |

## Corpus lead log (desktop WebKit, `npm run corpus` in `js/`)

Desktop WebKit is not iOS: no blocker, other codecs, some sites bot-wall it. Treat a failure as a lead to check on the phone.

| Date | Observation |
|---|---|
| 2026-11-06 | Corpus is green: static, news, video, embedded, ad-heavy, SPA, JS-required. |
| 2026-11-06 | wikimedia Commons and archive.org file pages give the detector no usable `<video>` at load (source attached only after a click, or the player is built lazily). Left out of the corpus. Check on the phone whether the video button appears after the first tap on play. |
| 2026-11-06 | forbes.com answered 403 to headless WebKit on one run. Bot wall, not an app issue. Daily Mail stands in as the ad-heavy site. |
| 2026-11-06 | YouTube's own embed (inside an iframe) did not report a video in headless WebKit; on the phone YouTube and Reddit embeds pass (Phase 3). |
