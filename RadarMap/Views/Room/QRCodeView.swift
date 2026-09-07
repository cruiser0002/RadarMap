import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
// The QRCode package is used instead of raw CoreImage because CoreImage's QR generator filter
// isn't resolvable on watchOS in this project's toolchain (verified directly — even a plain
// `import CoreImage` fails to resolve for the watchOS target). QRCode uses CoreImage where
// available and falls back to its own pure-Swift generator on watchOS, so this same call works
// on every platform. A host wearing just their Watch can still show this on-screen for a
// teammate's phone camera to scan (see JoinQRBox.swift) — watchOS has no camera of its own to
// scan back with, so only the display side, never the scanner, is available there.
import QRCode

/// Renders a string (a `QRJoinPayload.encodedString()`) as a scannable QR code image.
public struct QRCodeView: View, Equatable {
    private let content: String
    // Regenerating a QR bitmap is real CPU work, and this view's body re-evaluates on every
    // re-render of whatever parent hosts it — which, since that parent observes the whole
    // GameStateManager, happens on any published change at all (health, member positions,
    // telemetry...), not just when `content` itself changes. Caching in state and only
    // recomputing via `.task(id: content)` (which only restarts when `content` actually
    // changes) means the image is generated once per distinct payload, not continuously.
    @State private var image: CGImage?

    public init(content: String) {
        self.content = content
    }

    // Lets `.equatable()` at the call site skip re-rendering this view (and its cached `image`)
    // whenever the parent re-renders for unrelated reasons (see JoinQRBox.swift) but `content`
    // itself hasn't changed.
    public static func == (lhs: QRCodeView, rhs: QRCodeView) -> Bool {
        lhs.content == rhs.content
    }

    public var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: content) {
            image = QRCodeView.generate(from: content)
        }
    }

    private static func generate(from string: String) -> CGImage? {
        // "M" (15% recovery) matches what this displayed at before switching off raw CoreImage,
        // rather than the QRCode package's own higher-recovery default — recovery capacity
        // trades directly against data capacity per QR version, and higher recovery than needed
        // just makes an already-small payload (room name + pin + database URL, all short,
        // user-typed text field values — see JoinQRBox.swift) denser than it needs to be.
        guard let cgImage = try? QRCode.build
            .text(string)
            .errorCorrection(.medium)
            .generate.image(dimension: 600)
        else { return nil }
        return cgImage
    }
}
