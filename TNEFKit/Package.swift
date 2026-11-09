// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TNEFKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TNEFKit", targets: ["TNEFKit"]),
        .library(name: "TNEFRender", targets: ["TNEFRender"]),
        .executable(name: "tnef-extract", targets: ["tnef-extract"]),
        .executable(name: "tnef-render", targets: ["tnef-render"]),
    ],
    targets: [
        .target(name: "TNEFKit"),
        .target(name: "TNEFRender", dependencies: ["TNEFKit"]),
        .executableTarget(name: "tnef-extract", dependencies: ["TNEFKit"]),
        .executableTarget(name: "tnef-render", dependencies: ["TNEFKit", "TNEFRender"]),
        .testTarget(
            name: "TNEFKitTests",
            dependencies: ["TNEFKit", "TNEFRender"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
