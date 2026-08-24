import Foundation
import AnkiBackend
import AnkiKit
import AnkiProtoBridge

/// Card rendering and collection statistics.
enum RenderStatsTools {
    static var tools: [AmgiTool] {
        [
            AmgiTool(
                name: "render_card",
                description: """
                    Renders a card's front and back templates exactly as the app shows \
                    them (HTML + CSS). Use to verify template/field edits produce sane \
                    output before the user reviews.
                    """,
                inputSchema: Schema.object(
                    ["card_id": Schema.int("Card id")],
                    required: ["card_id"]
                ),
                minimumTier: .readOnly
            ) { ctx, args in
                let id = CardID(Int64(try args.requireInt("card_id")))
                let rendered = try ctx.backend().invoke(.renderExistingCard(cardId: id))
                return """
                    FRONT:
                    \(rendered.frontHTML)

                    BACK:
                    \(rendered.backHTML)

                    CSS:
                    \(rendered.cardCSS)
                    """
            },
            AmgiTool(
                name: "collection_stats",
                description: """
                    Collection health summary: card-state totals, today's review \
                    activity, true retention, and future due load.
                    """,
                inputSchema: Schema.object([
                    "search": Schema.string("Optional Anki search filter (default whole collection)"),
                ]),
                minimumTier: .readOnly
            ) { ctx, args in
                let search = args.optionalString("search") ?? ""
                let snapshot = try ctx.backend().invoke(.graphs(search: search, days: 365))
                let counts = snapshot.cardCounts.excludingInactive
                let today = snapshot.today
                let retentionToday = snapshot.trueRetention.today
                let matureTotal = retentionToday.maturePassed + retentionToday.matureFailed
                let matureRate =
                    matureTotal > 0
                    ? String(format: "%.1f%%", Double(retentionToday.maturePassed) / Double(matureTotal) * 100)
                    : "n/a"
                return """
                    cards: new:\(counts.newCards) learning:\(counts.learn) relearning:\(counts.relearn) \
                    young:\(counts.young) mature:\(counts.mature) suspended:\(counts.suspended) buried:\(counts.buried)
                    today: \(today.answerCount) answers, \(today.correctCount) correct \
                    (\(today.learnCount) learn / \(today.reviewCount) review / \(today.relearnCount) relearn), \
                    \(today.answerMillis / 1000)s spent
                    true retention (mature, today): \(matureRate)
                    future due daily load: \(snapshot.futureDue.dailyLoad) | backlog: \(snapshot.futureDue.haveBacklog)
                    FSRS: \(snapshot.fsrs ? "enabled" : "off") | rollover hour: \(snapshot.rolloverHour)
                    """
            },
        ]
    }
}
