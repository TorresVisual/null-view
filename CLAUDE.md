# null-view

iOS-only personal video browser (Swift, SwiftUI + WKWebView), sideloaded via AltStore on a free Apple ID. The owner has a Windows PC and an iPhone, **no Mac**. iOS builds happen only on a GitHub Actions macOS runner.

## Start here

1. Read `docs/decisions.md`. It is the source of truth and overrides `docs/brief.md`.
2. Status: Phase 0 passed (`docs/phase0-results.md`). Phase 1 (browser foundation) passed on the phone on 2026-11-06 (built on the runner, six-point manual test). Phase 2 (content blocking: `NullView/Blocker.swift`, `BlockingViews.swift`, `Core/.../Blocking.swift`) passed the phone test on 2026-11-06. Phase 3 (video detection: `NullView/VideoDetector.swift`, `js/src/video-detect.js`, `Core/.../Video.swift`) passed the phone test on 2026-11-06 (YouTube, Reddit iframe embeds). Current step: **Phase 4, dedicated video experience**. Phases 4 to 8 follow the brief, adjusted by `decisions.md`. Progress is tracked in GitHub Issues, one per phase (#1 to #4 closed, #5 Phase 4 to #9 Phase 8 open). Tick the task boxes as work lands and close the issue when the phone test passes. File new bugs and ideas with the `file-issue` skill.
3. The Phase 0 spike (blocker, PiP and audio fixtures) was deleted in Phase 1 but lives in git history (commit `bdba6a0`). Phase 2 re-adds the blocker from there. `project.yml` still carries the AdGuard dependency and JS bundle for that.

If a task would break a decision in `decisions.md` or fail an assumption in it, stop and ask the owner. Don't silently fall back to a weaker design (for example a home-grown blocker).

## Layout

- `project.yml`: XcodeGen spec. The `.xcodeproj` and `Info.plist` are generated and git-ignored.
- `Core/`: pure-Swift package `NullViewCore` (address-bar resolution, deep links). Tests: `swift test --build-system native` in `Core/`, via the vcvars batch below.
- `NullView/`: the app target (Apple frameworks allowed). `BrowserModel` owns the WebView, `BrowserView` and `SettingsView` are the UI.
- `js/`: npm project that bundles AdGuard's cosmetic/scriptlet script to `js/dist/adblock-content.js`. Built on Linux in CI, git-ignored.
- `.github/workflows/build-ios.yml`: manual-trigger build of the unsigned IPA.

## Keep Apple-only code thin

Anything that needs no Apple framework (URL normalization, deep-link parsing, history/queue logic, rule handling) goes in a pure-Swift package and is tested here on Windows. Do not put `FilterEngine` (AdGuard) in that package: it uses POSIX `flock` and does not build on Windows. `ContentBlockerConverter` does build. JS is tested in Node or Playwright WebKit. Only the thin WebView, PiP, audio-session and URL-scheme layer needs the runner and the phone.

Never claim Swift app code works unless it was compiled on the runner. This PC cannot compile it.

## CI rules

The repo is public, so runner minutes are free (confirmed in billing). Rules still apply to save time. If the repo goes private, macOS bills at 10x.

- macOS jobs run only on demand (`workflow_dispatch` or release tags), never per push or PR.
- The runner only builds the unsigned IPA. No signing, simulator, or UI tests there.
- Logic tests, JS tests and lint run on Linux or Windows.
- Cache SwiftPM, shallow clone, `concurrency` with `cancel-in-progress`, short `timeout-minutes`.
- Batch changes before a macOS run. Read the whole failed log and fix everything in it before re-running. No speculative re-runs.

## Windows Swift toolchain (local checks)

Swift 6.4.2 is installed under `%LOCALAPPDATA%\Programs\Swift`. It is not on PATH in the Bash tool. Set `PATH` to include `Toolchains\6.4.2+Asserts\usr\bin` and `Runtimes\6.4.2\usr\bin`, and set `SDKROOT` to `Platforms\6.4.2\Windows.platform\Developer\SDKs\Windows.sdk`. For packages with C modules, run through a batch file that first calls the Visual Studio 2022 `vcvars64.bat` (VS 2026's 14.51 toolset is incomplete), and use `swift build --build-system native`. Clone third-party packages with `-c core.autocrlf=false`.

## Workflow notes

- Commit finished, coherent work automatically (global rule). Do not push unless the owner says so.
- The owner tests on the phone. Say exactly what to tap and what a pass looks like, and ask for the full log back.
