import AmgiAppCore
import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tokens from Sign in with ChatGPT. Lives in the keychain only.
struct ChatGPTCredentials: Codable, Sendable {
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
    var scopes: [String]
    var email: String?
    var subject: String
}

/// What survives sign-out: the client OpenAI issued this install, its host
/// ID, and the last ID token (sent as a hint when signing in again).
private struct ChatGPTRegistration: Codable, Sendable {
    var hostID: String
    var clientID: String?
    var lastIDToken: String?
    var email: String?
}

enum ChatGPTAuthError: LocalizedError {
    case notSignedIn
    case callback(String)
    case stateMismatch
    case registrationIncomplete
    case clientMismatch
    case tokenExchange(String)
    case invalidIDToken(String)
    case missingPlanScope

    var errorDescription: String? {
        switch self {
        case .notSignedIn: L10n.text("Sign in with ChatGPT again to keep using it.")
        case .callback(let reason): L10n.text("ChatGPT sign-in failed: \(reason)")
        case .stateMismatch: L10n.text("The sign-in response didn't match this request. Try again.")
        case .registrationIncomplete: L10n.text("OpenAI didn't finish registering Ijuka. Try again.")
        case .clientMismatch: L10n.text("OpenAI answered for a different app registration. Try again.")
        case .tokenExchange(let reason): L10n.text("Couldn't finish signing in: \(reason)")
        case .invalidIDToken(let reason): L10n.text("ChatGPT's identity token failed verification (\(reason)).")
        case .missingPlanScope: L10n.text("ChatGPT sign-in worked, but plan usage wasn't granted. Allow it when asked, or use an API key.")
        }
    }
}

/// Sign in with ChatGPT, the open-source flow: dynamic client registration
/// on first sign-in, PKCE, a loopback redirect, and an ID token checked
/// against OpenAI's published keys. Inference then runs on the public
/// Responses API with the access token, which refreshes itself.
///
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
actor ChatGPTAuth {
    static let shared = ChatGPTAuth()

    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    private static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    private static let dynamicClient = "dynamic_agent_client"
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let callbackPath = "/auth/callback"
    private static let callbackPorts: [UInt16] = [1455, 1456, 1457, 1458, 1459]
    private static let finishScheme = "ijuka-oauth"

    private static let credentialsAccount = "chatgpt.credentials"
    private static let registrationAccount = "chatgpt.registration"

    private var refreshing: Task<ChatGPTCredentials, any Error>?

    /// The stored session, if any. Cheap; safe to call from the UI.
    nonisolated static var storedCredentials: ChatGPTCredentials? {
        AssistantKeychain.value(ChatGPTCredentials.self, credentialsAccount)
    }

    // MARK: Sign in

    func signIn() async throws -> ChatGPTCredentials {
        var registration = AssistantKeychain.value(ChatGPTRegistration.self, Self.registrationAccount)
            ?? ChatGPTRegistration(hostID: "urn:uuid:\(UUID().uuidString.lowercased())")
        AssistantKeychain.set(value: registration, for: Self.registrationAccount)

        let server = try await LoopbackCallbackServer(
            ports: Self.callbackPorts, path: Self.callbackPath,
            finishURL: URL(string: "\(Self.finishScheme)://chatgpt")!
        )
        defer { server.stop() }

        let verifier = Self.randomToken(64)
        let state = Self.randomToken(32)
        let nonce = Self.randomToken(32)
        let clientID = registration.clientID ?? Self.dynamicClient

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: server.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "ext_agent_host_id", value: registration.hostID),
        ]
        if registration.clientID == nil {
            items.append(.init(name: "agent_name_hint", value: "Ijuka"))
        } else {
            if let hint = registration.lastIDToken { items.append(.init(name: "id_token_hint", value: hint)) }
            if let email = registration.email { items.append(.init(name: "login_hint", value: email)) }
        }
        components.queryItems = items

        let callback = try await Self.authorize(url: components.url!, server: server)
        if let error = callback.items["error"] {
            throw ChatGPTAuthError.callback(callback.items["error_description"] ?? error)
        }
        guard callback.items["state"] == state else { throw ChatGPTAuthError.stateMismatch }
        guard let code = callback.items["code"], !code.isEmpty else { throw ChatGPTAuthError.callback(L10n.text("no code returned")) }

        // First sign-in registers the app; the callback names the new client.
        let issued = callback.items["client_id"].flatMap { $0.isEmpty ? nil : $0 }
        let resolvedClient: String
        if let existing = registration.clientID {
            if let issued, issued != existing { throw ChatGPTAuthError.clientMismatch }
            resolvedClient = existing
        } else {
            guard let issued, issued != Self.dynamicClient else { throw ChatGPTAuthError.registrationIncomplete }
            resolvedClient = issued
            registration.clientID = issued
            AssistantKeychain.set(value: registration, for: Self.registrationAccount)
        }

        let response = try await Self.tokenRequest([
            "grant_type": "authorization_code",
            "client_id": resolvedClient,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": server.redirectURI,
            "resource": Self.resource,
        ])
        guard let idToken = response.idToken else { throw ChatGPTAuthError.invalidIDToken(L10n.text("missing")) }
        let identity = try await Self.verifyIDToken(idToken, clientID: resolvedClient, nonce: nonce)
        let credentials = try Self.credentials(from: response, idToken: idToken, identity: identity, clientID: resolvedClient)
        guard credentials.scopes.contains(Self.planScope) else { throw ChatGPTAuthError.missingPlanScope }

        registration.lastIDToken = idToken
        registration.email = credentials.email
        AssistantKeychain.set(value: registration, for: Self.registrationAccount)
        AssistantKeychain.set(value: credentials, for: Self.credentialsAccount)
        return credentials
    }

    /// Keeps the app registration and host ID; drops the tokens and the
    /// ID-token hint, as the flow asks after a sign-out.
    func signOut() {
        refreshing?.cancel()
        refreshing = nil
        AssistantKeychain.set(nil as Data?, for: Self.credentialsAccount)
        if var registration = AssistantKeychain.value(ChatGPTRegistration.self, Self.registrationAccount) {
            registration.lastIDToken = nil
            AssistantKeychain.set(value: registration, for: Self.registrationAccount)
        }
    }

    // MARK: Tokens

    /// A bearer token good for at least two more minutes, refreshing first
    /// when needed. Concurrent callers share one refresh.
    func accessToken() async throws -> String {
        guard let current = Self.storedCredentials else { throw ChatGPTAuthError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 120 { return current.accessToken }
        return try await refresh(current).accessToken
    }

    /// After a 401: the token was revoked or rotated elsewhere.
    func forceRefresh() async throws -> String {
        guard let current = Self.storedCredentials else { throw ChatGPTAuthError.notSignedIn }
        return try await refresh(current).accessToken
    }

    private func refresh(_ current: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        if let refreshing { return try await refreshing.value }
        let task = Task { () throws -> ChatGPTCredentials in
            do {
                let response = try await Self.tokenRequest([
                    "grant_type": "refresh_token",
                    "client_id": current.clientID,
                    "refresh_token": current.refreshToken,
                    "resource": Self.resource,
                ])
                var next = current
                next.accessToken = response.accessToken
                // The refresh token rotates; replace everything together.
                next.refreshToken = response.refreshToken ?? current.refreshToken
                next.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
                if let scope = response.scope { next.scopes = scope.split(separator: " ").map(String.init) }
                if let idToken = response.idToken { next.idToken = idToken }
                AssistantKeychain.set(value: next, for: Self.credentialsAccount)
                return next
            } catch let ChatGPTAuthError.tokenExchange(reason) where reason.contains("invalid_grant") {
                AssistantKeychain.set(nil as Data?, for: Self.credentialsAccount)
                throw ChatGPTAuthError.notSignedIn
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    // MARK: Browser

    /// Opens the authorize page in the system's web-authentication sheet and
    /// waits for the loopback server to catch the redirect. The server then
    /// bounces the sheet to a custom scheme, which closes it.
    private static func authorize(url: URL, server: LoopbackCallbackServer) async throws -> LoopbackCallbackServer.Callback {
        try await withThrowingTaskGroup(of: LoopbackCallbackServer.Callback?.self) { group in
            group.addTask { try await server.callback() }
            group.addTask {
                try await WebAuthenticationRunner.run(url: url, callbackScheme: finishScheme)
                return nil
            }
            while let result = try await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            throw ChatGPTAuthError.callback(L10n.text("the browser closed early"))
        }
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Int?
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
            case expiresIn = "expires_in", scope
        }
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reason = [body?["error"] as? String, body?["error_description"] as? String].compactMap { $0 }.joined(separator: ": ")
            throw ChatGPTAuthError.tokenExchange(reason.isEmpty ? "HTTP \(status)" : reason)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private struct Identity: Sendable {
        let subject: String
        let email: String?
    }

    private static func credentials(from response: TokenResponse, idToken: String, identity: Identity, clientID: String) throws -> ChatGPTCredentials {
        guard let refresh = response.refreshToken else { throw ChatGPTAuthError.tokenExchange(L10n.text("no refresh token")) }
        let scope = response.scope ?? ((try? JWT.parse(response.accessToken).payload["scope"]) as? String) ?? ""
        return ChatGPTCredentials(
            clientID: clientID, accessToken: response.accessToken, refreshToken: refresh, idToken: idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)),
            scopes: scope.split(separator: " ").map(String.init), email: identity.email, subject: identity.subject
        )
    }

    // MARK: ID token

    private static func verifyIDToken(_ token: String, clientID: String, nonce: String) async throws -> Identity {
        let jwt = try JWT.parse(token)
        guard jwt.header["alg"] as? String == "RS256" else { throw ChatGPTAuthError.invalidIDToken("alg") }
        let (data, _) = try await URLSession.shared.data(from: jwksURL)
        guard let keys = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["keys"] as? [[String: Any]] else {
            throw ChatGPTAuthError.invalidIDToken("jwks")
        }
        let kid = jwt.header["kid"] as? String
        let candidates = keys.filter { ($0["kty"] as? String) == "RSA" && (kid == nil || ($0["kid"] as? String) == kid) }
        guard candidates.contains(where: { JWT.verifyRS256(jwt, n: $0["n"] as? String, e: $0["e"] as? String) }) else {
            throw ChatGPTAuthError.invalidIDToken("signature")
        }
        let claims = jwt.payload
        guard (claims["iss"] as? String) == issuer else { throw ChatGPTAuthError.invalidIDToken("issuer") }
        let audience = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard audience.contains(clientID) else { throw ChatGPTAuthError.invalidIDToken("audience") }
        guard let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) > Date().addingTimeInterval(-60) else {
            throw ChatGPTAuthError.invalidIDToken("expired")
        }
        guard (claims["nonce"] as? String) == nonce else { throw ChatGPTAuthError.invalidIDToken("nonce") }
        guard let subject = claims["sub"] as? String else { throw ChatGPTAuthError.invalidIDToken("sub") }
        return Identity(subject: subject, email: claims["email"] as? String)
    }

    // MARK: Helpers

    private static func randomToken(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - JWT

enum JWT {
    struct Parsed {
        let header: [String: Any]
        let payload: [String: Any]
        let signingInput: Data
        let signature: Data
    }

    static func parse(_ token: String) throws -> Parsed {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = decode(parts[0]), let payloadData = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw ChatGPTAuthError.invalidIDToken("format") }
        return Parsed(header: header, payload: payload, signingInput: Data("\(parts[0]).\(parts[1])".utf8), signature: signature)
    }

    static func verifyRS256(_ jwt: Parsed, n: String?, e: String?) -> Bool {
        guard let n = n.flatMap(decode), let e = e.flatMap(decode) else { return false }
        let der = sequence(integer(n) + integer(e))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, jwt.signingInput as CFData, jwt.signature as CFData, nil)
    }

    static func decode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    private static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }

    private static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

// MARK: - Web authentication sheet

@MainActor
enum WebAuthenticationRunner {
    private static var active: ASWebAuthenticationSession?
    private static let anchor = AnchorProvider()

    /// Shows the sheet and returns when it lands on `callbackScheme`.
    /// Throws when the user closes it.
    static func run(url: URL, callbackScheme: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // `@Sendable` keeps this closure from inheriting main-actor isolation:
            // on macOS the session calls it on an XPC queue, and the inherited
            // isolation check traps there.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable _, error in
                Task { @MainActor in active = nil }
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
            // Reuse the browser's ChatGPT sign-in and passkeys.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = anchor
            active = session
            if !session.start() {
                active = nil
                continuation.resume(throwing: ChatGPTAuthError.callback(L10n.text("the sign-in sheet couldn't open")))
            }
        }
    }

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                #if os(macOS)
                NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
                #else
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                let windows = scenes.flatMap(\.windows)
                return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
                #endif
            }
        }
    }
}
