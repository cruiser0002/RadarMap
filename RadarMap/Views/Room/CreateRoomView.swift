import SwiftUI

public struct CreateRoomView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var roomName: String = ""
    @State private var roomPassword: String = ""
    @State private var customDatabaseURL: String = ""
    @State private var squadCapacity: Int = AppConstants.Subscription.freeTierMaxCapacity
    @State private var showPaywall: Bool = false
    @State private var navigateToLobby: Bool = false

    public init() {}

    private var nameLengthValid: Bool {
        let len = roomName.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= AppConstants.UI.minRoomNameEntryLength && len <= AppConstants.UI.maxRoomNameEntryLength
    }
    private var pinLengthValid: Bool {
        let len = roomPassword.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= AppConstants.UI.minPinLength && len <= AppConstants.UI.maxPinLength
    }
    private var nameFieldInvalid: Bool { !roomName.isEmpty && !nameLengthValid }
    private var pinFieldInvalid: Bool { !roomPassword.isEmpty && !pinLengthValid }
    private var canHost: Bool { nameLengthValid && pinLengthValid }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    // Room Name Field
                    TextField("Squad Name (4-12)", text: $roomName)
                        .font(.system(size: 12))
                        .foregroundColor(nameFieldInvalid ? .red : ((gameState.isHosting || gameState.firebaseManager.isConnected) ? .gray : .primary))
                        .opacity((gameState.isHosting || gameState.firebaseManager.isConnected) ? 0.6 : 1.0)
                        .padding(8)
                        .background(nameFieldInvalid ? Color.red.opacity(0.18) : Color.white.opacity(0.1))
                        .cornerRadius(6)
                        .lineLimit(1)
                        .submitLabel(.done)
                        .autocorrectionDisabled(true)
                        .disabled(gameState.isHosting || gameState.firebaseManager.isConnected)
                        .onChange(of: roomName) { _, newValue in
                            let sanitized = GameStateManager.sanitizeRoomNameInput(newValue)
                            if roomName != sanitized {
                                roomName = sanitized
                            }
                            gameState.savedRoomName = sanitized
                        }

                    // Squad PIN Field (mandatory, 4-16 digits)
                    TextField("PIN (4-16)", text: $roomPassword)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(pinFieldInvalid ? .red : ((gameState.isHosting || gameState.firebaseManager.isConnected) ? .gray : .primary))
                        .opacity((gameState.isHosting || gameState.firebaseManager.isConnected) ? 0.6 : 1.0)
                        .padding(8)
                        .background(pinFieldInvalid ? Color.red.opacity(0.18) : Color.white.opacity(0.1))
                        .cornerRadius(6)
                        .lineLimit(1)
                        .submitLabel(.done)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.asciiCapable)
                        #endif
                        .disabled(gameState.isHosting || gameState.firebaseManager.isConnected)
                        .onChange(of: roomPassword) { _, newValue in
                            let sanitized = GameStateManager.sanitizePinInput(newValue)
                            if roomPassword != sanitized {
                                roomPassword = sanitized
                            }
                            gameState.savedPin = roomPassword
                        }

                    // Capacity Tier Status (4 or 999)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("SQUAD CAPACITY")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.gray)
                            Spacer()
                            
                            if gameState.subscriptionManager.hasUnlimitedSquadUnlock {
                                Text("Up to \(AppConstants.Subscription.proTierMaxCapacity) Players (Pro)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.green)
                            } else {
                                Text("\(AppConstants.Subscription.freeTierMaxCapacity) Players (Free)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                        }
                        
                        if !gameState.subscriptionManager.hasUnlimitedSquadUnlock {
                            Button(action: {
                                showPaywall = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                    Text("Upgrade to \(AppConstants.Subscription.proTierMaxCapacity) Players (\(AppConstants.Subscription.lifetimePriceString))")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(Color.yellow.opacity(0.2))
                                .foregroundColor(.yellow)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                    
                    Button(action: {
                        gameState.hostRoom(name: roomName, pin: roomPassword) { success in
                            if success {
                                dismiss()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Host Squad")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(canHost ? Color.green : Color.gray.opacity(0.3))
                        .foregroundColor(.black)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canHost || gameState.isHosting || gameState.firebaseManager.isConnected)
                    .padding(.top, 4)

                    // Optional: run this squad on your own Firebase project instead of the
                    // shared default (see HUD Guide > Bring Your Own Firebase, or
                    // BRING_YOUR_OWN_FIREBASE.md).
                    DatabaseURLField(
                        value: $customDatabaseURL,
                        isEnabled: $gameState.isCustomDatabaseURLEnabled,
                        isDisabled: gameState.isHosting || gameState.firebaseManager.isConnected,
                        onEditingFinished: { gameState.syncConfigToWatchConnectivity() }
                    )
                    .onChange(of: customDatabaseURL) { _, newValue in
                        gameState.customDatabaseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .padding(.top, 4)

                    // Scanning here only ever sets the database URL, never the room name/PIN,
                    // since this screen is host-only.
                    JoinQRBox(
                        isHosting: gameState.firebaseManager.activeRoom != nil && gameState.firebaseManager.isConnected,
                        // The plain typed room name only — never the derived (salted+padded)
                        // Firebase room id. Read from the textbox state, not
                        // gameState.savedRoomName: that property gets rewritten on nearly every
                        // low-speed convergence sync tick (adoptCompanionSession in
                        // GameStateManager compares the derived activeRoom.id against the plain
                        // config.roomName, which never match, so it fires almost every sync and
                        // stomps savedRoomName) — which made the QR flicker on every
                        // upload/download. The textbox is the stable source of truth here, and a
                        // joiner re-derives the same padding locally from (name, pin) themselves.
                        roomId: roomName.isEmpty ? nil : roomName,
                        pin: roomPassword,
                        // The raw setting (empty when hosting on the shared default), not the
                        // resolved firebaseManager.databaseURL — a default-project host's QR
                        // should never embed that project's actual URL. See JoinQRBox.swift.
                        databaseURL: customDatabaseURL,
                        isDisabled: gameState.isHosting || gameState.firebaseManager.isConnected
                    ) { payload in
                        let trimmedURL = payload.d.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hasURL = !trimmedURL.isEmpty
                        withAnimation {
                            gameState.isCustomDatabaseURLEnabled = hasURL
                        }
                        if hasURL {
                            customDatabaseURL = trimmedURL
                            gameState.customDatabaseURL = trimmedURL
                        } else {
                            customDatabaseURL = ""
                            gameState.customDatabaseURL = ""
                        }
                        // Equivalent from the user's perspective to typing the URL box and hitting
                        // enter — push it out over WCSession explicitly, since customDatabaseURL
                        // only syncs on the field losing focus, which never happens here.
                        gameState.syncConfigToWatchConnectivity()
                    }
                }
                .padding(.horizontal, 6)
            }
            .navigationTitle("Host Room")
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
            .sheet(isPresented: $showPaywall) {
                PaywallView()
                    .environmentObject(gameState)
            }
            .sheet(isPresented: $gameState.showPaywallSheet) {
                PaywallView()
                    .environmentObject(gameState)
            }
            .onChange(of: gameState.firebaseManager.activeRoom != nil) { _, inRoom in
                if inRoom {
                    dismiss()
                }
            }
            .onChange(of: gameState.savedRoomName) { _, newRoom in
                if roomName != newRoom {
                    roomName = newRoom
                }
            }
            .onChange(of: gameState.savedPin) { _, newPin in
                if roomPassword != newPin {
                    roomPassword = newPin
                }
            }
            .onAppear {
                if roomName.isEmpty {
                    roomName = gameState.savedRoomName
                }
                if roomPassword.isEmpty {
                    roomPassword = gameState.savedPin
                }
                if customDatabaseURL.isEmpty {
                    customDatabaseURL = gameState.customDatabaseURL
                }
            }
        }
    }
}

