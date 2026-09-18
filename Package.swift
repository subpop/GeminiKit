// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GeminiKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "GeminiKit", targets: ["GeminiKit"]),
        .executable(name: "gemini", targets: ["Gemini"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "GeminiKit",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Sources/GeminiKit"
        ),
        .executableTarget(
            name: "Gemini",
            dependencies: [
                "GeminiKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Gemini"
        ),
        .testTarget(
            name: "GeminiKitTests",
            dependencies: [
                "GeminiKit",
                "Gemini",
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Tests/GeminiKitTests"
        ),
    ]
)
