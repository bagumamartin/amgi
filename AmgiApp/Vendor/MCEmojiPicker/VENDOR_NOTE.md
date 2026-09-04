# Vendored: MCEmojiPicker 1.2.5

- Upstream: https://github.com/izyumkin/MCEmojiPicker (tag `1.2.5`), MIT
  (see LICENSE). Sources are otherwise untouched.

## Why a dedicated target instead of an SPM dependency

Upstream's Package.swift declares **iOS only** (`platforms: [.iOS("11.1")]`),
which breaks resolution when the dual-destination app builds for macOS.
Vendoring also solves a second problem: the sources predate Swift strict
concurrency (Swift 4.2-era statics, main-actor isolation errors) and cannot
compile under the app target's Swift 6 mode.

So they live in their own **iOS-only static-library target** (`project.yml`,
target `MCEmojiPicker`, type `library.static`, `platform: iOS`) pinned to:

- `SWIFT_VERSION = 5.0`
- `SWIFT_STRICT_CONCURRENCY = minimal`

The app links it via `- target: MCEmojiPicker, destinationFilters: [iOS]`,
and `ProfileIconEditorSheet.swift` imports it inside `#if os(iOS)`.

## Resources

The picker loads emoji definitions from a CocoaPods-style
**`MCEmojiPicker.bundle`** directory (its `Bundle.module` shim is active
because we don't define `SWIFT_PACKAGE`). The eight emoji-definition JSONs
live at `AmgiApp/Resources/MCEmojiPicker.bundle/` (folder reference → copied
into the app bundle). The original `Vendor/MCEmojiPicker/Resources` tree was
removed to avoid duplication.

## Updating

1. Download the new tag's `Sources/MCEmojiPicker`.
2. Replace `AmgiApp/Vendor/MCEmojiPicker/*.swift` contents (keep LICENSE,
   drop its `Resources/` dir).
3. Refresh `Resources/MCEmojiPicker.bundle/*.json` from the same tag if the
   definitions changed.
4. If the new version adopts Swift 6 strict concurrency, the target's
   `SWIFT_STRICT_CONCURRENCY = minimal` can be relaxed back to the project
   default.
