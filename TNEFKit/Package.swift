// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TNEFKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TNEFKit", targets: ["TNEFKit"]),
        .executable(name: "tnef-extract", targets: ["tnef-extract"]),
    ],
    targets: [
        .target(name: "TNEFKit"),
        .executableTarget(name: "tnef-extract", dependencies: ["TNEFKit"]),
        .testTarget(
            name: "TNEFKitTests",
            dependencies: ["TNEFKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
