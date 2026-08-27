# Browse Redesign Spec

Status: approved plan (2026-08 session). Branch `local/browse-redesign` off
`local/disable-watchos-build`. Amendments arrive as short instructions appended
to §10; assumptions that break against measured reality get flagged here rather
than silently absorbed.

Source material: `ankitects/anki` qt/aqt/browser/{browser.py, sidebar/tree.py,
table/model.py, card_info.py, find_duplicates.py} + rslib browser_table.rs,
audited 2026-08. Verified engine facts live in §4.1 and are considered data,
not conjecture.

## 1. Locked decisions

| # | Decision |
|---|---|
| D1 | Entry: Browse becomes the fifth top-level section/tab on every platform (fills the slot Settings vacates). Library toolbar pill + deck-row context-menu + DeckDetailView action remain as drill-ins, all prefilling a `deck:` token. Deep link `amgi://browse?deck=N`. Standalone macOS browse window deferred (D-later). |
| D2 | Settings relocation: `ProfilePickerMenu` evolves into an account menu (profiles section unchanged + "Settings…" row pushing existing `SettingsRoute` stack + "Manage Profiles…" row). **The account menu appears on ALL root screens** (Library, Read, Study, Stats, Browse), not just Library — implemented once as a shared modifier wrapping the picker so placement stays uniform. iPadOS 26+/macOS additionally expose the Settings scene/menu-bar entry. |
| D3 | Rendering: hybrid. Content columns rendered natively from hydrated records (themeable state dots, flag chips, due pills, tag chips); numeric/format-sensitive columns served by engine `BrowserRowForId` (ease, interval, lapses, reps, card counts, timestamps, original position, FSRS S/D/R). Sorting always happens in-engine via `SearchRequest.SortOrder.builtin(column:, reverse:)` — never client-side page-window sorting. |
| D4 | Semantic search phase-one scope: fallback-suggestion UX in Browse only. When grammar search yields few/no results, offer "Search meaning of …" using the bundled multilingual-e5-small CoreML model. Corpus index built incrementally off note `mod`, stored per device outside sync. Extract `AmgiEmbeddings` target shared by AmgiIcons and Browse. |
| D5 | Duplicates: exact duplicates via a new small rslib-side capability in **our own** `anki-bridge-rs` crate (upstream ships no RPC — desktop does client-side SQL); fuzzy near-duplicates from the embedding cosine index shown alongside in the same dialog. |
| D6 | Mutations go through engine batch RPCs; undo/redo wired to the engine's undo stack; deletes become reversible (replacing today's "cannot be undone" copy). |

## 2. Current state (measured, not assumed)

Browse exists as a screen (`AmgiApp/Sources/Browse/`) with MVVM house style
(`@Observable @MainActor` models) but is **unreachable**:
`BrowseView(` has zero call sites; `DeckListView.swift:93-97` toolbar button is
a documented no-op TODO.

Known defects to fix while building (do not carry forward):

1. `Sources/AnkiClients/CardClient+Live.swift` stubs: `fetchByNote { _ in [] }`,
   `suspend`, `bury`, `save`, `undo` are silent no-ops → Browse suspend, row
   context menu, and note-card fanout all dead today.
2. Sort applies per 50-row page window after paging (`BrowseModel.sortedNotes`
   sorts hydrated window only); 5000-note hard cap; search fires per keystroke
   with no debounce/cancellation.
3. `NoteEditorModel.save` computes `csum` with Swift `String.hashValue` —
   must become Anki's FNV-based field checksum.
4. `BatchTagSheet` adds tags only; no removal path in bulk.
5. Editor lacks deck change / preview; single-row editing only.
6. ServiceCatalog drift (see §4.2).

Existing assets reused as-is: `RichNoteFieldEditor` (dual-host UITextView/
NSTextView, MathJax-preserving HTML round-trip), image-occlusion editors,
`NoteEditingDestinationView` routing, `CollectionStore` generation-keyed
refresh, `amgi://` external-events recipe in `AmgiAppApp`.

## 3. Desktop feature inventory (parity targets)

Three-pane layout (sidebar filter tree · table · editor), vertical/horizontal
splitter. Table with Cards↔Notes toggle; ~19 columns (question, answer, sort
field, tags, notetype, deck, due, ease, interval, lapses, card-mod, note-mod,
note-creation, reps, #cards, original position, FSRS stability/difficulty/
retrievability); engine-rendered cells with elide/RTL metadata; per-mode
column config persisted engine-side. Sidebar stages: Saved Searches,
Today (due/added/edited/studied today, first review, rescheduled, again today,
overdue), Card State (new/learn/review/suspended/buried), Flags (renamable),
Decks (+current, filtered glyphs), Notetypes (children: templates AND fields),
Tags (hierarchical, untagged). Click composition: replace / Alt=negate /
Ctrl=AND / Shift=OR; drag-drop reparent decks/tags, save searches by drop;
inline rename/delete with propagation. Selection actions: undo/redo, select
notes-as-search, invert, tag± , clear unused tags, toggle mark, change
notetype, change deck, delete, export, reposition, set due date, grade now,
forget, suspend/bury toggles, flags 0–7 (click active clears). Editor pane +
previewer + card info (revlog + FSRS charts). Power tools: find & replace,
find duplicates. Search history (30 entries).

Anything not listed above is out of scope until requested.

## 4. Architecture

### 4.1 Bridge additions — verified method IDs

Ground truth mechanism: method id = position of the rpc among services of the
same proto descriptor set (backend-block declarations first, then collection-
level ones offset by the backend block size — scheduler is +3). Literal pairs
are inspectable in `anki-upstream/out/pylib/anki/_backend_generated.py`. After
any anki-upstream update, diff that file before trusting constants.

New Request factories in `AnkiProtoBridge/Requests/`:

| Factory | Service | Method | Req→Resp |
|---|---|---|---|
| buildSearchString(SearchNode) | search(29) | 0 | SearchNode→String |
| joinSearchNodes(joiner,[nodes]) | 29 | 3 | JoinSearchNodesRequest→String |
| replaceSearchNode(prev,repl) | 29 | 4 | →String |
| findAndReplace(search,replace,repl,regex?,field?) | 29 | 5 | →OpChangesWithCount |
| allBrowserColumns() | 29 | 6 | Empty→BrowserColumns |
| browserRowForId(id) | 29 | 7 | Int64→BrowserRow |
| setActiveBrowserColumns([keys]) | 29 | 8 | StringList→Empty |
| buryOrSuspendCards(cardIds/noteIds,mode .suspend/.burySched/.buryUser) | scheduler(13) | 14 | →OpChanges |
| setDueDate(cardIds,daysIntervalText) | 13 | 19 | SetDueDateRequest→OpChanges |
| gradeNow(cardIds,rating) | 13 | 20 | →OpChanges |
| sortCards(cardIds,start,step,randomize,shift) | 13 | 21 | →OpChangesWithCount |
| redo() | collection(3) | Redo | OpChangesAfterUndo |

Already present, newly consumed: `setDeck`(cards 5/3), `updateCards`(5/1),
`undoLastAction`/`hasUndoableAction`, `scheduleCardsAsNew`, `removeCards`,
`setFlag`, `searchCardIds`.

### 4.2 Catalog repair

- Fix `DeckConfigMethod.getRetentionWorkload`: 11 → **9** (upstream literal
  `(11,9)`; currently latent breakage).
- Correct stale CLAUDE.md service-index rows (search 0=BuildSearchString/1=
  SearchCards/2=SearchNotes; notes GetNote=6) so future sessions stop
  inheriting bad constants.
- Every NEW factory gets a behavioral probe before UI wiring (§8).

### 4.3 Find-duplicates capability (D5)

Upstream implements dupes purely client-side (pylib SQL grouping of
`build_search_string(search, SearchNode(field_name=…))` hits by csum across
non-first fields). Our engine is a black box, so we add the logic inside OUR
crate `anki-bridge-rs`: a pseudo-service (aux id 200, name `AmgiAuxSvc`)
intercepted by the top-level request router BEFORE delegating unknown ids to
the generated engine dispatch. Stable four-symbol C ABI untouched; zero
edits to vendored anki-upstream; one XCFramework rebuild required.

Methods: aux 0 `findDupesExact(search_text, field_name) -> {value:
[note_ids]}` mirroring desktop semantics (group by first-field-or-target-field
checksum, exclude ids themselves appearing in other groups' fields — port the
exact upstream SQL so results match desktop byte-for-byte).

Later aux tenants (reserved namespace, same dispatch): semantic index ops if
the embedding index ever moves off-device-native storage, FSRS bulk tools.

### 4.4 CardClient un-stubbing

`fetchByNote` becomes `searchCardIds("nid:\(id)")` (batch-safe variant can use
one OR-chained query per selection). Implement real `suspend`/`unsuspend`,
`bury`/`unbury` via buryOrSuspend; wire `save` to updateCards. `undo(cardId)`
remains scoped to global undo plumbing (Review path unaffected).

### 4.5 Hybrid rendering contract

`BrowseColumn` enum mirrors engine column keys. Native provider covers:
sortField/question, deck, notetype, tags, cardState, flag, due (from hydrated
card records). Engine provider covers everything else lazily per visible row,
cached per `CollectionStore` generation, invalidated alongside native caches.
Column availability differs cards vs notes mode like desktop defaults.
FSRS columns render plain text from `BrowserRow`; they may later gain a theme
accent, never a reimplementation.

### 4.6 AmgiEmbeddings extraction (D4)

New sibling package target consuming the bundled `.mlmodelc` + tokenizer,
moving load/tokenize/run/normalize out of AmgiIcons (which then depends on it)
so Browse shares ONE resident model instance. Public surface: embed(texts:[String],
prefix: .query/.passage) async throws -> [[Float]] (384-dim L2-normalized),
model warmup, device hints (Neural Engine batching). Index: flat binary +
sidecar metadata keyed by NoteID, cosine via vDSP brute force (adequate ≤50k
notes; revisit ANN only when measured need exists). Prefix handling audited
against the icon pipeline (e5 expects "query:"/"passage:"; icon labels likely
omitted them harmlessly — retrieval cares). Storage under app group root
NOT in col.conf (whole-blob last-write-wins sync would thrash). Initial build
is a background job (BGProcessingTask/iOS, idle/macOS), thermal-aware.

## 5. UI design

### 5.1 Entry points

- Root spine grows to five sections everywhere: Library · Read · Study ·
  Stats · **Browse** (tail position — maintenance weight; study loop stays
  front-loaded). iPhone: bottom tab. iPad/iPadOS26+/macOS: sidebar item.
- Drill-ins prefill tokens: Library toolbar pill (empty), deck-row context
  menu "Browse Cards", DeckDetailView header action — both insert
  `deck:"<name>"`.
- Deep links: `amgi://browse`, `amgi://browse?deck=N`; route through the
  existing `handlesExternalEvents` pattern.

### 5.2 Account menu (D2)

Shared modifier (e.g. `.accountMenu()` installing `ProfilePickerMenu`-based
control into each root's toolbar leading edge). Menu sections: profiles
(existing behavior incl. pending-switch badge) → separator → Settings…
(gearshape, pushes `SettingsView` onto local stack) → Manage Profiles…
(macOS: inert duplicates of menu-bar behavior may be hidden). All five roots
adopt it.

### 5.3 Shell

- iPhone: NavigationStack list w/ `.searchable(tokens:)`; detail pushed;
  sheets use presentationDetents; long-press select mode like Mail.
- iPad/macOS: NavigationSplitView(sidebar, content) + trailing
  `.inspector(isPresented:)` hosting three tabs: Edit / Preview / Info.
  macOS keeps left-leaning titles; no principal-item pills (known wrap bug).

### 5.4 Search

Tokens first: tapping filter-rail entries inserts/removes structured chips.
Raw grammar remains primary power path (validated via buildSearchString with
inline error). Composition gestures mirror desktop semantics where hardware
allows (⌥ negate, ⌃ AND, ⇧ OR on Mac keyboard) and land as context-menu
alternatives elsewhere (Combine > AND/OR/Negate). History capped 30, persisted
per profile.

### 5.5 Filter rail (sidebar)

Sections with collapse persistence (collection-config bool keys as desktop):
Saved Searches, Today, Card State, Flags, Decks, Notetypes(+templates+fields),
Tags. Source-list styling, flag colors themed from palette slots; per-deck
icons reuse DeckIconRendering. Mutations available: rename/delete decks &
tags (propagating), save/rename/update searches, untagged/no-flag nodes.

### 5.6 Rows

Two-line cell: title line = sfld/query question with inline HTML stripped
(native styling, Dynamic Type), caption = `Notetype · Tags` or mode-appropriate
subtitle; trailing accessory zone: state dot (palette cardState slots), flag
chip, due pill (tinted by due bucket). Engine-only columns render their text
in fixed-width numerals. Select mode swaps to checkmark affordances.

### 5.7 Selection operations

Bottom action bar (iOS compact) / toolbar menus (regular width): Tags… (add/
remove), Mark toggle, Flags grid (0–7, click-active-clears), Change Deck…,
Suspend/Bury toggles (state-aware), Forget, Grade Now (Again/Hard/Good/Easy),
Reposition…, Set Due Date… (preset chips + custom range), Delete (engine-backed
undo instead of dread copy), Find&Replace… (scoped). Undo/Redo buttons bound
to engine status with dynamic labels like desktop's undo tooltip text.

### 5.8 Inspector tabs

Edit: existing rich editor pipeline against single selection. Preview:
NativeCardView flip reuse (real renderer, real theme). Info: Swift Charts over
card_stats_data bridge — revlog strip, interval/ease history, FSRS trend,
next-state descriptions. Native beats desktop's webview cold-start cost.

### 5.9 Duplicates dialog

One sheet, two groups: Exact (aux findDupesExact; pick field, enter text,
report count+groups, tap-to-load nid:(…) search) and Near (cosine clusters ≥
0.95 within current scope; tap-through same way; optionally cluster-collapsed
subrows). Tag-all-duplicates preset action both sides.

## 6. Data & sync contracts

- Saved searches: collection config key `savedFilters` (desktop-compatible:
  cross-device via normal sync; desktop sees ours, vice versa).
- Column prefs: mirror into engine via setActiveBrowserColumns so a future
  desktop round-trip stays coherent; local SwiftUI persistence caches last.
- Embedding index + near-dupe cache: app-group filesystem, per device, never
  synced, rebuilt opportunistically; keyed invalidation on note mod bumps.
- Deck icons config conventions unchanged; account menu writes nothing new.

## 7. Phases

1. **Plumbing** — factories per §4.1, catalog repairs §4.2, CardClient
   un-stubbing, aux find-dupes in bridge-rs + xcframework rebuild + probes.
   Acceptance: probe suite green for every new (svc,method); swift build OK.
2. **Core screen** — reachable entries (D1/D2 incl. account menu on all roots),
   adaptive shell, token search bar, hybrid rows + upgraded hydration
   (infinite fetch-ahead, no 5000 cap, cancellation, debounce), cards/notes
   toggle, full selection bar + engine undo, deep links. Acceptance: feature-
   complete parity subset usable end-to-end; BuildProject green.
3. **Filter rail** — all seven sections, composition gestures, saved searches
   sync via `savedFilters`. Acceptance: sidebar-click modifies token set;
   sync survives desktop round-trip.
4. **Inspector** — edit/preview/info tabs wired to single selection; editor
   gains deck change + FNV csum fix.
5. **Semantic layer** — AmgiEmbeddings extraction, index build/maintenance
   jobs, fallback suggestion UI, near-dupe clusters into dialog.
6. **Polish** — shortcuts (stable-identity focused values), search history,
   export hook, density/theme audit incl. Minimal/Muted/Sepia, full VoiceOver
   pass, standalone macOS window if desired.

## 8. Verification protocol

- Behavioral probes precede UI wiring: send empty/minimal payloads for each
  new (svc,method) pair through amgi-mcp helper (`--dry-run` style) against
  scratch collection; assert typed responses, log schema mapping.
- Root package `swift build`/`swift test` on macOS IS the verification lane
  for AnkiProtoBridge/AnkiServices/AnkiClients changes (macOS slice).
- App target: Xcode MCP `BuildProject` only; xcodegen rerun resets run
  destination — apply osascript snippet afterwards (memory/preferences).
- Rust change ⇒ rebuild xcframework via scripts/build-xcframework.sh; rerun
  Swift tests; smoke-review one real card against rebuilt framework.
- After anki-upstream updates: regen protos, diff `_backend_generated.py`,
  reconcile catalog drift mechanically.

## 9. Risks & gotchas carried forward

- NonisolatedNonsendingByDefault + blocking FFI: every new client closure
  awaits async invoke or wraps in backendOffload (decisions.md rule).
- Method-ID shifts on any proto edit (scheduler +3 lesson); probes are the
  guard, `_backend_generated.py` the oracle.
- Deleting many notes while helpers hold the collection → launch busy screen
  interplay; long ops must tolerate retry loop.
- Widget/watch targets never link AmgiEmbeddings or Phosphor paths.
- Page-window sorting bug class: forbid client-side sorts in code review;
  engine order or bust.

## 10. Amendments

- 2026-08 (initial): account menu present on all root screens (was Library-
  only gear); FindDupes realized as anki-bridge-rs pseudo-service (upstream
  has none); scheduler/search/cards method IDs corrected post-audit;
  DeckConfig drift fix added.

- 2026-08 (implementation batch 2): TextEmbedder shipped as a public actor
  INSIDE the AmgiIcons package rather than a separate target — moving the
  CoreML resources would break the fetch script + gitignore contract from
  the deck-icons decision; both consumers share ONE resident engine, which
  was the actual goal. SemanticNoteIndex lives beside the profile folder
  (<profile>/semantic-index.json), cap 2000 notes, near-dupe threshold
  0.95. Filter rail ships as a sheet (phase-3 form); NavigationSplitView
  sidebar hosting remains an option for later. Inspector on macOS uses the
  .inspector pane; iPadOS wide layouts use the sheet pending width-tier
  conditionals. Info tab is native scheduling facts; full revlog history
  waits on engine-row columns. Find-dupes field picker lists fields of the
  first hydrated row's notetype.
