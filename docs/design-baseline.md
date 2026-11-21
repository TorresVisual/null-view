# Design baseline (issue #16)

One page. Small enough to apply by hand, not a design system. Presentation only: it never changes blocker, DRM or video-mode behaviour (`decisions.md` wins). Constants live in one file, `NullView/Theme.swift`.

## Identity

Taken from the app icon (`icon-1024.png`).

| Token | Dark | Light | Use |
|---|---|---|---|
| `accent` | `#a2e484` | `#1f8a4c` | tint: buttons, toggles, links, selected state, progress. Light is darker because lime on white is about 1.5:1. |
| `brandGradient` | `#e4f77e` to `#5fd08a` | same | brand mark only: launch screen, start page. Never on controls. |
| `ink` | `#14171b` | | launch screen and video-mode / Spotify backdrop |
| `paper` | `#f4f6f2` | | text and icons on `ink` |

Set as the `AccentColor` asset (so `.tint`, `Toggle`, `ProgressView` and `Button` pick it up with no per-view code). The app follows the system light/dark setting; video mode and Spotify stay dark. App icon unchanged. Launch screen: `ink` background plus the slash-and-ring mark (`Brand.svg` in the asset catalog, `UILaunchScreen` with `UIColorName` and `UIImageName`).

## Type

System font only, Dynamic Type styles only (no fixed point sizes except the 44 pt icon frames).

| Role | Style |
|---|---|
| Screen and sheet titles | `.headline` (nav bars) |
| Row title, banner text | `.body` / `.subheadline` |
| Row detail, captions, footers | `.footnote` or `.caption`, `.secondary` |
| Numbers that change (time, HUD) | `.monospacedDigit()` |
| Logs and rules | `.system(.caption2, design: .monospaced)` |

## Spacing and shape (in `Theme`)

| Token | Value | Use |
|---|---|---|
| `Theme.gap` | 12 | padding between items, bar insets |
| `Theme.pad` | 16 | screen edge padding |
| `Theme.radiusSmall` | 8 | thumbnails, address field |
| `Theme.radius` | 14 | tiles, cards, banners |
| `Theme.hit` | 44 | minimum touch target (unchanged from Phase 7) |

Replaces the ad hoc 6 / 10 / 14 values. Controls over video use `.ultraThinMaterial` circles; surfaces use `.bar`. No other fills.

## Banners

One component, `Banner(icon:text:action:dismiss:)`: leading icon (`.secondary`), one line of `.subheadline` text, optional prominent button, optional dismiss (44 pt). Same layout for all four.

**Stacking: one at a time.** Priority (highest first), the rest wait and appear when the one above goes away:
1. Blocked popup (the page asked for it just now)
2. Toast (transient, 2 s, confirms an action)
3. Link on clipboard
4. Resume where you left off

Never shown in video mode. Slides in from the bottom as today.

## Toolbar

Six items: Back, Reload/Stop, Shield (accent when blocking is on, `.secondary` when off), **Sites**, Library, More. Sites and Library are always visible: they are the main views.

- **More** (`ellipsis.circle`) is a menu: Forward, Hide an element, Settings. It carries the warning badge when a filter update failed (replaces the swapped Settings icon). Forward can live here because edge-swipe back and forward is on (`BrowserModel.swift`).
- "Hide an element" becomes a visible menu item (was a hidden long-press on the shield).
- Disabled items use the standard dimmed look, no custom colours.

## Video button

Moves to the bottom left of the page area, so it no longer covers site tab bars (YouTube's "You"). The disabled state is hidden instead of dimmed: no source, no button.

## Start page

Brand mark (gradient slash-and-ring, 72 pt) and "Null View" in `.title2` above the sites grid. Setup text replaced by one `.footnote` line with a link to Settings, not a paragraph. Empty grid shows only "Add site".

## Library

- Row titles `.primary` (they render tint-blue today, as buttons do): use `.buttonStyle(.plain)` on the row.
- "This page" actions become one row of two bordered buttons ("Watch later", "Add to queue"), not two list rows.
- Posterless rows (all queue items) show the site's initial on a `radiusSmall` tile, same as Sites tiles, not a grey box.
- Tabs and sort/filter unchanged.

## Settings: five groups

1. **Blocking**: a "Filter lists" row (summary: "7 on, updated 18:20") that pushes the list toggles, with Update now, Custom rules and Allowed sites beside it. The long footer becomes one sentence.
2. **Search**: search URL field and reset.
3. **Sharing**: the nullview:// line and a shorter footer.
4. **Privacy**: Clear website data and the privacy sentence.
5. **Advanced**: Video detection log (pushed screen, with Copy log), Custom rules.

List timestamps use `.relative` ("updated 1 hour ago"), one line.

## Video mode

Keep the layout. Apply: `Theme.hit`, `paper` foreground, accent on the scrubber and the active speed or sleep state. Options icon changes from a gear (reads as Settings) to `slider.horizontal.3`.

## Spotify

Same banner-style header (title, Done in accent). Transport bar uses `paper` icons with accent only on the play state, instead of stock blue.

## Check

On the phone, from one runner build: light and dark, portrait and landscape, largest Dynamic Type; the Phase 8 checklist (`docs/phone-checklist.md`) still passes, including 44 pt targets and VoiceOver labels; before and after screenshots attached to #16.
