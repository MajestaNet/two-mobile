// swift-tools-version: 5.9
import PackageDescription

// Shared by TwoPhone and TwoWatch. URLSession and Security.framework only.
// Licensed under the Apache License, Version 2.0. See LICENSE and NOTICE.
// macOS is the host for offline URLProtocol tests on this mini, not a third app.
let package = Package(
    name: "TwoClient",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TwoClient", targets: ["TwoClient"]),
    ],
    targets: [
        .target(
            name: "TwoClient",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "TwoClientTests",
            dependencies: ["TwoClient"]
        ),
    ]
)
