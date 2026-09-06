// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RadarMap",
    platforms: [
        .watchOS(.v10),
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "RadarMap",
            targets: ["RadarMap"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", "12.0.0"..<"13.0.0"),
        // Core Image's QR generator filter isn't resolvable on watchOS in this project's
        // toolchain (verified directly — even a plain `import CoreImage` fails to resolve for
        // the watchOS target). QRCode ships its own pure-Swift generator for watchOS instead of
        // relying on Core Image there, while still using Core Image on platforms that have it.
        .package(url: "https://github.com/dagronf/QRCode.git", from: "20.0.0"),
    ],
    targets: [
        .target(
            name: "RadarMap",
            dependencies: [
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseDatabase", package: "firebase-ios-sdk"),
                .product(name: "QRCode", package: "QRCode"),
            ],
            path: "RadarMap",
            exclude: [
                "Resources/Info.plist",
                "Resources/GoogleService-Info.plist",
                "Resources/RadarMap.storekit"
            ]
        ),
        .testTarget(
            name: "RadarMapTests",
            dependencies: ["RadarMap"],
            path: "RadarMapTests"
        ),
    ]
)
