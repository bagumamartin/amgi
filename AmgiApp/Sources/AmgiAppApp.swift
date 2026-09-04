// AmgiApp/Sources/AmgiAppApp.swift
import SwiftUI
import RootFeature

/// The iOS app target holds only `@main`. Dependency composition lives in
/// `AmgiRoot.bootstrap()` and view composition in `RootView`, both in the
/// `RootFeature` package target — which is what lets every other feature
/// module drop from `public` to `package`.
@main
struct AnkiAppApp: App {
    init() { AmgiRoot.bootstrap() }
    var body: some Scene { AmgiRoot.scenes }
}
