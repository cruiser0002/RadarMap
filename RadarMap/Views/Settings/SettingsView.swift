import SwiftUI
import CoreLocation
#if canImport(HealthKit)
import HealthKit
#endif

public struct SettingsView: View {
    @EnvironmentObject var gameState: GameStateManager
    @Environment(\.dismiss) private var dismiss
    
    // Form fields
    @State private var callsignInput: String = ""
    @State private var squadName: String = ""
    @State private var squadPin: String = ""
    @State private var customDatabaseURL: String = ""

    // Focus states for auto-scrolling on keyboard appearance
    private enum FocusField: Hashable {
        case callsign
        case squadName
        case pin
        case databaseURL
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

    private var nameLengthValid: Bool {
        let len = squadName.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= AppConstants.UI.minRoomNameEntryLength && len <= AppConstants.UI.maxRoomNameEntryLength
    }
    private var pinLengthValid: Bool {
        let len = squadPin.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= AppConstants.UI.minPinLength && len <= AppConstants.UI.maxPinLength
    }
    private var nameFieldInvalid: Bool { !squadName.isEmpty && !nameLengthValid }
    private var pinFieldInvalid: Bool { !squadPin.isEmpty && !pinLengthValid }
    private var canHostOrJoin: Bool { nameLengthValid && pinLengthValid }
    
    public var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    joinQRBox
                    joinButton
                    hostButton
                    callsignField
                    squadNameField
                    pinField
                    databaseURLField
                    locationUploadToggle
                    healthDataUploadToggle
                    radarColorRow
                    paywallRow
                    hudGuideRow
                    policyRow
                }
                
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
                    // room.name is an alias for the room's Firebase id (the salted+padded
                    // string) — never the plain typed name. savedRoomName is the one property
                    // guaranteed to hold only what was actually typed, whether hosting or joined.
                    if squadName.isEmpty {
                        squadName = gameState.savedRoomName
                    }
                    if squadPin.isEmpty {
                        squadPin = gameState.savedPin
                    }
                    if customDatabaseURL.isEmpty {
                        customDatabaseURL = gameState.customDatabaseURL
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
        TextField("Room Name (4-12)", text: $squadName)
            .font(.system(size: 11))
            .foregroundColor((gameState.squadNameError || nameFieldInvalid) ? .red : (isBusy ? .gray : .primary))
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
            .listRowBackground((gameState.squadNameError || nameFieldInvalid) ? Color.red.opacity(0.18) : nil)
            .onChange(of: squadName) { _, newValue in
                gameState.squadNameError = false
                let sanitized = GameStateManager.sanitizeRoomNameInput(newValue)
                if squadName != sanitized {
                    squadName = sanitized
                }
                gameState.savedRoomName = sanitized
            }
    }

    @ViewBuilder
    private var pinField: some View {
        TextField("PIN (4-16)", text: $squadPin)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor((gameState.pinError || pinFieldInvalid) ? .red : (isBusy ? .gray : .primary))
            .opacity(isBusy ? 0.6 : 1.0)
            .lineLimit(1)
            .submitLabel(.done)
            .textContentType(.oneTimeCode)
            #if os(iOS)
            .keyboardType(.asciiCapable)
            #endif
            .focused($focusedField, equals: .pin)
            .id(FocusField.pin)
            .disabled(isBusy)
            .listRowBackground((gameState.pinError || pinFieldInvalid) ? Color.red.opacity(0.18) : nil)
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
    private var databaseURLField: some View {
        // Optional: run this squad on your own Firebase project instead of the shared default.
        // See the HUD Guide's "Bring Your Own Firebase" entry, or BRING_YOUR_OWN_FIREBASE.md.
        DatabaseURLField(
            value: $customDatabaseURL,
            isEnabled: $gameState.isCustomDatabaseURLEnabled,
            isDisabled: isBusy,
            recentURLs: gameState.recentDatabaseURLs,
            onEditingFinished: { gameState.syncConfigToWatchConnectivity() }
        )
        .id(FocusField.databaseURL)
        .onChange(of: customDatabaseURL) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            gameState.customDatabaseURL = trimmed
        }
    }

    @ViewBuilder
    private var joinQRBox: some View {
        // A scanned full join code fills the room name/PIN above too, since this field is shared
        // by both the Host and Join actions here.
        JoinQRBox(
            // Shown once connected, whether hosting or joined as a client, so any member can
            // hand teammates a no-friction join code — not just the host.
            isHosting: isConnected,
            // The plain typed room name only — never the derived (salted+padded) Firebase room
            // id. Read from the textbox state, not gameState.savedRoomName: that property gets
            // rewritten on every low-speed convergence sync tick (adoptCompanionSession compares
            // the derived activeRoom.id against the plain config.roomName, which never match, so
            // it fires on nearly every sync and stomps savedRoomName), which made the QR flicker
            // on every upload/download. The textbox is the stable source of truth here, and a
            // joiner re-derives the same padding locally from (name, pin) themselves.
            roomId: squadName.isEmpty ? nil : squadName,
            pin: squadPin,
            // The raw setting (empty when hosting on the shared default), not the resolved
            // firebaseManager.databaseURL — a default-project host's QR should never embed that
            // project's actual URL. See JoinQRBox.swift.
            databaseURL: customDatabaseURL,
            isDisabled: isBusy && !isConnected
        ) { payload in
            // payload.r is the plain room name (see the roomId comment above) — safe to treat
            // exactly like manual entry, including saving it into gameState.savedRoomName below.
            squadName = payload.r
            gameState.savedRoomName = payload.r
            squadPin = payload.p ?? ""
            gameState.savedPin = payload.p ?? ""
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
            // A scan is a batch fill of all 4 synced fields at once, equivalent from the user's
            // perspective to typing each textbox and hitting enter — push it out over WCSession
            // explicitly rather than relying on individual field triggers (customDatabaseURL in
            // particular only syncs on the field losing focus, which never happens here).
            gameState.syncConfigToWatchConnectivity()
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
                _ = gameState.hostRoom(name: name, pin: pin)
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
            .disabled(!canHostOrJoin || gameState.isJoining || gameState.isInitiatingHost || isClient)
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
                let dbURL = customDatabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                gameState.joinRoom(id: name, name: name, pin: pin, databaseURL: dbURL.isEmpty ? nil : dbURL)
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
            .disabled(!canHostOrJoin || gameState.isInitiatingHost || gameState.isJoining || isHost)
        }
    }
    
    @ViewBuilder
    private var radarColorRow: some View {
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
    
    @ViewBuilder
    private var locationUploadToggle: some View {
        Toggle(isOn: Binding(
            get: {
                gameState.isUploadLocationEnabled && permissionState(for: gameState.locationHeadingManager.authorizationStatus) == .granted
            },
            set: { enabled in
                handlePermissionBackedToggle(
                    enabled: enabled,
                    currentState: permissionState(for: gameState.locationHeadingManager.authorizationStatus),
                    requestAccess: { gameState.locationHeadingManager.requestPermissions() },
                    setPreference: { gameState.isUploadLocationEnabled = $0 },
                    deniedInstructions: "Location access was denied. On your Watch, open Settings \u{2192} Privacy & Security \u{2192} Location Services \u{2192} RadarMap, or manage it from the Watch app on your iPhone."
                )
            }
        )) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text("Location")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundColor(isConnected ? .gray : .primary)
        .opacity(isConnected ? 0.6 : 1.0)
        .disabled(isConnected)
    }

    @ViewBuilder
    private var healthDataUploadToggle: some View {
        Toggle(isOn: Binding(
            get: {
                gameState.isUploadHeartRateEnabled && permissionState(for: gameState.healthKitManager.authorizationStatus) == .granted
            },
            set: { enabled in
                handlePermissionBackedToggle(
                    enabled: enabled,
                    currentState: permissionState(for: gameState.healthKitManager.authorizationStatus),
                    requestAccess: { gameState.healthKitManager.requestAuthorization() },
                    setPreference: { gameState.isUploadHeartRateEnabled = $0 },
                    deniedInstructions: "Health access was denied. On your iPhone, open the Health app \u{2192} your profile icon \u{2192} Apps \u{2192} RadarMap, then enable Heart Rate and Workouts."
                )
            }
        )) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                Text("Health data")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundColor(isConnected ? .gray : .primary)
        .opacity(isConnected ? 0.6 : 1.0)
        .disabled(isConnected)
    }

    private enum PermissionState {
        case notDetermined
        case deniedOrRestricted
        case granted
    }

    private func permissionState(for status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .deniedOrRestricted
        default: return .granted
        }
    }

    private func permissionState(for status: HKAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .sharingDenied: return .deniedOrRestricted
        default: return .granted
        }
    }

    private func handlePermissionBackedToggle(
        enabled: Bool,
        currentState: PermissionState,
        requestAccess: () -> Void,
        setPreference: (Bool) -> Void,
        deniedInstructions: String
    ) {
        guard enabled else {
            withAnimation { setPreference(false) }
            return
        }
        switch currentState {
        case .notDetermined:
            // Not yet decided — this is a genuine first-time OS prompt.
            requestAccess()
            withAnimation { setPreference(true) }
        case .deniedOrRestricted:
            // iOS/watchOS will never re-show the system dialog after a denial, so point the
            // user at the one place they can actually flip it back on.
            currentErrorText = deniedInstructions
            showErrorAlert = true
        case .granted:
            withAnimation { setPreference(true) }
        }
    }
    
    @ViewBuilder
    private var paywallRow: some View {
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
    
    @ViewBuilder
    private var hudGuideRow: some View {
        NavigationLink(destination: HUDGuideView()) {
            HStack(spacing: 8) {
                Image(systemName: "book.pages.fill")
                    .foregroundColor(.green)
                Text("HUD Guide")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
    }
    
    @ViewBuilder
    private var policyRow: some View {
        NavigationLink(destination: PolicyView()) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(.cyan)
                Text("Policy")
                    .font(.system(size: 11, weight: .semibold))
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
                            
                            if member.role == .leader {
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

