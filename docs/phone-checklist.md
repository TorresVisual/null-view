# Phone checklist (every release build)

Run after installing a new IPA through AltStore. One line per check, tick it or write what you saw. Send back anything that fails, with Settings > Video detection log > Copy log.

Before anything: `Core` (`swift test`) and `js` (`npm test`) are green, and the corpus (`npm run corpus` in `js/`) shows no new failures.

## Browser
- [ ] Type `example.com`: the page loads. Type `hello world`: DuckDuckGo results load.
- [ ] Back, forward, reload work. A dead address shows "Can't open page" and Try again works.
- [ ] Kill the app and reopen: the last page is back with "Resume where you left off".

## Blocking
- [ ] Settings > Blocking > Update now: rule counts show, no red error.
- [ ] Open an ad-heavy page (for example dailymail.co.uk): far fewer ads than in Safari without a blocker.
- [ ] Shield button: allow this site. The page reloads with ads. Remove it again and they are gone.
- [ ] Custom rule `example.com##h1`, Save and apply: example.com has no heading.

## Video
- [ ] YouTube watch page: the video button appears. Tap it: landscape, controls on top.
- [ ] Gestures: drag sideways seeks, left half up/down brightness, right half up/down volume, double-tap skips 10 s, long-press plays at 2x, one tap toggles controls.
- [ ] Page's own fullscreen button enters video mode. Back control returns to the same page and position.
- [ ] Lock the screen: audio keeps playing. Picture in Picture works.
- [ ] A page with an embedded video (Reddit post, w3schools tryit) is detected.
- [ ] A DRM site (Netflix): button stays disabled and the page still browses normally.

## Library
- [ ] Watch past 15 s, leave: the video is under Continue Watching and resumes at that point.
- [ ] Watch Later add/remove, queue add, reorder, clear. When a video ends, the queue plays the next page.
- [ ] History shows visited pages; search, sort and site filter work.

## Sites
- [ ] Blank start page shows "Add site". Add youtube.com: a tile appears; "cute cats" is rejected.
- [ ] Tiles show the site's icon (a letter if the site has none).
- [ ] Tap the tile: the site loads. Force-quit and reopen: the tile is still there.
- [ ] Open a second site twice: it moves in front of the first. Long-press a tile, Remove: it is gone.
- [ ] The Sites button in the bottom toolbar opens the same grid as a sheet; tapping a tile closes it and loads the site.

## Spotify
- [ ] Open `https://open.spotify.com/album/6UN8m07SmIzyDe63H0oljL` after visiting YouTube: the Spotify overlay opens fitted to the screen (sidebar, main area, right panel), pinch zooms in only. Log in with the free account.
- [ ] Play the album: tracks go in order, the next one starts by itself, with and without the screen locked. Settings log shows `private pref ... applied` and `native zoom=0.2`.
- [ ] Done stops playback; opening the link again does not reload the page.

## Sharing
- [ ] The Shortcut from Settings > Sharing opens a shared link in the app.
- [ ] Copy a link, reopen the app: "Link on clipboard" banner, Open loads it.

## Privacy
- [ ] Clear website data logs you out of a site you were signed in to.
