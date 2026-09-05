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
- **Model weights download from CDN on first launch (2026-09, supersedes the
  bundled-model rows above)**: `ModelAssetManager` (AmgiEmbeddings actor)
  fetches `https://amgiassets.bagumamartin.com/manifest.json` (v1: 206MB
  `.mlpackage.zip` + sha256 + byteSize), downloads with progress (delegate
  transport, Wi-Fi-only by default via `allowsExpensiveNetworkAccess=false`),
  verifies size + SHA-256 (CryptoKit, streamed), unzips (ZIPFoundation — no
  system unzip on iOS), compiles via `MLModel.compileModel` into the
  app-group container `<group>/AmgiEmbeddings/models/v<N>/`
  (backup-excluded), prunes old versions. Ships the `.mlpackage`, NOT
  `.mlmodelc`: compiler output is version-tied and zip-fragile.
  `TextEmbedder` lookup = installed dir → bundle `.mlmodelc` (dev leftover)
  → bundle `.mlpackage`→Caches → throw with graceful degradation
  (name-token icons, no semantic fallback). Manager calls
  `TextEmbedder.resetEngineForModelInstall()` post-install because load
  failures are memoized in `engineError`. `ModelDownloadCoordinator`
  (@Observable, SyncFeature) runs the first-launch `.confirmationDialog`
  (Wi-Fi / cellular / offline variants, exact MB from a silent manifest
  fetch) from `.syncFlow()` (so it only appears post-onboarding).
  `ModelDownloadPreferences` (UserDefaults: consentGiven, wifiOnly default
  policy). `NetworkMonitor` (@Observable NWPathMonitor singleton) drives
  policy-aware auto-retry of `.failed` (`retryIfAllowed` on
  isSatisfied/usesWiFi flips; constrained treated as expensive).
  `ModelDownloadToast` (progress/MB, success auto-dismiss, failure+Retry)
  shares ONE bottom overlay with `SyncToast` (`combinedToastOverlay` in
  SyncFeature; the single `syncToastOverlay` stays for other hosts).
  MaintenanceView gains an AI Model section (status view + policy picker +
  confirmed delete). No system notifications — repo has zero
  UNUserNotification usage and a new permission prompt isn't worth it for a
  one-time download.
- **Interruption recovery (2026-09)**: `cancelDownload()` + resume-data
  sidecar (`.resume-vN.dat` at models root — NOT staging, which is wiped on
  every exit) + `downloadTask(withResumeData:)` with one fresh fallback.
  Status is `.downloading(fraction:receivedBytes:totalBytes:)` so toasts
  render MB. REAL BUG found by E2E: the fresh-fallback `guard resumeData !=
  nil` couldn't distinguish "resume rejected" from "user just cancelled" —
  a cancel that produced resume data instantly restarted the transfer
  (second task completed, status went ready). Fixed with `guard
  !userCancelled`. Proof harness: throttled localhost Range-supporting
  server (CDN fetches 216MB in ~5s here, so no fixed-sleep cancel test can
  ever win the race — the committed cancel test cancels on first sighting
  instead). Kill -9 mid-download (no resume data produced) still restarts
  fresh — safe via size+SHA gate, just wasteful. Server verified
  `Accept-Ranges: bytes` + 206, so resume engages in practice.
- **Engine moved to `AmgiEmbeddings/` sibling SPM (2026-09)**: AmgiIcons is
  icons-only (`IconSuggester`, picker, Phosphor, `IconEmbeddings.json`);
  `TextEmbedder`, `ModelAssetManager`, `ModelAssetStatusView`, `Tokenizer/`
  live in AmgiEmbeddings (path dep from AmgiIcons + AmgiFeatures
  SyncFeature/SettingsFeature/AmgiAppShared). Store renamed to the group
  container (see next row); `migrateLegacyStoreIfNeeded()` moves the
  unshipped `AmgiIcons/models` layout once. History preserved via
  `git mv` for tracked files.
- **Model store lives in the app-group container (2026-09)**: `<group>/
  AmgiEmbeddings/models`, next to `AnkiCollection` — one visible home, no
  scattered sandboxes. Sandbox Application Support is the fallback for
  unentitled contexts (`swift test`, previews). Nothing outside the main
  app reads the model (helper/widget/watch don't use it), so the move is
  safe; group placement future-proofs helper-side semantic tools. Group ID
  is mirrored by hand from `AppGroup.identifier` (package must not depend
  on AmgiTheme/AnkiKit for six lines). Migration chain: sandbox
  `AmgiIcons/models` → sandbox `AmgiEmbeddings/models` → group.
- **Test hygiene (2026-09)**: `ModelAssetManager.modelsRootOverride`
  (`nonisolated(unsafe)`, test-only) redirects the store to a temp dir;
  `ModelStoreTestSupport` actor-serializer runs ALL store-touching tests
  mutually exclusive (suites run parallel in-process — an NSLock can't be
  held across awaits in Swift 6.2, and without serialization an E2E
  download lands in another suite's scratch or the real install — observed
  live). E2E (env-gated) downloads into temp, tears down everything
  including the cached engine; host verified CLEAN after every run.
  Caution learned twice: (1) fixed-sleep cancel tests can never win against
  a ~5s 206MB fetch — cancel on first sighting; (2) `CODE_SIGNING_ALLOWED=NO`
  breaks keychain → SyncCoordinatorTests fail with `.noServer` — always
  sign test runs on this machine.
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

- **ONE channel, industry standard: `uvx amgi-mcp` over stdio (2026-08,
  after every channel failed in the wild)**. HTTP transport (LocalHTTPServer/
  HTTPTransport.swift, `--http`, mcp.http.json, app-supervised spawn) was
  REMOVED — it required the app running and its Accept/Origin/Bearer
  validation 406'd real clients. Per-client snippet generation (Zed
  context_servers, Hermes YAML, Codex TOML, Qwen httpUrl…) was also removed:
  Qwen desktop rejects any command except literal "npx"/"uvx", which proved
  custom paths can't be made universal. Settings now shows exactly one
  registration: Command `uvx`, Parameters `amgi-mcp` (+ JSON block). The
  PyPI shim (python/) finds the bundled helper itself, so no absolute paths.
- **Helper lifetime — stdin relay (2026-08)**: the SDK's StdioTransport
  parks forever on stdin EOF, orphaning helpers (4 stale processes observed;
  through uvx a getppid watch NEVER fires — uvx outlives its own parent and
  keeps the helper as its child). Fix: `pipe()` + relay thread — the sole
  reader of fd 0 forwards bytes into the transport (constructed with
  `input: FileDescriptor(rawValue: pipeReadEnd)` from `System` — NOT
  SystemPackage, the SDK's `#if canImport(System)` picks System); on EOF it
  closes the write end, sleeps 1s (last response flush), `exit(0)`.
  GOTCHAS, both hit live: (a) a second fd-0 reader or a kqueue
  EVFILT_READ watcher breaks the SDK's non-blocking read loop — responses
  silently stop; (b) `swift build | tail` masks build failure (pipeline
  exit = tail's) — chain with `&&` only, never pipe before `&&`.
  Verified: handshake + clean exit 1.0s after stdin close via uvx.

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

- **`get_review_context` — live session state over the bridge (2026-08)**:
  the ONE tool about app UI state, not the collection. `MCPBridge` service-0
  sentinel grew `sessionStateMethod = 1` (ping is 0/0); `MCPBridgeServer`
  intercepts it before the engine forward and answers from
  `ReviewSessionContext.shared` — a lock-based (NOT actor; bridge thread
  reads it) snapshot registry that `ReviewSession.publishContext()` refreshes
  on every card transition (single publish point inside `advanceToNextCard`
  covers start/answer/undo/finish) and `deinit` clears. Snapshot type
  (`ReviewSessionSnapshot`, AnkiKit — shared Codable) carries current
  cardId+noteId, deck scope, queue remaining + new/learn/review, session
  stats, answered-today timeline. Helper tool (readOnly) probes
  `ProxyCaller.ping` FIRST — `ctx.backend()` would fall through to a direct
  collection open and die on the engine lock held by sibling helpers before
  it could say "app not running" — then enriches with `is:buried` /
  `is:suspended` counts in scope via `Request.searchCardIds`. App closed ⇒
  clean error by design: current card exists only while the app does.
  GOTCHA: IDs are **Int64**-backed (`Identifiers.swift`), not UInt64.

- **Widget progress = reviewer math (2026-08 fix)**: widgets showed
  answers-today over a frozen calendar-midnight baseline — diverging from
  the study screen, which counts GRADUATIONS over live remaining. Widget
  snapshot now carries `completedToday` (`statsClient.graduatedToday` =
  `is:review rated:1` in scope — re-answers/Again don't inflate) and
  `todayProgressFraction = completed / (completed + live totalDue)` — the
  exact `DailyProgressBar` formula. `reviewedToday` kept as FYI only.
  Day boundary: snapshot carries `nextDayStart` computed from
  `graphs.rolloverHour` via `DailyProgressCalculator` — the timeline's
  rollover entry + reload policy use it, NEVER calendar midnight (Anki
  rollover hour is user-settable). Per-deck graduated searches bounded to
  decks with due cards or an existing snapshot file (N+1 guard). Theme:
  `ThemeManager.refreshFromDefaults()` called per widget timeline reload —
  widget processes can outlive an app-side theme change; palette plumbing
  (app-group defaults + Bundle.module themes + `palette(for: colorScheme)`)
  was already correct, only the cache was stale-prone. Study landing ring
  already used graduated math (`StudyLandingModel.resolveCollectionProgress`)
  — its `dueBaselineToday` field name is a misnomer (holds completed+remaining).

- **Progress nuance — Again holds the bar everywhere (2026-08 fix)**:
  "done for today" = re-graduated past the rollover. Two engine-verified
  bugs: (1) `is:review` is TYPE-based (`type IN (Review, Relearn)` per
  sqlwriter.rs) so `is:review rated:1` counted Again-lapsed cards that
  Anki keeps showing today — `graduatedToday` now uses
  **`rated:1 -is:learn`** (state-based: excludes type Learn/Relearn
  whatever button sequence got it there; Hard on a review card counts —
  it schedules ≥1 day). (2) learn counts (queue AND deck-tree
  `due_counts.sql`) only include intraday learning within the ~20-min
  learn-ahead window — answering Again with a longer step made
  `completed/(completed+remaining)` jump without graduation, then dip.
  Fix: **`learningDueToday`** on StatsClient — search
  `is:learn prop:due<=0 -is:suspended -is:buried` (+scope); `prop:due` is
  queue-aware (learn epoch dues compared vs next-day start), so it's the
  true learning-remaining-today. Used by ReviewSession
  (`refineRemainingLearning()` after start/answer/undo — replaces
  queue.learningCount), WriteWidgetSnapshot (widget learnCount),
  StudyLandingModel (ring). Hardening: `loadDailyProgress()` failure now
  falls back to `secondsUntilNextDayStart = 86_400` (was 0 → every
  sub-day interval instantly "graduated"). All four indicators (review
  bar, landing ring, widgets, live repaint) observe: Again holds the bar;
  re-graduation past today moves it once; sub-day FSRS steps hold.

- **Launch crash on locked collection (2026-08 fix)**: `try!
  prepareDependencies` in `AnkiAppApp.init` trapped (EXC_BREAKPOINT via
  `swift_unexpectedError`, symbolicated to AmgiAppApp.swift:93) whenever
  `openCollection` failed — which is now a NORMAL condition: MCP helper
  sessions hold the collection while the app is closed. Fix:
  `CollectionLaunchState` (@MainActor @Observable singleton) + busy screen
  (`CollectionBusyView`): open failure degrades to "Amgi is busy — an AI
  assistant is using your collection", background retry every 2 s on a
  DETACHED task (blocking FFI off main per the NonisolatedNonsending
  rule), auto-recovers when helpers quit or switch to bridged mode.
  Backend handle is rebuilt on the failure path (init is lock-free; only
  openCollection contends). `prepareDependencies` still registers the
  backend so the bridge/services work; ContentView is replaced by the
  busy view until open succeeds, so nothing downstream touches a closed
  collection.

## Browse redesign (2026-08, browse-redesign-spec.md, branch local/browse-redesign)

- **Decisions**: Browse = 5th tab/section everywhere (fills old Settings slot);
  Settings lives in the profile menu → account menu with Settings/Manage
  Profiles rows — on ALL root screens (settings row later moved per entry-v2); hybrid row rendering (native themeable
  content columns + engine BrowserRowForId for numeric/FSRS); sorting ALWAYS
  engine-side via SearchOrder.builtin (page-window sort bug class banned);
  semantic search = fallback-suggestion UX phase one (shared AmgiEmbeddings
  target extracted from AmgiIcons, index per-device outside sync);
  duplicates = rslib aux RPC + cosine near-dupes in one dialog.
- **Method-ID oracle**: `_backend_generated.py` holds literal `(svc, method)`
  pairs; ids = declaration order, BackendSchedulerService declares its own
  rpcs so scheduler collection-level methods shift +3. Audited values:
  BuryOrSuspendCards=14, RestoreBuriedAndSuspended=12, SetDueDate=19,
  GradeNow=20, SortCards=21; search BuildSearchString=0 …BrowserRowForId=7,
  SetActiveBrowserColumns=8; cards UpdateCards=1/SetDeck=3; collectionOps
  redo=9. FIXED drift: DeckConfigMethod.getRetentionWorkload was 11, really
  **9** (latent production bug). CLAUDE.md index rows corrected too.
- **Service-ID shift from upstream Github+I18n insertion (2026-09, stats
  empty on device)**: upstream added GithubService(33) + I18nService(35)
  after the catalog was written, shifting every later service by 2 —
  imageOcclusion 35→37, importExport 37→39, media 39→41, stats 41→43,
  tags 43→45 (method IDs inside each service were all correct).
  `graphs` dispatched to MediaService/trash_media_files and protobuf
  decoded the wrong response as empty charts — success with all zeros,
  which is why the Stats tab showed flat charts with no error on a
  collection with full history. Same silent misdispatch affected tags,
  media check, export, and image occlusion. Caught by a new behavioral
  probe (`GraphsEngineProbesTests`: graphs on scratch cards must show
  card counts; answered cards must show today/reviews) — failed pre-fix,
  green post-fix. Oracle re-verified for all services; pre-29 IDs
  confirmed correct (sync 1, scheduler 13, notes 25, cardRendering 27,
  search 29).
- **Aux service pattern**: anki-bridge-rs `AnkiAuxSvc` id 200 intercepted in
  anki_run_method before engine dispatch; JSON wire format both sides;
  findDupesExact composes only PUBLIC engine rpcs (with_col is crate-private)
  mirroring desktop find_dupes incl strip_html grouping. Adding methods needs
  xcframework rebuild but zero proto regen.
- **Engine behaviors asserted by probes** (BrowseEngineProbesTests, live
  scratch collection): BrowserRowForId FAILS "Active browser columns not
  set" until SetActiveBrowserColumns runs (UI must activate keys before first
  render); AND-joined search text is space-separated (no literal AND);
  column keys are strum serializations noteCrt/noteFld/noteTags/note/
  cardDue/cardEase/cardIvl/cardReps/cardLapses; user-bury queues < -1,
  suspend -1; UndoStatus carries label strings for dynamic toolbar titles.

- **Entry-point v2 + chrome + export (2026-08, supersedes the drill-in
  wording above)**: NO browse buttons anywhere — search IS browse. Section
  icon = magnifyingglass. Library = four-glyph exception (Sync · Import ·
  Export · New Deck) plus native iOS 26 minimized search
  (.searchToolbarBehavior(.minimized), attach AFTER .searchable; iPhone-only
  pill idiom, iPad/Mac render standard fields automatically) funneling live
  into Browse via RootSearchHandoff debounce (Shared/CollectionChrome.swift).
  Read: books-scoped search, same modifier, no Browse handoff. Study:
  hidden-bar iPhone uses header magnifyingglass → `due:today` scoped launch;
  Mac hosts a real toolbar field with identical scope. DeckDetail menu row
  dropped ("rely on context"). Trailing chrome standardized Undo · Sync · ⋯
  (EngineUndoMonitor = engine stack mirror refreshed on store generation;
  Sync posts .amgiPresentSync) — Library exempted by user fiat.
  ExportPackagesSheet: .colpkg via exportCollectionPackage / .apkg via
  exportDeckPackage(deckId,path,sched,cfg,media,legacy=false), tmp file +
  ShareLink; opened from Library's Export glyph. Semantic fallback gated on
  searchTextIsPlainFreeText (no structural prefixes) so scoped queries stay
  clean.

- CardClient un-stubbed: fetchByNote = nid: search + per-card getCard
  (no batch getCards upstream), save via UpdateCards(5/1), batch surface
  suspendCards/buryUserCards/restoreBuriedAndSuspended/setDueDate/gradeNow/
  repositionCards/changeDeck added for Browse selection bar.

- **Phases 3-6 shipped (2026-08)**: Filter rail as sheet w/ desktop AND/OR/
  Negate context-menu semantics; SavedSearchStore on col.conf
  "savedFilters" (desktop-compatible sync). BrowseDetailTabs inspector
  (Edit/Preview/CardWebView-renderer Preview/Info); macOS .inspector host,
  others sheet. TextEmbedder public actor inside AmgiIcons package — spec's
  separate-target extraction amended away to preserve the mlmodelc fetch/
  gitignore contract; one resident engine shared with IconSuggester.
  SemanticNoteIndex: <profile>/semantic-index.json, per-device, corpus cap
  2000, fnv1a staleness, cosine fallback ("Search meaning of…") when the
  grammar path is empty + near-dupe clusters >=0.95 into FindDuplicatesView
  alongside exact aux RPC groups. NoteEditorModel csum now FNV-1a
  (hashValue never matched engine dupe expectations).
- **Build-through gotchas (2026-08, xcodegen+Xcode 26.5)**: (a) new source
  files need `xcodegen generate` BEFORE BuildProject sees them ("cannot find
  X in scope" storm otherwise); (b) under -explicit-module-build a brand-new
  file importing local SPM package AmgiIcons reported "No such module" while
  long-standing importers compiled fine — workaround = bridge through an
  existing importer file (NoteEmbedderBridge in Shared/); revisit if
  toolchain changes; (c) ToolbarContentBuilder.buildBlock caps at 10 items —
  consolidate via ToolbarItemGroup; (d) StudyLandingContent went generic for
  headerAccessory, so its State enum moved to file scope (StudyLandingState)
  with typealias back-compat.

## Browse structure v3 — one split view, search only in Browse (2026-09)

- **Root cause of the "ugly, disorganised" Browse**: it was a 3-column
  `NavigationSplitView` mounted INSIDE the root `NavigationSplitView`'s detail
  column, with a `NavigationStack` wrapped around each of its own three
  columns. Four nested columns in one window ⇒ the notes list collapsed to a
  ~165pt empty sliver, toolbar items rendered above whichever column SwiftUI
  chose (sort/emoji cluster landed over the deck tree; Notes/Cards + undo +
  sync + ⋯ + ＋ + search piled up over the detail pane). **Rule: never nest a
  NavigationSplitView inside another one.** Mail has exactly three columns and
  so do we.
- **macOS = window takeover**: `MainTabView` forks — `selection == .browse`
  renders `BrowseView` directly instead of the root split view, so Browse's
  own sidebar REPLACES Library/Read/Study/Stats. Way back = `BrowseExit`
  (title + icon + action) rendered as a `.selectionDisabled()` header row at
  the top of Browse's sidebar; `previousSection` is tracked in an
  `.onChange(of: selection)` so ⌘1–5, sidebar clicks and deep links all feed
  it. iOS keeps `Tab(role: .search)` and the split view collapses natively
  (sources → list → detail); the manual `columnVisibility` poking is gone.
- **Search lives ONLY in Browse** (supersedes the entry-point-v2 entry above):
  deleted `NotesSearchFieldModifier`, `SearchSectionView`,
  `RootSearchResultsView` and the already-dead `RootSearchHandoff` from
  Shared/CollectionChrome.swift, plus the never-called
  `TrailingChromeModifier`/`trailingChrome()`. Library/Study/Stats carry no
  notes-search field at all. Read's book filter and the in-sheet pickers
  (Change Deck, icon picker, notetype/template fields) stay — they filter a
  local list, they are not collection search. Only ONE `.searchable` per
  window now exists, so the NSToolbar double-searchable crash can't recur; it
  is attached to the LIST column's stack (Mail's placement), not the split view.
- **One selection model**: `BrowseSource { allDecks, deck, tag, saved }`
  replaces the `parentDeck`/`activeDeck`/`activeTag` triple. Previously decks
  used a `DeckID?` List binding while tags wrote `model.activeTag` directly
  (so tags never highlighted) and saved searches just assigned `searchText`.
  `buildQuery()` switches on the source; `.saved` injects its stored query
  wrapped in parens. `activeDeck`/`activeTag` survive as computed accessors.
- **Deck tree is collapsible**, default COLLAPSED (desktop Anki parity),
  expansion persisted in `@AppStorage("browse.sidebar.expandedDecks")` as a
  newline-joined name list. Rendered as a FLAT list of visible rows with
  manual chevrons + depth padding rather than `DisclosureGroup`, so every row
  stays a plain selectable `List` row (predictable native selection and
  compact-width push). Orphaned subdecks attach to their nearest EXISTING
  ancestor. A free-text query force-expands the tree so hits are reachable.
- **Empty middle column fixed**: unscoped browse with no text used to compose
  the empty query string and render a placeholder. `buildQuery()` now falls
  back to `deck:*` (same fragment the semantic corpus build uses), and
  `resolveResultDecks()` keys off the TYPED text rather than the composed
  query so it doesn't sample 240 cards on every idle browse.
- **Selection is platform-shaped**: macOS `List(selection: Set<Int64>)` with
  ⌘/⇧-click — a lone click is a peek (publishes NO batch scope, or Find &
  Replace would silently narrow from "all loaded results" to that one note),
  >1 arms the batch bar via `BrowseSelectionState.showsBatchActions`. iOS uses
  single-selection to drive the collapsed push, long-press for select mode.
  Mode + sort + result count moved OUT of the toolbar into the list column's
  own header bar (`.principal` was the reason the picker floated over the
  wrong pane, and it was duplicated inside the sort menu).
- **Cards mode now drives the inspector**: focus is held as whole records
  (`focusedNote`/`focusedCard`) instead of ids into `noteRecords`/
  `cardRecords`, because `performSearch` prunes those dicts to the current
  result set — and the counterpart record is never in the active id space.
- **Bugs found while refactoring**: (a) `runSemanticFallback` bound its
  neighbor ids to a LOCAL `matches` that shadowed `ids`, so the fallback
  re-hydrated the previous empty window and showed nothing; (b)
  `SavedSearchStore` had `@ObservationIgnored` but no `@Observable`, and
  nothing called `refresh()` at startup, so saved searches never appeared;
  (c) `loadHistory()` was private and never called, so search suggestions
  were empty on every fresh launch. All three fixed.
- **DesignConformanceTests is GREEN (2026-09)**: the 26 pre-existing
  offenders were fixed (palette/amgiFont/AmgiRadius adoption across 13
  files) plus one justified `permanentlyExempt` entry for
  Widgets/SmallWidgetView.swift (palette.positive-derived completion glow;
  widget target can't use the app-target amgiChromeShadow). The scanner
  reports first-match-per-pattern per file, so fix EVERY occurrence in a
  flagged file, not just the reported lines.
- **Verification note**: Xcode MCP was unavailable, so builds went through
  `xcodebuild`. `-destination 'generic/platform=iOS Simulator'` FAILS at link
  time — it builds arm64 + x86_64 and the Rust xcframework's simulator slice
  is arm64-only; pass `ARCHS=arm64` or name a concrete simulator. macOS
  `test` runs natively since 2026-09: `TEST_HOST` + `LD_RUNPATH_SEARCH_PATHS`
  carry `[sdk=macosx*]` variants (Contents/MacOS executable, ../Frameworks
  runpaths) in project.yml. 94/94 AmgiAppTests pass on both `platform=macOS`
  and iOS Simulator.
- **macOS tests share the login keychain with the real app** (KeychainHelper
  service derives from the host bundle id): SyncCoordinatorTests
  snapshot/restore ambient credentials around a staged `test.invalid`
  endpoint, and CollectionStoreTests scope a neutered syncCoordinator, so a
  real endpoint can never fire the live auto-sync debounce into an unstubbed
  client (and signOut tests can't wipe real credentials).

## Browse compact Search tab (2026-09)

- **iPhone is a NavigationStack, not a collapsed split view.** `Tab(role:
  .search)` only morphs the tab-bar magnifying-glass circle into a bottom
  search pill when the tab's root is a `NavigationStack` with `.searchable`
  and **no** `placement:`. The previous compact path showed the split-view
  sidebar first, so the only `.searchable` (on the list column) was
  off-screen and the morph never fired. `BrowseView` now forks on
  `horizontalSizeClass`: compact → `BrowseLandingView` in a stack; regular
  → the three-column split unchanged.
- **Platform search matrix**:
  - iPhone (compact): tab-bar pill, large "Search" title, `.accountMenu()`
    at default leading placement. `searchToolbarBehavior(.minimize)` is
    **off** this path (it targets toolbar search, not tab search).
  - iPad (regular): three-column split; field floats top-trailing (iPadOS
    26) via existing `.searchable(placement:)` + `searchMinimizedIfAvailable`.
  - macOS: always-expanded Mail-style field in the list column toolbar.
    `searchToolbarBehavior` is documented for macOS 26; we do not opt in
    (Anki Desktop / Mail parity). The earlier "annotation missing on macOS"
    comment was stale.
- **Landing states**: idle = quick-filter capsules (`today().prefix(3)` +
  `cardStates()`) plus inset-grouped Decks / Tags / Saved Searches (plain
  `Button`s, no `List(selection:)` — that was the grey full-bleed slab);
  focused-empty = Recent Searches + Clear (`BrowseModel.clearSearchHistory`)
  plus Saved Searches; non-empty query = `BrowseListColumn` in place.
  Deck-tree flattening lives in `BrowseDeckTree`, sharing
  `@AppStorage("browse.sidebar.expandedDecks")` with the sidebar.
- **Tab bar**: `.tabBarMinimizeBehavior(.onScrollDown)` availability-gated
  to iOS 26 on the root `TabView`. If the morph fails because `BrowseView`
  sits between `Tab` and the stack, inline the compact stack into the
  search tab (plan fallback). `.task { await appear() }` and the
  `searchText` debounce hang off the shared `BrowseView` body so both
  layouts get deep-link seeds and typed search.

## RenderPreview spawns a REAL app instance (2026-08)

- Calling MCP `RenderPreview` on this project boots the actual app binary
  from DerivedData via PreviewShellMac — including `AmgiAppApp.init`'s
  `prepareDependencies` + `openCollection` on the REAL group-container
  collection. A timed-out/abandoned preview therefore leaves an invisible
  Amgi clone holding the engine lock + `mcp.sock`, and the user's next real
  launch shows the "Amgi is busy" screen. Symptom signature: lsof shows a
  `DerivedData/.../Debug/AmgiApp.app` process with `-NSDocumentRevisions
  DebugMode YES`. Fix: `kill <pid>`, user retries. Rule: prefer not to
  RenderPreview root/app-init views; if one times out, check and kill the
  preview agent before anything else.

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

## Review card rendering

- **MathJax loader sentinel (fixed 2026-08)**: `amgiEnsureMathJaxReady` in
  `CardWebViewBridge.js` used to cache its promise and only clear it on throw,
  but the normal failure paths RESOLVE — one slow/failed first load (1.3 MB
  core + cold WebContent) disabled math for the whole session. Now: sentinel
  resets whenever the load doesn't succeed, MathJax warms eagerly at frame-page
  load, budget raised 1500→4000 ms, typesetting happens after visibility
  restore so a hung load shows raw TeX instead of a blank card.
- **Native card reveal perf**: `NativeCardView` no longer decodes media images
  synchronously in `body` (`NativeMediaImageCache`, CGImage thumbnails ≤2048px,
  decode off-main, NSCache); `FlipContainer` builds both sides up-front in a
  ZStack (opacity cross-dissolve, no identity swap) so back-side construction
  is off the animation's critical path; `NativeCardView: Equatable` +
  `.equatable()` at call site stops unrelated session-field invalidations from
  re-running body. Diagnostic logs: `[NativeCard] image … ready`,
  `[FlipContainer] back committed`, `[CardWebView][diag] mathjax-*`,
  `[CardAssetScheme] serving/unresolvable asset`.

## macOS app groups — TWO IDs required (fixed 2026-08)

The macOS app must be entitled to BOTH group IDs in `AmgiApp-macOS.entitlements`:
- `39557WW39R.group.com.bagumamartin.AmgiApp` (via `$(APP_GROUP_IDENTIFIER)`
  sdk=macosx* override) — widget snapshots + shared defaults
  (`AppGroup.identifier`).
- `group.com.bagumamartin.AmgiApp` (literal) — canonical collection root
  (`CollectionLayout.macGroupAnkiCollectionRoot`), shared with the unsandboxed
  amgi-mcp helper. The live collection.anki2 lives in THIS container.

Listing only one breaks the other half: prefixed-only → SQLite CannotOpen(14)
on collection open → "Amgi is busy" screen; unprefixed-only → widget snapshot
writes fail EPERM (Code=513) and cfprefsd detaches the defaults suite. The
entitlements file must never collapse back to a single ID.

## Review screen macOS update loop (fixed 2026-08)

`ReviewContent`'s `.focusedSceneValue(\.reviewActions, …)` allocated a NEW
`ReviewActions` struct of closures on every body evaluation. SwiftUI treats
each write as a change → scene/menu rebuild → body re-eval → new struct →
loop: hundreds of body evals/sec saturating the main thread, delaying every
card reveal (native ~250–1000 ms, HTML slightly) — macOS-only, because the
modifier is `#if os(macOS)` (iOS was instant). Log signature: endless
`[ReviewCardArea] body built` + "FocusedValue update tried to update multiple
times per frame". Fix: `ReviewActions` is now a stable CLASS instance in
`@State`, closures rebound once in `onAppear`; writing the same reference is
a no-op for change detection. Rule: focused-value payloads must have stable
identity across renders — never construct them inline in `body`.

## Review undo + hardware shortcuts (fixed 2026-09)

⌘Z on Mac went nil once WKWebView became first responder, so Edit → Undo
died after one step or while the card was revealed. Xcode 26 removed
`@FocusedSceneValue` / `FocusedSceneValues`; the replacement is an
`@Observable` `ReviewActions` published with `.focusedSceneValue(reviewActions)`
and read from commands with `@FocusedValue(ReviewActions.self)`. Card
WKWebView declines first-responder / passes ⌘Z through. Session undo pops
at most `extraEngineOpsAfter+1+2` engine ops and **redoes** them if the
card didn't restore — the old 20-pop loop ate earlier answers. Space/ratings
go through `.onKeyPress` which consumes `.repeat` so a held Space can't
flash the deck (a tap on the back still repeats the last rating). iPad
arrow-key ratings: recorded `U+F700` must map to `KeyEquivalent.upArrow`;
the focus engine steals arrows from `.keyboardShortcut` on the rating buttons.

## Native card typography — uniform, no invented hierarchy (2026-08)

User directive: the renderer must NOT invent typography. All their cards are
plain text; the old "first text block = headword" heuristic (48/34pt first
line) misled on list cards (e.g. a 6-drug list where line 1 looked like a
heading). Rules now, identical on iOS/iPadOS/macOS:
- Front: ALL text blocks 32pt semibold serif.
- Back: recap (front-side text, before the divider) 22pt SEMIBOLD — header-like,
  per user's explicit preference; answer 20pt regular.
- Only user-authored inline markup (<b>/<i>) adds emphasis. No
  minimumScaleFactor shrink; long lines wrap.
- Recap/answer split: real <hr> is authoritative; when the template lacks one
  (user's hand-made templates do), synthesize the split by matching the
  front side's normalized plain text as a prefix of the back's
  (`NativeCardContent.answerStartIndex(front:)`); nil → whole side is answer.
- FlipContainer equalizes both sides' card height to the taller side
  (Front/BackCardNaturalHeightKey → `\.nativeCardMinHeight` environment), so
  flips don't jump geometrically. Height is measured on the inner VStack,
  outside the minHeight application, to avoid a feedback loop.

## Widget-click window reuse (2026-08)

`widgetURL(amgi://study)` taps opened a NEW main window on every click —
SwiftUI macOS delivers external events to a `WindowGroup` by spawning a
window before `onOpenURL` runs (known behavior; SO 66647052). Fix is the
two-part `handlesExternalEvents` recipe in AmgiAppApp:
- Root view: `.handlesExternalEvents(preferring: ["study"], allowing: ["*"])`
  → an existing main window claims the event (activated + navigated in place).
- Scene: `.handlesExternalEvents(matching: ["study"])` → creates a window only
  when none exists.
The "study" string matches the URL's path component (`amgi://study`). The
AppDelegate second-instance guard (DerivedData vs /Applications copies) stays.

## Review context dots + repeat-last-rating action (2026-08)

- Title-bar context dots (principal toolbar item, both platforms): state dot
  (new/learning/review/relearning via `CardReviewState` from card `type`) +
  rating dot (last revlog rating; never-reviewed → new-state hue). Dots only,
  no text; hairline ring for tinted-chrome visibility. Rating dot is tappable
  = repeat last rating; dims while the answer isn't showing.
- `ReviewShortcutAction.repeatLastRating` (default Space) is the 10th
  rebindable action; the hidden zero-size button uses its binding. It and
  revealAnswer (also Space by default) never coexist — reveal is active only
  while the answer is hidden, repeat only while showing.

## Review window title + appearance (2026-08)

- macOS review title: plain left-leaning `navigationTitle`, breadcrumb
  "Parent › Child" (engine's `::` replaced); NO principal toolbar item —
  macOS 26 wraps principal items in a Liquid Glass pill.
- iOS/iPad title: `.topBarLeading` (left-leaning), no deck-tone dot; deck
  name (parent) gets `.bodyEmphasis`, subdeck leaf gets `.micro` — swapped
  from the old sizes per user preference. Top-level decks (no parent) keep
  the big font.
- Context dots (state + last rating) live in the DailyProgressBar header
  center via its `center` @ViewBuilder slot (ZStack header so they sit at the
  true bar midpoint).
- **Stale-chrome bug**: `cardChromeColor/isDark` were never reset between
  cards — an HTML card's dark chrome pinned `contentPalette` (auto-match →
  `palette(forExplicitScheme:)`) for all later native cards, so the window
  ignored system light/dark. Fix: reset both in `advanceToNextCard`; WebView
  re-reports per card.

## Revlog ease vs button (2026-08)

`CardStats`'s `StatsRevlogEntry.ease` is the ease FACTOR (e.g. 2500), not the
pressed button — upstream populates it from `RevlogEntry.ease_factor`. The
pressed button is `button_chosen`. Any "last rating" logic must read
`buttonChosen` (walking backwards past button-0 entries from manual
reschedules), never `ease`.

## Trailing chrome — Undo · Sync · ⋯ (2026-09)

- **Review undo is session-wired**: the review trailing group is Undo ·
  Sync · plain `ellipsis`. The glyph calls `ReviewSession.undo()` (answer
  stack + queue restore), not `EngineUndoButton` / `cardClient.undoLast()`.
  Overflow no longer duplicates Undo. `CardContextMenu` takes `title:`
  "More actions" so the nested Suspend/Bury/Forget row is not a bare
  ellipsis; Browse rows keep the icon-only trigger.
- **Engine undo stays on collection screens**: Browse and Deck Detail keep
  `EngineUndoButton` (engine stack mirror: delete notes, etc.). The
  chrome-branch claim "undo is review-only" applied to a tree that did not
  yet have `EngineUndoMonitor`.
- **Sync is the ubiquitous tool-group glyph** (`SyncToolbarButton` posts
  `.amgiPresentSync`). Review, Deck Detail, Browse, Stats, and Read all
  carry it — Browse especially, because on Mac it takes over the window
  and Library's sync cluster is not on screen. Library keeps its existing
  Sync · Import cluster (plus New Deck) rather than collapsing to the
  three-glyph pill.
