# null-view

iOS-only personal video browser (Swift, WKWebView). No Mac available: all iOS builds happen on a GitHub Actions macOS runner.

**Read `docs/decisions.md` first.** It is the source of truth and overrides `docs/brief.md` (the original intent and phase outline). Current step: Phase 0 feasibility gate. Don't build the full app before it passes.

## CI cost rule (macOS runner)

macOS runner minutes bill at **10x** the Linux rate, so every second on the runner counts. When writing or changing workflows:

- Run macOS jobs only on demand (`workflow_dispatch` / release tags), never on every push or PR.
- Do the minimum on the runner: build the unsigned IPA only. No signing, no simulator boot, no UI tests there.
- Run everything that doesn't need Apple frameworks (logic tests, JS tests, filter-list conversion, lint) on Linux/Windows, never macOS.
- Cache SwiftPM/derived data, use a shallow clone, set `concurrency` with `cancel-in-progress`, and set a short `timeout-minutes`.
- Never retry or re-run macOS jobs speculatively. Check the workflow locally first.
