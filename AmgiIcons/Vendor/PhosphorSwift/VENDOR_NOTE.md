# Vendored: PhosphorSwift 2.1.0

- Upstream: https://github.com/phosphor-icons/swift (tag `2.1.0`), MIT license
  (see LICENSE).
- **Why vendored:** upstream's `Package.swift` declares no `resources:` rule,
  but the source loads icons via `Bundle.module`. SwiftPM therefore never
  generates the resource bundle accessor and the package fails to compile —
  reproducible with a plain `swift build` (verified 2026-08, toolchain
  Xcode 26). Vendoring lets us carry the one-line manifest fix without
  waiting on upstream.
- **Local change vs upstream:** two deviations from the upstream tag:
  1. Only this `Package.swift` differs in *code* terms — adds
     `.process("PhosphorSwift/Resources")` so `Bundle.module` works.
  2. **`Resources/Assets.xcassets` is pruned to the regular weight only**
     (1,518 of 9,108 imagesets). Measured on this machine (2026-08):
     actool takes **8m39s** to compile the full six-weight catalog and
     **2m04s** regular-only; the other five weights are dead weight unless
     you actually render `.fill`/`.bold`/`.thin`/`.light`/`.duotone`
     somewhere. If you do, re-copy those `*-<weight>.imageset` folders from
     the upstream tag into `SVG/` and accept the proportional build time.
     Using an accessor for a pruned weight compiles fine but renders blank
     at runtime (`Image("x-fill")` resolves to nothing).

## Updating

1. Download the new upstream tag.
2. Replace everything except `Package.swift`.
3. Re-verify that every icon name in
   `scripts/icon-embeddings/icon_tags_full.py` still resolves through
   `Ph.amgi(named:)` — the `AmgiIconsTests.phIndex` test pins the case count
   (1,512 at v2.1.0) and will fail loudly if the catalog drifts. Regenerate
   `IconEmbeddings.json` if names were added/removed.
