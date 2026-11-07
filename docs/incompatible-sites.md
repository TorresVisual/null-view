# Incompatible sites

Where video mode cannot engage and the app behaves as a plain browser (decisions.md: fail open). Add a row whenever a phone test or `npm run corpus` finds one. "Blocking" problems (a site breaks because of a list) are fixed with the allowlist (shield button) and noted here too.

| Site / kind | Problem | Status | Found |
|---|---|---|---|
| DRM streaming (Netflix, Disney+, Prime Video, etc.) | Video mode is allowed since 2026-11-07 (decisions.md "Video"). Untested: fill in per site from the phone. Server-inserted ads are not blockable | Untested | 2026-11-07 |
| Joyn (joyn.at) | DRM video in web-component players (`<video>` inside shadow roots): video mode works since the shadow-root fix. Ads not checked | Works (phone, 2026-11-07) | 2026-11-07 |
| Spotify | DRM, so no video mode. Handled by a dedicated desktop-UA WebView instead (decisions.md "Spotify"). Ads not blocked, short gap between tracks | Works with limits | 2026-11-06 |
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

## Custom rules that help

### Joyn (joyn.at), open problem 2026-11-07

Symptom: with ads blocked the title only starts after about 40 s. The show's own video stays paused with its poster until then; no ad is visible. uBlock Origin on a PC starts the title straight away.

What is known:
- Joyn's ad service lives at `somquery.sqrt-5041.de` (`/v1/ad-pod/`). uBlock blocks it for `joyn.at` as XHR only (`||sqrt-5041.de^$xhr,domain=joyn.at|joyn.de`, uAssets issue 18684) and adds a `no-fetch-if zomap.de` scriptlet for `joyn.de/at/ch`.
- uBlock also lists **exceptions** for `joyn.de` so its lists do not break the player: `ad.71i.de/global_js/AppConfig/Joyn/desktop.json`, `adition.com/1x1.gif`, `aws.route71.net/ad-`, `research.de.com/bb-mx/prime`, `script.ioam.de/iam.js`, `securepubads.g.doubleclick.net/pcs/view/`. Our lists block `ad.71i.de` (AdGuard German), `ioam.de` (EasyPrivacy) and `adition.com` (EasyList, AdGuard Mobile).
- **A `@@` line in Custom rules cannot undo another list's block**: Safari's ignore-previous-rules only reaches earlier rules of the same compiled list, and each list compiles separately. Exceptions only work inside the list that blocks.
- The desktop browser cannot reproduce it (the player errors out before asking for ads).

Bisect on the phone: all built-in lists off, Custom rules only:

```
||sqrt-5041.de^$xmlhttprequest,domain=joyn.at
joyn.at#%#//scriptlet('prevent-fetch', 'zomap.de')
```

If the title then starts at once, turn lists back on one at a time to find which one stalls the player. If an exception is needed, the fix is to append the custom `@@` lines to every list before it is converted (not built).

Result of the bisect (2026-11-07): with only those two rules some plays start at once and some still stall about 40 s, so a blocked host alone is not the whole story. A network diagnostic was added: on a page with a video, the video log (Settings, Copy log) now gets `net` lines for fetch/XHR calls that failed, were still pending after 5 s, took over 3 s or look like ads (`ad-pod`, `ima3`, `gampad`, `sqrt-`, `zomap`, `adition`, `71i.de`, `ioam`, `doubleclick`, `hybrid-prd`, ...). Format: `net +12.3s GET host/path result ms` (`ERR` = failed, `pending>5s` = no answer yet). Fetch and XHR only: not workers, scripts or images. To read it: reproduce a stall, copy the log straight after, and compare with a play that starts at once.

First log with it (2026-11-07): a resumed episode (position 37 s) had its duration within a second and played; a fresh start of another title sat at `paused pos=1.0 dur=?` for 7+ s (no stream loaded). No `ad-pod`, `sqrt-` or `pending>5s` line appeared for either, only the Google `sodar` and `adsid` helper calls (200). So the wait is not on a main-frame fetch/XHR. Working theory: the stall is the pre-roll step, which only runs on a fresh start (a resume skips it), which would also explain "some plays start at once". The diagnostic now also reports from every frame (ad iframes) and includes scripts/styles/images that failed to load (blocked or offline), tagged with the tag name, e.g. `net +4.1s script host/path.js ERR 0ms`.

Second log (2026-11-07, build before the all-frames change): the stall also happens on a **resume**, so the pre-roll theory is dropped. The log covered only 5 s (video mode was left early) and showed `paused-by-page pos=1.0 dur=?` with only Google `ima_ppub_config`/`sodar`/`adsid` calls (200). The diagnostic was then widened: every distinct fetch/XHR outcome is logged once (known tracker hosts skipped), up to 60 per frame, 150 per page; the video log keeps 300 lines. Next capture: newest build, open the title normally (not via the resume banner), touch nothing for 60 s or until it plays, then Copy log.

Third log (2026-11-07, newest diagnostic): title opened from the home page at 16:02:55, `POST api.vod-prd.s.joyn.de/v1/asset/<id>/playlist 200` at 16:02:56, then **28 s with no logged fetch/XHR at all** (no ERR, no pending) and `dur=?`, then `dur=3527.8` and playing at 16:03:26. So the wait is not a blocked or hanging request. The page has **two** `<video>` elements (every line says `video #1 of 2`). Working theory: the other one plays the ad (hidden by size or a cosmetic rule, or no sound) and the title starts when it ends, the stream URLs being loaded natively (HLS) where JS cannot see them. The log now prints the other videos' state on an `others:` line (playing/paused, muted, size, pos, dur). Checks: (1) does `others:` show a video playing for the whole wait? (2) does the stall also happen with the shield off (site allowlisted, nothing blocked)? If yes, blocking is not the cause and the wait is the ad itself. A possible fix then is a generic "short secondary video that plays while the main one is paused: seek it to its end" in video-detect.js, like uBlock's 0.1 s media redirect for the sister sites.

Fourth log (2026-11-07, build with the `others:` line): resume at 43 s. `playlist 200` at 17:18:05 (+4.7 s), FairPlay certificate 200 at +4.9 s, then no JS-visible request for 30 s; `dur` appears at 17:18:35, playing at 17:18:36, and `POST /v1/license 200` at +35.7 s. The second `<video>` (#0) is **0x0, has no source and never plays**, so the "ad plays in the other video" theory is dropped. The stall is the main video's own media load: `dur=?` the whole time, license request only after it. New theory: the player first loads something else into the same `<video>` (IMA reuses the content element for ads on iOS), a native media request (invisible to JS) is blocked, and the ad SDK waits out its timeout before the title starts. Shortly after starting, the page paused the video at 44.9 s (`paused-by-page`), maybe a mid-roll cue. Next diagnostic: the video log now shows the element's `src` (host + path), `networkState`, `readyState` and MediaError code, so a log shows what it loads during the wait. Still wanted: the same title with joyn.at allowlisted (shield off) to see whether the wait remains.
