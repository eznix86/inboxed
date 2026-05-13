// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Inboxed",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Inboxed", targets: ["Inboxed"])
    ],
    targets: [
        .executableTarget(
            name: "Inboxed",
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
