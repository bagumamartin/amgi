import AnkiClients
import AnkiKit
import AnkiSync
import Dependencies
import os
import SwiftUI

private let logger = Logger(subsystem: "com.amgiapp.AmgiApp", category: "WatchLogin")

struct WatchLoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var endpoint = ""
    /// Form submission state. `showLoginFields` used to sit here too and was
    /// never read.
    enum SubmissionState {
        case idle
        case submitting
        case failed(String)
    }

    @State private var submission: SubmissionState = .idle
    var onLoginSuccess: () -> Void

    private var isSubmitting: Bool {
        if case .submitting = submission { return true }
        return false
    }
    var body: some View {
        ScrollView {
            VStack {
                loginFieldsView
            }
        }
        .onAppear {
            // Prefill endpoint from keychain if available
            if let saved = KeychainHelper.loadEndpoint() {
                endpoint = saved
            }
        }
    }
    private var loginFieldsView: some View {
        VStack {
            TextField("Server URL", text: $endpoint)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $password)
                .textContentType(.password)
            if case .failed(let error) = submission {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await login() }
            } label: {
                if isSubmitting {
                    ProgressView()
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty || password.isEmpty || isSubmitting)
        }
    }
    private func login() async {
        submission = .submitting
        // Persist endpoint if provided
        let ep = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ep.isEmpty {
            // Ignore errors here; login flow should still proceed
            try? KeychainHelper.saveEndpoint(ep)
        }
        do {
            _ = try await SyncClient.login(username: username, password: password)
            // Initial sync to get the collection
            @Dependency(\.syncClient) var syncClient
            _ = try await syncClient.sync()
            submission = .idle
            onLoginSuccess()
        } catch {
            logger.error("Login failed: \(error)")
            submission = .failed("Login failed. Check your credentials.")
        }
    }
}
