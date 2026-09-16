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
    case bulletList
    case numberedList
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

@MainActor
protocol NoteFieldFormatResponder: AnyObject {
    func perform(_ action: NoteFieldFormatAction)
    func insertImage(filename: String)
    func insertSound(filename: String)
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var currentStyle: NoteFieldHTML.Style { get }
    var currentListKind: NoteFieldHTML.ListKind { get }
}
