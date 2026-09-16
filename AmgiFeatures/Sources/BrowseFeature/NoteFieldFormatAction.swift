enum NoteFieldFormatAction: Equatable, Sendable {
    case undo
    case redo
    case bold
    case italic
    case underline
    case strike
    case superscript
    case `subscript`
    case code
    case math
    case clear
    case list(NoteFieldHTML.ListKind)
    case align(NoteFieldHTML.Alignment)
    case indent
    case outdent
    case toggleHTMLSource
    case cloze
    case clozeSame
    case camera
    case photoLibrary
    case attach
    case dismiss
}

enum NoteFieldMediaSource: Equatable, Sendable {
    case camera
    case library
    case files
}

struct NoteFieldChromeState: Equatable {
    var style: NoteFieldHTML.Style = .init()
    var listKind: NoteFieldHTML.ListKind = .none
    var alignment: NoteFieldHTML.Alignment = .unspecified
    var indent: Int = 0
    var canUndo = false
    var canRedo = false
    var showsCloze = false
    var isHTMLSource = false
}

@MainActor
protocol NoteFieldFormatResponder: AnyObject {
    func perform(_ action: NoteFieldFormatAction)
    func insertImage(filename: String)
    func insertSound(filename: String)
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var currentStyle: NoteFieldHTML.Style { get }
    var currentListKind: NoteFieldHTML.ListKind { get }
    var currentAlignment: NoteFieldHTML.Alignment { get }
    var currentIndent: Int { get }
    var isHTMLSource: Bool { get }
}
