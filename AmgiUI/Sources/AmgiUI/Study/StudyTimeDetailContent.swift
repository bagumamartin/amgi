public import SwiftUI
import AmgiTheme

/// The screen a chart row opens. The count is the whole match. The number
/// starts there and can only be lowered. Study is absent when nothing matched.
public struct StudyTimeDetailContent: View {
    let row: StudyTimeRow
    @Binding var limit: Int
    @Binding var reschedules: Bool
    let isBusy: Bool
    let message: String?
    let onStudy: () -> Void

    @Environment(\.palette) private var palette

    public init(
        row: StudyTimeRow,
        limit: Binding<Int>,
        reschedules: Binding<Bool>,
        isBusy: Bool,
        message: String?,
        onStudy: @escaping () -> Void
    ) {
        self.row = row
        self._limit = limit
        self._reschedules = reschedules
        self.isBusy = isBusy
        self.message = message
        self.onStudy = onStudy
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if row.count == 0 {
                    ContentUnavailableView(
                        row.emptyMessage,
                        systemImage: "calendar",
                        description: Text(row.detailTitle)
                    )
                } else {
                    countBlock
                    limitBlock
                    Toggle("Answering reschedules these cards", isOn: $reschedules)
                        .amgiFont(.body)
                        .tint(palette.accent)
                    studyButton
                    if let message {
                        Text(message)
                            .amgiFont(.caption)
                            .foregroundStyle(palette.warning)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .amgiScreenCanvas()
        .navigationTitle(row.detailTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var countBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(row.count)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
            Text(row.count == 1 ? "card" : "cards")
                .amgiFont(.body)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var limitBlock: some View {
        Stepper(value: $limit, in: 1...max(row.count, 1)) {
            Text("Study \(limit)")
                .amgiFont(.body)
                .foregroundStyle(palette.textPrimary)
                .monospacedDigit()
        }
        .disabled(row.count <= 1)
    }

    private var studyButton: some View {
        Button(action: onStudy) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                Text("Study · \(limit)")
                    .amgiFont(.body)
                    .bold()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(palette.accent, in: Capsule())
        }
        .buttonStyle(.pressScale)
        .disabled(isBusy || limit < 1)
    }
}
