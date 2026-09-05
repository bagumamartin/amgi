# AmgiEmbeddings

Shared e5-small text-embedding engine + its CDN weight lifecycle. Used by
`AmgiIcons` (deck-icon suggestion) and Browse (semantic search) so only ONE
resident CoreML model instance exists. Split out of AmgiIcons 2026-09 —
icons-only there, engine here.

## Contents

- `TextEmbedder` — public actor; `"query: "` / `"passage: "` prefixed
  embeddings (384-dim L2-normalized) over the bundled `Tokenizer/`.
- `ModelAssetManager` — downloads the ~200MB `.mlpackage.zip` from
  `https://amgiassets.bagumamartin.com` (manifest-pinned version + SHA-256),
  verifies, unzips (ZIPFoundation), compiles into the app-group container
  (`<group>/AmgiEmbeddings/models/v<N>/`, next to `AnkiCollection`;
  backup-excluded, sandbox fallback when unentitled), prunes old versions.
  Supports cancel + resume-data across launches. Never starts on its own —
  the app's consent coordinator drives it.
- `ModelAssetStatusView` — one-line Settings status (progress / version /
  retry).

## Dev workflow — run the app once

Weights are not bundled and not in git. Accept the in-app consent dialog
once; the download lands in the app-group container next to
`AnkiCollection`. Engine tests skip cleanly until a model exists. A precompiled `MultilingualE5Small.mlmodelc` placed
next to the sources is still honored (lookup fallback) but nothing guides
you there.

## Tests

- Offline unit tests: CDN contract, URL resolution, store isolation.
- `AMGI_E2E_MODEL_DOWNLOAD=1`: live download + cancel tests. Store is
  redirected to a temp dir (`modelsRootOverride`, serialized across suites)
  so the host machine is never polluted — verified CLEAN after every run.

If the model is ever swapped, regenerate `IconEmbeddings.json` in AmgiIcons
via `scripts/icon-embeddings/precompute_embeddings.py` so the vector space
stays in sync with the encoder.
