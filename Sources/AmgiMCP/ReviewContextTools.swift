import Foundation
import AnkiKit
import AnkiProtoBridge
import MCP

/// Live review-session context — the one tool that is about the APP's
/// UI state rather than the collection. Asks Amgi.app over the IPC
/// bridge (service-0 sentinel, `MCPBridge.sessionStateMethod`) which
/// card is on screen, the deck scope, and what was answered today; then
/// enriches with QoL scheduling counts (buried / suspended) from the
/// engine. Requires the app to be open — by definition: "the current
/// card" does not exist when it isn't.
enum ReviewContextTools {
    static var tools: [AmgiTool] {
        [
            AmgiTool(
                name: "get_review_context",
                description: """
                    What the user is looking at right now in the Amgi app: the \
                    current card (id + note id), the review scope (deck and \
                    whether it's the All-Decks session), queue position and \
                    remaining new/learning/review counts, whether the answer/back \
                    side is currently revealed (flipped), and every answer \
                    given this session with ratings and timestamps. Also \
                    reports buried and suspended card counts in scope. \
                    Requires Amgi to be open — call this first when the user \
                    says "this card", "current card", or "today's review", \
                    then use get_card / get_note / render_card on the ids it \
                    returns.
                    """,
                inputSchema: Schema.object([:]),
                minimumTier: .readOnly
            ) { ctx, _ in
                // Probe the bridge FIRST: ctx.backend() would fall back to
                // opening the collection directly (and could die on the
                // engine lock held by sibling helpers) before we can tell
                // the agent "the app simply isn't running".
                let socketPath = MCPBridge.socketPath()
                guard ProxyCaller.ping(socketPath: socketPath) else {
                    throw ToolError.blocked(
                        """
                        Amgi.app is not running. The current-card context only exists while \
                        the app is open — ask the user to open Amgi and start a review session. \
                        (Other Amgi tools still work: they read the collection directly.)
                        """
                    )
                }
                let caller = try ctx.backend()
                guard case .bridged(let bridgePath) = caller.kind else {
                    throw ToolError.blocked(
                        "Amgi.app's bridge is not accepting connections — restart Amgi."
                    )
                }
                let path = bridgePath

                // 1) Live session snapshot from the app.
                let (status, payload) = try ProxyCaller.transact(
                    socketPath: path,
                    service: MCPBridge.pingService,
                    method: MCPBridge.sessionStateMethod,
                    payload: Data()
                )
                guard status == .ok else {
                    throw ToolError.blocked(
                        String(decoding: payload, as: UTF8.self).isEmpty
                            ? "No active review session — the user isn't reviewing right now."
                            : String(decoding: payload, as: UTF8.self)
                    )
                }
                let snapshot: ReviewSessionSnapshot
                do {
                    snapshot = try JSONDecoder().decode(ReviewSessionSnapshot.self, from: payload)
                } catch {
                    throw ToolError.blocked("Could not decode session state (\(error.localizedDescription)).")
                }

                // 2) QoL enrichment — buried / suspended counts in scope,
                // straight from the engine (bridged or direct, both work).
                var buriedCount: Int?
                var suspendedCount: Int?
                let scopeQuery: String
                if snapshot.isAllDecksScope {
                    scopeQuery = ""
                } else {
                    let escaped = snapshot.deckName.replacingOccurrences(of: "\"", with: "\\\"")
                    scopeQuery = "deck:\"\(escaped)\" "
                }
                // Best-effort: enrichment failures never hide the snapshot.
                if let engine = try? ctx.backend() {
                    buriedCount = try? engine.invoke(.searchCardIds(query: scopeQuery + "is:buried")).count
                    suspendedCount = try? engine.invoke(.searchCardIds(query: scopeQuery + "is:suspended")).count
                }

                // 3) Render as agent-readable text (ids included for follow-ups).
                var lines: [String] = []
                lines.append("scope: \(snapshot.isAllDecksScope ? "All Decks" : snapshot.deckName) (deckId \(snapshot.deckId))")
                if let cardId = snapshot.currentCardId {
                    lines.append("current card: id \(cardId), noteId \(snapshot.currentNoteId.map(String.init) ?? "?"), template ordinal \(snapshot.cardOrdinal)")
                    lines.append("answer: \(snapshot.isAnswerRevealed ? "revealed (back side visible)" : "hidden (front/question side)") — isAnswerRevealed=\(snapshot.isAnswerRevealed)")
                } else {
                    lines.append("current card: none (between cards)")
                }
                lines.append("queue: \(snapshot.queueRemaining) remaining after current — new:\(snapshot.remainingNew) learning:\(snapshot.remainingLearning) review:\(snapshot.remainingReview)")
                lines.append("session: \(snapshot.reviewed) answered, \(snapshot.correct) correct, streak \(snapshot.streak)\(snapshot.isFinished ? ", FINISHED" : "")")
                if !snapshot.answered.isEmpty {
                    lines.append("answered this session (oldest first):")
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    for answer in snapshot.answered.suffix(20) {
                        let date = Date(timeIntervalSince1970: Double(answer.atMs) / 1000)
                        lines.append("  card \(answer.cardId) — \(answer.rating) at \(formatter.string(from: date))")
                    }
                    if snapshot.answered.count > 20 {
                        lines.append("  … (\(snapshot.answered.count - 20) earlier answers omitted)")
                    }
                }
                if let buried = buriedCount, let suspended = suspendedCount {
                    lines.append("in scope: \(buried) buried, \(suspended) suspended (buried cards return after the day rolls over or via unbury; suspended stay out until unsuspended)")
                }
                lines.append("follow-ups: get_note noteId for full fields/tags; render_card cardId for HTML; deck_tree for sibling decks")
                return lines.joined(separator: "\n")
            },
        ]
    }
}
