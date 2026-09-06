import SwiftUI

/// The box below the database URL field: while hosting *or already joined as a client*, it
/// displays this squad's join QR code (room + PIN + database URL) so any member can hand a
/// teammate a no-friction join code. Otherwise it shows a QR icon in the same size/shape and acts
/// as a tap target that opens the camera to scan *another* squad's QR code, filling in the fields
/// a caller cares about via `onScannedJoinPayload`. See BRING_YOUR_OWN_FIREBASE.md / the in-app HUD Guide.
public struct JoinQRBox: View {
    /// True once connected to a room (hosting or joined) — despite the name, this is not
    /// host-exclusive; see the type doc above.
    var isHosting: Bool
    var roomId: String?
    var pin: String?
    /// The host's *raw* custom database URL setting, not the resolved one — pass "" when hosting
    /// on the shared default so the encoded QR's `d` field is empty too. A joiner scanning an
    /// empty `d` gets no explicit override and falls back to their own default resolution (see
    /// `GameStateManager.applyDatabaseURL`), rather than the literal shared URL being embedded
    /// and handed out to everyone who scans a default-project host's code.
    var databaseURL: String
    var isDisabled: Bool
    var onScannedJoinPayload: (QRJoinPayload) -> Void

    public init(
        isHosting: Bool,
        roomId: String?,
        pin: String?,
        databaseURL: String,
        isDisabled: Bool = false,
        onScannedJoinPayload: @escaping (QRJoinPayload) -> Void
    ) {
        self.isHosting = isHosting
        self.roomId = roomId
        self.pin = pin
        self.databaseURL = databaseURL
        self.isDisabled = isDisabled
        self.onScannedJoinPayload = onScannedJoinPayload
    }

    #if os(iOS)
    @State private var showScanner: Bool = false
    #endif

    #if os(watchOS)
    private static let boxSide: CGFloat = 120
    #else
    private static let boxSide: CGFloat = 160
    #endif

    public var body: some View {
        VStack(spacing: 6) {
            Text("SCAN TO JOIN")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.gray)
            boxContent
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var boxContent: some View {
        if isHosting, let roomId {
            // Display works on watchOS too (see QRCodeView.swift) — a teammate can scan the
            // Watch's screen with their phone even though the Watch itself has no camera to
            // scan back with, which is why only this display branch, never the scan-to-join
            // button below, is available there.
            if let payload = QRJoinPayload(roomName: roomId, pin: pin, databaseURL: databaseURL).encodedString() {
                QRCodeView(content: payload)
                    .equatable()
                    .frame(width: Self.boxSide, height: Self.boxSide)
            }
        } else {
            #if os(iOS)
            Button(action: { showScanner = true }) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: Self.boxSide, height: Self.boxSide)
                    .overlay(
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 48))
                            .foregroundColor(.cyan)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1.0)
            .sheet(isPresented: $showScanner) {
                ScannerSheetView(mode: .qrCode) { scanned in
                    showScanner = false
                    if let payload = QRJoinPayload.decode(scanned) {
                        onScannedJoinPayload(payload)
                    }
                } onCancel: {
                    showScanner = false
                }
            }
            #endif
        }
    }
}
