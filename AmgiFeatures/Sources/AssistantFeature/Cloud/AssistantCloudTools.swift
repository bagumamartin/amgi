import Foundation

/// The same intents the on-device model gets, as JSON-Schema functions for
/// cloud models. ``AssistantToolbox`` runs them either way, so a cloud model
/// can't save anything the user hasn't reviewed either.
enum AssistantCloudTools {
    static func make(canFixCard: Bool, hasReading: Bool) -> [CloudTool] {
        var tools = [studyOverview, findNotes, relatedCards, makeFlashcards, openScreen]
        if canFixCard { tools.append(fixThisCard) }
        if hasReading { tools.append(findGaps) }
        return tools
    }

    @MainActor
    static func run(_ call: CloudToolCall, with toolbox: AssistantToolbox) async -> String {
        let arguments = JSONValue.parse(call.arguments) ?? [:]
        switch call.name {
        case "studyOverview":
            return await toolbox.studyOverview(focus: arguments["deck"]?.string)
        case "findNotes":
            return await toolbox.findNotes(arguments["question"]?.string ?? "", scope: arguments["scope"]?.string)
        case "relatedCards":
            return await toolbox.relatedCards(arguments["text"]?.string)
        case "findGaps":
            return await toolbox.findGaps()
        case "makeFlashcards":
            let cards = (arguments["cards"]?.array ?? []).compactMap { card -> (front: String, back: String)? in
                guard let front = card["front"]?.string else { return nil }
                return (front, card["back"]?.string ?? "")
            }
            return await toolbox.makeFlashcards(cards, deckHint: arguments["deck"]?.string)
        case "openScreen":
            return await toolbox.open(destination: arguments["destination"]?.string ?? "library", target: arguments["target"]?.string)
        case "fixThisCard":
            let fixes = (arguments["fixes"]?.array ?? []).compactMap { fix -> (field: String, text: String)? in
                guard let field = fix["field"]?.string, let text = fix["text"]?.string else { return nil }
                return (field, text)
            }
            return await toolbox.fixThisCard(fixes)
        default:
            return "FAILED: there is no tool named \(call.name)."
        }
    }

    private static let studyOverview = CloudTool(
        name: "studyOverview",
        description: "Cards due today in each deck. Use when the user asks what to study, how much is due, or about their workload.",
        parameters: [
            "type": "object",
            "properties": ["deck": ["type": "string", "description": "A deck the user named, if any"]],
            "additionalProperties": false,
        ]
    )

    private static let findNotes = CloudTool(
        name: "findNotes",
        description: "Search the user's own flashcards, notes and books. Use when the answer should come from what they have studied.",
        parameters: [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "What to look for. Rephrase into the key terms; call again with other wording if results are thin."],
                "scope": [
                    "type": "string", "enum": ["auto", "collection", "cards", "books"],
                    "description": "auto (default) searches the attached book or deck when there is one, else everything; collection searches everything; cards only flashcards; books only the reader library.",
                ],
            ],
            "required": ["question"],
            "additionalProperties": false,
        ]
    )

    private static let relatedCards = CloudTool(
        name: "relatedCards",
        description: "The user's cards most similar in meaning to the attached card, or to the given text. Use to connect an idea to what they already know, to explain a card through related ones, or to check for duplicates before or after making cards.",
        parameters: [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "Text to compare. Omit to use the attached card or passage."]],
            "additionalProperties": false,
        ]
    )

    private static let findGaps = CloudTool(
        name: "findGaps",
        description: "Passages of the attached chapter, page or book that none of the user's cards cover yet, least covered first. Use when the user asks what they have not made cards for, or before making cards for a reading so new cards fill gaps instead of repeating existing ones.",
        parameters: ["type": "object", "properties": JSONValue.object([:]), "additionalProperties": false]
    )

    private static let makeFlashcards = CloudTool(
        name: "makeFlashcards",
        description: "Create flashcards. Use only when the user asks to make, add or create cards. The user reviews and edits them before anything is saved. Write atomic cards: one fact each, the front phrased as a question.",
        parameters: [
            "type": "object",
            "properties": [
                "cards": [
                    "type": "array", "maxItems": 20,
                    "items": [
                        "type": "object",
                        "properties": [
                            "front": ["type": "string", "description": "The question or prompt side"],
                            "back": ["type": "string", "description": "The answer side"],
                        ],
                        "required": ["front", "back"],
                        "additionalProperties": false,
                    ],
                ],
                "deck": ["type": "string", "description": "The deck the user named, if any"],
            ],
            "required": ["cards"],
            "additionalProperties": false,
        ]
    )

    private static let openScreen = CloudTool(
        name: "openScreen",
        description: "Open part of the app: start reviewing a deck, browse cards, see stats, or go to the library. Use only when the user asks to go somewhere or start studying.",
        parameters: [
            "type": "object",
            "properties": [
                "destination": ["type": "string", "enum": ["review", "browse", "stats", "library"]],
                "target": ["type": "string", "description": "Deck name for review, or search words for browse"],
            ],
            "required": ["destination"],
            "additionalProperties": false,
        ]
    )

    private static let fixThisCard = CloudTool(
        name: "fixThisCard",
        description: "Correct or improve the attached card. Use only when the user says it is wrong, has a typo, is unclear, or asks to change it. Send the complete new text of each field that changes, named as in the card context. The user reviews the change before it is saved.",
        parameters: [
            "type": "object",
            "properties": [
                "fixes": [
                    "type": "array", "maxItems": 8,
                    "items": [
                        "type": "object",
                        "properties": [
                            "field": ["type": "string", "description": "Field name, for example Front or Back"],
                            "text": ["type": "string", "description": "The NEW text of the field"],
                        ],
                        "required": ["field", "text"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["fixes"],
            "additionalProperties": false,
        ]
    )
}
