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
    case mathBlock
    case mathLatex(environment: String)
    case textColor(String?)
    case highlight(String?)
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
    case recordAudio
    /// Resize the selected image (`width` px, height auto; nil restores the
    /// original dimensions by clearing stored attrs).
    case imageSize(String?)
    case dismiss
}

enum NoteFieldMediaSource: Equatable, Sendable {
    case camera
    case library
    case files
}

/// Image attachment under the tap cursor, for the resize menu.
struct SelectedFieldImage: Equatable, Sendable {
    var filename: String
    var widthAttr: String?
    var heightAttr: String?
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
    var selectedImage: SelectedFieldImage?
    var sourceCursorLine: Int?
    var sourceCursorColumn: Int?
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
