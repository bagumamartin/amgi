import AmgiAppCore
import AmgiTheme
import AmgiUI
import AnkiKit
import Foundation
import SwiftUI

/// Problems a note can have that the engine won't flag on its own. Each is
/// a quick, local read of the note's fields; nothing here changes a note.
enum NoteCheckIssue: String, CaseIterable, Identifiable, Sendable {
    case emptyFront, missingCloze, brokenCloze, duplicateFront, missingMedia, longAnswer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emptyFront: L10n.text("Empty front")
        case .missingCloze: L10n.text("Cloze note with no cloze")
        case .brokenCloze: L10n.text("Unclosed cloze")
        case .duplicateFront: L10n.text("Same front as another note")
        case .missingMedia: L10n.text("Missing picture or sound")
        case .longAnswer: L10n.text("Answer too long to learn")
        }
    }

    var detail: String {
        switch self {
        case .emptyFront: L10n.text("The first field has no text or media, so the card shows a blank question.")
        case .missingCloze: L10n.text("A cloze note type needs a {{c1::…}} deletion to make any card.")
        case .brokenCloze: L10n.text("A {{c1:: opens without a closing }}, so part of the note won’t render.")
        case .duplicateFront: L10n.text("Two or more notes ask the same question.")
        case .missingMedia: L10n.text("A field refers to a file that isn’t in the collection’s media.")
        case .longAnswer: L10n.text("More than \(NoteChecker.longAnswerLimit) characters behind the question. Long answers are hard to recall; consider splitting.")
        }
    }

    var systemImage: String {
        switch self {
        case .emptyFront: "rectangle.dashed"
        case .missingCloze: "ellipsis.rectangle"
        case .brokenCloze: "curlybraces"
        case .duplicateFront: "square.on.square"
        case .missingMedia: "photo.badge.exclamationmark"
        case .longAnswer: "text.alignleft"
        }
    }
}

enum NoteChecker {
    static let longAnswerLimit = 700

    /// Notes with each issue, in input order.
    static func check(
        _ records: [NoteRecord],
        clozeNotetypes: Set<NotetypeID>,
        mediaExists: (String) -> Bool
    ) -> [NoteCheckIssue: [NoteID]] {
        var found: [NoteCheckIssue: [NoteID]] = [:]
        var fronts: [String: [NoteID]] = [:]
        for record in records {
            let fields = record.flds.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            let front = fields.first ?? ""
            let frontText = plainText(front)
            let all = fields.joined(separator: "\n")

            if frontText.isEmpty && mediaReferences(in: front).isEmpty && !clozeNotetypes.contains(record.mid) {
                found[.emptyFront, default: []].append(record.id)
            }
            let openings = all.matches(of: /\{\{c\d+::/).count
            if clozeNotetypes.contains(record.mid), openings == 0 {
                found[.missingCloze, default: []].append(record.id)
            }
            if openings > all.matches(of: /\}\}/).count {
                found[.brokenCloze, default: []].append(record.id)
            }
            if !frontText.isEmpty, !clozeNotetypes.contains(record.mid) {
                fronts[frontText.lowercased(), default: []].append(record.id)
            }
            if mediaReferences(in: all).contains(where: { !mediaExists($0) }) {
                found[.missingMedia, default: []].append(record.id)
            }
            let answer = fields.dropFirst().map(plainText).joined(separator: " ")
            if answer.count > longAnswerLimit {
                found[.longAnswer, default: []].append(record.id)
            }
        }
        let duplicates = fronts.values.filter { $0.count > 1 }.flatMap { $0 }
        if !duplicates.isEmpty { found[.duplicateFront] = duplicates }
        return found
    }

    /// File names a field refers to: `<img src>` and `[sound:]`.
    static func mediaReferences(in html: String) -> [String] {
        var names: [String] = []
        for match in html.matches(of: /<img[^>]*?src\s*=\s*["']([^"']+)["']/) {
            names.append(String(match.1))
        }
        for match in html.matches(of: /\[sound:([^\]]+)\]/) {
            names.append(String(match.1))
        }
        // Remote images aren't the collection's to check.
        return names
            .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") && !$0.hasPrefix("data:") }
            .map { $0.removingPercentEncoding ?? $0 }
    }

    static func plainText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\[sound:[^\\]]+\\]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// Runs the checker over the current search and lists what it found; a row
/// shows those notes in the list.
struct NoteCheckerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let scopeTitle: String
    let run: () async -> [NoteCheckIssue: [NoteID]]?
    let onShow: ([NoteID]) -> Void

    @State private var results: [NoteCheckIssue: [NoteID]]?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let results {
                    if results.isEmpty {
                        ContentUnavailableView(
                            "No Problems Found",
                            systemImage: "checkmark.seal",
                            description: Text("Every note in \(scopeTitle) passed.")
                        )
                    } else {
                        List {
                            Section {
                                ForEach(NoteCheckIssue.allCases.filter { results[$0] != nil }) { issue in
                                    issueRow(issue, notes: results[issue] ?? [])
                                }
                            } footer: {
                                Text("Checked \(scopeTitle). Nothing is changed until you edit a note.")
                            }
                        }
                    }
                } else if failed {
                    ContentUnavailableView("Couldn’t Check Notes", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("Checking notes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Check Notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let found = await run() { results = found } else { failed = true }
            }
        }
    }

    private func issueRow(_ issue: NoteCheckIssue, notes: [NoteID]) -> some View {
        Button {
            onShow(notes)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: issue.systemImage)
                    .foregroundStyle(palette.warning)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .foregroundStyle(palette.textPrimary)
                    Text(issue.detail)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: 8)
                Text(notes.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
