# AI and capture overhaul

Current implementation: 19 October 2026. Current regression checks and the
historical 14 October validation record are separated below. Historical results
do not validate the later assistant rewrite, cloud providers, or reader changes.
Compilation, model parity, and UI and device acceptance are separate checks.

## Product contract

- iPhone uses native tabs with an Ask AI and Quick Capture bottom accessory.
  iPad adapts between tabs and a sidebar; Mac uses split navigation. Wider
  screens show a floating Ask AI pill beside a separate capture circle.
  Readers hide the global entry and provide their own contextual action;
  Review also exposes Ask AI for the current card.
- Quick Capture offers Camera and Text and reuses the rich note editor in a
  separate draft. Each fresh session targets deck ID 1, including a renamed
  Default deck; a missing destination requires selection. Saving clears the
  saved content, confirms the destination, and keeps capture open. Camera
  inserts media rather than automatically generating card fields.
- Each assistant presentation starts a fresh chat; opening and closing without
  sending creates no empty history entry. History remains local per profile.
  Screen context becomes removable chips for a collection, deck, card, book,
  chapter, page, passage, or whole screen. Sending moves the chips onto that
  message; later turns retain them, and resumed chats restore saved contexts.
- Apple Intelligence runs on device. Optional ChatGPT sign-in, OpenAI API keys,
  and Claude API keys select cloud models through the provider settings. Keys
  and sign-in credentials live in Keychain. Image/PDF attachments require a
  cloud model; the chosen provider receives the prompt, attached contexts and
  files, conversation history, and relevant tool results. Availability and
  account limits require live provider validation.
- The assistant shows Swift-generated activity and completed-write results.
  Card creation and correction require editable review sheets before saving;
  closing or stopping interrupts generation and pending review.

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

`AssistantEngine` owns the turn loop, streaming replies, context chips,
attachments, review continuations, and history for a presentation. ManifoldKit
provides chat persistence and history, rather than running the tool loop.
`AssistantStore` shares a per-profile SwiftData container configured with
`cloudKitDatabase: .none`; its JSON sidecar stores contexts, activity, sources,
and per-turn model/file metadata. Reopened chats show file stubs and thumbnails;
original attachment bytes live only for the active session.

`AssistantToolbox` exposes task-shaped intents: `studyOverview`, `findNotes`,
`relatedCards`, `findGaps`, `makeFlashcards`, `openScreen`, and `fixThisCard`.
Swift resolves deck, note type, and field identities. Apple Foundation Models
uses native tool adapters; `AssistantCloudTools` describes and dispatches the
same intents for cloud models. `CloudConversation` builds provider-specific
requests and replays tool results during a bounded loop of up to eight rounds.
The old `read_collection` / `change_collection` / `open_app` catalog and
`AssistantRuntime` execution host have been removed.

Retrieval can target attached decks, books, chapters, or pages, or search the
whole collection. Related-card search excludes the attached card. Coverage-gap
results rank passages by their nearest-card similarity; this is a heuristic,
not proof that a concept is missing. Cloud turns about a whole book retrieve
relevant excerpts before generation. Source links and activity come from actual
tool results.

New cards and field corrections wait for the user's review. A declined proposal
cannot be repeated within the same turn. Correction commits check the collection
activation, note identity and contents, and ordered field names under the backend
lifecycle lock immediately before saving. A changed or deleted note or changed
field layout requires a new proposal. Only included fields are replaced; current
tags and untouched rich text are retained. `AssistantStep` records success only
after the backend write completes. These intents do not expose arbitrary
collection CRUD, sync, import, or export operations.

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
  Model identity changes invalidate incompatible records. Source fingerprints
  skip extraction and embedding for unchanged notes and files; stable segment
  IDs permit resumed indexing. Pruning follows complete source scans, never a
  partial Browse window. Moving a card alone does not update indexed deck-name
  text until the note changes; deck-scoped queries use current engine membership.
- The coordinator visits all note IDs, all fields/tags/deck names, owned Anki
  media and managed reader books/annotations. It does not crawl the Mac.
  Text passages overlap; PDF pages retain text/OCR and page anchors. Audio uses
  16 kHz mono windows of 30 seconds with a 25-second hop. Video samples every
  three seconds, skips near-duplicate frames and indexes its audio independently.
- Native ordered mixed inputs use a joint forward, not vector averaging.
  Search combines lexical rank with semantic rank standardized by modality.
  Per-row int8 vectors with scales are loaded into a contiguous in-memory table
  for blocked matrix-vector search, rather than decoding every stored payload
  for each query. Large-library latency and memory measurements remain a release
  gate.
- Settings exposes module downloads, indexing progress, persistent pause/resume
  and failed-source details. Low power mode and high temperature pause background
  indexing. Profile changes cancel indexing and fence collection reads/writes.

Only relevant DigUp ideas and synthetic fixtures are used. Reference revision:
`ARahim3/DigUp@f9b8106ffb8308b4f48b76149d270f7c2e6b4918` (MIT, AbdurRahim).
Its llama.cpp backend, filesystem crawler and global desktop controls are not
part of Ijuka. Fixture attribution is alongside the reference inputs in
`AmgiEmbeddings/Tests/AmgiEmbeddingsTests/Fixtures/DigUpReference`.

## Correction regression validation: 19 October 2026

The `AmgiAppMac` build and all 25 `AssistantFeatureTests` across six suites
passed on Xcode 27.1 using the `AIOverhaul` test plan. Five new tests use real
Rust backends with temporary collections to verify approved-field saves,
preservation of current tags and untouched rich text, and rejection of concurrent
field edits, renamed fields, mismatched collection activations, and deleted
notes. The existing context, request-format, sign-in-helper, markdown, and prompt
tests also passed. This run does not establish live cloud authentication,
model-generated correction quality, device behavior, or UI acceptance.

## Historical validation: 14 October 2026

The results below belong to the original overhaul, including tool/approval tests
and UI flows that the later rewrite replaced. They are retained as historical
evidence, not current test counts or acceptance of the present assistant. In
particular, the 15-test assistant result and raw tool-call examples below do not
establish the current task-shaped intent behavior.

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
2. Evaluate the current task-shaped intents on Apple Intelligence and every
   connected cloud provider, including sign-in/key handling, streaming,
   attachments, limits, stop/close, history, profile switching, multiple windows,
   approved/declined writes, stale corrections, and source opening. The old Mac
   note-creation result does not validate these rewritten flows.
3. Run sustained indexing on the user's iPhone/iPad/Mac; record whole-process
   memory, thermal response, latency and idle unload behavior beyond the bounded
   native reference gates already recorded above.
4. Validate retrieval ranking with representative text/image/audio/video and
   ordered mixed queries, multilingual study terms and exact lookup fixtures.
   Calibrate icon confidence and duplicate thresholds for the new model.
5. Evaluate the new reader card-capture, context-chip, and cloud-attachment
   flows separately from embedding parity. Richer EPUB media extraction,
   note/media joint context, and grouped temporal video windows still require
   their own implementation and validation evidence.
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
