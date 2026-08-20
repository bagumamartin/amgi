/// Hops a synchronous Engine call off the caller's actor.
///
/// `AnkiServices` facades wrap their bodies in this so a `@MainActor` model
/// never runs an RPC — or waits on the backend's global lock — on the main
/// thread. Required because `NonisolatedNonsendingByDefault` makes a bare
/// `async` closure run on the *caller's* actor, so declaring a facade
/// `async` is not on its own enough to get off the main thread.
///
/// One hop per facade call: wrap the whole closure body rather than each
/// individual `invoke`, so a body doing several RPCs pays one context
/// switch instead of several.
public func backendOffload<R: Sendable>(
    _ work: @escaping @Sendable () throws -> R
) async throws -> R {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}
