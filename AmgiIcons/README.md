# AmgiIcons

Deck-icon suggestion + picker for Amgi: a CoreML multilingual-e5-small
encoder ranks Phosphor icon names semantically against the deck title.

Icons-only package: the embedding engine lives in the sibling
`AmgiEmbeddings` package (shared with Browse semantic search). Until its
model is installed, suggestion falls back to name-token matching —
`IconSuggester` never throws. See `AmgiEmbeddings/README.md` for the weight
download, dev workflow, and tests.

## Vendored dependencies

- `Vendor/PhosphorSwift` — upstream 2.1.0 with a one-line manifest fix; see
  `Vendor/PhosphorSwift/VENDOR_NOTE.md`.
