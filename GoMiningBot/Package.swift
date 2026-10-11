// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoMiningBot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GoMiningCore", targets: ["GoMiningCore"]),
        .executable(name: "GoMiningBot", targets: ["GoMiningBot"]),
    ],
    targets: [
        // Plattformneutrale Logik: Modelle, Engine, Backtest, Statistik, Persistenz, Parser.
        .target(name: "GoMiningCore"),
        // SwiftUI-App (nur macOS): Netzwerk, Schluesselbund, Oberflaeche.
        .executableTarget(name: "GoMiningBot", dependencies: ["GoMiningCore"]),
        .testTarget(name: "GoMiningCoreTests", dependencies: ["GoMiningCore"]),
    ]
)
