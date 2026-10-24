// swift-tools-version:5.9
import PackageDescription

/// The wire protocol is compiled into both apps and, here, into a testable
/// library. Keeping framing and message types in one place is what lets the
/// host and client be verified independently of the UI.
let package = Package(
    name: "OrielProtocol",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OrielProtocol", targets: ["OrielProtocol"])
    ],
    targets: [
        .target(name: "OrielProtocol", path: "Shared"),
        .testTarget(name: "OrielProtocolTests", dependencies: ["OrielProtocol"], path: "Tests")
    ]
)
