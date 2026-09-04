import SwiftUI
import AmgiUI
import AmgiTheme
import AnkiClients
import AnkiSync

struct LoginSheet: View {
    @Environment(\.palette) private var palette

    @Binding var isPresented: Bool
    let onSuccess: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(palette.danger)
                            .amgiFont(.caption)
                    }
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                #if !os(macOS)
                                .frame(maxWidth: .infinity)
                                #endif
                        } else {
                            Text("Sign In")
                                #if !os(macOS)
                                .frame(maxWidth: .infinity)
                                #endif
                        }
                    }
                    #if os(macOS)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    #endif
                    .disabled(username.isEmpty || password.isEmpty || isLoading)
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
            .presentationSizing(.fitted)
            #endif
            .navigationTitle("Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

}

private extension LoginSheet {
    func login() async {
        isLoading = true
        errorMessage = nil
        do {
            _ = try await SyncClient.login(username: username, password: password)
            isPresented = false
            onSuccess()
        } catch {
            errorMessage = "Login failed. Check your username and password."
        }
        isLoading = false
    }
}

#if DEBUG

// MARK: - Preview

#Preview {
    LoginSheet(isPresented: .constant(true), onSuccess: {})
}
#endif
