// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kidicom",
    platforms: [.macOS(.v26)],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "KidicomKit", dependencies: ["COpenJPEG"]),
        // JPEG 2000 decoder (OpenJPEG 2.5.3, BSD 2-clause), vendored.
        .target(
            name: "COpenJPEG",
            exclude: ["LICENSE", "README.md"],
            cSettings: [.define("MUTEX_pthread", to: "1"), .unsafeFlags(["-w"])]
        ),
        .executableTarget(
            name: "Kidicom",
            dependencies: ["KidicomKit"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "KidicomKitTests", dependencies: ["KidicomKit"]),
    ]
)
