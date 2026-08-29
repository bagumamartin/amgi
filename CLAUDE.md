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
             WatchFeature  → AmgiCharts, AmgiReviewCore
                                                (the watchOS app; watchOS-clean)
             SettingsFeature → Reader, Review, Browse, Templates, Sync,
                             AmgiReviewCore, AmgiAppCore   (the aggregator)
  Everything else reaches sideways into AmgiUI/AmgiTheme/AnkiKit/AnkiClients.

  **Cxx chain.** ReaderFeature declares `.interoperabilityMode(.Cxx)`, and so
  do SettingsFeature and the app target. Only ReaderFeature actually touches C++
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

  SettingsFeature (2026-08-18) joined the chain and stays there: it hosts
  ReaderSettingsView and links to `ReaderDictionarySettingsView`, so it imports
  ReaderFeature for real UI, not a single injectable view. Inverting that the
  way ReviewFeature's was would mean injecting two whole settings screens
  through the environment to save caching on one target. Not worth it unless
  the reader's settings screens move out of ReaderFeature.

  AmgiWidget links WidgetFeature only, which brings AmgiAppCore + AmgiTheme
  and must never reach AnkiClients. That, by itself, is why the sink is two
  targets rather than one.
  AmgiWatchApp links WatchFeature *and* the full engine (AnkiClients,
  AnkiServices, AnkiBackend, AnkiSync, AmgiCardWeb), so the no-AnkiClients
  rule does not apply to it. Neither it nor WatchFeature can link
  AmgiAppShared, for a different reason: AmgiAppShared imports UIKit and
  WidgetKit unguarded, so it does not build for watchOS.
  (Corrected 2026-08-15. This block previously claimed neither extension
  reaches AnkiClients, which was never true of the watch — verify against
  AmgiApp/project.yml, not this note.)

AnkiBridge package — Anki engine surface
  SwiftUI feature code (AmgiFeatures/Sources/*Feature)
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
  AnkiRustLib (binaryTarget) = AnkiRustLib.xcframework
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
| `AnkiRustLib` | `binaryTarget` pointing at `AnkiRustLib.xcframework`. iOS-only. |

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
| `AmgiAppShared` (./AmgiFeatures) | The engine-touching half of the sink, iOS-only: `CollectionStore`, `ImportHelper`, `ShareSheet`, `CardContextMenu(+Model)`, `writeWidgetSnapshot()`, the `deckImport` modifier. Exists so `AmgiAppCore` can stay engine-free. |
| `AmgiCharts` (./AmgiFeatures) | Pure chart/heatmap views over `GraphsSnapshot` + palette. No `AnkiClients` path, so its previews render without linking the xcframework. **Compiled for watchOS in its entirety** — the watch links the product, so every file here must be watchOS-clean, not just the ones the watch renders. |
| `TemplatesFeature` (./AmgiFeatures) | Card-template editor (`DeckTemplateListView`, `TemplateEditorView`, `TemplateSourceEditor`, …). Lifted out of `Decks/` to close the Decks↔Review cycle; consumed by Settings and Review. |
| `StatsFeature` (./AmgiFeatures) | Stats dashboard — `StatsDashboardView` Container / `StatsDashboardContent` + `State` enum / `StatsDashboardModel`. Deps: `AmgiCharts`, `AnkiClients`. |
| `SyncFeature` (./AmgiFeatures) | Sync flow: `SyncCoordinator`, `SyncSheet`, `LoginSheet`, `OnboardingView`, `SyncToast(+Controller)`, `AnkiMobileAttributionView`. Public surface is now **zero items, all `package`** (narrowed 2026-08-29 with `RootFeature` inside the package): the `syncFlow` modifier, its `EnvironmentValues.startSync` trigger, `OnboardingView`, `AnkiMobileAttributionView`, `SyncCoordinator`'s `init`/`cancel()`/`resetForProfileSwitch()`, and the `DependencyValues.syncCoordinator` key are all `package` — `RootFeature` is the only consumer, and it's in the same package. `SyncState`, `state`, `startSync()`, `SyncSheet` and the toast stay internal; don't re-export them to drive sync from a view. |
| `ReaderFeature` (./AmgiFeatures) | The EPUB + Anki-note readers, the offline-dictionary lookup UI, and the Study landing screen (absorbed — it was a landing screen over Reader, not a feature). The only target that touches `AmgiReaderDictionary`, and — since the `LookupPopupView` edge was inverted on 2026-08-15 — once again the only feature in the Cxx chain. See the Cxx-chain note in the diagram above before adding an import of it. Public surface is six entry points — `ReaderLibraryView`, `StudyLandingView`, `LookupPopupView`, `ReaderDictionarySettingsView`, `ReaderFontOption`, `ReaderThemeColor`; models stay internal. Note it holds **two** readers with separate preference namespaces (`EPUBChapterReaderView`/`reader_typo_*` and `ChapterReaderView`/`reader_pref_*`), branched at `ReaderBookDetailView.swift:120`. |
| `BrowseFeature` (./AmgiFeatures) | Note browsing + note authoring: browse list/search/selection, add & edit note, batch tagging, collection-wide tag management, and the whole image-occlusion editor. Public surface is exactly five views — `BrowseView`, `AddNoteView`, `NoteEditorView`, `NoteEditingDestinationView`, `TagsView`; models stay internal. It has **no** app-folder dependencies, which is why it extracted first: Reader, Review, Decks, and Settings all reach into it, so it had to leave the app target before they can. |
| `AmgiReviewCore` (./AmgiFeatures) | The review state machine (`ReviewSession`) + `TemplateRenderOverrides`. Watch-shared: `AmgiWatchApp` links it, so it must stay watchOS-clean — no `AmgiAppShared`, no UI, guard UIKit with `#if canImport(UIKit)`. Exists because project.yml used to cherry-pick these files into the watch target by path, compiling them twice as two distinct types. Same role `AmgiCharts` plays for stats. |
| `ReviewFeature` (./AmgiFeatures) | The review screen: WebKit card host, flip chrome, rating bar, native renderer, render-mode UI. Engine logic belongs in `AmgiReviewCore`, presentation here. Public surface: `ReviewView`, `CardWebViewContentAlignment`, and the `CardRenderEngine` display helpers. Deliberately does **not** import `ReaderFeature`: it takes the dictionary popup from `EnvironmentValues.lookupPopup` instead, which is what keeps it (and Decks) out of the Cxx chain. Don't re-add the import. |
| `DecksFeature` (./AmgiFeatures) | Deck list, deck detail, deck config + FSRS simulator, profile picker. Public surface is `DeckListView` alone. `DeckListView.init` takes `onSwitchProfile` because `switchProfile(to:)` is composition-root work (closes/reopens the collection, cancels sync, flips the keychain anchor) and stays in `AmgiAppApp.swift`. No Cxx settings — it left the chain when `ReviewFeature` did, with no source change of its own. |
| `SettingsFeature` (./AmgiFeatures) | The Settings root plus every screen it pushes to (appearance, accounts, sync, review behaviour, card rendering, reader display, code editor, template overrides, database maintenance, empty cards, media check, backups, about) and the shared `SettingsRow`/`SettingsControls` chrome. Public surface is `SettingsView` alone. It is the app's fan-in point, so it depends on nearly every other feature — inherent to a settings screen, not a layering smell. Two consequences: it's in the **Cxx chain** (imports `ReaderFeature`), and it's the only `*Feature` that imports `AnkiBackend` (`MaintenanceModel.resetEverything` needs `closeCollection()`; `AnkiClients` already links it, so this costs no new linkage). `SettingsView.init` takes `onSwitchProfile` for the same reason `DeckListView.init` does. Extracted 2026-08-18. |
| `WidgetFeature` (./AmgiFeatures) | Everything the iOS widget extension does: the `AmgiWidget` `Widget`, its `AmgiWidgetIntent` AppIntents configuration + `DeckEntity` query, the `AppIntentTimelineProvider` that replays `WidgetSnapshot.projectedEntries`, and the three family views. Only `@main AmgiWidgetBundle` stays in the `AmgiWidget` target. Public surface is `AmgiWidget` alone. Deps: `AmgiAppCore`, `AmgiTheme` — **must never gain `AnkiClients`**; the widget is a separate process that reads the app group and has no business reaching the Rust engine. Extracted 2026-08-16. |
| `WatchFeature` (./AmgiFeatures) | Every screen the watchOS app renders: `WatchContentView`, `WatchDeckListView`, `WatchDeckDetailView`, `WatchReviewView`, `WatchStatsView`, `WatchLoginView`, `DeckCountsView`. Only `@main WatchApp` stays in the `AmgiWatchApp` target, holding the backend/collection bootstrap — same split as `WidgetFeature`. Public surface is `WatchContentView` + `WatchLoginView`. Deps: `AmgiCharts`, `AmgiReviewCore`, `AnkiKit`/`AnkiClients`/`AnkiBackend`/`AnkiSync`/`AmgiCardWeb`, `AmgiTheme`. **Must stay watchOS-clean** — no `AmgiAppShared`, no iOS-only API. Extracted 2026-08-23. |
| `RootFeature` (./AmgiFeatures) | The composition root: `RootView` (root composition + the `MainTabView` tab bar it hosts), `StartupErrorView`, and dependency bootstrap (`AmgiRoot.bootstrap()`, `openCollection`, `switchProfile`). The only iOS-app-facing product — `AmgiApp/Sources/AmgiAppApp.swift` imports nothing else. Public surface is `RootView`, `AmgiRoot`/`AmgiRoot.bootstrap()` — kept `public` because the app target links this product directly, the same reason `WidgetFeature`/`WatchFeature` keep theirs. In the **Cxx chain** (imports `ReaderFeature`). Extracted 2026-08-29, which is what let every other `*Feature` module narrow from `public` to `package` (see the narrowing entry below). |

### Module naming convention
Three prefixes/suffixes, each answering a different question:
- **`Anki*`** — derived from the upstream Anki engine (`AnkiKit`, `AnkiClients`, `AnkiSync`).
- **`Amgi*`** — app-owned and *reusable*; other modules may depend on it
  (`AmgiUI`, `AmgiTheme`, `AmgiCharts`, `AmgiAppCore`, `AmgiAppShared`).
- **`*Feature`** — app-owned **screen-level** module: `BrowseFeature`,
  `SyncFeature`, `StatsFeature`, `TemplatesFeature`, `ReaderFeature`,
  `ReviewFeature`, `DecksFeature`, `WidgetFeature`, `SettingsFeature`,
  `WatchFeature`. (No
  `StudyFeature` — Study was absorbed into `ReaderFeature`.)

  On the suffix: `WidgetFeature` and `WatchFeature` stretch "screen-level"
  to cover app extensions and the companion app. A widget is not a screen inside the app, but the alternative —
  `AmgiWidgetUI` — claims the reusability the `Amgi*` prefix promises and
  nothing has, and sits one character from the `AmgiWidget` *target* name.
  Extensions count as screen-level for the suffix; `Amgi*` still means
  reusable.

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
- Remaining folders: a `Watch/` stub holding only `@main WatchApp.swift`, a
  `Widgets/` stub holding only `@main AmgiWidgetBundle.swift` + `Info.plist`,
  plus one root file: `AmgiAppApp.swift`, which imports only `RootFeature`
  (plus `SwiftUI`) and holds `@main` alone — `init` calls
  `AmgiRoot.bootstrap()` and `body` returns `RootView()`, both from
  `RootFeature`. `Watch/` and `Widgets/` are in `AmgiApp.sources.excludes`,
  so the iOS app target proper is that one file.
  (2026-08-29: `RootFeature` extracted — view composition (`RootView`,
  `MainTabView`, `StartupErrorView`) and dependency bootstrap
  (`AmgiRoot.bootstrap`, `openCollection`, `switchProfile`) moved out of the
  app target into a new `RootFeature` package target; `ContentView.swift` no
  longer exists, its contents having become `RootFeature/RootView.swift` +
  `RootFeature/MainTabView.swift`. 2026-08-23: `MainTabView` folded into
  `ContentView`, `StartupErrorView` into `AmgiAppApp`, `DeckImportModifier`
  moved to `AmgiAppShared`, and `RetroactiveIdentifiable` deleted —
  `Int64: Identifiable` had no callers and `EntityID: Identifiable` now lives
  non-retroactively in `AnkiKit`. `DebugView` was already gone when this note
  was written.)
- Widget target depends on `WidgetFeature` alone (which brings `AmgiAppCore` +
  `AmgiTheme`). The old `AnkiKit` dependency was vestigial and was dropped on
  2026-08-16 — no widget source ever imported it. Keep its deps narrow.
- Watch target keeps its full dependency list even after the `WatchFeature`
  lift, because `@main WatchApp.swift` still bootstraps the collection itself
  (`AnkiBackend`, `AnkiSync`, `AmgiTheme`). Three of those deps —
  `AmgiAppCore`, `Sharing`, `SwiftNavigation` — are imported by **no** watch
  source and look vestigial; they were left alone as out of scope for the
  extraction, not verified as needed.
- Direct `AnkiBackend` imports left in the app target: `RootFeature`
  (`Bootstrap.swift`, `ProfileSwitching.swift` — the composition root,
  correct; `AmgiAppApp.swift` itself imports only `RootFeature`) and
  `Watch/WatchApp` (the watch's composition root, same reason). Two
  `*Feature`s import it —
  `SettingsFeature/MaintenanceModel`, for `closeCollection()` in "Reset
  Everything", and `WatchFeature/WatchReviewView` — and it should stay at
  those two. The old reason for the
  ban ("a feature target that links `AnkiRustLib` stops rendering previews")
  died with the dynamic-framework fix on 2026-08-17, and every feature that
  links `AnkiClients` already links `AnkiBackend` transitively anyway; what
  survives is taste, so route through an `AnkiServices` facade where one exists.
- `project.yml` must contain **no per-file `path:` entries under `Sources/`**.
  Cross-target file sharing goes through a product (see `AmgiReviewCore`).

### Extraction status (2026-08-15)
The app target went from ~18.7k LOC to ~4.4k in one session, then to ~1.2k
when Settings followed on 2026-08-18. That last figure is 505 lines of root
files plus what was then 735 lines in `Watch/`; the `WatchFeature` lift on
2026-08-23 took all but the 85-line `@main WatchApp.swift`. `Watch/` is
excluded from the iOS target either way, so the iOS app itself is ~500 lines. Order was forced by the coupling graph,
not preference.

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
5. **`SettingsFeature`** (2026-08-18) — all 19 files, last out. This entry
   used to read "Settings stays … extracting it would buy a boundary nothing
   needs"; the user asked for the extraction anyway and it was cheaper than
   that note implied. The whole coupling surface was two touchpoints:
   `MainTabView` presenting `SettingsView`, and one call to the free function
   `switchProfile(to:)`, now an `onSwitchProfile` init closure exactly like
   `DeckListView`'s. The prediction that held: the boundary buys little on its
   own. What it does buy is that the app target is now only its composition
   root, and Settings compiles as a package target. What it costs is real —
   SettingsFeature is in the Cxx chain (see above) and so loses compilation
   caching, and it imports 7 of the 12 sibling products.
6. **`WidgetFeature`** (2026-08-16) — six of seven files out of the `AmgiWidget`
   extension target; only `@main AmgiWidgetBundle` + `Info.plist` remain.
   Note this did **not** shrink the app target: `Sources/Widgets` was already
   in `AmgiApp.sources.excludes`, so the 4.4k figure never counted it.

   Two findings recorded so they are not re-raised. The extraction was first
   pitched as "give the widget views previews" — they already had them, in the
   real `#Preview(as: .systemSmall) { AmgiWidget() }` WidgetKit form. That is
   why `AmgiWidget`, the intent, and the provider all had to move too: leaving
   any of them behind pins the other two and forces rewriting all three
   previews. Moving *all* of them turned out to force the rewrite anyway —
   see the next paragraph. And the
   widget's date math (`LargeWidgetView.dayLabel(_:)`, `progressFraction`,
   `chartMax`) is still untested — testing it was offered as a smaller,
   separate change (lift into `AmgiAppCore` beside `WidgetSnapshot`) and
   declined. Don't fold it in.

   **No WidgetKit preview API survives in a package target** (found
   2026-08-17). A *widget* preview needs a widget-extension process to host it;
   a file in a package target is previewed by XCPreviewAgent, which is an app,
   so Xcode fails with `NoCandidatesProvidedToComputeAgent: No candidates found
   to host preview` over a build graph that tops out at `WidgetFeature` with no
   extension node. Not scheme wiring — the `AmgiApp` scheme already builds
   `AmgiWidget`; an `.appex` simply cannot host a package target's preview. And
   it is not the `#Preview(as:)` *macro*: what tags the preview as a widget is
   **`WidgetPreviewContext`**, so rewriting to a `PreviewProvider` +
   `previewContext(WidgetPreviewContext(family:))` fails identically, with the
   same `(SmallWidgetView.swift, Previews, widget)` node. (Inside the `#Preview`
   macro `previewContext` is additionally a no-op — `warning: PreviewContext is
   ignored in a #Preview macro`.) Both were tried and both failed; don't retry
   either.

   The three widget previews are therefore plain `#Preview`s of the concrete
   view at a hand-set frame, with the rounded widget background faked via
   `.background(_:in:)`. Costs: no timeline scrubber, nominal rather than
   device-exact sizing, and the `\.palette` default instead of ThemeManager's
   live theme. Getting the real thing back means moving `AmgiWidget`, the
   intent, and the provider back into the `AmgiWidget` target — i.e. undoing
   this extraction.

   **Watch was considered and declined here, then done anyway on 2026-08-23**
   (see item 7). The reasoning below still holds and is why the lift bought
   little: no preview payoff — every watch screen transitively reaches
   `AnkiBackend`, so its previews would die on the way out exactly as both
   `DeckListView` previews did. No build-coverage payoff either: the sources
   use no watchOS-only API and would compile for iOS, but the iOS scheme still
   wouldn't build the product because nothing on iOS links it. The real watch
   defect — the iOS scheme doesn't build `AmgiWatchApp`, so breakage is silent
   — is scheme wiring, not modularization, and is **still open**.

   AppIntents metadata extraction **does** work from a SwiftPM static-library
   target: the built `AmgiWidget.appex` carries a complete
   `Metadata.appintents/extract.actionsdata` naming
   `WidgetFeature.AmgiWidgetIntent`, `WidgetFeature.DeckEntityQuery`
   (`defaultQueryForEntity: true`), and the `deck` parameter. Runtime
   confirmation of the edit-sheet picker is still pending.

   The predicted preview payoff was **unverified** at the time: package-target
   previews failed project-wide with `JITError: Symbols not found:
   [_anki_open_backend, …]`, and a control run on the untouched
   `AmgiUI/Library/LibraryListContent.swift` failed identically — so the
   breakage predated the extraction and said nothing about it either way. That
   root cause was the static Rust archive and is **fixed as of 2026-08-17** (see
   the preview bullet below); the widget previews specifically are still
   unmeasured.

7. **`WatchFeature`** (2026-08-23) — seven of eight files out of the
   `AmgiWatchApp` target; only `@main WatchApp.swift` remains, holding the
   backend/collection bootstrap. Same split as `WidgetFeature`, and it did
   **not** shrink the iOS app target: `Sources/Watch` was already in
   `AmgiApp.sources.excludes`. Cost was two files needing `public` + a
   `public import SwiftUI` (`WatchContentView`, `WatchLoginView`) and six
   `DesignConformanceTests` keys re-pathed `Watch/` → `WatchFeature/`. The
   payoffs predicted as absent in the 2026-08-16 note stayed absent — no
   previews, no iOS build coverage. What it buys is that the watch's screens
   compile as a package target with the package's stricter settings
   (`MemberImportVisibility`, `AccessLevelOnImport`) instead of the app
   target's looser ones.

8. **`RootFeature`** (2026-08-29) unblocked a narrowing pass across the eight
   feature modules it composes (`Browse`, `Decks`, `Reader`, `Review`,
   `Settings`, `Stats`, `Sync`, `Templates`): with `RootFeature` inside
   `AmgiFeatures` and no target outside the package composing those views any
   longer, `public` on them was dead reach. 110 `public` declarations across
   25 files went to `package` (re-verified at narrowing time — same figure as
   at plan time). Every `public import` that existed only to support one of
   those declarations dropped to `package import` or plain `import`
   (`AccessLevelOnImport` named each one). Three `public` entry points
   survive, one per executable that actually links a product directly:
   `RootFeature` (the app), `WidgetFeature` (the widget), `WatchFeature` (the
   watch) — plus the four sinks the widget and watch link directly
   (`AmgiAppCore`, `AmgiAppShared`, `AmgiCharts`, `AmgiReviewCore`), left
   untouched. Verification: `rg -c "^\s*public " AmgiFeatures/Sources/{Browse,Decks,Reader,Review,Settings,Stats,Sync,Templates}Feature`
   returns zero for all eight.

**If you extract another module, budget for these five.** Every lift this
session hit at least two:
- **Engine-touching previews used to die on the way out — fixed 2026-08-17.**
  A preview of a file in the app target runs against `AmgiApp.debug.dylib`,
  which exports the four `anki_*` FFI symbols. A preview of a file in a
  *package* target runs in XCPreviewAgent with no app host, and the JIT
  resolves only against dylibs in the products dir. While the xcframework
  shipped `libanki_bridge_ios.a` — a **static** archive — every preview that
  transitively reached `AnkiBackend` failed with `JITError: Runtime linking
  failure — Symbols not found: [_anki_open_backend, …]`. That killed both
  `DeckListView` previews on the DecksFeature lift (2026-08-15).
  `anki-bridge-rs` is now a `cdylib` shipped as a **dynamic**
  `AnkiRustLib.framework`, so those symbols resolve and package previews render
  against the live collection. Do not switch `crate-type` back to `staticlib`.
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
