import SwiftUI

#if DEBUG
/// Hidden debug panel, reached by holding the Policy screen for 5 seconds.
/// Gated behind a password stored in DebugSecrets.swift (gitignored, local-only).
struct DebugUnlockView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss

    @State private var passwordInput: String = ""
    @State private var isUnlocked: Bool = false
    @State private var showIncorrectPassword: Bool = false

    @AppStorage(AppConstants.Storage.isDebugDisplayEnabledKey) private var isDebugDisplayEnabled: Bool = true

    /// Synced phone<->watch via `GameStateManager.isEncryptionEnabled` (not a raw per-device
    /// `@AppStorage` flag) so toggling this here can't leave the two devices unable to decrypt
    /// each other's telemetry/tactical payloads — see `ConfigSnapshot.isEncryptionEnabled`.
    private var isEncryptionEnabledBinding: Binding<Bool> {
        Binding(
            get: { gameState.isEncryptionEnabled },
            set: { gameState.isEncryptionEnabled = $0 }
        )
    }

    private var isProUnlocked: Bool {
        gameState.subscriptionManager.hasUnlimitedSquadUnlock
    }

    /// Setting this to true force-unlocks Pro. Setting it to false is a no-op — once Pro is
    /// unlocked (here or via a real purchase) this toggle can never take it away.
    private var proBinding: Binding<Bool> {
        Binding(
            get: { isProUnlocked },
            set: { newValue in
                if newValue {
                    gameState.subscriptionManager.debugForceUnlockPro()
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if isUnlocked {
                    unlockedForm
                } else {
                    passwordGate
                }
            }
            .navigationTitle("Debug")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var passwordGate: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22))
                .foregroundColor(.gray)

            SecureField("Password", text: $passwordInput)
                .onSubmit(attemptUnlock)

            Button("Unlock", action: attemptUnlock)
                .disabled(passwordInput.isEmpty)
        }
        .padding()
        .alert("Incorrect Password", isPresented: $showIncorrectPassword) {
            Button("OK", role: .cancel) {}
        }
    }

    private func attemptUnlock() {
        if passwordInput == DebugSecrets.debugPanelPassword {
            isUnlocked = true
        } else {
            showIncorrectPassword = true
        }
        passwordInput = ""
    }

    private var unlockedForm: some View {
        Form {
            Toggle("Debug Display", isOn: $isDebugDisplayEnabled)
            Toggle("Encryption", isOn: isEncryptionEnabledBinding)
            Toggle("Pro", isOn: proBinding)
        }
    }
}
#endif
