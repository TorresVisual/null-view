# brief

# Mobile Video Browser — Project Plan

## 1. Project Overview

### 1.1 Goal

Build a **mobile-first video browser** that combines normal web browsing with a dedicated video-watching experience and a genuine web-content blocking system.

The application should allow users to discover and watch web-hosted videos while providing a cleaner, more focused experience than a conventional mobile browser.

The project is not intended to be a general-purpose browser. Its primary purpose is:

> **Browse the web → find video → watch it comfortably → return later and continue watching.**

### 1.2 Core Principles

The project should follow these principles:

- **Video-first** — watching videos is the primary use case.

- **Real content blocking** — ad blocking is a core subsystem, not a cosmetic feature.

- **Mobile-first** — interaction and UI should be designed around phones.

- **Native-feeling watching** — fullscreen, landscape, gestures, PiP, and playback state should feel like a dedicated video application.

- **Existing technology where possible** — avoid reinventing mature infrastructure.

- **Modular architecture** — browser, blocker, video handling, and persistence should be independently testable.

- **Privacy-conscious** — unnecessary tracking and telemetry should be avoided.

---

# 2. Core Feature Areas

## 2.1 Content Blocking

The application must provide genuine web-content/ad blocking.

### Requirements

- Integrate an established filtering engine.

- Support standard filter-list formats where supported.

- Support commonly used lists such as EasyList/EasyPrivacy where technically feasible.

- Block network requests where the platform/browser integration permits it.

- Support cosmetic/element filtering where available.

- Support scriptlet-based filtering where supported by the chosen engine.

- Maintain filter-list subscriptions.

- Update filter lists automatically.

- Allow manual filter-list updates.

- Provide custom blocking rules.

- Provide allowlists.

- Allow blocking to be disabled for individual sites.

- Allow users to view basic blocking statistics.

### Architectural requirement

The project **must not implement its own minimal ad-blocking engine** unless no suitable established engine can satisfy the platform requirements.

The first technical milestone should therefore be:

> **Evaluate existing filtering engines and determine which can realistically integrate with the selected mobile browser technology.**

---

# 3. Video Experience

The browser should identify when a page contains a meaningful video and provide a dedicated watching experience.

### Features

- Detect primary/active video elements.

- Enter dedicated video mode.

- Improved fullscreen handling.

- Automatic landscape orientation where appropriate.

- Picture-in-picture where supported.

- Playback controls optimized for touch.

- Gesture controls.

- Seek gestures.

- Volume/brightness gestures where platform APIs allow.

- Prevent accidental navigation while watching.

- Restore playback position.

- Continue watching.

### Video mode

Video mode should reduce unnecessary browser UI while preserving access to essential controls.

Conceptually:

```text
┌─────────────────────────────┐
│                             │
│                             │
│           VIDEO             │
│                             │
│                             │
├─────────────────────────────┤
│  ◀  ━━━━━━━●━━━━━━  ⚙  ⛶   │
└─────────────────────────────┘
```

The exact UI should be determined during UX design rather than locked in during the initial implementation.

---

# 4. Browsing

The application still needs to function as a real web browser.

### Core functionality

- URL/address input.

- Web navigation.

- Back/forward navigation.

- Reload.

- Page loading state.

- Error handling.

- Basic browser history.

- Link interaction.

- Text selection/copying.

- Share/open URL.

- External URL handling.

### Mobile-specific behavior

- Safe-area handling.

- Keyboard-aware navigation.

- Touch-friendly controls.

- Swipe navigation where appropriate.

- Mobile viewport handling.

- Orientation changes.

- System back-button integration.

---

# 5. Watching & Persistence

Watching state should be treated as a separate subsystem.

### Continue Watching

Store:

- Video/page URL.

- Title where available.

- Thumbnail where available.

- Current playback position.

- Duration where available.

- Last watched timestamp.

- Site/source.

- Completion state.

### Additional features

- Watch Later.

- History.

- Continue Watching.

- Playback position restoration.

- Queue.

- Session restoration.

The system should distinguish between:

```text
History
    ↓
Things the user visited

Continue Watching
    ↓
Videos with meaningful unfinished progress

Watch Later
    ↓
Videos explicitly saved by the user

Queue
    ↓
Videos currently scheduled for playback
```

---

# 6. Mobile Integration

The application should integrate naturally with the operating system.

### Required integrations

- Share sheet → open URL in application.

- Open supported links in application.

- Deep links.

- System fullscreen.

- Picture-in-picture where available.

- Orientation handling.

- Background playback where platform capabilities and policies allow.

- Media/session controls where available.

---

# 7. High-Level Architecture

The application should be divided into independently testable subsystems.

```text
┌─────────────────────────────────────┐
│             Mobile UI               │
│                                     │
│ Browser │ Video │ Library │ Settings│
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│          Application Layer          │
│                                     │
│ Navigation                          │
│ Video Detection                     │
│ Watching State                      │
│ Session Management                  │
└───────────────┬───────────┬─────────┘
                │           │
       ┌────────▼──────┐ ┌──▼─────────────┐
       │ Browser Layer │ │ Persistence    │
       │               │ │                │
       │ WebView       │ │ History        │
       │ Navigation    │ │ Watch Later    │
       │ Web APIs      │ │ Progress       │
       └───────┬───────┘ │ Sessions       │
               │         └────────────────┘
       ┌───────▼──────────┐
       │ Content Blocking │
       │                  │
       │ Filter Engine    │
       │ Filter Lists     │
       │ Custom Rules     │
       │ Allowlists       │
       └──────────────────┘
```

The important architectural boundary is:

```text
Browser
   │
   ├── Content Blocking
   │
   └── Video Detection
           │
           ▼
      Video Experience
           │
           ▼
     Watching State
           │
           ▼
       Persistence
```

---

# 8. Technical Investigation Phase

Before committing to the implementation architecture, investigate the platform.

This phase is deliberately early because **the content-blocking requirement may constrain the entire technology stack**.

## Questions to answer

### Browser engine

- Which mobile platform(s) are supported?

- Which WebView/browser engine is available?

- Can requests be intercepted?

- Can navigation be intercepted?

- Can JavaScript be injected?

- Can cosmetic filtering be implemented?

- Can scriptlets be supported?

- What restrictions exist?

### Ad-blocking engines

Evaluate existing implementations based on:

| Criterion | Requirement |
| --- | --- |
| Filter-list compatibility | High |
| EasyList support | Required if feasible |
| EasyPrivacy support | Desired |
| Network filtering | Required |
| Cosmetic filtering | Strongly preferred |
| Scriptlets | Preferred |
| Mobile compatibility | Required |
| License | Must be compatible |
| Performance | Must be acceptable |
| Maintenance | Actively maintained preferred |

**Deliverable:** a short technology decision document explaining the selected browser stack and filtering engine.

---

# 9. Development Phases

## Phase 0 — Technical Feasibility

**Goal:** prove that the core technology is viable.

Tasks:

- Select target mobile platform.

- Investigate available WebView/browser APIs.

- Investigate existing ad-blocking engines.

- Prototype WebView integration.

- Prototype request filtering.

- Load a real filter list.

- Test blocking against representative websites.

- Investigate video detection.

- Document platform limitations.

### Exit criteria

The prototype can:

```text
Open website
     ↓
Load filter rules
     ↓
Block representative unwanted requests
     ↓
Load a real video
     ↓
Identify the video
```

Do **not** build the complete application before this milestone succeeds.

---

# 10. Phase 1 — Browser Foundation

Build the minimal usable browser.

### Tasks

- Application shell.

- Navigation UI.

- WebView integration.

- URL handling.

- Back/forward.

- Reload.

- Loading/error states.

- Basic settings.

- Share URL into application.

### Exit criteria

A user can open arbitrary websites and navigate normally.

---

# 11. Phase 2 — Content Blocking

Build the complete blocking subsystem.

### Tasks

- Integrate selected filtering engine.

- Filter-list loading.

- Filter-list storage.

- Filter-list updates.

- Request filtering.

- Cosmetic filtering if supported.

- Custom rules.

- Allowlist.

- Per-site controls.

- Blocking statistics.

- Failure handling.

### Exit criteria

The browser provides meaningful real-world content blocking without breaking ordinary browsing.

---

# 12. Phase 3 — Video Detection

Introduce the video-first functionality.

### Tasks

- Detect HTML video elements.

- Identify active/primary video.

- Detect video metadata.

- Determine playback state.

- Detect duration/current position.

- Build video abstraction independent of individual websites.

- Handle pages containing multiple videos.

### Exit criteria

The application can reliably identify the video the user is interacting with on representative sites.

---

# 13. Phase 4 — Dedicated Video Experience

Build the actual watching experience.

### Tasks

- Video mode.

- Fullscreen.

- Landscape orientation.

- Custom mobile controls.

- Gesture controls.

- Picture-in-picture.

- Playback state.

- Navigation locking.

- Return-to-browser behavior.

### Exit criteria

Watching a video feels substantially different from simply viewing a webpage containing a video.

---

# 14. Phase 5 — Watching State

Implement persistence.

### Tasks

- History.

- Continue Watching.

- Watch Later.

- Playback position.

- Queue.

- Session restoration.

- Thumbnail/title metadata.

- Automatic cleanup rules.

### Exit criteria

A user can leave the application and later resume their previous watching session.

---

# 15. Phase 6 — Library & Discovery

Create the user's persistent video library.

Potential structure:

```text
Library

├── Continue Watching
├── Watch Later
├── History
└── Queue
```

Tasks:

- Library UI.

- Sorting.

- Filtering.

- Remove items.

- Clear history.

- Queue management.

- Search within saved content.

---

# 16. Phase 7 — UX & Polish

Only after the core functionality is stable.

### Tasks

- Onboarding.

- First-run experience.

- Animations.

- Loading states.

- Error states.

- Empty states.

- Accessibility.

- Touch targets.

- Dark/light themes.

- Performance optimization.

- Battery/memory investigation.

- UX consistency.

---

# 17. Phase 8 — Testing

Testing should cover the individual subsystems as well as real websites.

### Unit tests

Test:

- Watching-state calculations.

- Playback-position handling.

- History management.

- Queue management.

- Custom filter rules.

- Allowlist logic.

- Filter-list parsing/integration boundaries.

### Integration tests

Test:

- Browser ↔ blocker.

- Browser ↔ video detector.

- Video ↔ watching state.

- Watching state ↔ persistence.

- Share intent ↔ browser.

### Real-world compatibility tests

Maintain a small test corpus of representative websites:

```text
Static website
Video website
News website
Ad-heavy website
Multiple-video website
SPA
Site requiring JavaScript
Site with embedded video
```

The exact sites should be selected during implementation and tested regularly.

---

# 18. Performance Requirements

The blocker and browser must not introduce unreasonable overhead.

Measure:

- Startup time.

- Page load overhead.

- Memory usage.

- CPU usage.

- Battery impact.

- Filter-list update time.

- Filter matching performance.

- Video playback performance.

The application should avoid repeatedly parsing or rebuilding filter data unnecessarily.

---

# 19. Security & Privacy

Because the application processes arbitrary websites, security is important.

Requirements:

- Minimize privileged native functionality.

- Treat webpage content as untrusted.

- Avoid unnecessary JavaScript bridges.

- Validate native ↔ web messages.

- Secure persistent data.

- Avoid collecting browsing history remotely.

- Avoid unnecessary analytics.

- Clearly document what data leaves the device.

---

# 20. Non-Goals

To prevent scope creep, the first version should **not** attempt to become a complete browser replacement.

Explicit non-goals:

- Desktop browser.

- Browser extensions ecosystem.

- Full bookmark management comparable to major browsers.

- Browser synchronization.

- Built-in search engine.

- Social network.

- Video downloading.

- Website-specific scraping implementations for dozens of platforms.

- Custom ad-blocking engine.

The application should work with websites through **general browser/video mechanisms**, rather than becoming a collection of site-specific hacks.

---

# 21. Initial MVP

The first genuinely useful version should be much smaller:

```text
┌───────────────────────────────┐
│          MVP                  │
├───────────────────────────────┤
│ ✓ Mobile WebView              │
│ ✓ Basic navigation            │
│ ✓ Real ad/content blocking    │
│ ✓ Filter lists                │
│ ✓ Allowlist                   │
│ ✓ Video detection             │
│ ✓ Dedicated video mode        │
│ ✓ Fullscreen                  │
│ ✓ Playback position           │
│ ✓ Continue Watching           │
│ ✓ Basic history               │
│ ✓ Share URL into app          │
└───────────────────────────────┘
```

Everything else can follow once this works reliably.

---

# 22. Definition of Done

The project should not be considered successful merely because the UI works.

The MVP is complete when a user can:

 1. Open the application.

 2. Navigate to a normal website.

 3. Browse without being overwhelmed by unwanted web content.

 4. Find a video.

 5. Enter the dedicated video experience.

 6. Watch it comfortably in fullscreen.

 7. Leave the application.

 8. Return later.

 9. Resume the video from approximately where they stopped.

10. Continue browsing or watching additional content.

And critically:

> **The content blocker must use a real, established filtering implementation and demonstrate meaningful blocking against real-world websites.**

That last requirement is what keeps this from turning into "a WebView with a video player and a few hardcoded ad URLs."