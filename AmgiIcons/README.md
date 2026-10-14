# AmgiIcons

Deck-icon suggestion and picker for Ijuka. The shared native MLX EmbeddingGemma 2
engine ranks Phosphor tag descriptions against the deck title. The model-specific
768-dimensional catalog builds locally and checkpoints for interrupted runs.
Legacy E5 vectors are not loaded.

Icons-only package: the embedding engine lives in the sibling
`AmgiEmbeddings` package (shared with Browse semantic search). Until its
model is installed, suggestion falls back to name-token matching —
`IconSuggester` never throws. See `AmgiEmbeddings/README.md` for the weight
download, dev workflow, and tests.

## Vendored dependencies

- `Vendor/PhosphorSwift` — upstream 2.1.0 with a one-line manifest fix; see
  `Vendor/PhosphorSwift/VENDOR_NOTE.md`.
