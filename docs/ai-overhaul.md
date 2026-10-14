# AI and capture overhaul

Implementation and validation record, 14 October 2026. Work is in progress;
compilation and model parity are separate from UI and device acceptance.

## Product contract

- iPhone: Ask AI pill above the navigation pill, with a separate Quick Capture
  circle. Scrolling into content compacts the arrangement to navigation, AI and
  capture in one row; reverse scrolling and the left control expand navigation.
  The controls use native Liquid Glass. Scene code owns the coordination: the
  system's separated Search tab is not repurposed as a capture action.
- iPad and Mac: a compact floating Ask AI pill and separate capture circle in
  one bottom-right row, over content rather than in the sidebar or a full-width
  bottom bar. The assistant opens in a floating corner card; Mac supports card
  resizing. iPad retains native adaptive navigation and keyboard avoidance.
  Reader and Review expose a contextual assistant action.
- Quick Capture has exactly Camera and Text. It reuses the rich note fields in
  a separate draft. Each fresh session targets deck ID 1, including a renamed
  Default deck; a missing destination requires selection. Saving keeps capture
  open, clears the saved content and confirms the destination. Camera inserts
  media; it does not generate fields or run automatic OCR into the draft.
- Suggestions precede keyboard focus. Chats retain scope, draft and local
  history per profile. New chats inherit current screen context; resumed chats
  keep their saved scope until “Use current screen.” Closing stops generation
  and pending approvals. Commit receipts record writes that actually completed.
- Vendors sit behind the assistant provider boundary. Only the existing Apple
  Foundation Models provider is registered. No API credential, cloud model,
  ChatGPT sign-in or fictitious provider is added by this change.

## Versions and platform support

| Component | Pin / floor |
| --- | --- |
| ManifoldKit | Unmodified 0.79.0, `610c6a538da3e991eff88a510a1a804327974bca` |
| Main iOS/iPadOS and macOS app | 26.0 minimum |
| Watch | 11.0; assistant/MLX packages stay outside its target dependency graph |
| Native EmbeddingGemma2Swift source | `2c7815fc9e2f6d99df05b3cd259f6086ed65e9cc` |
| MLX Swift | 0.32.3 |
| Compatible model repository | `Nurymanau/EmbeddingGemma-2-MLX-Swift`, revision `06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd` |
| Source Google checkpoint | `914f7f89142e33e77833254d9c9b90c3cef7303b` |
| Weights | Text and vision Q8; audio BF16; BF16/FP32 activations; normalized 768-dimensional Float32 vectors |

Native source and license notices are in `Libraries/EmbeddingGemma2`. App-owned
changes add ordered mixed inputs, video placeholders and one complete tokenizer
envelope. Model identity includes weight revision, profiles, dimensions and
preprocessing revision. E5 vectors/tokenizers are not reused.

## Assistant execution

`AssistantRuntime` owns each window's Manifold bootstrap, chat and history view
models. Profile windows share a SwiftData container and versioned metadata.
Send, retry and deterministic turns take a per-chat lease. The sidecar stores
drafts, scopes, sources, timestamps, interruption state and deletion tombstones.
Saved source navigation binds to the current profile activation.

The small advertised tool catalog is `read_collection`, `change_collection` and
`open_app`. Typed adapters support note/card/deck/notetype/template operations.
Reads and navigation use existing services and scene routing. Sync/import/export
open their existing coordinated workflows; an opened workflow is not reported
as a completed operation.

`AssistantToolCatalog` is shared by all providers: ordinary JSON Schema, JSON
arguments, Manifold tool results and the same review/execution host. It has no
Foundation Models dependency. The Apple-only backend translates these schemas
and transcript entries to native Foundation Models formats. Native tool selection
only emits an intent into Manifold's dispatch loop; it cannot execute an app
mutation or authorize one. Completed calls/results replay as native transcript
entries to avoid repeated reads. Other backends keep their own wire formats and
use the identical catalog and approval gate. Provider-specific activity/privacy
copy also stays in the provider rather than being hardcoded into the surface.
Read operations use explicit list/get names and exclude write-only arguments.
Deck/notetype results expose JSON numeric IDs, including exact 64-bit values;
the shared contract is tested independently of any Apple model/session.
Writes use `fieldContents` for ordered question/answer contents, retaining
decoding of old persisted `fields` calls. Misplaced note content in the card-only
`value` parameter is rejected. Created-note results carry the actual backend ID
and the contents saved after review edits, so later model turns do not assume
the original draft was saved verbatim.

Every assistant collection change requires a fresh, single-use review. The user
can select targets and edit supported field drafts. The host snapshots profile
and target state, then revalidates under the backend lifecycle lock immediately
before synchronous typed RPCs. Concurrent edits invalidate the proposal. Active
review mutations are excluded. Partial tag batches report actual committed IDs;
cancellation after an RPC does not erase its outcome. Undo/redo use the backend's
existing undo stack, not fabricated app-local rollback.

## Retrieval and assets

- One serial MLX engine serves Browse, note comparison, icon suggestions and the
  assistant. Optional vision/audio modules load on demand. A bounded vector
  cache, a 64 MiB MLX transient cache and idle unloading limit residency.
- Downloads require module-specific consent. Pinned file lengths and SHA-256
  hashes are verified before an atomic module receipt is published. Interrupted
  transfers retain resume data. Existing E5 consent does not authorize Gemma
  downloads. At normal app startup, sanitation removes only recognized legacy
  E5 compiled-model folders and E5 partial-download artifacts from the current
  and known prior model-store locations; it preserves Gemma assets, retrieval
  indexes, and unrelated files.
- A per-profile SQLite store commits source metadata, vectors and FTS together.
  Model identity changes invalidate incompatible records. Source hashes and
  stable segment IDs permit resumed indexing. Pruning follows complete source
  scans, never a partial Browse window.
- The coordinator visits all note IDs, all fields/tags/deck names, owned Anki
  media and managed reader books/annotations. It does not crawl the Mac.
  Text passages overlap; PDF pages retain text/OCR and page anchors. Audio uses
  16 kHz mono windows of 30 seconds with a 25-second hop. Video samples every
  three seconds, skips near-duplicate frames and indexes its audio independently.
- Native ordered mixed inputs use a joint forward, not vector averaging.
  Search combines lexical rank with semantic rank standardized by modality.
  The current search implementation scans stored vectors; large-library latency
  and memory measurements remain a release gate.
- Settings exposes module downloads, indexing progress, persistent pause/resume
  and failed-source details. Low power mode and high temperature pause background
  indexing. Profile changes cancel indexing and fence collection reads/writes.

Only relevant DigUp ideas and synthetic fixtures are used. Reference revision:
`ARahim3/DigUp@f9b8106ffb8308b4f48b76149d270f7c2e6b4918` (MIT, AbdurRahim).
Its llama.cpp backend, filesystem crawler and global desktop controls are not
part of Ijuka. Fixture attribution is alongside the reference inputs in
`AmgiEmbeddings/Tests/AmgiEmbeddingsTests/Fixtures/DigUpReference`.

## Evidence so far

- Mac app and dedicated `AIOverhaul` test targets compile on Xcode 27.
- iPhone/iPad app compiles for the iOS device SDK. This does not establish an
  installed device run or minimum-OS runtime behavior.
- Focused offline tests passed for approval rejection/cancellation,
  stale targets, malformed field drafts, verified module manifests, E5 rejection,
  vector shape, SQLite persistence/pruning and sync behavior. A real Rust backend
  positive commit/stale-snapshot test also passes. The latest assistant suite
  passes 15 tests; the unchanged embedding/sync suites pass 8 / 22 offline tests
  (three download-dependent embedding tests are opt-in, separately exercised by
  native reference gates).
- A real native MLX run downloaded all pinned modules into an isolated temporary
  store and passed the full reference gate in 95.277 seconds including downloads.
  Cosine agreement against DigUp's llama.cpp reference vectors:

| Fixture | Agreement |
| --- | ---: |
| English / Bengali / Arabic query | 0.999790 / 0.999763 / 0.999847 |
| Document / long document | 0.999665 / 0.999711 |
| Screen, 280 soft tokens | 0.999739 |
| Photo, 140 soft tokens | 0.999234 |
| Frame, 70 soft tokens | 0.998509 |
| Audio | 0.999747 |

  The same run passed single-frame video equivalence, text-only mixed/ordinary
  encoding equivalence, finite mixed vectors and input-order sensitivity. These
  checks caught and corrected an EOS-before-content error; their thresholds were
  not weakened. They establish bounded cross-runtime parity, not real-library
  retrieval quality, multi-frame temporal understanding or device memory safety.
- A separate, collection-free test host passed the physical iPhone 15 Pro Max
  multimodal reference gate in 96.443 seconds including downloads. Text/image/
  audio agreements ranged from 0.998574 to 0.999850; a joint text, image, audio
  and timestamped frame returned a finite normalized 768-vector. MLX allocation
  peak was 1,648,172,416 bytes, not whole-process RSS. Cold first query including
  engine/JIT took 9.782 seconds; subsequent Arabic/Bengali fixtures took 0.090 /
  0.714 seconds. This is bounded fixture evidence, not sustained device safety.
- Isolated native Mac UI checks exercised real Apple text generation, restored
  a draft after reopening, and saved a rich two-field Quick Capture note into
  Default. Save cleared both fields, confirmed the destination and kept capture
  open. Native tool selection retrieved the actual Default deck; completed-call
  replay and the revised floating UI received follow-up checks. The revised Mac
  launcher has a 48-point capture circle beside the AI pill in the bottom-right
  corner. Its menu has exactly Camera/Text; the floating card opens/closes,
  restores drafts and resizes through an accessible handle. The iOS device SDK
  build passes; physical iPad UI geometry remains separate from its model gate.
- A live Apple-model turn performed list-notetypes, list-decks and get-notetype
  reads and reached an Add Note review in about 13 seconds. The draft confused
  field names with contents; review edits corrected both fields before saving.
  Exactly one corrected note persisted in the isolated collection and its due
  count rose from one to two. A repeated proposal was declined. This proves the
  reviewed execution path. A subsequent clean turn with the final fieldContents
  contract produced both requested field values exactly, without manual edits;
  Apply created note `1792004079642` in the isolated Default deck and returned
  its real ID plus saved contents. The final reply matched the saved note, with
  no repeated proposal; a read-only check after app closure confirmed both exact
  fields. A single successful draft is bounded evidence, not a broad model-quality
  evaluation. Readable tool-status labels use Manifold's public styling hook;
  provider-facing names and conversation records remain intact. A public
  per-part renderer preserves response line/paragraph breaks and inline
  emphasis/links; fenced code blocks retain Manifold's built-in renderer.
- The same collection-free host passed the physical M1 iPad reference/mixed
  gate in 87.809 seconds including downloads. Agreement ranged from 0.998560
  to 0.999847. MLX peak allocations were 1,955,453,875 bytes; cold first query
  took 9.288 seconds, then Arabic/Bengali fixtures took 0.415 / 0.077 seconds.
  The first attempt lost its audio-module download connection; the retry passed.
- Mac XCTest UI automation is currently unavailable: after reconstructing and
  verifying the temporary runner signature, XCTest times out while enabling
  automation mode. No security setting was changed. Cua window checks and
  physical-device validation must be recorded separately.

## Acceptance still required

1. Render and interact with the iPhone expanded/compact navigation states,
   manual expansion, capture menu and keyboard transitions; verify iPad/Mac
   geometry, Dynamic Type, Reduce Motion, VoiceOver and narrow windows.
2. Expand the live model task evaluation beyond the passing Mac note-creation
   flow; repeat stop/close, history, retry, profile switching, multiple windows,
   approved/declined writes and source opening across the supported devices.
3. Run sustained indexing on the user's iPhone/iPad/Mac; record whole-process
   memory, thermal response, latency and idle unload behavior beyond the bounded
   native reference gates already recorded above.
4. Validate retrieval ranking with representative text/image/audio/video and
   ordered mixed queries, multilingual study terms and exact lookup fixtures.
   Calibrate icon confidence and duplicate thresholds for the new model.
5. Complete richer EPUB media extraction, note/media joint context, grouped
   temporal video windows and transient query-attachment entry points. Standalone
   media indexing and the native mixed-input API do not replace those surfaces.
6. Extend the honest tool capability list only alongside concrete typed adapters
   and exact review/commit tests. Unsupported operations retain existing app
   workflows and must never be claimed as completed by the model.

## Reproduction

Use `AmgiAppMac` / `AmgiApp` with the `AIOverhaul` test plan. Cached builds use
`-disableAutomaticPackageResolution -skipPackageUpdates`. Network/model tests
are opt-in with `AMGI_E2E_MODEL_DOWNLOAD=1`; full modality reference tests also
require `AMGI_E2E_MEDIA=1`. Swift Testing method selectors include `()`.
Pass the variables to the test target's environment, not just xcodebuild's
parent shell. Check that a test actually ran before interpreting its exit code.

UI fixtures use `AMGI_UI_FIXTURE=<unique-id>`, `AMGI_IN_MEMORY_KEYCHAIN=1` and
`--ui-testing`. Their collection/reader/chat files live under the app's own temp
directory. Never install a QA build over the user's main app to prove this work.
