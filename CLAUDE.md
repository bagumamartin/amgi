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
  StatsFeature → AmgiCharts     TemplatesFeature     AmgiAppShared → AmgiAppCore
  BrowseFeature → AmgiAppShared    SyncFeature → AmgiAppShared → AmgiAppCore
  Only four intra-package edges exist; everything else reaches sideways into
  AmgiUI/AmgiTheme/AnkiKit/AnkiClients.

  AmgiWidget links AmgiAppCore only and must never reach AnkiClients. That,
  by itself, is why the sink is two targets rather than one.
  AmgiWatchApp links AmgiAppCore + AmgiCharts *and* the full engine
  (AnkiClients, AnkiServices, AnkiBackend, AnkiSync, AmgiCardWeb), so the
  no-AnkiClients rule does not apply to it. It cannot link AmgiAppShared for
  a different reason: AmgiAppShared imports UIKit and WidgetKit unguarded, so
  it does not build for watchOS.
  (Corrected 2026-08-15. This block previously claimed neither extension
  reaches AnkiClients, which was never true of the watch — verify against
  AmgiApp/project.yml, not this note.)

AnkiBridge package — Anki engine surface
  SwiftUI feature code (AmgiApp/Sources/{Decks,Review,Reader,Stats,…})
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
| `BrowseFeature` (./AmgiFeatures) | Note browsing + note authoring: browse list/search/selection, add & edit note, batch tagging, collection-wide tag management, and the whole image-occlusion editor. Public surface is exactly five views — `BrowseView`, `AddNoteView`, `NoteEditorView`, `NoteEditingDestinationView`, `TagsView`; models stay internal. It has **no** app-folder dependencies, which is why it extracted first: Reader, Review, Decks, and Settings all reach into it, so it had to leave the app target before they can. |

### Module naming convention
Three prefixes/suffixes, each answering a different question:
- **`Anki*`** — derived from the upstream Anki engine (`AnkiKit`, `AnkiClients`, `AnkiSync`).
- **`Amgi*`** — app-owned and *reusable*; other modules may depend on it
  (`AmgiUI`, `AmgiTheme`, `AmgiCharts`, `AmgiAppCore`, `AmgiAppShared`).
- **`*Feature`** — app-owned **leaf**. Nothing depends on it; only the app
  target imports it (`BrowseFeature`, `SyncFeature`, `StatsFeature`,
  `TemplatesFeature`). Pending: `DecksFeature`, `ReaderFeature`,
  `ReviewFeature`, `SettingsFeature`, `StudyFeature`.

`Feature` is a **suffix, not a prefix** — Swift/Cocoa put the head noun last
(`UIViewController` *is a* Controller), so `SyncFeature` reads "the Sync
feature" while `FeatureSync` reads backwards. Renamed 2026-08-15.

Do **not** use `Amgi*` for a new feature module: `AmgiSync` would sit one
letter from the existing `AnkiSync`, and `Amgi`/`Anki` is already this repo's
most misread pair. The suffix keeps the app layer visually distinct.

### App target
- `AmgiApp/` — Xcode project, generated by xcodegen from `project.yml`.
- Feature folders: `AmgiApp/Sources/{Decks,Review,Reader,Study,Settings,Watch,Widgets}`
  (`Stats/`, `Theme/`, `Browse/`, `Sync/` and `Shared/` are gone — they migrated
  into `AmgiFeatures`/`AmgiUI`, or in `Shared/`'s case dissolved into their one
  real consumer each; see 2026-08-15 below).
- Widget target shares `AmgiTheme` + `AnkiKit` + `AmgiAppCore` only — keep its deps narrow.
- `Reader/` imports no `AnkiBackend` (2026-08-15). Keep it that way: the target
  it becomes must not link `AnkiRustLib`, or its previews stop rendering.
  `Review/`, `Settings/MaintenanceModel`, `Watch/` and `DebugView` still do.

### Extraction status (2026-08-15)
Remaining app-target code is ~18k LOC, ~69% of the app layer. Order is forced
by the coupling graph, not preference:

1. **`ReaderFeature`** (absorbs `Study/`, which is a 166-LOC landing screen over
   Reader, not a feature). Unblocked: `Reader/` is now `AnkiBackend`-free, and a
   probe target proved an SPM target consumes the Cxx-mode `AmgiReaderDictionary`
   with nothing but `swiftSettings: [.interoperabilityMode(.Cxx)]` — the
   `OTHER_SWIFT_FLAGS` duplication in project.yml is an Xcode-target problem SPM
   does not have. **Payoff:** the five `Reader/` files are the app target's last
   importers of `AmgiReaderDictionary`, so after this the app can drop
   `SWIFT_CXX_INTEROPERABILITY_MODE` + `CLANG_CXX_*` and regain explicit modules
   and compilation caching (see the project.yml comment calling that
   "unfixable" — it is fixable by extraction). Benchmark it afterwards.
2. **`ReviewFeature`** — blocked. `project.yml` cherry-picks three files out of
   `Sources/Review/` into AmgiWatchApp by path (`ReviewSession.swift`,
   `ReviewAudioSession.swift`, `RenderEngine/TemplateRenderOverrides.swift`).
   That is file-level coupling across a target boundary and is inexpressible
   once Review is a module. Promote them to a watchOS-clean target that both
   `ReviewFeature` and the watch link — the way `AmgiCharts` already works —
   rather than moving them.
3. **`DecksFeature`** — after Review; `Decks/DeckDetail/DeckDetailPresentations.swift`
   presents `ReviewView`.
4. **Settings** — probably stays. It is an aggregator that consumes types from
   every other feature; once 1–3 land it is a thin shell over public module APIs.

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
`Sources/Watch/`, `Sources/Review/`'s three watch-shared files, or project.yml's
target wiring need their own build:
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
