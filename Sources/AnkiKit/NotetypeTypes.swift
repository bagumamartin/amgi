public struct NotetypeInfo: Sendable {
    public let id: NotetypeID
    public let name: String
    public let fieldNames: [String]
    public let kind: Notetype.Kind

    package init(
        id: NotetypeID,
        name: String,
        fieldNames: [String],
        kind: Notetype.Kind = .normal
    ) {
        self.id = id
        self.name = name
        self.fieldNames = fieldNames
        self.kind = kind
    }
}

/// Per-field config info for a notetype field — used by typed-answer rendering.
public struct NotetypeFieldInfo: Sendable {
    public let name: String
    public let ordinal: Int
    public let fontName: String
    public let fontSize: Int

    package init(name: String, ordinal: Int, fontName: String, fontSize: Int) {
        self.name = name
        self.ordinal = ordinal
        self.fontName = fontName
        self.fontSize = fontSize
    }
}

public struct NewNoteTemplate: Sendable {
    public let notetypeId: NotetypeID
    public var fields: [String]
    public var tags: [String]

    public init(notetypeId: NotetypeID, fields: [String]) {
        self.notetypeId = notetypeId
        self.fields = fields
        self.tags = []
    }
}
