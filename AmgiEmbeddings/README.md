# AmgiEmbeddings

Shared native MLX EmbeddingGemma 2 engine for Ijuka retrieval, duplicate
comparison and icon suggestions. Text and vision weights use 8-bit quantization;
audio weights use BF16. Outputs are normalized 768-dimensional Float32 vectors.
Minimum deployment: iOS/iPadOS 26 and macOS 26. This package is excluded from the
watch target graph.

The compatible model revision and each file's SHA-256/length are pinned in
`Sources/AmgiEmbeddings/Resources/Gemma2/manifest.json`. Text, vision and audio
are separate downloads with explicit consent. Model files are not committed.
E5 assets and consent are not reused. The vendored native implementation and
its notices live in `../Libraries/EmbeddingGemma2`.

`TextEmbedder.shared` owns the serial engine and bounded cache. `RetrievalIndex`
commits FTS, vectors and source anchors together in SQLite. `MediaIndexer` visits
only app-owned source URLs supplied by the profile coordinator; it does not
crawl arbitrary directories.

Use the app's `AIOverhaul` test plan for offline tests. The live reference test
requires `AMGI_E2E_MODEL_DOWNLOAD=1` and `AMGI_E2E_MEDIA=1` in the test target's
environment. Its Swift Testing selector is
`ModelAssetE2ETests/allModalitiesReference()` (including parentheses).

Physical iOS devices require an app-hosted test bundle. The separate
`AmgiModelGates` Xcode scheme builds a collection-free app with its own bundle
identifier. Running that scheme opts into verified model downloads in temporary
storage and attaches reference-vector, timing and MLX memory measurements to the
XCTest result. It does not replace the installed Ijuka app.

See [the implementation and validation record](../docs/ai-overhaul.md) for exact
pins, migration behavior, results and outstanding acceptance gates. Model parity
is distinct from retrieval quality and sustained device performance.
