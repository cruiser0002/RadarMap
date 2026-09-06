import SwiftUI

public struct RoomDiscoveryView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var manualRoomCode: String = ""
    @State private var manualPin: String = ""
    @State private var manualDatabaseURL: String = ""
    @State private var isManualDatabaseURLEnabled: Bool = true
    @State private var showCreateRoomSheet: Bool = false

    public init() {}

    private var nameLengthValid: Bool {
        let len = manualRoomCode.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= AppConstants.UI.minRoomNameEntryLength && len <= AppConstants.UI.maxRoomNameEntryLength
    }
    private var pinLengthValid: Bool {
        let len = manualPin.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= AppConstants.UI.minPinLength && len <= AppConstants.UI.maxPinLength
    }
    private var nameFieldInvalid: Bool { !manualRoomCode.isEmpty && !nameLengthValid }
    private var pinFieldInvalid: Bool { !manualPin.isEmpty && !pinLengthValid }
    private var canJoin: Bool { nameLengthValid && pinLengthValid }

    public var body: some View {
        NavigationStack {
            List {
                // Host Squad Section
                Section {
                    Button(action: {
                        showCreateRoomSheet = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                            Text("Host New Squad")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.gray)
                        }
                    }
                }

                // Direct Room Entry Section
                Section(header: Text("Join Squad").font(.system(size: 9))) {
                    TextField("Squad Name (4-12)", text: $manualRoomCode)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(nameFieldInvalid ? .red : ((gameState.isJoining || gameState.firebaseManager.isConnected) ? .gray : .primary))
                        .opacity((gameState.isJoining || gameState.firebaseManager.isConnected) ? 0.6 : 1.0)
                        .lineLimit(1)
                        .submitLabel(.done)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .disabled(gameState.isJoining || gameState.firebaseManager.isConnected)
                        .listRowBackground(nameFieldInvalid ? Color.red.opacity(0.18) : nil)
                        .onChange(of: manualRoomCode) { _, newValue in
                            let sanitized = GameStateManager.sanitizeRoomNameInput(newValue)
                            if manualRoomCode != sanitized {
                                manualRoomCode = sanitized
                            }
                            gameState.savedRoomName = sanitized
                        }

                    TextField("PIN (4-16)", text: $manualPin)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(pinFieldInvalid ? .red : ((gameState.isJoining || gameState.firebaseManager.isConnected) ? .gray : .primary))
                        .opacity((gameState.isJoining || gameState.firebaseManager.isConnected) ? 0.6 : 1.0)
                        .lineLimit(1)
                        .submitLabel(.done)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.asciiCapable)
                        #endif
                        .disabled(gameState.isJoining || gameState.firebaseManager.isConnected)
                        .listRowBackground(pinFieldInvalid ? Color.red.opacity(0.18) : nil)
                        .onChange(of: manualPin) { _, newValue in
                            let sanitized = GameStateManager.sanitizePinInput(newValue)
                            if manualPin != sanitized {
                                manualPin = sanitized
                            }
                            gameState.savedPin = manualPin
                        }

                    Button(action: {
                        let cleaned = manualRoomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        let pin = manualPin.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dbURL = isManualDatabaseURLEnabled ? manualDatabaseURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                        gameState.joinRoom(id: cleaned, name: "Squad \(cleaned)", pin: pin, databaseURL: dbURL.isEmpty ? nil : dbURL) { success in
                            if success {
                                dismiss()
                            }
                        }
                    }) {
                        HStack(spacing: 6) {
                            Spacer()
                            if gameState.isJoining {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Joining...")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.cyan)
                            } else {
                                Text("Join Squad")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.cyan)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canJoin || gameState.isJoining || gameState.firebaseManager.isConnected)

                    // See HUD Guide > Bring Your Own Firebase.
                    DatabaseURLField(
                        value: $manualDatabaseURL,
                        isEnabled: $isManualDatabaseURLEnabled,
                        isDisabled: gameState.isJoining || gameState.firebaseManager.isConnected
                    )

                    // Tap to scan a host's QR code — fills room/PIN/URL above and joins.
                    JoinQRBox(
                        isHosting: false,
                        roomId: nil,
                        pin: nil,
                        databaseURL: manualDatabaseURL,
                        isDisabled: gameState.isJoining || gameState.firebaseManager.isConnected
                    ) { payload in
                        // payload.r is the plain room name a host typed — never the derived
                        // (salted+padded) Firebase id — so this joins exactly like manual entry,
                        // re-deriving the padding locally from (name, pin).
                        manualRoomCode = payload.r
                        manualPin = payload.p ?? ""
                        let trimmedURL = payload.d.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasURL = !trimmedURL.isEmpty
                        withAnimation {
                            isManualDatabaseURLEnabled = hasURL
                            gameState.isCustomDatabaseURLEnabled = hasURL
                        }
                        manualDatabaseURL = trimmedURL
                        if hasURL {
                            gameState.customDatabaseURL = trimmedURL
                        } else {
                            gameState.customDatabaseURL = ""
                        }
                        gameState.savedPin = payload.p ?? ""
                        // Equivalent from the user's perspective to typing room/PIN/URL and
                        // hitting enter — push it out over WCSession explicitly, since
                        // customDatabaseURL only syncs on the field losing focus, which never
                        // happens here.
                        gameState.syncConfigToWatchConnectivity()
                        gameState.joinRoom(id: payload.r, pin: payload.p, databaseURL: payload.d) { success in
                            if success {
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Squad Operations")
            #if os(watchOS) || os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showCreateRoomSheet) {
                CreateRoomView()
                    .environmentObject(gameState)
            }
            .onChange(of: gameState.firebaseManager.activeRoom != nil) { _, inRoom in
                if inRoom {
                    dismiss()
                }
            }
            .onChange(of: gameState.savedRoomName) { _, newRoom in
                if manualRoomCode != newRoom {
                    manualRoomCode = newRoom
                }
            }
            .onChange(of: gameState.savedPin) { _, newPin in
                if manualPin != newPin {
                    manualPin = newPin
                }
            }
        }
        .onAppear {
            if manualRoomCode.isEmpty {
                manualRoomCode = gameState.savedRoomName
            }
            if manualPin.isEmpty {
                manualPin = gameState.savedPin
            }
        }
    }
}

