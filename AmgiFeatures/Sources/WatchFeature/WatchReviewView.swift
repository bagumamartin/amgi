import AVFoundation
import AnkiBackend
import AnkiKit
import Dependencies
import AmgiCardWeb
import SwiftUI
import AmgiReviewCore

struct WatchReviewView: View {
    let deckId: DeckID
    let onDismiss: () -> Void
    @State private var session: ReviewSession
    @State private var audioPlayer = AVQueuePlayer()
    /// Computed once per card side instead of in `body`. Stripping runs
    /// several whole-document regex passes, and body was re-evaluating it on
    /// every state change — including isAudioPlaying flips — on the slowest
    /// CPU in the project.
    @State private var strippedText: String = ""

    private var currentHTML: String {
        session.showAnswer ? session.backHTML : session.frontHTML
    }
    @Environment(\.dismiss) private var dismiss
    init(deckId: DeckID, onDismiss: @escaping () -> Void) {
        self.deckId = deckId
        self.onDismiss = onDismiss
        self._session = State(initialValue: ReviewSession(deckId: deckId))
    }
    var body: some View {
        VStack {
            if session.isFinished {
                finishedView
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        Text(strippedText)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                    }
                    .task(id: currentHTML) {
                        strippedText = CardText.plainText(currentHTML)
                    }
                    if session.showAnswer {
                        HStack(spacing: 0) {
                            ratingButton(.again, color: .red)
                            ratingButton(.good, color: .green)
                        }
                    } else {
                        reviewButton("Show Answer", color: .blue) { session.revealAnswer() }
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Color.black)
        ._statusBarHidden()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .onTapGesture { playAudio(from: session.showAnswer ? session.backHTML : session.frontHTML) }
        .onTapGesture(count: 2) { dismiss() }
        .task {
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playback,
                    mode: .default,
                    policy: .longFormAudio
                )
                // watchOS-only API. Unguarded, it makes WatchFeature fail to
                // compile for an iOS destination, which is what the
                // AmgiFeatures-Package scheme builds — so no package test
                // target could run at all. Guarding changes nothing on watchOS.
                #if os(watchOS)
                try await AVAudioSession.sharedInstance().activate(options: [])
                #endif
            } catch {
                // Audio may fail silently on watchOS if session setup errors.
            }
            session.start()
        }
        .onChange(of: session.frontHTML) { _, new in playAudio(from: new) }
        .onChange(of: session.showAnswer) { _, show in if show { playAudio(from: session.backHTML) } }
    }
    private var finishedView: some View {
        VStack {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Finished!").font(.headline)
            Text("\(session.sessionStats.reviewed) cards").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { onDismiss() }.buttonStyle(.borderedProminent)
        }.padding()
    }
    private func reviewButton(_ title: String, color: Color, font: Font = .headline, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(font).frame(maxWidth: .infinity)
        }
        .padding(10).buttonStyle(.plain).frame(maxWidth: .infinity).background(color)
    }
    private func ratingButton(_ rating: Rating, color: Color) -> some View {
        reviewButton(session.nextIntervals[rating] ?? "", color: color, font: .caption) {
            session.answer(rating: rating)
        }
    }
    private func playAudio(from html: String) {
        @Dependency(\.ankiBackend) var backend
        guard let mediaDir = backend.currentMediaFolderPath else { return }
        let items = CardText.soundFilenames(in: html).map { filename in
            AVPlayerItem(url: URL(fileURLWithPath: mediaDir).appendingPathComponent(filename))
        }
        audioPlayer.removeAllItems()
        items.forEach { if audioPlayer.canInsert($0, after: nil) { audioPlayer.insert($0, after: nil) } }
        audioPlayer.play()
    }
}
