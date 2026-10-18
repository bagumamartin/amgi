import AmgiAppCore
import Foundation
import Observation

/// Where a reply is generated.
enum AssistantProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device model. Private, free, text only.
    case apple
    /// The user's ChatGPT plan, through Sign in with ChatGPT.
    case chatGPT
    /// An OpenAI Platform API key.
    case openAI
    /// An Anthropic API key.
    case anthropic

    var id: String { rawValue }
    var isCloud: Bool { self != .apple }

    var title: String {
        switch self {
        case .apple: L10n.text("Apple Intelligence")
        case .chatGPT: "ChatGPT"
        case .openAI: L10n.text("OpenAI API")
        case .anthropic: "Claude"
        }
    }

    /// Asset-free mark for menus and rows.
    var systemImage: String {
        switch self {
        case .apple: "apple.intelligence"
        case .chatGPT: "bubble.left.and.text.bubble.right"
        case .openAI: "key"
        case .anthropic: "asterisk"
        }
    }
}

struct AssistantModel: Codable, Hashable, Identifiable, Sendable {
    let provider: AssistantProvider
    /// The slug the API takes as `model`.
    let slug: String
    let name: String
    var id: String { "\(provider.rawValue):\(slug)" }

    static let onDevice = AssistantModel(provider: .apple, slug: "system", name: L10n.text("Apple Intelligence"))
}

/// Connected AI providers, their models, and the model chats use. Secrets
/// live in the keychain; this holds only what the UI shows.
@MainActor @Observable
final class AssistantProviderStore {
    static let shared = AssistantProviderStore()

    private(set) var selection: AssistantModel
    private(set) var models: [AssistantProvider: [AssistantModel]]
    private(set) var connected: Set<AssistantProvider> = []
    private(set) var chatGPTEmail: String?
    private(set) var loading: Set<AssistantProvider> = []
    var lastError: [AssistantProvider: String] = [:]
    /// The one-time welcome after the first ChatGPT sign-in.
    var showsPlanWelcome = false

    private static let selectionKey = "assistant.model.selection"
    private static let modelsKey = "assistant.model.catalog"

    private init() {
        let defaults = UserDefaults.standard
        selection = defaults.data(forKey: Self.selectionKey).flatMap { try? JSONDecoder().decode(AssistantModel.self, from: $0) } ?? .onDevice
        models = defaults.data(forKey: Self.modelsKey).flatMap { try? JSONDecoder().decode([AssistantProvider: [AssistantModel]].self, from: $0) } ?? [:]
        reloadConnections()
    }

    /// The model a new turn runs on: the user's pick while its provider is
    /// still connected, else Apple's.
    var effectiveModel: AssistantModel {
        selection.provider == .apple || connected.contains(selection.provider) ? selection : .onDevice
    }

    var hasCloudProvider: Bool { !connected.isEmpty }

    func isConnected(_ provider: AssistantProvider) -> Bool { provider == .apple || connected.contains(provider) }

    func select(_ model: AssistantModel) {
        selection = model
        UserDefaults.standard.set(try? JSONEncoder().encode(model), forKey: Self.selectionKey)
    }

    func reloadConnections() {
        var next: Set<AssistantProvider> = []
        let chatGPT = ChatGPTAuth.storedCredentials
        if chatGPT != nil { next.insert(.chatGPT) }
        chatGPTEmail = chatGPT?.email
        if AssistantKeychain.string(Self.keyAccount(.openAI)) != nil { next.insert(.openAI) }
        if AssistantKeychain.string(Self.keyAccount(.anthropic)) != nil { next.insert(.anthropic) }
        connected = next
    }

    // MARK: Connect

    func signInWithChatGPT() async {
        lastError[.chatGPT] = nil
        loading.insert(.chatGPT)
        defer { loading.remove(.chatGPT) }
        do {
            _ = try await ChatGPTAuth.shared.signIn()
            reloadConnections()
            if !UserDefaults.standard.bool(forKey: "assistant.chatgpt.planWelcomed") {
                UserDefaults.standard.set(true, forKey: "assistant.chatgpt.planWelcomed")
                showsPlanWelcome = true
            }
            await refreshModels(.chatGPT, selectFirst: true)
        } catch is CancellationError {
            // Closed the sheet.
        } catch {
            lastError[.chatGPT] = Self.describe(error)
        }
    }

    /// Checks the key by listing models before keeping it.
    func connect(_ provider: AssistantProvider, apiKey: String) async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .openAI || provider == .anthropic, !key.isEmpty else { return false }
        lastError[provider] = nil
        loading.insert(provider)
        defer { loading.remove(provider) }
        do {
            let list = try await Self.fetchModels(provider, credential: .apiKey(key))
            guard AssistantKeychain.set(key, for: Self.keyAccount(provider)) else {
                lastError[provider] = L10n.text("Couldn't save the key to the keychain.")
                return false
            }
            store(list, for: provider)
            reloadConnections()
            if let first = list.first, selection.provider == .apple { select(first) }
            return true
        } catch {
            lastError[provider] = Self.describe(error)
            return false
        }
    }

    func disconnect(_ provider: AssistantProvider) async {
        switch provider {
        case .apple: return
        case .chatGPT: await ChatGPTAuth.shared.signOut()
        case .openAI, .anthropic: AssistantKeychain.set(nil as String?, for: Self.keyAccount(provider))
        }
        models[provider] = nil
        persistModels()
        reloadConnections()
        if selection.provider == provider { select(.onDevice) }
    }

    func refreshModels(_ provider: AssistantProvider, selectFirst: Bool = false) async {
        guard provider.isCloud, connected.contains(provider) else { return }
        loading.insert(provider)
        defer { loading.remove(provider) }
        do {
            let list = try await Self.fetchModels(provider, credential: try await credential(for: provider))
            store(list, for: provider)
            if selectFirst || (selection.provider == provider && !list.contains(selection)), let first = list.first {
                select(first)
            }
            lastError[provider] = nil
        } catch {
            lastError[provider] = Self.describe(error)
            if case ChatGPTAuthError.notSignedIn = error { reloadConnections() }
        }
    }

    private func store(_ list: [AssistantModel], for provider: AssistantProvider) {
        models[provider] = list
        persistModels()
    }

    private func persistModels() {
        UserDefaults.standard.set(try? JSONEncoder().encode(models), forKey: Self.modelsKey)
    }

    // MARK: Credentials

    enum Credential: Sendable {
        case apiKey(String)
        case bearer(String)
    }

    func credential(for provider: AssistantProvider) async throws -> Credential {
        switch provider {
        case .apple: throw AssistantCloudError.notConnected(provider)
        case .chatGPT: return .bearer(try await ChatGPTAuth.shared.accessToken())
        case .openAI, .anthropic:
            guard let key = AssistantKeychain.string(Self.keyAccount(provider)) else { throw AssistantCloudError.notConnected(provider) }
            return .apiKey(key)
        }
    }

    private static func keyAccount(_ provider: AssistantProvider) -> String { "apikey.\(provider.rawValue)" }

    // MARK: Model lists

    private static func fetchModels(_ provider: AssistantProvider, credential: Credential) async throws -> [AssistantModel] {
        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            if case .apiKey(let key) = credential { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            switch credential {
            case .apiKey(let key), .bearer(let key): request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AssistantCloudError.http(status, CloudErrorText.message(in: data)) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        // Sign in with ChatGPT: `models` in the server's order, listable ones.
        if let entries = json["models"] as? [[String: Any]] {
            return entries.compactMap { entry -> AssistantModel? in
                guard let slug = entry["slug"] as? String ?? entry["id"] as? String else { return nil }
                if let visibility = entry["visibility"] as? String, visibility != "list" { return nil }
                return AssistantModel(provider: provider, slug: slug, name: entry["display_name"] as? String ?? slug)
            }
        }
        let entries = json["data"] as? [[String: Any]] ?? []
        if provider == .anthropic {
            return entries.compactMap { entry in
                (entry["id"] as? String).map { AssistantModel(provider: provider, slug: $0, name: entry["display_name"] as? String ?? $0) }
            }
        }
        // A Platform key lists every model the org can call: keep chat models,
        // newest first.
        let excluded = ["audio", "realtime", "tts", "transcribe", "image", "embedding", "moderation", "search", "instruct", "dall-e", "whisper", "davinci", "babbage", "codex", "computer-use"]
        let chat = entries.compactMap { entry -> (String, Double)? in
            guard let id = entry["id"] as? String, id.hasPrefix("gpt-") || id.hasPrefix("o"),
                  !excluded.contains(where: id.contains) else { return nil }
            return (id, entry["created"] as? Double ?? 0)
        }
        return chat.sorted { $0.1 > $1.1 }.map { AssistantModel(provider: provider, slug: $0.0, name: Self.prettyName($0.0)) }
    }

    /// "gpt-5.1-mini" → "GPT-5.1 Mini".
    private static func prettyName(_ slug: String) -> String {
        var parts = slug.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return slug }
        var head = parts.removeFirst()
        if head == "gpt", !parts.isEmpty { head = "GPT-" + parts.removeFirst() }
        return ([head] + parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }

    static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
