// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppPowerDistributor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AppPowerDistributor", targets: ["AppPowerDistributor"]),
        .executable(name: "apd", targets: ["apd"]),
        .executable(name: "power-burn", targets: ["power-burn"]),
        .library(name: "PowerKit", targets: ["PowerKit"]),
    ],
    targets: [
        .target(
            name: "CProbes",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "PowerKit", dependencies: ["CProbes"]),
        .executableTarget(name: "apd", dependencies: ["PowerKit"]),
        .executableTarget(name: "AppPowerDistributor", dependencies: ["PowerKit"]),
        .executableTarget(name: "power-burn", linkerSettings: [.linkedFramework("Metal")]),
        // power-burn is a dependency so it's built first: the tests throttle a copy of it.
        .testTarget(name: "PowerKitTests", dependencies: ["PowerKit", "power-burn"]),
    ]
)
