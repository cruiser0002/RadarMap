import SwiftUI

/// The "Enter custom URL" row in the Config screen: a normal
/// keyboard-editable text field, an enable toggle that switches between the shared default RTDB
/// and a custom one, and — iOS only — a camera button that reads a URL directly off the Firebase
/// console webpage via live text recognition, so a host never has to turn their own URL into a QR
/// code just to get it into the app. See BRING_YOUR_OWN_FIREBASE.md / the in-app HUD Guide for the
/// end-to-end host setup this supports.
public struct DatabaseURLField: View {
    @Binding var value: String
    /// Off: the field and camera button are grayed out and the shared default RTDB is used. On:
    /// the field/camera are editable and `value` is used (falling back to the default if empty).
    @Binding var isEnabled: Bool
    var isDisabled: Bool
    /// Most-recently-used custom database URLs, newest first (see `GameStateManager.recentDatabaseURLs`).
    var recentURLs: [String]
    /// Called once the field loses focus, i.e. the user is done editing — not on every keystroke.
    /// Callers use this to push the finished value out over WCSession, since syncing on every
    /// character typed would spam the phone/watch connection.
    var onEditingFinished: () -> Void

    public init(value: Binding<String>, isEnabled: Binding<Bool>, isDisabled: Bool = false, recentURLs: [String] = [], onEditingFinished: @escaping () -> Void = {}) {
        self._value = value
        self._isEnabled = isEnabled
        self.isDisabled = isDisabled
        self.recentURLs = recentURLs
        self.onEditingFinished = onEditingFinished
    }

    #if os(iOS)
    @State private var showURLScanner: Bool = false
    #endif
    @FocusState private var isFieldFocused: Bool

    private var isFieldInteractive: Bool { !isDisabled && isEnabled }
    /// True once the user has typed something that isn't a URL Firebase can accept — used to turn
    /// the field red before it's ever submitted, since `Database.database(url:)` traps on garbage
    /// input instead of failing gracefully.
    private var isURLInvalid: Bool {
        isFieldInteractive && !value.isEmpty && !AppConstants.Network.isValidDatabaseURL(value)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                #if os(iOS)
                Button(action: { showURLScanner = true }) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 13))
                        .foregroundColor(isFieldInteractive ? .cyan : .gray)
                }
                .buttonStyle(.plain)
                .disabled(!isFieldInteractive)
                .sheet(isPresented: $showURLScanner) {
                    ScannerSheetView(mode: .url) { scanned in
                        showURLScanner = false
                        value = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
                    } onCancel: {
                        showURLScanner = false
                    }
                }
                #endif

                if isEnabled {
                    TextField("Enter custom URL", text: $value)
                        .font(.system(size: 11))
                        .foregroundColor(isURLInvalid ? .red : (isFieldInteractive ? .primary : .gray))
                        .lineLimit(1)
                        .submitLabel(.done)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .padding(6)
                        .background(isURLInvalid ? Color.red.opacity(0.18) : Color.clear)
                        .cornerRadius(6)
                        .disabled(!isFieldInteractive)
                        .focused($isFieldFocused)
                        .onChange(of: value) { _, newValue in
                            let sanitized = AppConstants.Network.sanitizeInput(newValue)
                            if value != sanitized {
                                value = sanitized
                            }
                        }
                } else {
                    Text("using default server")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle("Custom URL", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isDisabled)
            }

            if isFieldFocused && isFieldInteractive && !recentURLs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recentURLs, id: \.self) { url in
                        Button(action: {
                            value = url
                            isFieldFocused = false
                        }) {
                            Text(url)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        if url != recentURLs.last {
                            Divider()
                        }
                    }
                }
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
            }
        }
        .opacity(isDisabled ? 0.6 : 1.0)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                isFieldFocused = false
            }
        }
        .onChange(of: isFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                onEditingFinished()
            }
        }
    }
}
