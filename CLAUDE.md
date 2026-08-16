# Amgi — Project Instructions — Project Instructions

## Memory System

At the start of every session, read these files to understand context:
- `memory/user.md` — Who the user is, their experience and Swift preferences
- `memory/preferences.md` — Code style, architecture patterns, tools & build setup
- `memory/decisions.md` — Key architectural decisions and their rationale
- `memory/people.md` — People involved and key repositories

Update these files when you learn new information during the session.

## Project Overview

Amgi is an offline-first, Anki-compatible iOS flashcard client with sync-server
support, plus an EPUB reader with offline dictionary lookup. The Anki engine is
the upstream Rust crate (`anki-upstream/`, AGPL-3.0) compiled into an XCFramework
and called from Swift via C FFI + protobuf.

## Architecture (zoomed out)

```
AmgiApp (iOS app target — AmgiApp/, xcodegen → AmgiApp.xcodeproj)
  ├─ depends on → AnkiBridge  package (this repo's root Package.swift)
  ├─ depends on → AmgiReader  (sibling SPM, ./AmgiReader; vendors EPUBKit)
  ├─ depends on → AmgiUI      (sibling SPM, ./AmgiUI)
  └─ depends on → AmgiFeatures (sibling SPM, ./AmgiFeatures)

AmgiFeatures package — app-layer shared code + migrated features
  Sinks:     AmgiAppShared → AmgiAppCore        AmgiCharts (watchOS-clean)
             AmgiReviewCore → AmgiAppCore       (watchOS-clean; watch links it)
  Features:  StatsFeature → AmgiCharts          TemplatesFeature
             BrowseFeature → AmgiAppShared      SyncFeature → AmgiAppShared
             ReaderFeature → BrowseFeature, AmgiAppShared
             ReviewFeature → BrowseFeature, TemplatesFeature,
                             AmgiReviewCore, AmgiAppShared
             DecksFeature  → ReviewFeature, BrowseFeature, AmgiAppShared
             WidgetFeature → AmgiAppCore        (the iOS widget extension)
  Everything else reaches sideways into AmgiUI/AmgiTheme/AnkiKit/AnkiClients.

  **Cxx chain.** ReaderFeature declares `.interoperabilityMode(.Cxx)`, and so
  does the app target. Only ReaderFeature actually touches C++
  (AmgiReaderDictionary → hoshidicts); the app inherits it because Cxx interop
  is transitive through the module graph — a target that imports a Cxx-mode
  module gets the CHoshiDicts modulemap in its own Clang dependency scan and
  fails with "module 'CHoshiDicts' requires feature 'cplusplus'" without the
  setting. Every target in the chain drops out of explicit modules and
  compilation caching (rdar://122829880).

  ReviewFeature and DecksFeature *used* to be in it, purely transitively, via
  one edge: ReviewFeature importing ReaderFeature for `LookupPopupView`.
  Inverted 2026-08-15 — the app root injects the popup through
  `EnvironmentValues.lookupPopup` (AmgiAppShared), so ReviewView renders it
  without knowing what it is. **Measured, paired, own cold DerivedData per arm,
  3 runs each:** cached clean (wipe DerivedData, warm CAS — the branch-switch
  case) went 110.0s → 80.5s, **−26.9%**, with non-overlapping ranges (worst
  arm-B run beat best arm-A run, 3/3). `xcodebuild clean` + build went 23.2s →
  22.0s (−5.0%). Single-file incremental did **not** move (11.3s → 10.9s,
  noise) — caching pays on full-module rebuilds, not the edit loop. Don't
  quote the incremental number as the win.

  Any new feature that imports ReaderFeature joins the chain — and anything
  importing Review or Decks no longer does. Keep it that way: reach for an
  injection point in a sink over an import of a Cxx-mode module.

  AmgiWidget links WidgetFeature only, which brings AmgiAppCore + AmgiTheme
  and must never reach AnkiClients. That, by itself, is why the sink is two
  targets rather than one.
  AmgiWatchApp links AmgiAppCore + AmgiCharts *and* the full engine
  (AnkiClients, AnkiServices, AnkiBackend, AnkiSync, AmgiCardWeb), so the
  no-AnkiClients rule does not apply to it. It cannot link AmgiAppShared for
  a different reason: AmgiAppShared imports UIKit and WidgetKit unguarded, so
  it does not build for watchOS.
  (Corrected 2026-08-15. This block previously claimed neither extension
  reaches AnkiClients, which was never true of the watch — verify against
  AmgiApp/project.yml, not this note.)

AnkiBridge package — Anki engine surface
  SwiftUI feature code (AmgiFeatures/Sources/*Feature, AmgiApp/Sources/Settings)
    ↓ @Dependency(\.xxxClient)
  AnkiClients          ─ thin @DependencyClient structs, live values
    ↓
  AnkiServices         ─ high-level facades (Decks, Scheduler, Sync, Stats…)
    ↓ backend.invoke(.factory(...))
  AnkiProtoBridge      ─ typed Request<R> factories, ServiceID/*Method enums,
                          protobuf ↔ Swift-mirror conversions
    ↓
  AnkiBackend          ─ Swift class wrapping the 4 C FFI symbols
    ↓ C FFI: anki_open_backend / anki_run_method /
              anki_free_response / anki_close_backend
  AnkiRustLib (binaryTarget) = AnkiRust.xcframework
    ↑ produced by ./scripts/build-xcframework.sh
  anki-bridge-rs/      ─ Rust crate exposing the C ABI; links anki-upstream
  anki-upstream/       ─ ankitects/anki rslib (vendored, AGPL-3.0)
```

**Rust owns**: SQLite collection DB, sync protocol, FSRS scheduling, card
template rendering, search, import/export.
**Swift owns**: SwiftUI views, navigation, charts, keychain, EPUB reader,
dictionary UI, widgets.

## Module Map

### `AnkiBridge` package (./Package.swift, root)
| Module | Purpose |
|---|---|
| `AnkiKit` | Pure Swift domain types (Rating, FSRSState, DeckInfo, …). No deps. |
| `AnkiProto` | Generated SwiftProtobuf types from 24 .proto files. **Package-internal** — only `AnkiBackend` and `AnkiProtoBridge` may import it. |
| `AnkiBackend` | Swift class wrapping the Rust C FFI; owns the backend pointer, dispatches `Request<R>`, decodes responses. Carries the `RPCObserver` hook. |
| `AnkiProtoBridge` | The sole sanctioned bridge between protobufs and Swift mirrors. Exposes `Request<R>` factories (`.deckNames`, `.getDeckTree`, …), `ServiceCatalog`, and `*Method` typed dispatch wrappers. Conversions live in `Sources/AnkiProtoBridge/Conversions/`. |
| `AnkiServices` | High-level service facades (`DecksService`, `SchedulerService`, `SyncService`, `StatsService`, `NotesService`, `NotetypesService`, `CardRenderingService`, `ImportExportService`, `CollectionService`). |
| `AnkiClients` | `@DependencyClient` structs + `liveValue` implementations. The UI's preferred entry point into the Anki engine; where no client wrapper exists, feature code may use an `AnkiServices` facade directly (sanctioned second tier — don't add thin pass-through clients just to avoid it). Direct `AnkiBackend` use is reserved for the composition root and low-level asset/config plumbing. |
| `AnkiSync` | KeychainHelper for sync credentials. |
| `AmgiCardWeb` | WebKit-based card renderer host. |
| `AnkiRustLib` | `binaryTarget` pointing at `AnkiRust.xcframework`. iOS-only. |

### Sibling SPM packages (path-resolved)
| Package / Module | Purpose |
|---|---|
| `AmgiReader` (./AmgiReader) | Pure-Swift reader domain types — no EPUB/Cxx deps. |
| `AmgiReaderDictionary` (./AmgiReader) | Cxx-mode wrapper around `hoshidicts` (Yomitan-compatible offline dictionary). Isolated so importing `AmgiReader` stays Cxx-free. |
| `AmgiReaderEPUB` (./AmgiReader) | EPUB parsing built on the vendored EPUBKit. |
| `AmgiTheme` (./AmgiUI) | Palette data, theme tokens, resources. Themes are **data, not enum-bound code** (see memory). |
| `AmgiUI` (./AmgiUI) | Shared SwiftUI components built on `AmgiTheme`. |
| `EPUBKit` (./Libraries/EPUBKit) | Vendored MIT-licensed EPUB parser; consumed only by `AmgiReaderEPUB`. |
| `AmgiAppCore` (./AmgiFeatures) | The engine-free sink: preferences (`ReviewPreferences`, `ReaderPreferences`, `SyncPreferences`), `AccountStore`, app-group keys, `WidgetSnapshot(+Store)`, `StreakCalculator`, `CardFlag`. Deps: `AnkiKit`, `Sharing`. **Must never gain an `AnkiClients` dependency** — the widget and watch extensions link it, and that edge would drag the Rust engine into both. |
| `AmgiAppShared` (./AmgiFeatures) | The engine-touching half of the sink, iOS-only: `CollectionStore`, `ImportHelper`, `ShareSheet`, `CardContextMenu(+Model)`, `writeWidgetSnapshot()`. Exists so `AmgiAppCore` can stay engine-free. |
| `AmgiCharts` (./AmgiFeatures) | Pure chart/heatmap views over `GraphsSnapshot` + palette. No `AnkiClients` path, so its previews render without linking the xcframework. **Compiled for watchOS in its entirety** — the watch links the product, so every file here must be watchOS-clean, not just the ones the watch renders. |
| `TemplatesFeature` (./AmgiFeatures) | Card-template editor (`DeckTemplateListView`, `TemplateEditorView`, `TemplateSourceEditor`, …). Lifted out of `Decks/` to close the Decks↔Review cycle; consumed by Settings and Review. |
| `StatsFeature` (./AmgiFeatures) | Stats dashboard — `StatsDashboardView` Container / `StatsDashboardContent` + `State` enum / `StatsDashboardModel`. Deps: `AmgiCharts`, `AnkiClients`. |
| `SyncFeature` (./AmgiFeatures) | Sync flow: `SyncCoordinator` (+ its `DependencyValues.syncCoordinator` key), `SyncSheet`, `LoginSheet`, `OnboardingView`, `SyncToast(+Controller)` and the `syncToastOverlay` modifier, `AnkiMobileAttributionView`. |
| `ReaderFeature` (./AmgiFeatures) | The EPUB + Anki-note readers, the offline-dictionary lookup UI, and the Study landing screen (absorbed — it was a landing screen over Reader, not a feature). The only target that touches `AmgiReaderDictionary`, and — since the `LookupPopupView` edge was inverted on 2026-08-15 — once again the only feature in the Cxx chain. See the Cxx-chain note in the diagram above before adding an import of it. Public surface is six entry points — `ReaderLibraryView`, `StudyLandingView`, `LookupPopupView`, `ReaderDictionarySettingsView`, `ReaderFontOption`, `ReaderThemeColor`; models stay internal. Note it holds **two** readers with separate preference namespaces (`EPUBChapterReaderView`/`reader_typo_*` and `ChapterReaderView`/`reader_pref_*`), branched at `ReaderBookDetailView.swift:120`. |
| `BrowseFeature` (./AmgiFeatures) | Note browsing + note authoring: browse list/search/selection, add & edit note, batch tagging, collection-wide tag management, and the whole image-occlusion editor. Public surface is exactly five views — `BrowseView`, `AddNoteView`, `NoteEditorView`, `NoteEditingDestinationView`, `TagsView`; models stay internal. It has **no** app-folder dependencies, which is why it extracted first: Reader, Review, Decks, and Settings all reach into it, so it had to leave the app target before they can. |
| `AmgiReviewCore` (./AmgiFeatures) | The review state machine (`ReviewSession`) + `TemplateRenderOverrides`. Watch-shared: `AmgiWatchApp` links it, so it must stay watchOS-clean — no `AmgiAppShared`, no UI, guard UIKit with `#if canImport(UIKit)`. Exists because project.yml used to cherry-pick these files into the watch target by path, compiling them twice as two distinct types. Same role `AmgiCharts` plays for stats. |
| `ReviewFeature` (./AmgiFeatures) | The review screen: WebKit card host, flip chrome, rating bar, native renderer, render-mode UI. Engine logic belongs in `AmgiReviewCore`, presentation here. Public surface: `ReviewView`, `CardWebViewContentAlignment`, and the `CardRenderEngine` display helpers. Deliberately does **not** import `ReaderFeature`: it takes the dictionary popup from `EnvironmentValues.lookupPopup` instead, which is what keeps it (and Decks) out of the Cxx chain. Don't re-add the import. |
| `DecksFeature` (./AmgiFeatures) | Deck list, deck detail, deck config + FSRS simulator, profile picker. Public surface is `DeckListView` alone. `DeckListView.init` takes `onSwitchProfile` because `switchProfile(to:)` is composition-root work (closes/reopens the collection, cancels sync, flips the keychain anchor) and stays in `AmgiAppApp.swift`. No Cxx settings — it left the chain when `ReviewFeature` did, with no source change of its own. |
| `WidgetFeature` (./AmgiFeatures) | Everything the iOS widget extension does: the `AmgiWidget` `Widget`, its `AmgiWidgetIntent` AppIntents configuration + `DeckEntity` query, the `AppIntentTimelineProvider` that replays `WidgetSnapshot.projectedEntries`, and the three family views. Only `@main AmgiWidgetBundle` stays in the `AmgiWidget` target. Public surface is `AmgiWidget` alone. Deps: `AmgiAppCore`, `AmgiTheme` — **must never gain `AnkiClients`**; the widget is a separate process that reads the app group and has no business reaching the Rust engine. Extracted 2026-08-16. |

### Module naming convention
Three prefixes/suffixes, each answering a different question:
- **`Anki*`** — derived from the upstream Anki engine (`AnkiKit`, `AnkiClients`, `AnkiSync`).
- **`Amgi*`** — app-owned and *reusable*; other modules may depend on it
  (`AmgiUI`, `AmgiTheme`, `AmgiCharts`, `AmgiAppCore`, `AmgiAppShared`).
- **`*Feature`** — app-owned **screen-level** module: `BrowseFeature`,
  `SyncFeature`, `StatsFeature`, `TemplatesFeature`, `ReaderFeature`,
  `ReviewFeature`, `DecksFeature`. (No `StudyFeature` — Study was absorbed
  into `ReaderFeature`. No `SettingsFeature` planned; see extraction status.)

  `WidgetFeature` stretches "screen-level" to cover app extensions. A widget is
  not a screen inside the app, but the alternative — `AmgiWidgetUI` — claims the
  reusability the `Amgi*` prefix promises and nothing has, and sits one
  character from the `AmgiWidget` *target* name. Extensions count as
  screen-level for the suffix; `Amgi*` still means reusable.

  This used to read "**leaf** — nothing depends on it; only the app target
  imports it." That was never true (`BrowseFeature` was already imported by
  four others) and is still false: `DecksFeature → ReviewFeature →
  BrowseFeature` is a three-deep chain. Features *do* depend on features. What
  holds is the direction: nothing in `AmgiFeatures` may depend on the app
  target, and the `Amgi*` sinks never depend on a `*Feature`.
  Prefer routing shared code down into a sink (`AmgiAppCore`,
  `AmgiAppShared`, `AmgiReviewCore`, `AmgiCharts`) over adding a
  feature→feature edge — and check the Cxx-chain note before adding one that
  reaches Reader.

  The four surviving feature→feature edges (`Review → Browse`,
  `Review → Templates`, `Reader → Browse`, `Decks → Browse`) are deliberate:
  each is a sheet over another feature's editor, and none costs anything
  measurable. Only the Reader edge did, so only that one was inverted.

`Feature` is a **suffix, not a prefix** — Swift/Cocoa put the head noun last
(`UIViewController` *is a* Controller), so `SyncFeature` reads "the Sync
feature" while `FeatureSync` reads backwards. Renamed 2026-08-15.

Do **not** use `Amgi*` for a new feature module: `AmgiSync` would sit one
letter from the existing `AnkiSync`, and `Amgi`/`Anki` is already this repo's
most misread pair. The suffix keeps the app layer visually distinct.

### App target
- `AmgiApp/` — Xcode project, generated by xcodegen from `project.yml`.
- Remaining folders: `AmgiApp/Sources/{Settings,Watch}`, a `Widgets/` stub
  holding only `@main AmgiWidgetBundle.swift` + `Info.plist`, plus six root
  files (`AmgiAppApp`, `ContentView`, `MainTabView`, `DebugView`,
  `DeckImportModifier`, `RetroactiveIdentifiable`). Everything else migrated
  into `AmgiFeatures`/`AmgiUI`.
- Widget target depends on `WidgetFeature` alone (which brings `AmgiAppCore` +
  `AmgiTheme`). The old `AnkiKit` dependency was vestigial and was dropped on
  2026-08-16 — no widget source ever imported it. Keep its deps narrow.
- Direct `AnkiBackend` imports left in the app target: `AmgiAppApp` (the
  composition root, correct), `DebugView`, `Settings/MaintenanceModel`, and
  `Watch/`. No `*Feature` module imports it, and none should — a feature target
  that links `AnkiRustLib` stops rendering previews.
- `project.yml` must contain **no per-file `path:` entries under `Sources/`**.
  Cross-target file sharing goes through a product (see `AmgiReviewCore`).

### Extraction status (2026-08-15)
The app target went from ~18.7k LOC to ~4.4k in one session. Order was forced
by the coupling graph, not preference; all of it is done except Settings.

1. **`Sources/Shared` dissolved.** Neither file was shared — `DeckCountsView`
   had one consumer (the watch), the tags UI had one (Settings). Went to
   `Sources/Watch` and `BrowseFeature` respectively.
2. **`ReaderFeature`** — absorbed `Study/`. Six public entry points.
   The predicted payoff did **not** materialize: moving every
   `AmgiReaderDictionary` import out of the app target does *not* let the app
   drop its Cxx settings, because Xcode puts every package's include dir on the
   app's `-Xcc` line and the Clang dependency scanner walks
   `hoshidicts/include/module.modulemap` regardless of what any source imports.
   Both "drop all Cxx settings" and "keep all but the `OTHER_SWIFT_FLAGS` copy"
   were tried against clean builds; both fail. Do not re-litigate this.
3. **`AmgiReviewCore`** — unblocked Review by promoting the files `project.yml`
   cherry-picked into the watch by path. Only two of the three were really
   shared; `ReviewAudioSession` was dead on the watch.
4. **`ReviewFeature`**, then **`DecksFeature`** — Decks presents `ReviewView`,
   so it had to follow Review.
5. **Settings stays.** It is the aggregator — it consumes types from every
   other feature and is now a thin shell over public module APIs. Extracting it
   would buy a boundary nothing needs.
6. **`WidgetFeature`** (2026-08-16) — six of seven files out of the `AmgiWidget`
   extension target; only `@main AmgiWidgetBundle` + `Info.plist` remain.
   Note this did **not** shrink the app target: `Sources/Widgets` was already
   in `AmgiApp.sources.excludes`, so the 4.4k figure never counted it.

   Two findings recorded so they are not re-raised. The extraction was first
   pitched as "give the widget views previews" — they already had them, in the
   real `#Preview(as: .systemSmall) { AmgiWidget() }` WidgetKit form. That is
   why `AmgiWidget`, the intent, and the provider all had to move too: leaving
   any of them behind pins the other two and forces rewriting all three
   previews into a chrome-less `#Preview { SmallWidgetView(...) }`. And the
   widget's date math (`LargeWidgetView.dayLabel(_:)`, `progressFraction`,
   `chartMax`) is still untested — testing it was offered as a smaller,
   separate change (lift into `AmgiAppCore` beside `WidgetSnapshot`) and
   declined. Don't fold it in.

   **Watch was considered and declined.** No preview payoff — every watch
   screen transitively reaches `AnkiBackend`, so its previews would die on the
   way out exactly as both `DeckListView` previews did. No build-coverage
   payoff either: the sources use no watchOS-only API and would compile for
   iOS, but the iOS scheme still wouldn't build the product because nothing on
   iOS links it. Cost: a new product, watchOS-clean constraints, and eight
   allowlist keys to re-path. The real watch defect — the iOS scheme doesn't
   build `AmgiWatchApp`, so breakage is silent — is scheme wiring, not
   modularization, and is still open.

   The predicted preview payoff is **unverified**: package-target previews fail
   project-wide in this checkout with `JITError: Symbols not found:
   [_anki_open_backend, …]` while materializing `static-ReviewFeature`, and a
   control run on the untouched `AmgiUI/Library/LibraryListContent.swift` fails
   identically — so the breakage predates this extraction and says nothing about
   it either way. Re-measure before claiming the win.

**If you extract another module, budget for these four.** Every lift this
session hit at least two:
- `DesignConformanceTests` keys its allowlist by path *and* asserts no stale
  entries, so a file move fails it in both directions at once. Update
  `permanentlyExempt` in the same commit.
- `@testable import AmgiApp` tests that reach the moved types need a second
  `@testable import <NewModule>`.
- The package enables `MemberImportVisibility`; the app target does not. Files
  that borrowed a transitive `import SwiftUI`/`UniformTypeIdentifiers` from the
  app target need it spelled out once they move.
- **Scan for free functions, not just types.** A type-declaration scan said
  `Decks/` had zero inbound dependencies; it actually called `switchProfile(to:)`,
  a free function in `AmgiAppApp.swift`. Compiler caught it, the survey did not.

Also: **run `xcodebuild clean build`, not an incremental one, when verifying a
module move.** An incremental build passed on stale cached modules and produced
a wrong conclusion about the Cxx settings this session; the clean build caught
it.

Two findings that did *not* survive investigation, recorded so they are not
re-raised: the "three duplicate reader preference systems" are two separate
live readers (EPUB via `reader_typo_*`, Anki-note via `reader_pref_*`, branched
at `ReaderBookDetailView.swift:120`) — converging them is a product decision,
not a refactor; and the `AmgiTheme`/`ReaderThemeColor` hex duplication is
deliberate, per the exemption in `DesignConformanceTests.swift:28`.

## Working with the Rust Backend

The Rust engine is a black-box RPC service. You never call it directly — you go
through the four layers in order:

1. **Add / change a .proto** in `anki-upstream/proto/anki/*.proto` (rare — only
   when upstream changes or you need a method we haven't surfaced).
2. **Regenerate Swift protobuf types**: `./scripts/generate-protos.sh`.
   Output lands in `Sources/AnkiProto/` as `Anki_<Service>_<Message>` types.
3. **Add a `Request<R>` factory** in `Sources/AnkiProtoBridge/Requests/`. This
   is where service ID + method ID + request/response types get bound:
   ```swift
   public static func getDeckTree(now: Int64 = 0) -> Request<Anki_Decks_DeckTreeNode> {
       .init(
           service: .decks,
           method: DecksMethod.getDeckTree,
           payload: Anki_Decks_DeckTreeRequest.with { $0.now = now }
       )
   }
   ```
   Add the service/method ID to `ServiceCatalog.swift` if it's not already there.
4. **Expose it via a service facade** in `Sources/AnkiServices/` and (if
   user-facing) a `@DependencyClient` in `Sources/AnkiClients/`.
5. **Rebuild the XCFramework** *only* if you changed `anki-bridge-rs/` or
   `anki-upstream/`. Pure protobuf/Swift changes do **not** require a rebuild.

The four C symbols (in `anki-bridge-rs/src/lib.rs`) are stable: `anki_open_backend`,
`anki_run_method`, `anki_free_response`, `anki_close_backend`. Don't add new FFI
symbols unless absolutely necessary — prefer routing through `anki_run_method`
with a new service/method pair.

## Build & Run — MCP, not shell

All builds, previews, and tests go through an MCP server. Do NOT hand-roll
`xcodebuild` or `swift build` to verify changes — the only shell steps are the
Rust/proto scripts and `xcodegen` below.

Two servers may be connected; pick the branch by what's available this session:

### Branch A — XcodeBuildMCP connected (`mcp__XcodeBuildMCP__*`) — preferred
- Call `session_show_defaults` once, then `build_sim` / `test_sim` — this is
  the ground truth for "it builds" / "tests pass". Works headlessly (no Xcode
  window needed) and is immune to the run-destination gotcha below.
- Simulator work: `install_app_sim`, `launch_app_sim`; drive the UI with
  `snapshot_ui` → `tap`/`batch`/`type_text` (never osascript — see memory).
- IDE-only tools (need Xcode.app open) go through the bridge:
  `xcode_ide_call_tool` exposes the full built-in set — `RenderPreview`,
  `DocumentationSearch`, `GetBuildLog`, `XcodeListNavigatorIssues`, etc.
  First bridge call after Xcode starts may time out; retry with
  `xcode_ide_list_tools({refresh: true})`.

### Branch B — only built-in Xcode MCP connected (`mcp__xcode__*`)
1. If `AmgiApp/project.yml` changed: `cd AmgiApp && xcodegen generate` (shell).
2. `XcodeListWindows` — get the `tabIdentifier` for AmgiApp.xcodeproj
   (open the project in Xcode first if no window is listed).
3. `BuildProject` with that tab — ground truth for "it builds".
4. On failure, `GetBuildLog`. Previews via `RenderPreview`, docs via
   `DocumentationSearch`, tests via `RunSomeTests` (suite names in
   `Tests/README.md`).

**Branch-B gotchas:**
- `xcodegen generate` resets the run destination; `BuildProject` then fails
  with a spurious "requires a development team" signing error (no team is
  configured — this repo builds for the simulator). Re-select a simulator in
  Xcode's toolbar or headlessly:
  ```bash
  osascript -e 'tell application "Xcode"
    set ws to first workspace document
    repeat with d in run destinations of ws
      if (name of d) is "iPhone 17 Pro" then set active run destination of ws to d
    end repeat
  end tell'
  ```
- `RunSomeTests` reports tests as "not run" until a simulator is booted AND
  the active run destination is set; freshly added test files may still show
  "No result" — fall back to `xcodebuild test -only-testing:` to confirm.

Either branch: SPM tests are compile-verified only under `swift test` because
`AnkiRustLib` is iOS-only (see memory) — run them on a simulator destination.

Either branch: the iOS scheme does **not** build `AmgiWatchApp`. Changes to
`Sources/Watch/`, to `AmgiReviewCore`/`AmgiCharts`/`AmgiAppCore` (the products
the watch links), or to project.yml's target wiring need their own build:
```bash
xcodebuild build -project AmgiApp/AmgiApp.xcodeproj -scheme AmgiWatchApp \
  -destination 'generic/platform=watchOS Simulator' ARCHS=arm64
```
`ARCHS=arm64` is required: the xcframework's watch slice is arm64-only, so the
default multi-arch simulator build fails to link x86_64 with a wall of
"ignoring file … found architecture 'arm64', required architecture 'x86_64'".
That is a packaging gap in `scripts/build-xcframework.sh`, not a regression —
do not go debugging it as one.

Also: `CODE_SIGNING_ALLOWED=NO` makes `KeychainProfileScopingTests` fail with
`saveFailed(-34018)` (errSecMissingEntitlement). Drop the flag when running the
iOS test suite; those failures are the flag, not the code.

### Shell (scripts only — not for build verification)
```bash
# Rebuild the Rust XCFramework. Required when:
#   - anki-bridge-rs/ changes
#   - anki-upstream/ is updated
#   - a .proto file is added/changed (and protos are regenerated)
./scripts/build-xcframework.sh

# Regenerate Swift protobuf types from anki-upstream/proto/anki/*.proto
./scripts/generate-protos.sh

# Regenerate the Xcode project after project.yml changes
cd AmgiApp && xcodegen generate
```

macOS SPM builds are NOT a verification path: `AnkiProtoBridge` pulls in
`AnkiBackend` (iOS-only `AnkiRustLib`) and `AmgiUI` uses UIKit types, so both
fail on macOS. Only `swift build --target AnkiKit` works, and it proves little —
use `BuildProject`.

## Key Patterns

### Dependency Client (struct-closure DI)
```swift
@DependencyClient
public struct CardClient: Sendable {
    public var fetchDue: @Sendable (_ deckId: Int64) throws -> [CardRecord]
    public var answer: @Sendable (_ cardId: Int64, _ rating: Rating, _ timeSpent: Int32) throws -> Void
}

extension CardClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            fetchDue: { deckId in /* call Rust backend */ },
            answer: { cardId, rating, timeSpent in /* call Rust backend */ }
        )
    }()
}
```

### Calling the Rust Backend
```swift
// Typed RPC: encode request protobuf → C FFI → decode response protobuf
let response: Anki_Decks_DeckTreeNode = try backend.invoke(
    service: AnkiBackend.Service.decks,
    method: AnkiBackend.DecksMethod.getDeckTree,
    request: Anki_Decks_DeckTreeRequest()
)
```

### Service Index Reference
| Service ID | Name | Key Methods |
|---|---|---|
| 1 | BackendSyncService | 3=SyncLogin, 5=SyncCollection, 6=FullUploadOrDownload |
| 3 | BackendCollectionService | 0=OpenCollection, 1=CloseCollection |
| 2 | CollectionService | 0=CheckDatabase |
| 7 | BackendDecksService | 8=GetDeckTree |
| 13 | BackendSchedulerService | 3=GetQueuedCards, 4=AnswerCard, 7=CountsForDeckToday |
| 25 | BackendNotesService | 5=GetNote |
| 29 | BackendSearchService | 0=SearchCards, 1=SearchNotes |

## Import Rules (Swift 6.2 + InternalImportsByDefault)

- `public import` for any module whose types appear in public API signatures
- `import` (internal) for modules used only within the file
- `@Table` structs need `public import StructuredQueries`
- `@DependencyClient` files need `public import Dependencies`
- SwiftProtobuf methods (serializedData, init(serializedBytes:)) need `import SwiftProtobuf`

## Known Issues & Workarounds

- **DeckTree with counts fails on fresh sync**: Use `now=0` to skip counts, fetch per-deck separately
- **SyncCollection returns FULL_DOWNLOAD for empty local DB**: Must auto-download, not just return "complete"
- **SourceKit false positives**: The IDE shows errors that don't exist in actual builds. Trust `swift build` / `xcodebuild`
- **Apple Compression framework has no zstd**: Rust handles zstd internally, no need for Swift-side compression
- **XCFramework is iOS-only**: `swift build` on macOS can't build AnkiBackend. Use `BuildProject` (Xcode MCP) or `xcodebuild` for full builds.
