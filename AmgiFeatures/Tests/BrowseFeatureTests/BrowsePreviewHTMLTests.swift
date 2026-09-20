import Testing
@testable import BrowseFeature

@Suite("Browse preview HTML")
struct BrowsePreviewHTMLTests {

    @Test func answerOnlyStripsQuestionBeforeAnswerRule() {
        let back = "Question text<hr id=answer>Classification and HPLC"
        #expect(BrowsePreviewHTML.answerHTML(from: back) == "Classification and HPLC")
    }

    @Test func answerOnlyAcceptsQuotedAnswerId() {
        let back = #"Front<hr id="answer">Back field"#
        #expect(BrowsePreviewHTML.answerHTML(from: back) == "Back field")
    }

    @Test func answerOnlyAcceptsSingleQuotedAnswerId() {
        let back = "Front<hr id='answer' />Back field"
        #expect(BrowsePreviewHTML.answerHTML(from: back) == "Back field")
    }

    @Test func answerOnlyKeepsBackWhenNoRule() {
        #expect(BrowsePreviewHTML.answerHTML(from: "just the back") == "just the back")
    }

    @Test func displayHTMLUsesFrontUntilAnswerIsShown() {
        #expect(
            BrowsePreviewHTML.displayHTML(
                front: "Q",
                back: "Q<hr id=answer>A",
                showAnswer: false,
                answerOnly: false
            ) == "Q"
        )
    }

    @Test func displayHTMLUsesFullBackWhenShowingAnswer() {
        #expect(
            BrowsePreviewHTML.displayHTML(
                front: "Q",
                back: "Q<hr id=answer>A",
                showAnswer: true,
                answerOnly: false
            ) == "Q<hr id=answer>A"
        )
    }

    @Test func displayHTMLAnswerOnlyIgnoresShowAnswerFlag() {
        #expect(
            BrowsePreviewHTML.displayHTML(
                front: "Q",
                back: "Q<hr id=answer>A",
                showAnswer: false,
                answerOnly: true
            ) == "A"
        )
    }

    @Test func wrappedDocumentUsesCardClassAndNotNightModeInLight() {
        let html = BrowsePreviewHTML.wrappedDocument(
            html: "Hello",
            css: ".card { color: black; }",
            isDarkMode: false,
            cardOrdinal: 0
        )
        #expect(html.contains("class=\"card card1\""))
        #expect(!html.contains("nightMode"))
        #expect(html.contains("Hello"))
    }

    @Test func wrappedDocumentAddsNightModeAndRewritesBlackInDark() {
        let html = BrowsePreviewHTML.wrappedDocument(
            html: "Hello",
            css: ".card { color: black; }",
            isDarkMode: true,
            cardOrdinal: 1
        )
        #expect(html.contains("card card2"))
        #expect(html.contains("nightMode"))
        #expect(html.contains("var(--amgi-card-fg)"))
        #expect(!html.contains("color: black"))
    }
}
