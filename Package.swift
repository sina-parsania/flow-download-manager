// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// First-party module graph for Download Manager. The Xcode project
// (DownloadManager.xcodeproj) hosts only the app + agent executables and the test
// bundles; all reusable modules live here so SwiftPM resolves GRDB (and its
// internal GRDBSQLite C module) correctly. See Documentation/adr/0001-build-system.md.
//
// Targets are added as their sources land per slice; SwiftPM requires each declared
// target to contain at least one source file.

// First-party targets build in Swift 6 language mode (complete strict concurrency)
// with warnings as errors. `unsafeFlags` is permitted because this is a local
// (path) package, never consumed by a versioned dependent.
let strict: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"]),
]

let package = Package(
    name: "DownloadKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "XPCContracts", targets: ["XPCContracts"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "SharedObservability", targets: ["SharedObservability"]),
        .library(name: "SharedSecurity", targets: ["SharedSecurity"]),
        .library(name: "EngineAgent", targets: ["EngineAgent"]),
        .library(name: "Presentation", targets: ["Presentation"]),
        .library(name: "TestFaultService", targets: ["TestFaultService"]),
        .executable(name: "test-services", targets: ["test-services"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        // Objective-C SPI shim isolating NSXPCConnection.auditToken.
        .target(
            name: "XPCSecuritySupport",
            path: "Sources/XPCSecuritySupport",
            publicHeadersPath: "include"
        ),

        .target(name: "Domain", path: "Sources/Domain", swiftSettings: strict),

        .target(name: "SharedObservability", path: "Sources/SharedObservability", swiftSettings: strict),

        .target(name: "SharedSecurity", path: "Sources/SharedSecurity", swiftSettings: strict),

        .target(
            name: "XPCContracts",
            dependencies: ["Domain"],
            path: "Sources/XPCContracts",
            swiftSettings: strict
        ),

        .target(
            name: "Persistence",
            dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Persistence",
            swiftSettings: strict
        ),

        .target(
            name: "EngineAgent",
            dependencies: [
                "Domain", "Persistence", "XPCContracts",
                "SharedObservability", "XPCSecuritySupport",
            ],
            path: "Sources/EngineAgent",
            swiftSettings: strict
        ),

        .target(
            name: "Presentation",
            dependencies: ["Domain", "XPCContracts", "SharedObservability"],
            path: "Sources/Presentation",
            swiftSettings: strict
        ),

        // Deterministic loopback fault services for integration tests.
        .target(name: "TestFaultService", path: "Sources/TestFaultService", swiftSettings: strict),
        .executableTarget(
            name: "test-services",
            dependencies: ["TestFaultService"],
            path: "Sources/TestServicesMain",
            swiftSettings: strict
        ),
    ]
)
