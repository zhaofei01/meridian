// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Meridian",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Meridian", targets: ["MeridianApp"]),
        .executable(name: "MeridianChecks", targets: ["MeridianChecks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(
            name: "MeridianCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .target(
            name: "MeridianVM",
            dependencies: ["MeridianCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "MeridianApp",
            dependencies: ["MeridianCore", "MeridianVM", "SwiftTerm"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "MeridianChecks",
            dependencies: ["MeridianCore"],
            path: "Sources/MeridianChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
