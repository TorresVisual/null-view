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

### Joyn (joyn.at), tested 2026-11-07

With the AdGuard German list on, ads no longer showed on joyn.at but the title only started after a delay. The list's Joyn rules are written for `joyn.de`: the `prevent-fetch` scriptlet is what turns the blocked ad-pod request into an instant empty answer (scriptlet lets the request fail, then returns a fake empty response), and it does not apply on `.at`. Paste into Settings, Custom rules:

```
! Joyn Austria: copies of AdGuard German's joyn.de rules, host independent
/ad-pod/$domain=joyn.at
joyn.at#%#//scriptlet('prevent-fetch', '/\/v\d+\/ad-pod\//')
joyn.at#%#//scriptlet('prevent-fetch', 'zomap.de')
joyn.at##div.MuiBox-root[class*=" mui-"]:has(> div[id^="BTS_"][id*="_Incontent-"])
@@||imagesrv.adition.com/1x1.gif$domain=joyn.at
@@||securepubads.g.doubleclick.net/pcs/view^$domain=joyn.at
```

Assumes the ad-pod path on `.at` is the same `/v1/ad-pod/` as on `.de` (not confirmed: the desktop browser cannot reach the playback step). If the delay stays, the phone log or a Safari Web Inspector network capture of the first seconds of playback gives the real host and path.
