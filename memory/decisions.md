# Decisions

## Card WebView prewarm pool (2026-08)

- **First HTML review card must never wait on a WKWebView cold-start** — logs
  showed WebContent/GPU/Networking process spawns of 1.8–3.7s paid *after* the
  Study tap. `CardWebViewPrewarmer` (app target, Review/) keeps one configured,
  frame-loaded webview; triggers: app-root idle task (+2s) and
  DeckDetailView `.task` on every appear.
- **Adoption = whole-pair handoff**: `makeCoordinator` takes the pooled
  coordinator, so frame-load state (page signature, isPageLoaded) carries over;
  `makeUIView` uses `coordinator.prewarmedWebView ?? makeCardWebView`. The
  pooled coordinator's nil callbacks are filled by the first `applyCardUpdate`
  via `refreshCallbacks` (coordinator callback properties are vars now).
- **iOS tap-interaction bootstrap + amgiLookupText/amgiRevealAnswer handlers are
  registered unconditionally** (was: only when callbacks non-nil): the pool
  builds config before any session exists; over-injection is safe because JS
  messages land in the coordinator and die on nil optional chaining. Runtime
  gating unchanged (lookupPopupEnabled card state + typed-answer guards).
- Coordinator holds `prewarmedWebView` **strongly** (nothing else retains it
  pre-adoption); handler→coordinator→webview cycle is broken by dismantle's
  existing removeScriptMessageHandler calls, and by the prewarmer's memory-
  warning eviction (`prewarmedWebView = nil` then `stored = nil`).
- Stale-appearance frames self-heal through applyCardUpdate's page-signature
  reload; single-use pool (take clears), fallback to inline creation keeps
  warm-process benefit when the user beats the prewarm.

## Colour system — one card-state palette (2026-08)

- **Rating buttons, count dots, badges, rings, and progress fills all bind to
  the theme's `cardStateNew/Learning/Review(/Relearn)` slots** — no hardcoded
  system colours anywhere user-facing. Mapping: Again→relearn(red),
  Hard→learning(orange), Good→review(green), Easy→new(blue). User runs the
  **Vivid** theme (bright ≈ system colours); Minimal/Muted/Sepia stay muted by
  design — brightening theme data across all themes was explicitly rejected.
- **Progress fills = "lit composition"**: the fill/arc is a full-strength copy
  of the dim new/learn/review backdrop revealed up to the progress fraction,
  so hue flips land exactly on the backdrop's segment boundaries; single-state
  days stay one hue throughout. Empty composition (day done / zero due)
  falls back to the solid `positive` sweep + glow. Implemented in
  DailyProgressBar, StudyDueRing, SmallDueRing, LargeWidgetView bar.
- Widgets read the selected theme via `ThemeManager.shared.palette(for:)`
  injected in AmgiWidget.swift — they follow the app's theme setting.
- `swift build --target AmgiUI` **succeeds on macOS** (2026-08): the old
  "AmgiUI fails on macOS (UIKit)" note is stale; AmgiUI is a valid local
  verification path again. App-target files remain parse-check only.

## Deck icons (2026-08, deck-icon-picker-spec.md + amendments)

- **New sibling SPM `AmgiIcons/`** owns the whole feature: IconSuggester
  engine, IconPickerView, bundled resources (CoreML model, tokenizer,
  embeddings). App target links it; widget/watch do not.
- **Model**: `tamikisg/multilingual-e5-small-coreml` (fp16, ~224 MB, inputs
  `input_ids`/`attention_mask` 1×256 int32, output `embeddings` 1×384
  L2-normalized). Bundled **precompiled** (`xcrun coremlcompiler compile` →
  `.mlmodelc`, `.copy` resource): raw `.mlpackage` made Xcode auto-generate
  a Swift model class whose plain `import CoreML` breaks under
  InternalImportsByDefault (device build failure 2026-08), and cost ~8s
  first-launch compile. AmgiIcons is therefore the ONE target without
  InternalImportsByDefault/AccessLevelOnImport — keep it that way.
- **Model is NOT in git** (2026-08): weight.bin is 224 MB (> GitHub's 100 MB
  file limit) and `bagumamartin/amgi` is a public fork, which GitHub blocks
  from uploading ANY new LFS objects. The `.mlmodelc` folder is gitignored;
  fresh clones must fetch + compile per `AmgiIcons/README.md`. LFS tracking
  (`**/*.mlmodelc/**` in .gitattributes) is kept so a detached/non-fork repo
  can flip the .gitignore line and use LFS immediately.
- **Tokenizer**: swift-transformers `AutoTokenizer.from(modelFolder:)`
  (product `Tokenizers`). Verified byte-identical token IDs vs Python HF.
- **Embedding space parity**: runtime query vectors match
  `sentence-transformers` output to ~1e-5 (attention-mask bug fixed during
  dev — mask must cover only real tokens, computed BEFORE pad-filling).
- **Persistence**: manual picks live in Anki's **collection config**
  (`col.conf`) under `"amgi.deckIcons"` — one JSON blob `{deckId: caseName}`
  (`DeckIconOverrides`, app target). Anki-sanctioned home for app-specific
  data that rides normal collection sync, so icons stay consistent across
  devices. Writes are fetch→patch→write against a freshly pulled blob
  (never the cached mirror) because config syncs last-write-wins at the
  blob level. The bridge helpers (`AnkiBackend.getConfigJSONValue/
  setConfigJSONValue`) already existed — zero Rust/FFI work. Absence ⇒ icon
  derives from deck name at render time (rename-reactive). Anki schema
  untouched.
- **Auto picks sync too** (`"amgi.deckIconsAuto"`, `{deckId: {icon, name}}`):
  **first writer prevails** — the first device to resolve a deck records it
  and every other device adopts that choice instead of deriving its own.
  Entries carry the deck name; a rename re-resolves once. Precedence at
  render: manual > synced auto pick > compute-and-record. The earlier
  device-local UserDefaults suggestion cache was removed (legacy key is
  deleted on refresh); deterministic-model consistency is now guaranteed by
  shared state rather than determinism alone.
- **Instant refresh**: every icon write bumps `CollectionStore` generation
  (via `invalidateAll(.localUser)` or the mutation's own changes), so all
  generation-keyed screens reload with fresh conf immediately; `.localUser`
  also queues the automatic sync push.
- **Icon names**: Phosphor camelCase case names (`"airTrafficControl"`);
  `Ph.amgi(named:)` index converts kebab rawValues → camel. `repeat` needs
  backticks at use sites.
- **PhosphorSwift is vendored** at `AmgiIcons/Vendor/PhosphorSwift`
  (upstream 2.1.0): its manifest omits `resources:` while using
  `Bundle.module` → doesn't compile under SwiftPM. Only Package.swift
  differs (see VENDOR_NOTE.md).
- **AmgiUI stays icon-library-free**: `DeckIconRendering.provider` (MainActor
  static) is registered by the app at startup; watch never registers →
  letter tiles. Phosphor doesn't declare watchOS, so a direct AmgiUI dep
  would break the watch build.
- **Emoji decks keep legacy tiles** unless manually overridden
  (`DeckTileGlyph.hasLeadingEmoji`).
- **Threshold 0.80, not spec's 0.75**: measured e5-small sims compress into
  ~0.82–0.88 across the catalog (garbage ≥0.84), so 0.75 can never fire.
- **Picker UX**: curated `Ph.deckTopPicks` (~80) as landing grid + "Show
  all 1,512" expander; search falls through to full-set semantic results
  (debounce 150 ms via cancellable `.task(id:)`).
- **Embeddings JSON**: floats rounded to 6 decimals (5.8 MB) — precision
  loss is irrelevant at cosine granularity.

## Agent surface — amgi-mcp helper + App Intents (2026-08)

- **MCP server lives in Swift** (`Sources/AmgiMCP/`, executable product
  `amgi-mcp`, official swift-sdk): zero changes to anki-bridge-rs or
  anki-upstream; reuses AnkiProtoBridge Request<R> factories. Depends on
  AnkiServices tier, deliberately NOT AnkiClients (keeps the hoshidicts
  C++ chain out of the binary).
- **Same-file architecture**: the helper opens the app's actual
  `collection.anki2` via `CollectionLayout` (AnkiKit) — no sync code, agent
  edits propagate cross-device through the app's normal auto-sync.
- **Simultaneity via IPC bridge** (supersedes the earlier quit-app
  workaround): the SQLITE_BUSY-style "Anki already open" error only bites
  on contended writes/opens, but rslib serializes collection ownership,
  so the app HOSTS the engine and serves AnkiKit.MCPBridge framing over
  `<root>/mcp.sock`; helper probes it per call (ProxyCaller) and falls
  back to direct open when absent. App bumps CollectionStore after
  forwarded mutations (hardcoded service/method table in
  MCPBridgeServer — mirrors tier metadata). GOTCHA that hung the app:
  `Task {}` from App.init inherits MainActor — the blocking accept loop
  must run on `Thread.detachNewThread`.
- **Canonical Mac root = group container** (`…/Group Containers/
  group.com.bagumamartin.AmgiApp/AnkiCollection`): sole location both
  sandboxed app and unsandboxed helper can write. NOTE:
  containerURL resolves to the PLAIN-named dir on this machine even
  though a Team-prefixed twin exists — never reconstruct group paths;
  always go through CollectionLayout. Migration
  (migrateIntoCanonicalRoot) moved container/home legacy data in on
  first launch.
- **Live-refresh rail**: after each mutation the helper posts a distributed
  notification `com.amgi.collection.changed`; the app observes it and bumps
  CollectionStore generation (origin `.helperMutation`, which also rides
  automatic sync like localUser).
- **Tiers** (mcp.json next to profiles, written by Settings → Agent):
  readOnly / safeWrite (default) / full; destructive ops snapshot db+wal+shm
  trio first (SQLite online-backup API contends with rslib's read state —
  file-copy is the reliable route). Service/method index audit found ONE
  catalog drift: NotesMethod.removeNotes was 3, actually **7** (verified by
  behavioral probe of every mutating index).
- **Helper embedded in app bundle**: project.yml target `AmgiMCPHelper`
  (type: tool, macOS) compiles Sources/AmgiMCP; an AmgiApp post-build
  script cp's it to Contents/Helpers/amgi-mcp (ditto denied by script
  sandbox; declared input/output keeps ENABLE_USER_SCRIPT_SANDBOXING).
  xcodegen dependency-level `copy:` produced unsealed/nested-bundle
  breakage — don't use it for tools. MCPManager prefers bundled path,
  then ~/bin (install script now optional). AnkiProtoBridge became a
  package product for this target. Request.serviceId/.methodId/.body/
  .decode made public as IPC plumbing.
- **App Intents** (AmgiApp/Sources/Intents/): force-quit-proof on-device
  actions; system cold-launches the app. Gotcha recorded: @Dependency
  property wrappers inside AppIntent structs explode the type checker
  ("failed to produce diagnostic") — use `<Client>.liveValue` stored lets
  there instead. DeckEntity ids must be String (EntityIdentifierConvertible).

## General

- **NonisolatedNonsendingByDefault + blocking FFI = main-thread freezes** (fixed
  2026-08): nonisolated `async` closures awaited from `@MainActor` run ON the
  main actor, so any synchronous `backend.invoke(...)` inside them blocks the
  UI for the whole call (sync froze until completion). Rule: service/client
  closures that touch the backend must either `await` the async
  `AnkiBackend.invoke` overload (detaches internally) or wrap sync calls in
  `backendOffload` (AnkiClients) / `Task.detached` — never call the sync
  overload from an async closure reachable from MainActor.
- Sibling SPMs (AmgiUI, AmgiReader, AmgiIcons) are path-resolved from the
  app's project.yml; root `Package.swift` (AnkiBridge) is separate.
- `DeckRowViewData` / `DeckDetailViewData` carry optional `iconName`;
  AmgiUI renders glyphs only through `DeckIconRendering.provider`.
