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
  Profiles rows — on ALL root screens; hybrid row rendering (native themeable
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
