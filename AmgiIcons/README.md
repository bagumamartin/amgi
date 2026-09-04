# AmgiIcons

Deck-icon suggestion + picker for Amgi: a CoreML multilingual-e5-small
encoder ranks Phosphor icon names semantically against the deck title.

## Build prerequisite — fetch the CoreML model

The compiled model (`Sources/AmgiIcons/Resources/MultilingualE5Small.mlmodelc`,
224 MB) is **not in git**: GitHub rejects files >100 MB, and public forks
cannot push Git LFS objects. Fetch and compile it once per clone:

```bash
# 1. Download the fp16 .mlpackage from Hugging Face
#    https://huggingface.co/tamikisg/multilingual-e5-small-coreml
#    (inputs: input_ids / attention_mask, 1×256 int32; output: embeddings 1×384,
#    L2-normalized)

# 2. Compile it into the resource folder
xcrun coremlcompiler compile MultilingualE5Small.mlpackage \
    Sources/AmgiIcons/Resources/
```

The `.copy` resource rule in `Package.swift` expects the compiled `.mlmodelc`
folder at that exact path; the build fails without it. Do not commit a raw
`.mlpackage` — Xcode would auto-generate a Swift model class whose plain
`import CoreML` breaks under the repo's import-discipline settings and costs
~8 s of first-launch compile (see `Package.swift` comments).

If the model is ever swapped, regenerate `IconEmbeddings.json` via
`scripts/icon-embeddings/precompute_embeddings.py` so the vector space stays
in sync with the encoder.

## Vendored dependencies

- `Vendor/PhosphorSwift` — upstream 2.1.0 with a one-line manifest fix; see
  `Vendor/PhosphorSwift/VENDOR_NOTE.md`.
