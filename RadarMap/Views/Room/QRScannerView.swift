import SwiftUI

#if os(iOS)
import VisionKit

/// Full-screen camera scanner wrapping VisionKit's `DataScannerViewController` (iOS 16+) rather
/// than hand-rolling AVFoundation capture — see CLOUD_DATA_MANAGEMENT.md's general preference for
/// system components over reimplemented plumbing. Calls `onScan` at most once per presentation,
/// with the raw scanned string.
public struct QRScannerView: UIViewControllerRepresentable {
    /// What to look for: a host's join QR code (barcode), or a bare database URL recognized via
    /// live text/OCR — e.g. pointed at the URL shown on the Firebase console website, so a host
    /// never has to turn their own URL into a QR code just to get it into the app.
    public enum Mode {
        case qrCode
        case url
    }

    public var mode: Mode
    public var onScan: (String) -> Void

    public init(mode: Mode = .qrCode, onScan: @escaping (String) -> Void) {
        self.mode = mode
        self.onScan = onScan
    }

    public func makeUIViewController(context: Context) -> DataScannerViewController {
        let dataTypes: Set<DataScannerViewController.RecognizedDataType>
        switch mode {
        case .qrCode:
            dataTypes = [.barcode(symbologies: [.qr])]
        case .url:
            dataTypes = [.text(textContentType: .URL)]
        }
        let controller = DataScannerViewController(
            recognizedDataTypes: dataTypes,
            qualityLevel: .balanced,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    public func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    public static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        public func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didScan else { return }
            for item in addedItems {
                switch item {
                case .barcode(let barcode):
                    if let payload = barcode.payloadStringValue {
                        didScan = true
                        onScan(payload)
                    }
                case .text(let text):
                    didScan = true
                    onScan(text.transcript)
                @unknown default:
                    continue
                }
                if didScan { break }
            }
        }
    }

    /// Whether this device/OS combination can actually run the scanner, so callers can show a
    /// fallback (e.g. manual entry) instead of presenting a controller that will do nothing.
    public static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

/// `QRScannerView` plus a visible close button, since the bare `DataScannerViewController` has no
/// chrome of its own and a sheet presenting it has no nav bar to put a Cancel button on — without
/// this, the only way out is an undiscoverable swipe-to-dismiss. Use this (not `QRScannerView`
/// directly) wherever the scanner is presented in a `.sheet`.
public struct ScannerSheetView: View {
    var mode: QRScannerView.Mode
    var onScan: (String) -> Void
    var onCancel: () -> Void

    public init(mode: QRScannerView.Mode = .qrCode, onScan: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.mode = mode
        self.onScan = onScan
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView(mode: mode, onScan: onScan)
                .ignoresSafeArea()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .padding()
        }
    }
}
#endif
