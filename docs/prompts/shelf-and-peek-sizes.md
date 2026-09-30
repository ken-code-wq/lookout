# Prompt: Shelf (new pillar) + Agent Peek sizing and 5-hour session readout

Paste everything below into a coding agent working directly in the `local-observer` repo (Swift Package
Manager, macOS 14.2+, SwiftUI/AppKit, no Xcode project). It assumes the agent can read the existing
source tree; it does not restate code that's already there, only what to add or change.

---

## Context you must respect

This is **Lookout** (bundle id and folders still say `dev.localobserver.app` / `LocalObserver` on
purpose; see `Sources/LocalObserver/LocalObserverApp.swift` and `PRODUCT.md` — don't rename those).
It's a native macOS **product**-register app (see `PRODUCT.md`): calm, exact, trustworthy, Notion-like
interaction patterns, no invented metrics, no decorative charts. Read `PRODUCT.md` before writing any UI.

The app today has two pillars, built independently of each other:
1. **Servers** (`Sources/LocalObserver/Core/Scanner.swift`, `ProcessManager.swift`, `Views/ServersPage.swift`)
   — discovers and manages locally running dev servers.
2. **Agents** (`Sources/LocalObserverCore/Agent*.swift`, `Sources/LocalObserver/Views/Agent*.swift`)
   — discovers coding-agent sessions (Claude Code, Codex, etc.), their token usage, and their plan limits.

Both surface through shared chrome: the **notch** (`Sources/LocalObserver/Core/NotchController.swift`,
`Views/NotchView.swift`), the **menu bar** (`Views/MenuBarView.swift`), the floating **Agent Peek** panel
(`Views/AgentPeekView.swift`, opened by `LiveSurfaces.swift`), and **desktop widgets**
(`Sources/LocalObserverWidgetUI/`, `Sources/LocalObserverWidgets/`).

You are asked to do two things in this pass:

- **Part A** — build **Shelf**, a brand-new third pillar. It must not read from, depend on, or import
  `AppState`, `AgentStore`, `ServerEntry`, or anything server/agent-specific. It stands on its own, the
  same way Agents didn't need Servers.
- **Part B** — improve **Agent Peek**: add a 5-hour session countdown, and make the panel switch between
  three fixed size modes (Large / Medium / Small) instead of always rendering at its current full size.

Do both in the same branch, as separate, cleanly separable commits. Do not let Part A and Part B code
touch each other.

---

## Part A — Shelf: a drop zone and clipboard history in the notch

### What it is

A place to park things while you move between apps and windows, and a searchable history of everything
you've copied. It lives in the notch (a new tab), the menu bar, and a desktop widget — never inside the
Servers/Agents window, and it works with zero servers or agents running.

### Data model (new target: `Sources/LocalObserverShelf/`, or a `Shelf` subfolder of `LocalObserverCore`
if you decide the types are generic enough to share — your call, but keep it dependency-free of
Agent/Server types either way)

```swift
public struct ShelfItem: Identifiable, Codable, Hashable {
    public enum Kind: String, Codable { case text, link, image, file, color }
    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    public var pinned: Bool
    public var sourceApp: String?        // bundle id of the app it was copied/dropped from, for context only
    // Payload, one of:
    public var text: String?             // .text, .link (the URL string)
    public var filePath: String?         // .file, .image: where the sandboxed copy lives on disk
    public var thumbnailPath: String?    // .image, .file: small PNG preview, generated once
    public var colorHex: String?         // .color
}
```

Two independent stores, both append-only with pruning, both **local-only, never networked**:

1. **Drop shelf** — items the user explicitly dragged in. Persisted indefinitely until removed by hand
   or by "Clear shelf". Cap at 200 items; oldest unpinned items drop off past that.
2. **Clipboard history** — everything captured from `NSPasteboard.general`. Cap at 500 items (configurable
   in Settings, default 500) or 30 days, whichever comes first for unpinned items. Pinned items are exempt
   from both caps.

Store metadata as JSON at `~/Library/Application Support/LocalObserver/Shelf/history.json` (same
directory family as the existing usage ledger — see `AgentStore`'s `Ledger` struct for the pattern: a
versioned wrapper struct, atomic writes, load-tolerant decode). Store any binary payloads (images, files)
as their own files under `~/Library/Application Support/LocalObserver/Shelf/blobs/<uuid>.<ext>`, referenced
by path from `ShelfItem`. Never put large binary data inside the JSON.

### Clipboard capture

macOS has no clipboard-changed notification. Poll `NSPasteboard.general.changeCount` on a
`Timer` every 300–500ms (only while the app is active or the notch/menu bar is open — don't poll forever
in the background if nothing is watching; use the same “start/stop cheaply” instinct as
`AppAudio.shared.start()`/`stopAll()`). On a change:

- Read the pasteboard's types. Classify: `public.url`/`NSURL` → `.link`; `public.utf8-plain-text` → `.text`;
  `public.tiff-image`/`public.png` → `.image`; `NSFilenamesPboardType`/file URLs → `.file`; a single color
  written by system color pickers → `.color`.
- **Skip capture entirely** when the pasteboard declares
  `org.nspasteboard.ConcealedType`, `org.nspasteboard.AutoGeneratedType`, or
  `org.nspasteboard.TransientType` (the informal but widely-respected convention password managers,
  including 1Password and the macOS Keychain, use to mark sensitive copies — this is the actual mechanism,
  not a guess). Also skip when the pasteboard has zero items or the content is identical to the
  most-recently-captured item (avoid duplicate spam from apps that rewrite the pasteboard repeatedly).
- Resolve `sourceApp` via `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` at capture time.
- For images: downscale to a thumbnail the same way `IconStore.thumbnail(_:side:)` does in
  `Sources/LocalObserver/Core/IconStore.swift` (reuse that pattern, don't reinvent it), store the full
  image too if it's under a size cap (e.g. 8 MB; otherwise store only the thumbnail and mark degraded).

Add a Settings toggle to pause capture entirely ("Pause clipboard history") and a menu item to clear all
non-pinned history. Never capture while an app the user has explicitly excluded is frontmost (build a
simple exclusion list in Settings, empty by default).

### Drop shelf (drag in / drag out)

The notch panel and the menu bar panel should register as drag destinations
(`NSView.registerForDraggedTypes` on the hosting view, or `.onDrop(of:isTargeted:perform:)` in SwiftUI,
whichever fits the existing panel construction better — `AgentPeekView`/`LiveSurfaces.showPeek()` already
hosts SwiftUI in an `NSPanel`, follow that construction). Accept `NSItemProvider` for files, images,
strings, and URLs. On drop:

- Copy dropped files into `Shelf/blobs/` (don't just reference the original path — the user may delete
  or move the source right after dropping).
- Generate a thumbnail for images the same way as clipboard image capture.
- Insert as a new `ShelfItem`, unpinned, at the top.

To drag an item **back out** into another app, wrap each item's row/tile in `.draggable(_:)` (SwiftUI,
macOS 14+) or fall back to `NSItemProvider` + `NSDraggingSession` if you need file-promise semantics. Text
and links drag as their string/URL; files and images drag as file URLs into the destination.

### UI surfaces

1. **Notch tab.** Add `case shelf` to `NotchTab` in `Sources/LocalObserver/Core/Preferences.swift`
   (alongside `agents, usage, limits, servers, media, sound`), give it a title ("Shelf") and SF Symbol
   (`tray.full` or similar), and add a `shelfTab` case to the `switch` in `NotchView.swift` next to
   `.agents`/`.servers`/etc. The shelf tab must render even when `agentStore` and `state` have nothing —
   don't gate its visibility on `!sessions.isEmpty` or `!state.visibleServers.isEmpty` the way
   `NotchView.swift:174` and `:178` gate the agents/servers tabs. It should show:
   - A grid of recent drop-shelf items (thumbnail + kind icon + relative time), pinned items first.
   - Below or in a segmented sub-view, a searchable clipboard history list (text preview truncated to
     ~2 lines, image thumbnail, link with favicon-less domain text). Reuse `AgentFormat.ago(_:)` for
     relative timestamps — it's already `public` in `LocalObserverCore`.
   - A search field filtering both by substring match on `text`/`filePath` basename.
   - Row actions: pin/unpin, copy (writes back to `NSPasteboard.general`), reveal in Finder (files),
     delete. Follow the row-action affordance style already used in `PeekRow`/`ServerRow`-type views
     (hover-revealed icon buttons, not always-visible clutter).
2. **Menu bar.** Add a "Shelf" section to `MenuBarView.swift` mirroring how Agents/Servers sections work
   there today — recent items, a "Clear shelf" action, an "Open Shelf" action that expands the notch to
   the shelf tab (`NotchController.shared` — check how `.agentActivity` etc. currently open the main window
   from the menu bar for the pattern to copy).
3. **Global hotkey.** Add `case shelf` to `HotKeyAction` in `Sources/LocalObserver/Core/GlobalHotKey.swift`
   with a sensible default (e.g. `⌃⌥⌘V` for "paste from history", since V is mnemonic and unused) and wire
   it the same way `.peek`, `.menuBar`, `.notch` are wired in `LiveSurfaces.swift` and
   `LocalObserverApp.swift`'s `CommandMenu`.
4. **Desktop widget.** Add `ShelfWidgetView` to `Sources/LocalObserverWidgetUI/` (small: pinned-item
   count + most recent thumbnail; medium: a small grid of recent items; Shelf doesn't need a large size
   unless you think it earns one) and a `ShelfWidget` to `Sources/LocalObserverWidgets/WidgetsBundle.swift`,
   following the exact pattern `AgentsWidget`/`ServersWidget` already use (`StaticConfiguration`,
   `WidgetFrame`, `SnapshotProvider`-style timeline). Shelf's widget needs its **own** snapshot file
   (e.g. `~/Library/Application Support/LocalObserver/Shelf/widget-snapshot.json`) written by the main app
   whenever the shelf changes — do not add shelf fields to the existing `WidgetSnapshot` in
   `Sources/LocalObserverCore/WidgetSnapshot.swift`; that type is agent/server data and must stay that way
   so the two pillars stay decoupled. Clicking the widget opens the notch or main window to the shelf
   (reuse the `localobserver://` URL scheme pattern from `WidgetTheme.swift`'s `WidgetLink` — add
   `WidgetLink.shelf`).
5. **Settings page.** Add a "Shelf" settings page next to Agents/Limits/Menu Bar in
   `Sources/LocalObserver/Views/AgentSettingsView.swift`'s pattern (or its own `ShelfSettingsView.swift` if
   that file is getting large — check its current line count first) with: pause capture, history size cap,
   excluded-apps list, clear history button, clear shelf button.

### Privacy, correctness, non-negotiables

- Never capture or persist clipboard content flagged concealed/transient (see above). This is not
  optional — password managers rely on every well-behaved clipboard tool honoring this.
- Never upload anything anywhere. Everything stays under `~/Library/Application Support/LocalObserver/Shelf/`.
- Handle the empty state everywhere (empty notch tab, empty widget, empty menu bar section) with the same
  quiet, instructive tone `WidgetEmpty` uses in `WidgetComponents.swift` ("Nothing here yet" + one line
  of what will appear, not "No data").
- Respect `prefers-reduced-motion`-equivalent: if `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
  is true, skip any insert/remove animation flourish.

### Acceptance criteria for Part A

- Quitting the app and relaunching preserves shelf items and clipboard history (minus anything pruned).
- Dragging a file onto the notch's shelf tab while the app has zero servers and zero agent sessions
  configured works end to end (add a note in your PR description confirming you tested this with
  `agentStore.settings.enabledAgents` empty and no servers running).
- Copying a password from a password manager that marks its pasteboard write as concealed does not
  appear in history. Confirm by checking the pasteboard flags in code, not by trusting the source app.
- The Shelf notch tab, widget, and menu bar section compile and run with `LocalObserverCore`'s
  `Agent*`/`Server*` types entirely unimported from your new Shelf files (a `grep -l "AgentStore\|ServerEntry"`
  across your new files should return nothing).

---

## Part B — Agent Peek: 5-hour session readout + three size modes

File: `Sources/LocalObserver/Views/AgentPeekView.swift` (plus `Preferences.swift` for the new persisted
setting, and `LiveSurfaces.swift` for panel sizing).

### B1 — Show 5-hour session time remaining

Right now, Peek's limit tiles (`LimitTile`, near the bottom of `AgentPeekView.swift`) show a percentage,
a pace chip (`+12%`, `On pace`, `Used up`, from `PaceDeviation.chip`), and a caption that *sometimes*
mentions time-to-reset buried inside pace-dependent phrasing (`PaceDeviation.caption` in
`Sources/LocalObserver/Views/AgentComponents.swift`) — but there's no direct, always-visible "how much
time is left in this window" readout, which is the number the user actually watches.

Add it:

- For every quota window whose `kind == .session` (see `AgentLimitKind` in
  `Sources/LocalObserverCore/AgentModels.swift` — Claude's 5-hour window and Codex's 5-hour window both
  use `.session`; don't hardcode `.claude`), compute remaining time as
  `window.resetsAt.map { max(0, $0.timeIntervalSince(now)) }` and format it with
  `AgentFormat.duration(_:)` (already `public` in `LocalObserverCore`) — e.g. "2h 14m left".
- Surface this as a **new line inside `LimitTile`**, always shown (not conditional on pace state), placed
  between the percentage ring and the existing pace chip/caption stack. Something like:
  `Text("\(AgentFormat.duration(remaining)) left")` in a quiet, secondary weight — this is the headline
  fact, the pace chip is secondary color-coded context, don't let the new text fight it for attention.
  If `kind != .session` for a given tile, don't show this line at all (weekly/monthly windows already
  communicate their reset via the existing caption; this addition is specifically for the short session
  window people watch minute-to-minute).
- Do **not** touch `PaceDeviation` or `LimitTile`'s existing chip/caption logic — add the new line
  alongside it, so nothing else in the app that reuses `PaceDeviation` (the widgets, `NotchLimitsView.swift`)
  is affected.
- Use a `TimelineView(.periodic(from: .now, by: 60))` exactly like `LimitTile` already does, so the
  countdown ticks down without a manual refresh (it already re-renders every minute — hook into that,
  don't add a second timer).

### B2 — Three size modes: Large / Medium / Small

Today `AgentPeekView` always renders at a fixed `.frame(width: 320)` with every section, every row, full
detail — regardless of how many sessions or windows there are, it can grow tall enough to cover a good
part of the screen, and the user is manually dragging it around to get it out of the way. Fix this by
giving it three fixed-content size modes the user picks explicitly (this is not live edge-dragging — it's
the same "discrete modes" pattern the app already uses for `NotchController.Mode`
(`compact`/`alert`/`hud`/`expanded`) and for `NotchLimitsPage.layout(for:)`'s column-count switch. Follow
that idiom, don't invent free-form window resizing.

1. **Add the setting.**
   ```swift
   enum PeekSize: String, CaseIterable, Identifiable, Codable {
       case large, medium, small
       var id: String { rawValue }
       var title: String {
           switch self { case .large: "Large"; case .medium: "Medium"; case .small: "Small" }
       }
       var width: CGFloat {
           switch self { case .large: 320; case .medium: 260; case .small: 200 }
       }
   }
   ```
   Add this next to `PeekTodayMetric` in `Preferences.swift`'s peek section, with a persisted
   `@Published var peekSize: PeekSize` (default `.large`, so existing users see no change until they
   opt in), following the exact `didSet { defaults.set(...) }` / `Keys.peekSize` / load-in-`init`
   pattern every other `peek*` preference already uses in that file.

2. **Let the user switch modes.** Add a compact three-way control to the Peek header (next to the
   existing filter menu / refresh / close buttons in the `header` computed property) — a segmented
   control or three small glass buttons (L / M / S, or a cycling single button if you think three
   separate glyphs would crowd the 320pt-wide header at Large — your call, but it must be reachable
   without opening a menu, since this is meant to fix "I keep manually resizing it" friction). Also
   add the same three options to the existing `filterMenu`'s `Menu { }` content as a `Picker`, for
   discoverability, the same way `Picker("Today shows", ...)` is already there.

3. **What changes per mode.** This must actually look like a smaller widget at Small, not just a
   narrower version of Large with everything squeezed in — go re-read
   `Sources/LocalObserverWidgetUI/AgentsWidgetView.swift` and `LimitsWidgetView.swift` right before
   doing this: match that level of restraint and information density at Small.

   | | **Large** (current) | **Medium** | **Small** |
   |---|---|---|---|
   | Width | 320 | 260 | 200 |
   | Header | Today-metric capsule + filter menu + refresh + close | Today-metric capsule (value only, no unit word) + refresh + close (drop the filter menu into a right-click/long-press context menu instead) | App-style compact header: just the size-mode control + close; drop the today-metric capsule entirely |
   | Agent rows | Full `PeekRow`: icon + host-app overlay, title, project + live duration, state pill with pulsing dot | Same `PeekRow` layout but drop the host-app icon overlay and shrink the state pill to icon-only (no text label) | One compact row per session: small agent icon, project name only (no title, no duration), a single state-colored dot (no pill, no icon) — this should look like `AgentsWidgetView`'s `CompactSessionRow`, not a shrunk `PeekRow` |
   | Row count shown | up to 6 (`sessions.prefix(6)`) | up to 4 | up to 3, with a "+N more" text row instead of scrolling |
   | Limits section | Full `LimitTile` grid (ring + chip + caption + new session-remaining line) | `LimitTile` but drop the caption line, keep ring + chip + session-remaining line | One line per shown window: small ring or just a percentage number, agent short name, session-remaining time only — no chip, no caption, no advice tooltip needed since there's no room to read it anyway |
   | Section headers (collapsible "Agents"/"Limits" labels) | shown | shown | hidden — Small has no room for chrome, sections are just visually grouped by spacing |
   | Hidden-providers note | shown | shown | hidden (still functional via the context menu, just not displayed) |

   Implement this as one `AgentPeekView` that reads `prefs.peekSize` and branches internally (small
   `if prefs.peekSize == .small { ... } else { ... }` blocks per section, or three small subviews per
   section if that reads cleaner) — do not fork into three separate top-level view files. Keep
   `PeekRow`/`LimitTile` as the Large/Medium implementations and add new, genuinely minimal
   `CompactPeekRow`/`CompactLimitLine`-style views for Small rather than adding a size parameter that
   makes the existing ones sprout conditionals for every property.

4. **Panel resizing.** `LiveSurfaces.showPeek()` already hosts the SwiftUI view in an `NSPanel` with
   `host.sizingOptions = [.preferredContentSize]`, and `windowDidResize` already keeps the panel's **top**
   edge anchored while height changes (see the `panelTop` handling around line 269–278 of
   `LiveSurfaces.swift`) — that logic already does the right thing for height changes from switching modes;
   confirm width changes anchor sensibly too (decide whether the panel should keep its **top-left** or
   top-right corner fixed when width shrinks — given it's usually placed near a screen edge via
   `setFrameTopLeftPoint` at first launch, anchoring top-left, i.e. letting the right edge move inward, is
   almost certainly correct; verify this visually before deciding otherwise). Animate the width/height
   transition with the same `.spring(response: 0.35, dampingFraction: 0.85)` already used elsewhere in this
   file for consistency.

5. **Persistence sanity.** `peekSize` should survive relaunch like every other `peek*` preference. Don't
   let switching modes reset `peekHiddenAgents`, `peekTodayMetric`, `collapsedPeekGroups`, or
   `peekClearGlass` — those stay independent of size.

### Acceptance criteria for Part B

- With 5+ running sessions and 3+ limit windows, Small mode fits comfortably without scrolling for a
  typical case (document in your PR what "typical" you tested — e.g. 3 sessions, 2 providers).
- The session-remaining line appears for Claude's and Codex's 5-hour windows and does **not** appear for
  weekly/monthly windows, at every size.
- Switching size mode mid-session doesn't drop or reorder `peekHiddenAgents`/`peekTodayMetric` state.
- `swift build` succeeds; run the existing debug snapshot harness
  (`LOCAL_OBSERVER_SNAPSHOT_DIR=/tmp/shots .build/debug/LocalObserver`, see
  `Sources/LocalObserver/Debug/SnapshotHarness.swift` — it already renders a `"peek"` page) and extend it
  to render all three Peek sizes in both light and dark, so the result can be reviewed as images before
  calling this done.

---

## General instructions for both parts

- Match existing code style exactly: doc comments (`///`) explaining *why*, not what; `N`/`NFont` tokens
  from `Sources/LocalObserver/Views/Theme.swift` for any new app-side (non-widget) UI; `WTheme`/`WFont`
  from `Sources/LocalObserverWidgetUI/WidgetTheme.swift` for widget UI. No em dashes in UI copy or comments
  — use commas or periods. No new third-party dependencies.
- Keep `Package.swift` targets clean: if Shelf becomes its own SwiftPM target, wire it exactly the way
  `LocalObserverWidgetUI` was added (a `.target` with a `path:`, listed as a dependency of `LocalObserver`
  and, if it has its own widget, of `LocalObserverWidgets` too).
- Run `swift build` (debug) after each part and fix all warnings you introduce, not just errors.
- Do not modify `AgentStore`, `AppState`, `ServerEntry`, or any file under `Sources/LocalObserverCore/Agent*`
  or `Sources/LocalObserver/Core/Scanner.swift`/`ProcessManager.swift` for Part A. If you find yourself
  needing to, stop and reconsider the design — Shelf must not need them.
- End with a short summary per part: files added, files changed, and how you verified each acceptance
  criterion (screenshots from the snapshot harness for anything visual).
