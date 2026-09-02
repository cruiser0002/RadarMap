import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss
    
    // Form fields
    @State private var callsignInput: String = ""
    @State private var squadName: String = ""
    @State private var squadPin: String = ""
    
    // Focus states for auto-scrolling on keyboard appearance
    private enum FocusField: Hashable {
        case callsign
        case squadName
        case pin
    }
    @FocusState private var focusedField: FocusField?
    
    // Paywall state
    @State private var showPaywall: Bool = false
    @State private var showErrorAlert: Bool = false
    @State private var currentErrorText: String = ""
    
    public init() {}
    
    private var squadMembers: [SquadMember] {
        guard let room = gameState.firebaseManager.activeRoom else { return [] }
        return Array(room.members.values)
    }
    
    private var isConnected: Bool {
        gameState.firebaseManager.isConnected && gameState.firebaseManager.activeRoom != nil
    }
    
    private var isHost: Bool {
        isConnected && gameState.isCurrentMemberHost
    }
    
    private var isClient: Bool {
        isConnected && !gameState.isCurrentMemberHost
    }
    
    private var isBusy: Bool {
        isConnected || gameState.isHosting || gameState.isInitiatingHost || gameState.isJoining
    }
    
    public var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    callsignField
                    squadNameField
                    pinField
                    hostButton
                    joinButton
                }
                
                radarColorSection
                
                privacyUploadSection
                
                paywallSection
                
                hudGuideSection
                
                policySection
                
                if let room = gameState.firebaseManager.activeRoom {
                    rosterSection(room: room)
                }
            }
            .navigationTitle("Config")
            #if os(watchOS) || os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    callsignInput = gameState.myCallsign
                    if let room = gameState.firebaseManager.activeRoom {
                        squadName = room.name
                    } else if squadName.isEmpty {
                        squadName = gameState.savedRoomName
                    }
                    if squadPin.isEmpty {
                        squadPin = gameState.savedPin
                    }
                    if let error = gameState.errorMessage, !error.isEmpty {
                        currentErrorText = error
                        showErrorAlert = true
                    }
                }
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack {
                    PaywallView()
                        .environmentObject(gameState)
                }
            }
            .alert(
                "Error",
                isPresented: $showErrorAlert
            ) {
                Button("OK", role: .cancel) {
                    DispatchQueue.main.async {
                        gameState.errorMessage = nil
                    }
                }
            } message: {
                Text(currentErrorText.isEmpty ? (gameState.errorMessage ?? "An error occurred.") : currentErrorText)
            }
            .onChange(of: gameState.errorMessage) { _, newError in
                DispatchQueue.main.async {
                    if let error = newError, !error.isEmpty {
                        currentErrorText = error
                        showErrorAlert = true
                    } else if newError == nil {
                        showErrorAlert = false
                    }
                }
            }
            .onChange(of: showErrorAlert) { _, isShowing in
                if !isShowing && gameState.errorMessage != nil {
                    DispatchQueue.main.async {
                        gameState.errorMessage = nil
                    }
                }
            }
            .onChange(of: focusedField) { _, newField in
                if let field = newField {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(field, anchor: .center)
                    }
                }
            }
            .onChange(of: isBusy) { _, busy in
                if busy {
                    focusedField = nil
                }
            }
            .onChange(of: gameState.myCallsign) { _, newCallsign in
                if callsignInput != newCallsign {
                    callsignInput = newCallsign
                }
            }
            .onChange(of: gameState.savedRoomName) { _, newRoom in
                if gameState.firebaseManager.activeRoom == nil && squadName != newRoom {
                    squadName = newRoom
                }
            }
            .onChange(of: gameState.savedPin) { _, newPin in
                if squadPin != newPin {
                    squadPin = newPin
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var callsignField: some View {
        TextField("Callsign", text: $callsignInput)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(gameState.callsignError ? .red : (isBusy ? .gray : .primary))
            .opacity(isBusy ? 0.6 : 1.0)
            .lineLimit(1)
            .submitLabel(.done)
            #if os(iOS) || os(watchOS)
            .textInputAutocapitalization(.characters)
            #endif
            .autocorrectionDisabled()
            .focused($focusedField, equals: .callsign)
            .id(FocusField.callsign)
            .disabled(isBusy)
            .listRowBackground(gameState.callsignError ? Color.red.opacity(0.18) : nil)
            .onChange(of: callsignInput) { _, newValue in
                gameState.callsignError = false
                let filtered = newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                gameState.myCallsign = filtered
            }
    }
    
    @ViewBuilder
    private var squadNameField: some View {
        TextField("Room Name", text: $squadName)
            .font(.system(size: 11))
            .foregroundColor(gameState.squadNameError ? .red : (isBusy ? .gray : .primary))
            .opacity(isBusy ? 0.6 : 1.0)
            .lineLimit(1)
            .submitLabel(.done)
            #if os(iOS) || os(watchOS)
            .textInputAutocapitalization(.characters)
            #endif
            .autocorrectionDisabled()
            .focused($focusedField, equals: .squadName)
            .id(FocusField.squadName)
            .disabled(isBusy)
            .listRowBackground(gameState.squadNameError ? Color.red.opacity(0.18) : nil)
            .onChange(of: squadName) { _, newValue in
                gameState.squadNameError = false
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                gameState.savedRoomName = trimmed
            }
    }
    
    @ViewBuilder
    private var pinField: some View {
        TextField("PIN (4 digits, optional)", text: $squadPin)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(gameState.pinError ? .red : (isBusy ? .gray : .primary))
            .opacity(isBusy ? 0.6 : 1.0)
            .lineLimit(1)
            .submitLabel(.done)
            .textContentType(.oneTimeCode)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .focused($focusedField, equals: .pin)
            .id(FocusField.pin)
            .disabled(isBusy)
            .listRowBackground(gameState.pinError ? Color.red.opacity(0.18) : nil)
            .onChange(of: squadPin) { _, newValue in
                gameState.pinError = false
                let sanitized = GameStateManager.sanitizePinInput(newValue)
                if squadPin != sanitized {
                    squadPin = sanitized
                }
                gameState.savedPin = squadPin
            }
    }
    
    @ViewBuilder
    private var hostButton: some View {
        if isHost {
            Button(action: {
                gameState.leaveCurrentRoom()
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "xmark.circle.fill")
                    Text("Disband")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(Color.red)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: {
                let name = squadName.trimmingCharacters(in: .whitespacesAndNewlines)
                let pin = squadPin.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = gameState.hostRoom(name: name, pin: pin.isEmpty ? nil : pin)
            }) {
                HStack(spacing: 6) {
                    Spacer()
                    if gameState.isInitiatingHost {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.black)
                        Text("Initiating...")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Host")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor((gameState.isJoining || isClient) ? .gray : .black)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .background((gameState.isJoining || isClient) ? Color.gray.opacity(0.3) : Color.green)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(gameState.isJoining || gameState.isInitiatingHost || isClient)
        }
    }
    
    @ViewBuilder
    private var joinButton: some View {
        if isClient {
            Button(action: {
                gameState.leaveCurrentRoom()
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Logout")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(Color.red)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: {
                let name = squadName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let pin = squadPin.trimmingCharacters(in: .whitespacesAndNewlines)
                gameState.joinRoom(id: name, name: name, pin: pin.isEmpty ? nil : pin)
            }) {
                HStack(spacing: 6) {
                    Spacer()
                    if gameState.isJoining {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.black)
                        Text("Joining...")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                    } else {
                        Image(systemName: "person.badge.plus")
                        Text("Join")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor((gameState.isInitiatingHost || isHost) ? .gray : .black)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .background((gameState.isInitiatingHost || isHost) ? Color.gray.opacity(0.3) : Color.cyan)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(gameState.isInitiatingHost || gameState.isJoining || isHost)
        }
    }
    
    @ViewBuilder
    private var radarColorSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { gameState.radarColorTheme == .green },
                set: { gameState.radarColorTheme = $0 ? .green : .red }
            )) {
                HStack {
                    Text("Radar color")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(gameState.radarColorTheme.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(gameState.radarColorTheme.color)
                }
            }
        }
    }
    
    @ViewBuilder
    private var privacyUploadSection: some View {
        Section(header: Text("Data Sharing").font(.system(size: 9))) {
            Toggle(isOn: Binding(
                get: { gameState.isUploadLocationEnabled },
                set: { enabled in
                    withAnimation {
                        gameState.isUploadLocationEnabled = enabled
                    }
                }
            )) {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("Upload Location")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            
            Toggle(isOn: $gameState.isUploadHeartRateEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("Upload HR")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
    }
    
    @ViewBuilder
    private var paywallSection: some View {
        Section {
            if gameState.subscriptionManager.hasUnlimitedSquadUnlock {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.yellow)
                    Text("Pro Unlocked")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.yellow)
                }
            } else {
                Button(action: {
                    showPaywall = true
                }) {
                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.yellow)
                        Text("Unlock Pro")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var hudGuideSection: some View {
        Section {
            NavigationLink(destination: HUDGuideView()) {
                HStack(spacing: 8) {
                    Image(systemName: "book.pages.fill")
                        .foregroundColor(.green)
                    Text("HUD Guide")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
    }
    
    @ViewBuilder
    private var policySection: some View {
        Section {
            NavigationLink(destination: PolicyView()) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.shield.fill")
                        .foregroundColor(.cyan)
                    Text("Policy")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
    }
    
    @ViewBuilder
    private func rosterSection(room: SquadRoom) -> some View {
        Section(header: Text("Roster (\(room.memberCount))").font(.system(size: 9))) {
            ForEach(squadMembers, id: \.id) { member in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(member.callsign)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(member.id == gameState.myMemberId ? .cyan : .white)
                            
                            if member.isHost {
                                Text("HOST")
                                    .font(.system(size: 7, weight: .bold))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.yellow.opacity(0.3))
                                    .foregroundColor(.yellow)
                                    .cornerRadius(3)
                            }
                        }
                        
                        Text("Heading: \(Int(member.heading))°")
                            .font(.system(size: 8))
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 8))
                            .foregroundColor(member.heartRateZoneColor)
                        Text("\(Int(member.heartRate))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                }
            }
        }
    }
}

