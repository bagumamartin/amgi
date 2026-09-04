# Preferences

- **Builds**: Xcode MCP only for app builds (`BuildProject`) — but the MCP
  server is not always attached to a session; when absent, verify isolated
  SPM packages with `swift build` / `swift test` on macOS (root package now
  fully runnable — mac xcframework slice) and `swiftc -parse` app files for
  syntax. Never use macOS SPM builds as proof for the app target
  (AmgiReaderDictionary is Cxx; app-target SwiftUI needs BuildProject).
- **After `xcodegen generate`**: re-select the simulator run destination
  (osascript snippet in CLAUDE.md) or `BuildProject` fails with a spurious
  signing error.
- **Swift style** (mirror sibling packages): swift-tools 6.2, the shared
  `sharedSwiftSettings` upcoming-feature block (IsolatedAny,
  ExistentialAny, InternalImportsByDefault, MemberImportVisibility,
  FullTypedThrows, InferIsolatedConformances, NonisolatedNonsendingByDefault,
  AccessLevelOnImport, StrictMemorySafety, StrictSendableMetatypes),
  `swiftLanguageModes: [.v6]`.
- **Import rules**: `public import` for modules whose types appear in public
  API (InternalImportsByDefault enforces this); plain `import` otherwise.
- **Docs/comments**: dense header comments explaining *why*; no comments on
  self-evident code. No emojis.
- **Python dev scripts** live in `scripts/` (e.g. `scripts/icon-embeddings/`);
  run with a local venv. Committed as of 2026-08 (user decision overrides the
  earlier "not committed" rule).
- **Tests**: Swift Testing (`@Test`/`@Suite`) in SPM packages; XCTest in the
  app target. SPM tests are runnable on macOS when the target doesn't touch
  AnkiRustLib.

- **Build-artifact cleanup policy**: user reported machine slowdowns from
  accumulated build junk (2026-08). Safe/recurring deletes: SPM `.build`
  dirs, stale /tmp logs. NEVER delete `anki-upstream/target` or
  `anki-bridge-rs/target` — Rust rebuilds are very expensive. Keep
  DerivedData (it's the runnable app). Root `.build` deletion kills the
  next swift-build cache — only with explicit ask.
